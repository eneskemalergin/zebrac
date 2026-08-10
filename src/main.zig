//! Spawn commands, collect samples, print stats or JSON.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const process = std.process;
const PERF = std.os.linux.PERF;
const fd_t = std.posix.fd_t;
const progress = @import("progress.zig");
const argv_parse = @import("argv_parse.zig");
const help = @import("help.zig");

const max_stderr_bytes = 1024 * 1024;
const stream_io_buf_len: usize = 1024;
const json_file_buf_len: usize = 4096;
const stderr_pipe_read_scratch: usize = 4096;
const max_stderr_drain_per_poll: usize = max_stderr_bytes + stderr_pipe_read_scratch;
const default_json_output_path = "zebrac-results.json";
const default_duration_ms: u64 = 5000;
const default_min_samples: u64 = 5;
const default_warmup: usize = 3;
const perf_ioctl_skip_limit_min: u32 = 32;
const perf_ioctl_skip_limit_max: u32 = 1024;
const perf_read_total_time_enabled: u64 = 1 << 0;
const perf_read_total_time_running: u64 = 1 << 1;
var sigchld_notification_fd: std.atomic.Value(fd_t) = .init(-1);

const DontForkMapping = struct {
    memory: []align(std.heap.page_size_min) u8,

    const SizeError = error{
        EmptyMapping,
        MappingSizeOverflow,
    };

    fn roundedLength(byte_len: usize) SizeError!usize {
        if (byte_len == 0) return error.EmptyMapping;
        const page_size = std.heap.pageSize();
        const padded = std.math.add(usize, byte_len, page_size - 1) catch
            return error.MappingSizeOverflow;
        return padded & ~(page_size - 1);
    }

    fn mapAnonymous(_: void, byte_len: usize) std.posix.MMapError![]align(std.heap.page_size_min) u8 {
        return std.posix.mmap(
            null,
            byte_len,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
    }

    fn applyDontFork(
        _: void,
        memory: []align(std.heap.page_size_min) u8,
    ) std.posix.MadviseError!void {
        try std.posix.madvise(memory.ptr, memory.len, std.os.linux.MADV.DONTFORK);
    }

    fn unmap(_: void, memory: []align(std.heap.page_size_min) u8) void {
        std.posix.munmap(memory);
    }

    fn initWith(
        byte_len: usize,
        context: anytype,
        comptime map_fn: anytype,
        comptime advise_fn: anytype,
        comptime unmap_fn: anytype,
    ) !DontForkMapping {
        const mapped_len = try roundedLength(byte_len);
        const memory = try map_fn(context, mapped_len);
        errdefer unmap_fn(context, memory);

        // The child must never inherit a page from this mapping. Apply the
        // advice before the parent writes any collection data into it.
        try advise_fn(context, memory);
        return .{ .memory = memory };
    }

    fn init(byte_len: usize) !DontForkMapping {
        return initWith(byte_len, {}, mapAnonymous, applyDontFork, unmap);
    }

    fn deinit(self: *DontForkMapping) void {
        std.posix.munmap(self.memory);
        self.* = undefined;
    }
};

const CollectionStorage = struct {
    samples: DontForkMapping,
    failure_capture: ?DontForkMapping,
    command_count: usize,
    max_samples: usize,

    const SizeError = error{CollectionSizeOverflow};

    fn checkedBytes(item_count: usize, item_size: usize) SizeError!usize {
        return std.math.mul(usize, item_count, item_size) catch
            error.CollectionSizeOverflow;
    }

    fn init(command_count: usize, max_samples_u64: u64, allow_failures: bool) !CollectionStorage {
        const max_samples = std.math.cast(usize, max_samples_u64) orelse
            return error.CollectionSizeOverflow;
        const sample_slots = std.math.mul(usize, command_count, max_samples) catch
            return error.CollectionSizeOverflow;
        const sample_bytes = try checkedBytes(sample_slots, @sizeOf(Sample));

        var samples = try DontForkMapping.init(sample_bytes);
        errdefer samples.deinit();

        var failure_capture: ?DontForkMapping = null;
        if (allow_failures) {
            // Each command can retain its first failure. One final slot is
            // shared scratch after a command has retained that text.
            const capture_slots = std.math.add(usize, command_count, 1) catch
                return error.CollectionSizeOverflow;
            const capture_bytes = try checkedBytes(capture_slots, max_stderr_bytes);
            failure_capture = try DontForkMapping.init(capture_bytes);
        }

        return .{
            .samples = samples,
            .failure_capture = failure_capture,
            .command_count = command_count,
            .max_samples = max_samples,
        };
    }

    fn deinit(self: *CollectionStorage) void {
        if (self.failure_capture) |*mapping| mapping.deinit();
        self.samples.deinit();
        self.* = undefined;
    }

    fn samplesFor(self: *CollectionStorage, command_index: usize) []Sample {
        std.debug.assert(command_index < self.command_count);
        const all_samples: [*]Sample = @ptrCast(@alignCast(self.samples.memory.ptr));
        const start = command_index * self.max_samples;
        return all_samples[start..][0..self.max_samples];
    }

    fn failureBuffersFor(
        self: *CollectionStorage,
        command_index: usize,
    ) struct { first: StderrCaptureBuf, second: StderrCaptureBuf } {
        std.debug.assert(command_index < self.command_count);
        const mapping = &self.failure_capture.?;
        const start = command_index * max_stderr_bytes;
        const spare_start = self.command_count * max_stderr_bytes;
        return .{
            .first = .{ .storage = mapping.memory[start..][0..max_stderr_bytes] },
            .second = .{ .storage = mapping.memory[spare_start..][0..max_stderr_bytes] },
        };
    }
};

const PerfMeasurement = struct {
    name: []const u8,
    config: PERF.COUNT.HW,
};

const perf_measurements = [_]PerfMeasurement{
    .{ .name = "cpu_cycles", .config = PERF.COUNT.HW.CPU_CYCLES },
    .{ .name = "instructions", .config = PERF.COUNT.HW.INSTRUCTIONS },
    .{ .name = "cache_references", .config = PERF.COUNT.HW.CACHE_REFERENCES },
    .{ .name = "cache_misses", .config = PERF.COUNT.HW.CACHE_MISSES },
    .{ .name = "branch_misses", .config = PERF.COUNT.HW.BRANCH_MISSES },
};

const Command = struct {
    raw_cmd: []const u8,
    argv: []const []const u8,
    measurements: Measurements,
    samples: []Sample = &.{},
    sample_count: usize = 0,
    failed_sample_count: u64,
    stderr_capture: ?StderrCaptureBuf = null,
    stderr_capture_spare: ?StderrCaptureBuf = null,
    first_failure_sample: ?usize = null,
    first_failure_exit_code: u8 = 0,
    first_failure_stderr: ?StderrCapture = null,
    perf_setup_skip_count: u32 = 0,
    perf_setup_first_error: ?PerfSampleResetError = null,

    const Measurements = struct {
        wall_time: Measurement,
        peak_rss: Measurement,
        minor_faults: Measurement,
        major_faults: Measurement,
        cpu_cycles: Measurement,
        instructions: Measurement,
        cache_references: Measurement,
        cache_misses: Measurement,
        branch_misses: Measurement,
    };
};

const Sample = struct {
    wall_time: u64,
    peak_rss: u64,
    minor_faults: u64,
    major_faults: u64,
    cpu_cycles: u64,
    instructions: u64,
    cache_references: u64,
    cache_misses: u64,
    branch_misses: u64,

    fn lessThanContext(comptime field: []const u8) type {
        return struct {
            fn lessThan(
                _: void,
                lhs: Sample,
                rhs: Sample,
            ) bool {
                return @field(lhs, field) < @field(rhs, field);
            }
        };
    }
};

const ColorMode = enum {
    auto,
    never,
    ansi,
};

const sep_mean: []const u8 = " ± ";
const sep_minmax: []const u8 = " … ";
const row_indent: usize = 2;
const col_gap: usize = 2;

const TableLayout = struct {
    name_w: usize,
    mean_w: usize,
    std_w: usize,
    min_w: usize,
    max_w: usize,
    outlier_w: usize,
    delta_w: usize,

    fn compute(
        measurements: Command.Measurements,
        baseline: ?Command.Measurements,
        with_delta: bool,
        show_major_faults: bool,
        all_commands_have_two_samples: bool,
    ) TableLayout {
        var layout: TableLayout = .{
            .name_w = row_indent + visibleLen("measurement"),
            .mean_w = visibleLen("mean"),
            .std_w = visibleLen("σ"),
            .min_w = visibleLen("min"),
            .max_w = visibleLen("max"),
            .outlier_w = visibleLen("outliers"),
            .delta_w = if (with_delta) visibleLen("delta") else 0,
        };
        var unit_buf: [32]u8 = undefined;
        var outlier_buf: [32]u8 = undefined;
        var delta_buf: [64]u8 = undefined;

        inline for (@typeInfo(Command.Measurements).@"struct".fields) |field| {
            const m = @field(measurements, field.name);
            const meta = measurementFieldMeta(field.name);
            if (!meta.hide_when_all_commands_are_zero or show_major_faults) {
                layout.name_w = @max(layout.name_w, row_indent + field.name.len);
                layout.mean_w = @max(layout.mean_w, measureUnit(&unit_buf, m.mean, m.unit));
                layout.std_w = @max(layout.std_w, measureUnit(&unit_buf, m.std_dev, m.unit));
                layout.min_w = @max(layout.min_w, measureUnit(&unit_buf, @floatFromInt(m.min), m.unit));
                layout.max_w = @max(layout.max_w, measureUnit(&unit_buf, @floatFromInt(m.max), m.unit));
                layout.outlier_w = @max(
                    layout.outlier_w,
                    measureOutlier(&outlier_buf, m.outlier_count, m.sample_count),
                );
                if (with_delta) {
                    const first_m = if (baseline) |b| @field(b, field.name) else null;
                    layout.delta_w = @max(layout.delta_w, measureDelta(
                        &delta_buf,
                        m,
                        first_m,
                        all_commands_have_two_samples,
                    ));
                }
            }
        }
        return layout;
    }

    fn meanSepVis(self: TableLayout) usize {
        return self.name_w + col_gap + self.mean_w;
    }

    fn stdColEndVis(self: TableLayout) usize {
        return self.name_w + col_gap + self.mean_w + visibleLen(sep_mean) + self.std_w;
    }

    fn minSepVis(self: TableLayout) usize {
        return self.stdColEndVis() + col_gap + self.min_w;
    }

    fn minMaxColEndVis(self: TableLayout) usize {
        return self.minSepVis() + visibleLen(sep_minmax) + self.max_w;
    }

    fn outlierStartVis(self: TableLayout) usize {
        return self.minMaxColEndVis() + col_gap;
    }

    fn deltaStartVis(self: TableLayout) usize {
        return self.outlierStartVis() + self.outlier_w + col_gap;
    }

    fn padVis(w: *Io.Writer, vis: *usize, target: usize) !void {
        if (target > vis.*) {
            try w.splatByteAll(' ', target - vis.*);
            vis.* = target;
        }
    }

    fn gap(w: *Io.Writer, vis: *usize) !void {
        try padVis(w, vis, vis.* + col_gap);
    }

    fn printStyledLabel(w: *Io.Writer, t: Io.Terminal, label: []const u8, colors: []const Io.Terminal.Color) !void {
        for (colors) |c| try t.setColor(c);
        try w.writeAll(label);
        try t.setColor(.reset);
    }

    fn printHeader(w: *Io.Writer, t: Io.Terminal, layout: TableLayout, with_delta: bool) !void {
        var vis: usize = 0;
        try w.splatByteAll(' ', row_indent);
        try w.writeAll("measurement");
        vis = row_indent + "measurement".len;
        try padVis(w, &vis, layout.name_w);

        try gap(w, &vis);
        try padVis(w, &vis, layout.meanSepVis() - "mean".len);
        try printStyledLabel(w, t, "mean", &.{.bright_green});
        vis = layout.meanSepVis();
        try t.setColor(.bold);
        try w.writeAll(sep_mean);
        try t.setColor(.reset);
        vis += visibleLen(sep_mean);
        try printStyledLabel(w, t, "σ", &.{.green});
        vis += visibleLen("σ");
        try padVis(w, &vis, layout.stdColEndVis());

        try gap(w, &vis);
        try padVis(w, &vis, layout.minSepVis() - "min".len);
        try printStyledLabel(w, t, "min", &.{ .bold, .cyan });
        vis = layout.minSepVis();
        try t.setColor(.bold);
        try w.writeAll(sep_minmax);
        try t.setColor(.reset);
        try printStyledLabel(w, t, "max", &.{.magenta});
        vis = layout.minSepVis() + visibleLen(sep_minmax) + "max".len;
        try padVis(w, &vis, layout.minMaxColEndVis());

        try gap(w, &vis);
        try padVis(w, &vis, layout.outlierStartVis());
        try printStyledLabel(w, t, "outliers", &.{ .bold, .bright_yellow });
        vis = layout.outlierStartVis() + "outliers".len;
        try padVis(w, &vis, layout.outlierStartVis() + layout.outlier_w);

        if (with_delta) {
            try gap(w, &vis);
            try padVis(w, &vis, layout.deltaStartVis());
            try printStyledLabel(w, t, "delta", &.{.bold});
        }
        try w.writeAll("\n");
    }
};

fn visibleLen(s: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8CodepointSequenceLength(s[i]) catch 1;
        n += 1;
        i += len;
    }
    return n;
}

const plain_unit_suffix = "";
const UnitScaled = struct {
    val: f64,
    suffix: []const u8,
};

const ScaleThreshold = struct {
    min: f64,
    div: f64,
    ns_suffix: []const u8 = "",
    count_suffix: []const u8 = "",
    byte_suffix: []const u8 = "",
};

fn unitScaleMin(div: f64) f64 {
    return div - div / 2000.0;
}

const ns_unit_thresholds = [_]ScaleThreshold{
    .{ .min = unitScaleMin(3600.0 * 1_000_000_000), .div = 3600.0 * 1_000_000_000, .ns_suffix = "h" },
    .{ .min = unitScaleMin(60.0 * 1_000_000_000), .div = 60.0 * 1_000_000_000, .ns_suffix = "m" },
    .{ .min = unitScaleMin(1_000_000_000.0), .div = 1_000_000_000.0, .ns_suffix = "s" },
    .{ .min = unitScaleMin(1_000_000.0), .div = 1_000_000.0, .ns_suffix = "ms" },
    .{ .min = 1_000.0, .div = 1_000.0, .ns_suffix = "µs" },
};

const qty_unit_thresholds = [_]ScaleThreshold{
    .{ .min = unitScaleMin(1_000_000_000_000.0), .div = 1_000_000_000_000.0, .count_suffix = "T", .byte_suffix = "TB" },
    .{ .min = unitScaleMin(1_000_000_000.0), .div = 1_000_000_000.0, .count_suffix = "G", .byte_suffix = "GB" },
    .{ .min = unitScaleMin(1_000_000.0), .div = 1_000_000.0, .count_suffix = "M", .byte_suffix = "MB" },
    .{ .min = 1_000.0, .div = 1_000.0, .count_suffix = "K", .byte_suffix = "KB" },
};

fn scaleUnit(x: f64, unit: Measurement.Unit) UnitScaled {
    if (unit == .nanoseconds) {
        for (ns_unit_thresholds) |t| {
            if (x >= t.min) return .{ .val = x / t.div, .suffix = t.ns_suffix };
        }
        return .{ .val = x, .suffix = "ns" };
    }
    for (qty_unit_thresholds) |t| {
        if (x >= t.min) return .{
            .val = x / t.div,
            .suffix = switch (unit) {
                .count => t.count_suffix,
                .bytes => t.byte_suffix,
                .nanoseconds => unreachable,
            },
        };
    }
    return .{
        .val = x,
        .suffix = plain_unit_suffix,
    };
}

fn measureScaledValueVis(buf: *[32]u8, value: f64) usize {
    var fbs = std.Io.Writer.fixed(buf);
    printNum3SigFigs(&fbs, value) catch return 0;
    return visibleLen(fbs.buffered());
}

fn measureUnit(buf: *[32]u8, x: f64, unit: Measurement.Unit) usize {
    const s = scaleUnit(x, unit);
    return measureScaledValueVis(buf, s.val) + visibleLen(s.suffix);
}

fn measureOutlier(buf: *[32]u8, count: u64, sample_count: u64) usize {
    const line = formatOutlierLine(buf, count, sample_count) catch return 0;
    return visibleLen(line);
}

const delta_baseline_epsilon: f64 = 1e-9;

const MeasurementFieldMeta = struct {
    unit: Measurement.Unit,
    hide_when_all_commands_are_zero: bool = false,
};

fn measurementFieldMeta(comptime field_name: []const u8) MeasurementFieldMeta {
    if (comptime std.mem.eql(u8, field_name, "wall_time"))
        return .{ .unit = .nanoseconds };
    if (comptime std.mem.eql(u8, field_name, "peak_rss"))
        return .{ .unit = .bytes };
    if (comptime std.mem.eql(u8, field_name, "major_faults"))
        return .{ .unit = .count, .hide_when_all_commands_are_zero = true };
    return .{ .unit = .count };
}

fn formatOutlierLine(buf: *[32]u8, count: u64, sample_count: u64) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    if (sample_count == 0) {
        try w.print("{d} (n/a)", .{count});
        return w.buffered();
    }
    const pct = metricOutlierRatePercent(count, sample_count);
    try w.print("{d} ({d:.0}%)", .{ count, pct });
    return w.buffered();
}

const SampleResourceUsage = struct {
    peak_rss: u64,
    minor_faults: u64,
    major_faults: u64,
};

const X86KernelTimeval = extern struct {
    sec: i32,
    usec: i32,
};

const X86KernelRusage = extern struct {
    utime: X86KernelTimeval,
    stime: X86KernelTimeval,
    maxrss: i32,
    ixrss: i32,
    idrss: i32,
    isrss: i32,
    minflt: i32,
    majflt: i32,
    nswap: i32,
    inblock: i32,
    oublock: i32,
    msgsnd: i32,
    msgrcv: i32,
    nsignals: i32,
    nvcsw: i32,
    nivcsw: i32,
};

comptime {
    if (@sizeOf(X86KernelRusage) != 72 or
        @offsetOf(X86KernelRusage, "maxrss") != 16 or
        @offsetOf(X86KernelRusage, "minflt") != 32)
    {
        @compileError("unexpected i386 kernel rusage layout");
    }
}

fn sampleResourceUsage(rus: process.Child.ResourceUsageStatistics) error{MissingResourceUsage}!SampleResourceUsage {
    const ru = rus.rusage orelse return error.MissingResourceUsage;
    if (builtin.cpu.arch == .x86) {
        // Linux i386 wait4 writes two 32-bit values in each timeval. Zig
        // 0.16's typed rusage uses a 64-bit usec field, which moves these
        // fields. Read the bytes written by the kernel with the i386 layout.
        const x86_ru: *const X86KernelRusage = @ptrCast(&ru);
        const peak_rss_kib: u64 = @intCast(@max(x86_ru.maxrss, 0));
        return .{
            .peak_rss = peak_rss_kib * 1024,
            .minor_faults = @intCast(@max(x86_ru.minflt, 0)),
            .major_faults = @intCast(@max(x86_ru.majflt, 0)),
        };
    }
    return .{
        .peak_rss = @intCast(rus.getMaxRss().?),
        .minor_faults = @intCast(@max(ru.minflt, 0)),
        .major_faults = @intCast(@max(ru.majflt, 0)),
    };
}

fn measureDelta(
    buf: *[64]u8,
    m: Measurement,
    first_m: ?Measurement,
    all_commands_have_two_samples: bool,
) usize {
    var w = std.Io.Writer.fixed(buf);
    writeDeltaPlain(&w, m, first_m, all_commands_have_two_samples) catch return 0;
    return visibleLen(w.buffered());
}

fn writeDeltaPlain(
    w: *Io.Writer,
    m: Measurement,
    first_m: ?Measurement,
    all_commands_have_two_samples: bool,
) !void {
    if (!all_commands_have_two_samples) {
        try w.writeAll("n/a");
        return;
    }
    if (first_m == null) {
        if (@abs(m.mean) < delta_baseline_epsilon) {
            try w.writeAll("n/a");
        } else {
            try w.writeAll("0%");
        }
        return;
    }
    const f = first_m.?;
    if (@abs(f.mean) < delta_baseline_epsilon) {
        try w.writeAll("n/a");
        return;
    }
    const diff_mean_percent = (m.mean - f.mean) * 100 / f.mean;
    var magnitude_buf: [64]u8 = undefined;
    var magnitude_writer = Io.Writer.fixed(&magnitude_buf);
    try magnitude_writer.print("{d:.1}", .{@abs(diff_mean_percent)});
    const magnitude = magnitude_writer.buffered();
    if (std.mem.eql(u8, magnitude, "0.0")) {
        try w.writeAll("0%");
        return;
    }
    const sign: u8 = if (diff_mean_percent > 0) '+' else '-';
    try w.print("{c}{s}%", .{ sign, magnitude });
}

const UnitAlign = enum { left, right };

fn printScaledUnit(
    terminal: Io.Terminal,
    w: *Io.Writer,
    s: UnitScaled,
    color: Io.Terminal.Color,
    color_enabled: bool,
) !void {
    try terminal.setColor(color);
    try printNum3SigFigs(w, s.val);
    if (color_enabled) try terminal.setColor(.dim);
    try w.writeAll(s.suffix);
    try terminal.setColor(.reset);
}

fn writeUnitAligned(
    terminal: Io.Terminal,
    w: *Io.Writer,
    vis: *usize,
    align_side: UnitAlign,
    end_vis: usize,
    x: f64,
    unit: Measurement.Unit,
    color: Io.Terminal.Color,
    color_enabled: bool,
    buf: *[32]u8,
) !void {
    const s = scaleUnit(x, unit);
    const value_vis = measureScaledValueVis(buf, s.val);
    const suffix_vis = visibleLen(s.suffix);
    switch (align_side) {
        .right => {
            try TableLayout.padVis(w, vis, end_vis - value_vis - suffix_vis);
            try printScaledUnit(terminal, w, s, color, color_enabled);
            vis.* = end_vis;
        },
        .left => {
            try printScaledUnit(terminal, w, s, color, color_enabled);
            vis.* += value_vis + suffix_vis;
        },
    }
}

fn writeDelta(
    w: *Io.Writer,
    terminal: Io.Terminal,
    vis: *usize,
    layout: TableLayout,
    m: Measurement,
    first_m: ?Measurement,
    all_commands_have_two_samples: bool,
    color_enabled: bool,
) !void {
    const col_start = layout.deltaStartVis();
    var buf: [64]u8 = undefined;
    var plain = Io.Writer.fixed(&buf);
    try writeDeltaPlain(&plain, m, first_m, all_commands_have_two_samples);
    const text = plain.buffered();
    if (color_enabled) try terminal.setColor(.dim);
    try w.writeAll(text);
    if (color_enabled) try terminal.setColor(.reset);
    vis.* = col_start + visibleLen(text);
    try TableLayout.padVis(w, vis, col_start + layout.delta_w);
}

fn jsonPathFromEqualsArg(arg: []const u8) ?[]const u8 {
    const prefix = "--json=";
    if (!std.mem.startsWith(u8, arg, prefix)) return null;
    const path = arg[prefix.len..];
    if (path.len == 0) return default_json_output_path;
    return path;
}

fn exitRequiresNumber(arg: []const u8) noreturn {
    std.debug.print("'{s}' requires a number.\n{s}", .{ arg, help.short_usage });
    process.exit(1);
}

fn parseFlagInt(
    comptime int_type: type,
    args: []const []const u8,
    arg_i: *usize,
    flag: []const u8,
) int_type {
    arg_i.* += 1;
    if (arg_i.* >= args.len) exitRequiresNumber(flag);
    return std.fmt.parseInt(int_type, args[arg_i.*], 10) catch exitRequiresNumber(flag);
}

fn durationNsFromMs(duration_ms: u64) error{DurationTooLarge}!u64 {
    return std.math.mul(u64, duration_ms, std.time.ns_per_ms) catch error.DurationTooLarge;
}

fn groupDurationNsFromMs(
    duration_ms: u64,
    command_count: usize,
) error{DurationTooLarge}!u64 {
    const per_command_ns = try durationNsFromMs(duration_ms);
    const count = std.math.cast(u64, command_count) orelse return error.DurationTooLarge;
    return std.math.mul(u64, per_command_ns, count) catch error.DurationTooLarge;
}

fn maximumDurationMs(command_count: usize) u64 {
    const count = std.math.cast(u64, command_count) orelse return 0;
    return std.math.maxInt(u64) / std.time.ns_per_ms / count;
}

const RunInputError = help.SampleLimitsError || error{
    MissingCommand,
    DurationTooLarge,
};

fn validateRunInput(
    command_count: usize,
    min_samples: u64,
    max_samples: u64,
    duration_ms: u64,
) RunInputError!u64 {
    if (command_count == 0) return error.MissingCommand;
    try help.validateSampleLimits(min_samples, max_samples);
    return groupDurationNsFromMs(duration_ms, command_count);
}

fn exitSampleLimitError(err: help.SampleLimitsError) noreturn {
    std.debug.print("error: {s}\n", .{help.errorMessage(err)});
    process.exit(1);
}

fn printResultsTable(
    w: *Io.Writer,
    terminal: Io.Terminal,
    measurements: Command.Measurements,
    baseline: ?Command.Measurements,
    with_delta: bool,
    show_major_faults: bool,
    all_commands_have_two_samples: bool,
) !void {
    const layout = TableLayout.compute(
        measurements,
        baseline,
        with_delta,
        show_major_faults,
        all_commands_have_two_samples,
    );
    try TableLayout.printHeader(w, terminal, layout, with_delta);
    inline for (@typeInfo(Command.Measurements).@"struct".fields) |field| {
        const m = @field(measurements, field.name);
        const meta = measurementFieldMeta(field.name);
        if (!meta.hide_when_all_commands_are_zero or show_major_faults) {
            const first_m = if (baseline) |b| @as(?Measurement, @field(b, field.name)) else null;
            try printMeasurement(
                terminal,
                layout,
                m,
                field.name,
                first_m,
                with_delta,
                all_commands_have_two_samples,
            );
        }
    }
}

fn anyCommandHasMajorFaults(commands: []const Command) bool {
    for (commands) |command| {
        if (command.measurements.major_faults.max > 0) return true;
    }
    return false;
}

fn appendCommandOperand(
    arena: std.mem.Allocator,
    commands: *std.ArrayList(Command),
    raw_cmd: []const u8,
) !void {
    var cmd_argv: std.ArrayList([]const u8) = .empty;
    argv_parse.parseCommandLine(arena, &cmd_argv, raw_cmd) catch |err| {
        std.debug.print("could not parse command '{s}': {s}\n", .{
            raw_cmd,
            argv_parse.errorMessage(err),
        });
        process.exit(1);
    };
    try commands.append(arena, .{
        .raw_cmd = raw_cmd,
        .argv = try cmd_argv.toOwnedSlice(arena),
        .measurements = undefined,
        .sample_count = 0,
        .failed_sample_count = 0,
    });
}

const outlier_rate_threshold_percent: f64 = 10.0;
const outlier_note_min_metrics: u32 = 2;

fn metricOutlierRatePercent(count: u64, sample_count: u64) f64 {
    return @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(sample_count)) * 100;
}

fn metricExceedsOutlierRateThreshold(meas: Measurement) bool {
    if (meas.sample_count == 0) return false;
    return metricOutlierRatePercent(meas.outlier_count, meas.sample_count) >=
        outlier_rate_threshold_percent;
}

fn measurementsTriggerOutlierNote(m: Command.Measurements) bool {
    var count: u32 = 0;
    inline for (@typeInfo(Command.Measurements).@"struct".fields) |field| {
        if (metricExceedsOutlierRateThreshold(@field(m, field.name))) {
            count += 1;
            if (count >= outlier_note_min_metrics) return true;
        }
    }
    return false;
}

fn anyCommandTriggersOutlierNote(commands: []const Command) bool {
    for (commands) |cmd| {
        if (measurementsTriggerOutlierNote(cmd.measurements)) return true;
    }
    return false;
}

const CommandBenchmarkConfig = struct {
    min_samples: u64,
    max_samples: u64,
    group_budget_ns: u64,
    allow_failures: bool,
    warmup: usize,
    child_exit_notifier: ?*ChildExitNotifier,
};

// A block runs every rotation of one circular order. That gives each command
// every position once, and makes one round end with the command that starts the
// next. The odd and even circle sets cover every way one command can follow a
// different command equally. Round boundaries supply the same-command pairs.
// Orders are calculated when needed and are never stored.
const CommandRoundOrder = struct {
    command_count: usize,
    cycle_index: u128,
    rotation: usize,
    zero_raw_position: usize,

    fn measured(command_count: usize, round_index: u64) CommandRoundOrder {
        return initAt(command_count, round_index);
    }

    fn beforeFirstMeasured(command_count: usize, rounds_before: usize) CommandRoundOrder {
        std.debug.assert(rounds_before > 0);
        const count: u128 = command_count;
        const distance: u128 = rounds_before;
        const rotation_back = distance % count;
        const rotation: usize = if (rotation_back == 0)
            0
        else
            @intCast(count - rotation_back);
        const blocks_back = (distance - 1) / count + 1;
        const cycle_count = commandOrderCycleCount(command_count);
        const cycle_back = blocks_back % cycle_count;
        const cycle_index = if (cycle_back == 0) 0 else cycle_count - cycle_back;
        return init(command_count, cycle_index, rotation);
    }

    fn initAt(command_count: usize, round_index: u128) CommandRoundOrder {
        const count: u128 = command_count;
        return init(
            command_count,
            round_index / count % commandOrderCycleCount(command_count),
            @intCast(round_index % count),
        );
    }

    fn init(
        command_count: usize,
        cycle_index: u128,
        rotation: usize,
    ) CommandRoundOrder {
        var order = CommandRoundOrder{
            .command_count = command_count,
            .cycle_index = cycle_index,
            .rotation = rotation,
            .zero_raw_position = 0,
        };
        if (command_count <= 4) return order;
        while (order.rawGenericVertex(order.zero_raw_position) != 0) {
            order.zero_raw_position += 1;
            std.debug.assert(order.zero_raw_position < command_count);
        }
        return order;
    }

    fn commandAt(self: CommandRoundOrder, position: usize) usize {
        std.debug.assert(position < self.command_count);
        return switch (self.command_count) {
            1 => 0,
            2 => blk: {
                const base = [2]usize{ 0, 1 };
                break :blk (base[position] + self.rotation) % 2;
            },
            3 => blk: {
                const bases = [2][3]usize{
                    .{ 0, 1, 2 },
                    .{ 0, 2, 1 },
                };
                const base = bases[@intCast(self.cycle_index)];
                const shift = self.rotation * base[2];
                break :blk (base[position] + shift) % 3;
            },
            4 => blk: {
                const bases = [4][4]usize{
                    .{ 0, 1, 2, 3 },
                    .{ 0, 2, 1, 3 },
                    .{ 0, 2, 3, 1 },
                    .{ 0, 3, 2, 1 },
                };
                const base = bases[@intCast(self.cycle_index)];
                const shift = self.rotation * base[3];
                break :blk (base[position] + shift) % 4;
            },
            else => self.genericCommandAt(position),
        };
    }

    fn genericCommandAt(self: CommandRoundOrder, position: usize) usize {
        const base_position = subtractModulo(position, self.rotation, self.command_count);
        const reverse = self.cycle_index % 2 == 1;
        const raw_position = if (reverse)
            subtractModulo(self.zero_raw_position, base_position, self.command_count)
        else
            addModulo(self.zero_raw_position, base_position, self.command_count);
        return self.rawGenericVertex(raw_position);
    }

    fn rawGenericVertex(self: CommandRoundOrder, raw_position: usize) usize {
        const n = self.command_count;
        if (n % 2 == 1) {
            if (raw_position == 0) return n - 1;
            const path_index: usize = @intCast(self.cycle_index / 2);
            return alternatingPathVertex(n - 1, path_index, raw_position - 1);
        }

        const within_matching: usize = @intCast(self.cycle_index % n);
        const path_index = within_matching / 2;
        const matching_index: usize = @intCast(self.cycle_index / n);
        return mapAlternatingPathToPairing(
            n,
            matching_index,
            alternatingPathVertex(n, path_index, raw_position),
        );
    }
};

fn commandOrderCycleCount(command_count: usize) u128 {
    return switch (command_count) {
        1, 2 => 1,
        3 => 2,
        4 => 4,
        else => if (command_count % 2 == 1)
            @as(u128, command_count - 1)
        else
            @as(u128, command_count) * @as(u128, command_count - 1),
    };
}

fn addModulo(a: usize, b: usize, modulus: usize) usize {
    std.debug.assert(a < modulus and b < modulus);
    return if (a >= modulus - b) a - (modulus - b) else a + b;
}

fn subtractModulo(a: usize, b: usize, modulus: usize) usize {
    std.debug.assert(a < modulus and b < modulus);
    return if (a >= b) a - b else modulus - (b - a);
}

fn alternatingPathVertex(order: usize, path_index: usize, position: usize) usize {
    std.debug.assert(order % 2 == 0);
    std.debug.assert(path_index < order / 2);
    std.debug.assert(position < order);
    if (position == 0) return path_index;
    const distance = (position + 1) / 2;
    return if (position % 2 == 1)
        subtractModulo(path_index, distance, order)
    else
        addModulo(path_index, distance, order);
}

fn mapAlternatingPathToPairing(
    command_count: usize,
    matching_index: usize,
    vertex: usize,
) usize {
    const half = command_count / 2;
    const circle_count = command_count - 1;
    const pair_index = vertex % half;
    if (vertex < half) {
        if (pair_index == 0) return command_count - 1;
        return subtractModulo(matching_index, pair_index, circle_count);
    }
    if (pair_index == 0) return matching_index;
    return addModulo(matching_index, pair_index, circle_count);
}

const PerfFdReadError = std.posix.ReadError || error{ShortPerfRead};

const PerfReadFailure = struct {
    counter_index: usize,
    reason: union(enum) {
        read: PerfFdReadError,
        schedule: struct {
            time_enabled: u64,
            time_running: u64,
        },
    },
};

const SampleMeasurementFailure = union(enum) {
    perf_disable: PerfSampleDisableError,
    perf_read: PerfReadFailure,
    missing_resource_usage,
};

const SampleMeasurementResult = union(enum) {
    sample: Sample,
    failure: SampleMeasurementFailure,
};

const MeasuredSample = struct {
    measurement: SampleMeasurementResult,
    term: process.Child.Term,
};

const TargetWaitResult = struct {
    term: process.Child.Term,
    duration: Io.Duration,
};

const MeasuredSampleDecision = enum {
    accepted,
    accepted_failure,
    rejected_exit,
    rejected_termination,
    measurement_failed,
};

fn decideMeasuredSample(
    term: process.Child.Term,
    allow_failures: bool,
    measurement: SampleMeasurementResult,
) MeasuredSampleDecision {
    switch (term) {
        .exited => |code| {
            if (code != 0 and !allow_failures) return .rejected_exit;
        },
        else => return .rejected_termination,
    }
    switch (measurement) {
        .failure => return .measurement_failed,
        .sample => {},
    }
    return switch (term) {
        .exited => |code| if (code == 0) .accepted else .accepted_failure,
        else => unreachable,
    };
}

fn finishSampleMeasurement(
    duration: Io.Duration,
    usage: process.Child.ResourceUsageStatistics,
    perf_fds: *const [perf_measurements.len]fd_t,
) SampleMeasurementResult {
    disablePerfGroupAfterSample(perf_fds[0]) catch |err| {
        return .{ .failure = .{ .perf_disable = err } };
    };

    const perf_result = readSamplePerfCounters(perf_fds);
    const perf_values = switch (perf_result) {
        .values => |values| values,
        .failure => |failure| return .{ .failure = .{ .perf_read = failure } },
    };

    const resource_usage = sampleResourceUsage(usage) catch {
        return .{ .failure = .missing_resource_usage };
    };
    return .{ .sample = .{
        .wall_time = @intCast(duration.toNanoseconds()),
        .peak_rss = resource_usage.peak_rss,
        .minor_faults = resource_usage.minor_faults,
        .major_faults = resource_usage.major_faults,
        .cpu_cycles = perf_values[0],
        .instructions = perf_values[1],
        .cache_references = perf_values[2],
        .cache_misses = perf_values[3],
        .branch_misses = perf_values[4],
    } };
}

fn runMeasuredSample(
    io: Io,
    argv: []const []const u8,
    stderr_capture: ?*StderrCaptureBuf,
    child_exit_notifier: ?*ChildExitNotifier,
    bar: ?*progress.ProgressBar,
) !MeasuredSample {
    var perf_fds: [perf_measurements.len]fd_t = @splat(-1);
    try openPerfGroup(&perf_fds);
    defer closePerfFds(&perf_fds);

    try resetPerfGroupBeforeSample(perf_fds[0]);

    if (stderr_capture) |capture_buf| capture_buf.reset();
    if (child_exit_notifier) |notifier|
        notifier.prepare() catch return error.TargetWaitFailed;

    // This is the public wall-time start point. It remains before spawn so
    // fork and exec stay part of the sample.
    const start: Io.Timestamp = .now(io, .awake);
    var child = spawnMeasuredTarget(io, argv, stderr_capture != null) catch |err| {
        if (bar) |b| b.clear() catch {};
        std.debug.print("\nerror: Couldn't execute {s}: {t}\n", .{ argv[0], err });
        return error.TargetStartFailed;
    };

    const waited = if (stderr_capture) |capture_buf| captured: {
        const result = waitChildAndDrainStderr(
            io,
            &child,
            start,
            capture_buf,
            child_exit_notifier,
        ) catch |err| {
            if (bar) |b| b.clear() catch {};
            std.debug.print("\nerror: Couldn't execute {s}: {t}\n", .{ argv[0], err });
            return error.TargetWaitFailed;
        };
        break :captured result;
    } else waitMeasuredChild(io, &child, start) catch |err| {
        if (bar) |b| b.clear() catch {};
        std.debug.print("\nerror: Couldn't execute {s}: {t}\n", .{ argv[0], err });
        return error.TargetWaitFailed;
    };

    return .{
        .measurement = finishSampleMeasurement(waited.duration, child.resource_usage_statistics, &perf_fds),
        .term = waited.term,
    };
}

fn runWarmup(
    io: Io,
    argv: []const []const u8,
    stderr_capture: ?*StderrCaptureBuf,
    child_exit_notifier: ?*ChildExitNotifier,
) !process.Child.Term {
    if (stderr_capture) |capture_buf| capture_buf.reset();
    if (child_exit_notifier) |notifier|
        notifier.prepare() catch return error.TargetWaitFailed;
    var child = try spawnWarmupTarget(io, argv, stderr_capture != null);
    if (stderr_capture == null) return (try waitChild(io, &child)).term;

    const waited = try waitChildAndDrainStderr(
        io,
        &child,
        .now(io, .awake),
        stderr_capture.?,
        child_exit_notifier,
    );
    return waited.term;
}

fn runOneWarmup(
    io: Io,
    command: *Command,
    config: CommandBenchmarkConfig,
    commands: []const Command,
    stderr_w: *Io.Writer,
) !void {
    const stderr_capture: ?*StderrCaptureBuf = if (config.allow_failures)
        &command.stderr_capture.?
    else
        null;
    const term = runWarmup(
        io,
        command.argv,
        stderr_capture,
        config.child_exit_notifier,
    ) catch |err| {
        std.debug.print("\nerror: Couldn't execute {s}: {t}\n", .{ command.argv[0], err });
        printCollectionNotesOnStop(stderr_w, commands);
        return error.CliReported;
    };
    switch (term) {
        .exited => |code| {
            if (code != 0 and !config.allow_failures) {
                std.debug.print("\nerror: warmup for '{s}' failed with exit code {d}\n", .{ command.raw_cmd, code });
                printCollectionNotesOnStop(stderr_w, commands);
                return error.CliReported;
            }
        },
        else => {
            std.debug.print("error: warmup terminated unexpectedly\n", .{});
            printCollectionNotesOnStop(stderr_w, commands);
            return error.CliReported;
        },
    }
}

fn collectOneMeasuredSample(
    io: Io,
    command: *Command,
    command_n: usize,
    commands: []const Command,
    config: CommandBenchmarkConfig,
    bar: ?*progress.ProgressBar,
    stderr_w: *Io.Writer,
) !void {
    const perf_ioctl_skip_limit = perfIoctlSkipLimit(config.max_samples);
    const measured = measured: while (true) {
        const stderr_capture: ?*StderrCaptureBuf = if (config.allow_failures)
            &command.stderr_capture.?
        else
            null;
        const measured = runMeasuredSample(
            io,
            command.argv,
            stderr_capture,
            config.child_exit_notifier,
            bar,
        ) catch |err| switch (err) {
            error.BadLeaderFd, error.DisableBeforeSpawnFailed, error.ResetFailed => {
                const setup_error: PerfSampleResetError = switch (err) {
                    error.BadLeaderFd => error.BadLeaderFd,
                    error.DisableBeforeSpawnFailed => error.DisableBeforeSpawnFailed,
                    error.ResetFailed => error.ResetFailed,
                    else => unreachable,
                };
                if (command.perf_setup_first_error == null) {
                    command.perf_setup_first_error = setup_error;
                }
                command.perf_setup_skip_count += 1;
                if (command.perf_setup_skip_count >= perf_ioctl_skip_limit) {
                    if (bar) |b| b.clear() catch {};
                    std.debug.print(
                        "\nerror: perf setup failed {d} times for '{s}': {s}\n",
                        .{
                            command.perf_setup_skip_count,
                            command.raw_cmd,
                            perfSetupFailureDetail(command.perf_setup_first_error.?),
                        },
                    );
                    printCollectionNotesOnStopExceptPerf(
                        stderr_w,
                        commands,
                        command_n - 1,
                    );
                    return error.CliReported;
                }
                continue;
            },
            error.PerfOpenFailed,
            error.TargetStartFailed,
            error.TargetWaitFailed,
            => {
                printCollectionNotesOnStop(stderr_w, commands);
                return error.CliReported;
            },
        };
        break :measured measured;
    };

    switch (decideMeasuredSample(measured.term, config.allow_failures, measured.measurement)) {
        .rejected_exit => {
            if (bar) |b| b.clear() catch {};
            std.debug.print("\nerror: Benchmark {d} command '{s}' failed with exit code {d}\n", .{
                command_n,
                command.raw_cmd,
                measured.term.exited,
            });
            std.debug.print("hint: pass --allow-failures to capture stderr from failing runs\n", .{});
            printCollectionNotesOnStop(stderr_w, commands);
            return error.CliReported;
        },
        .rejected_termination => {
            if (bar) |b| b.clear() catch {};
            switch (measured.term) {
                .signal => |signal| std.debug.print(
                    "\nerror: Benchmark {d} command '{s}' terminated by signal {d}\n",
                    .{ command_n, command.raw_cmd, @intFromEnum(signal) },
                ),
                .stopped => |signal| std.debug.print(
                    "\nerror: Benchmark {d} command '{s}' stopped by signal {d}\n",
                    .{ command_n, command.raw_cmd, @intFromEnum(signal) },
                ),
                .unknown => |status| std.debug.print(
                    "\nerror: Benchmark {d} command '{s}' returned unknown wait status {d}\n",
                    .{ command_n, command.raw_cmd, status },
                ),
                .exited => unreachable,
            }
            printCollectionNotesOnStop(stderr_w, commands);
            return error.CliReported;
        },
        .measurement_failed => {
            if (bar) |b| b.clear() catch {};
            printSampleMeasurementFailure(measured.measurement.failure);
            printCollectionNotesOnStop(stderr_w, commands);
            return error.CliReported;
        },
        .accepted_failure => {
            const code = measured.term.exited;
            command.failed_sample_count += 1;
            if (command.first_failure_sample == null) {
                command.first_failure_sample = command.sample_count + 1;
                command.first_failure_exit_code = code;
                command.first_failure_stderr = command.stderr_capture.?.view();
                command.stderr_capture = command.stderr_capture_spare;
                command.stderr_capture_spare = null;
            }
        },
        .accepted => {},
    }

    std.debug.assert(command.sample_count < command.samples.len);
    command.samples[command.sample_count] = measured.measurement.sample;
    command.sample_count += 1;
}

fn shouldRunAnotherRound(
    completed_rounds: u64,
    min_samples: u64,
    max_samples: u64,
    elapsed_ns: u64,
    budget_ns: u64,
) bool {
    return completed_rounds < max_samples and
        (completed_rounds < min_samples or elapsed_ns < budget_ns);
}

fn updateRoundProgress(
    io: Io,
    bar: *progress.ProgressBar,
    completed_rounds: u64,
    command_count: usize,
    elapsed_ns: u64,
    config: CommandBenchmarkConfig,
) !void {
    const count: u64 = @intCast(command_count);
    var ns_per_round = elapsed_ns / completed_rounds;
    if (ns_per_round == 0) ns_per_round = 1;
    const duration_rounds = std.math.divCeil(u64, config.group_budget_ns, ns_per_round) catch unreachable;
    const estimated_rounds = @min(
        config.max_samples,
        @max(completed_rounds, duration_rounds, config.min_samples),
    );
    bar.current = completed_rounds *| count;
    bar.estimate = estimated_rounds *| count;
    try bar.render(io);
}

fn benchmarkCommands(
    io: Io,
    commands: []Command,
    config: CommandBenchmarkConfig,
    bar: ?*progress.ProgressBar,
    stderr_w: *Io.Writer,
) !void {
    const command_count = commands.len;
    for (0..config.warmup) |warmup_round| {
        const rounds_before_measurement = config.warmup - warmup_round;
        const order = CommandRoundOrder.beforeFirstMeasured(
            command_count,
            rounds_before_measurement,
        );
        for (0..command_count) |position| {
            const command_index = order.commandAt(position);
            try runOneWarmup(
                io,
                &commands[command_index],
                config,
                commands,
                stderr_w,
            );
        }
    }

    const collection_start: Io.Timestamp = .now(io, .awake);
    var completed_rounds: u64 = 0;
    while (shouldRunAnotherRound(
        completed_rounds,
        config.min_samples,
        config.max_samples,
        @intCast(collection_start.untilNow(io, .awake).toNanoseconds()),
        config.group_budget_ns,
    )) {
        const order = CommandRoundOrder.measured(command_count, completed_rounds);
        for (0..command_count) |position| {
            const command_index = order.commandAt(position);
            try collectOneMeasuredSample(
                io,
                &commands[command_index],
                command_index + 1,
                commands,
                config,
                bar,
                stderr_w,
            );
        }
        completed_rounds += 1;
        for (commands) |command| {
            std.debug.assert(command.sample_count == completed_rounds);
        }
        if (bar) |b| {
            try updateRoundProgress(
                io,
                b,
                completed_rounds,
                command_count,
                @intCast(collection_start.untilNow(io, .awake).toNanoseconds()),
                config,
            );
        }
    }

    if (bar) |b| {
        b.estimate = b.current;
        try b.renderFinal(io);
        try b.clear();
        try stderr_w.writeAll("\n");
        try stderr_w.flush();
    }

    for (commands) |command| {
        if (command.sample_count == 0) {
            std.debug.print("\nerror: no samples collected for '{s}' (try longer --duration or more --min-samples)\n", .{
                command.raw_cmd,
            });
            printCollectionNotesOnStop(stderr_w, commands);
            return error.CliReported;
        }
    }
}

fn jsonFileErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => "access denied",
        error.NoSpaceLeft => "no space left on the device",
        error.DiskQuota => "the disk quota is full",
        error.ReadOnlyFileSystem => "the file system is read-only",
        error.FileNotFound => "the path or a parent directory does not exist",
        error.NotDir => "a path component is not a directory",
        error.PathAlreadyExists => "the destination cannot be replaced",
        error.SymLinkLoop => "a path component contains a symbolic-link loop",
        error.NameTooLong => "the path is too long",
        error.BadPathName => "the path is invalid",
        error.ProcessFdQuotaExceeded => "the process has too many open files",
        error.SystemFdQuotaExceeded => "the system has too many open files",
        error.SystemResources => "the system does not have enough resources",
        error.FileBusy, error.DeviceBusy => "the destination is busy",
        error.FileSystem, error.InputOutput => "the file system rejected the operation",
        error.WouldBlock => "the destination would block",
        error.WriteFailed => "the write failed",
        else => "the file operation failed",
    };
}

fn reportJsonFileError(path: []const u8, err: anyerror) void {
    std.debug.print("\nerror: cannot write JSON to '{s}': {s}\n", .{
        path,
        jsonFileErrorMessage(err),
    });
}

fn existingJsonFilePermissions(io: Io, path: []const u8) !?Io.File.Permissions {
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return if (stat.kind == .file) stat.permissions else null;
}

fn reportUnhandledCliError(err: anyerror) void {
    switch (err) {
        error.OutOfMemory => std.debug.print("error: zebrac does not have enough memory\n", .{}),
        error.WriteFailed => std.debug.print("error: cannot write command output\n", .{}),
        error.ReadFailed => std.debug.print("error: cannot read command input\n", .{}),
        error.Canceled => std.debug.print("error: the operation was canceled\n", .{}),
        else => std.debug.print("error: zebrac could not finish: {t}\n", .{err}),
    }
}

fn runMain(init: process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [stream_io_buf_len]u8 = undefined;
    var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdout_w = &stdout_writer.interface;

    var stderr_buffer: [stream_io_buf_len]u8 = undefined;
    var stderr_writer = Io.File.stderr().writerStreaming(io, &stderr_buffer);
    const stderr_w = &stderr_writer.interface;

    var commands: std.ArrayList(Command) = .empty;
    var duration_ms = default_duration_ms;
    var color: ColorMode = .auto;
    var allow_failures = false;
    var json_path: ?[]const u8 = null;
    var quiet = false;
    var min_samples: u64 = default_min_samples;
    var max_samples: u64 = help.max_samples_cap;
    var max_samples_clamped_from: ?u64 = null;
    var warmup: usize = default_warmup;

    var parse_flags = true;
    var arg_i: usize = 1;
    while (arg_i < args.len) : (arg_i += 1) {
        const arg = args[arg_i];
        if (!parse_flags or !std.mem.startsWith(u8, arg, "-")) {
            try appendCommandOperand(arena, &commands, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            parse_flags = false;
            continue;
        }
        if (jsonPathFromEqualsArg(arg)) |path| {
            json_path = path;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stdout_w.writeAll(help.usage_text);
            try stdout_w.flush();
            return process.cleanExit(io);
        } else if (std.mem.eql(u8, arg, "--version")) {
            try stdout_w.writeAll(help.version_line);
            try stdout_w.flush();
            return process.cleanExit(io);
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--duration")) {
            duration_ms = parseFlagInt(u64, args, &arg_i, arg);
        } else if (std.mem.eql(u8, arg, "--color")) {
            arg_i += 1;
            if (arg_i >= args.len) {
                std.debug.print("'{s}' requires a mode; options are 'auto', 'never', and 'ansi'.\n{s}", .{ arg, help.short_usage });
                process.exit(1);
            }
            const next = args[arg_i];
            if (std.meta.stringToEnum(ColorMode, next)) |when| {
                color = when;
            } else {
                std.debug.print(
                    \\unable to parse --color argument '{s}'
                    \\
                    \\available options are 'auto', 'never' and 'ansi'
                    \\
                , .{next});
                process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--allow-failures")) {
            allow_failures = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            if (arg_i + 1 < args.len and !std.mem.startsWith(u8, args[arg_i + 1], "-")) {
                arg_i += 1;
                json_path = args[arg_i];
            } else {
                json_path = default_json_output_path;
            }
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--min-samples")) {
            min_samples = parseFlagInt(u64, args, &arg_i, arg);
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--max-samples")) {
            const parsed_max = parseFlagInt(u64, args, &arg_i, arg);
            max_samples = @min(parsed_max, help.max_samples_cap);
            max_samples_clamped_from = if (parsed_max > help.max_samples_cap) parsed_max else null;
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--warmup")) {
            warmup = parseFlagInt(usize, args, &arg_i, arg);
        } else {
            std.debug.print("unrecognized argument: '{s}'\n{s}", .{ arg, help.usage_text });
            process.exit(1);
        }
    }

    const group_budget_ns = validateRunInput(
        commands.items.len,
        min_samples,
        max_samples,
        duration_ms,
    ) catch |err| switch (err) {
        error.MissingCommand => {
            @branchHint(.cold);
            try stdout_w.writeAll(help.usage_text);
            try stdout_w.flush();
            process.exit(1);
        },
        error.DurationTooLarge => {
            @branchHint(.cold);
            std.debug.print("error: --duration is too large (maximum {d} ms)\n", .{
                maximumDurationMs(commands.items.len),
            });
            process.exit(1);
        },
        error.MinSamplesZero => {
            @branchHint(.cold);
            exitSampleLimitError(error.MinSamplesZero);
        },
        error.MaxSamplesZero => {
            @branchHint(.cold);
            exitSampleLimitError(error.MaxSamplesZero);
        },
        error.MinSamplesExceedsMax => {
            @branchHint(.cold);
            exitSampleLimitError(error.MinSamplesExceedsMax);
        },
    };

    var run_notes: std.ArrayList([]const u8) = .empty;
    if (max_samples_clamped_from) |requested| {
        try run_notes.append(arena, try std.fmt.allocPrint(arena, "--max-samples {d} capped at {d}", .{
            requested, help.max_samples_cap,
        }));
    }

    const stderr_is_tty = Io.File.stderr().isTty(io) catch false;
    const no_color_env = if (init.environ_map.get("NO_COLOR")) |_| true else false;
    const clicolor_force_env = if (init.environ_map.get("CLICOLOR_FORCE")) |_| true else false;

    var child_exit_notifier: ?ChildExitNotifier = null;
    defer if (child_exit_notifier) |*notifier| notifier.deinit();
    if (allow_failures and !pidfdAvailable()) {
        child_exit_notifier = ChildExitNotifier.init() catch |err| {
            std.debug.print("error: cannot watch the direct command exit: {t}\n", .{err});
            return error.CliReported;
        };
    }

    var collection_storage = CollectionStorage.init(
        commands.items.len,
        max_samples,
        allow_failures,
    ) catch |err| {
        std.debug.print("error: cannot isolate benchmark collection memory: {t}\n", .{err});
        return error.CliReported;
    };
    defer collection_storage.deinit();
    for (commands.items, 0..) |*command, command_index| {
        command.samples = collection_storage.samplesFor(command_index);
        if (allow_failures) {
            const captures = collection_storage.failureBuffersFor(command_index);
            command.stderr_capture = captures.first;
            command.stderr_capture_spare = captures.second;
        }
    }

    var progress_mapping: ?DontForkMapping = null;
    defer if (progress_mapping) |*mapping| mapping.deinit();
    var bar: ?progress.ProgressBar = null;
    var terminal: ?Io.Terminal = null;
    if (!quiet) {
        terminal = Io.Terminal{
            .writer = stdout_w,
            .mode = switch (color) {
                .auto => try Io.Terminal.Mode.detect(
                    io,
                    .stdout(),
                    no_color_env,
                    clicolor_force_env,
                ),
                .never => .no_color,
                .ansi => .escape_codes,
            },
        };
    }
    if (progress.samplingShowsProgressBar(quiet, stderr_is_tty)) {
        const bar_mode = switch (color) {
            .auto => try Io.Terminal.Mode.detect(
                io,
                .stderr(),
                no_color_env,
                clicolor_force_env,
            ),
            .never => .no_color,
            .ansi => .escape_codes,
        };
        progress_mapping = DontForkMapping.init(progress.max_buffer_bytes) catch |err| {
            std.debug.print("error: cannot isolate progress memory: {t}\n", .{err});
            return error.CliReported;
        };
        bar = progress.ProgressBar.init(
            io,
            progress_mapping.?.memory,
            stderr_w,
            bar_mode,
            Io.File.stderr(),
        );
    }

    const bench_config = CommandBenchmarkConfig{
        .min_samples = min_samples,
        .max_samples = max_samples,
        .group_budget_ns = group_budget_ns,
        .allow_failures = allow_failures,
        .warmup = warmup,
        .child_exit_notifier = if (child_exit_notifier) |*notifier| notifier else null,
    };

    try benchmarkCommands(
        io,
        commands.items,
        bench_config,
        if (bar) |*b| b else null,
        stderr_w,
    );

    try writeAllowedFailureNotes(stderr_w, commands.items);

    // Sorting can use ordinary arena memory now because no target remains.
    const sort_scratch = try arena.alloc(Sample, @intCast(max_samples));
    for (commands.items) |*command| {
        command.measurements = Measurement.summarizeAll(
            command.samples[0..command.sample_count],
            sort_scratch,
        ) catch |err| {
            std.debug.print("\nerror: stats for '{s}': {s}\n", .{
                command.raw_cmd,
                Measurement.errorMessage(err),
            });
            return error.CliReported;
        };
    }

    for (commands.items) |command| {
        if (command.perf_setup_first_error) |err| {
            const noun = if (command.perf_setup_skip_count == 1) "attempt" else "attempts";
            try run_notes.append(arena, try std.fmt.allocPrint(
                arena,
                "{d} measurement setup {s} for '{s}' failed before target start: {s}",
                .{
                    command.perf_setup_skip_count,
                    noun,
                    command.raw_cmd,
                    perfSetupFailureDetail(err),
                },
            ));
        }
    }

    if (warmup == 0) {
        try run_notes.append(arena, "--warmup 0; first measured run may include cold-start effects");
    }
    if (anyCommandTriggersOutlierNote(commands.items)) {
        try run_notes.append(arena, try std.fmt.allocPrint(
            arena,
            "outlier rate >={d:.0}% on {d}+ metrics; check system load or raise --warmup",
            .{ outlier_rate_threshold_percent, outlier_note_min_metrics },
        ));
    }

    try help.printRunNotes(stderr_w, run_notes.items);

    const show_major_faults = anyCommandHasMajorFaults(commands.items);
    var all_commands_have_two_samples = true;
    for (commands.items) |command| {
        if (command.sample_count < 2) {
            all_commands_have_two_samples = false;
            break;
        }
    }
    for (commands.items, 1..) |*command, command_n| {
        if (terminal) |t| {
            const run_noun = if (command.sample_count == 1) "run" else "runs";
            try t.setColor(.bold);
            try stdout_w.print("Benchmark {d}", .{command_n});
            try t.setColor(.dim);
            if (command.failed_sample_count > 0) {
                try stdout_w.print(" ({d} {s}, {d} failed)", .{
                    command.sample_count,
                    run_noun,
                    command.failed_sample_count,
                });
            } else {
                try stdout_w.print(" ({d} {s})", .{ command.sample_count, run_noun });
            }
            try t.setColor(.reset);
            try stdout_w.print(": {s}\n", .{command.raw_cmd});

            const with_delta = commands.items.len >= 2;
            const baseline: ?Command.Measurements = if (command_n == 1) null else commands.items[0].measurements;
            try printResultsTable(
                stdout_w,
                t,
                command.measurements,
                baseline,
                with_delta,
                show_major_faults,
                all_commands_have_two_samples,
            );

            try stdout_w.flush();
        }
    }

    if (json_path) |path| {
        var file_buf: [json_file_buf_len]u8 = undefined;
        const existing_permissions = existingJsonFilePermissions(io, path) catch |err| {
            reportJsonFileError(path, err);
            return error.CliReported;
        };
        var atomic_file = std.Io.Dir.cwd().createFileAtomic(io, path, .{
            .permissions = existing_permissions orelse .default_file,
            .replace = true,
        }) catch |err| {
            reportJsonFileError(path, err);
            return error.CliReported;
        };
        defer atomic_file.deinit(io);
        if (existing_permissions) |permissions| {
            atomic_file.file.setPermissions(io, permissions) catch |err| {
                reportJsonFileError(path, err);
                return error.CliReported;
            };
        }
        var file_writer = atomic_file.file.writerStreaming(io, &file_buf);
        const json_config = JsonRunConfig{
            .duration_ms = duration_ms,
            .min_samples = min_samples,
            .max_samples = max_samples,
            .max_samples_requested = max_samples_clamped_from,
            .warmup = warmup,
            .allow_failures = allow_failures,
        };
        printJsonOutput(&file_writer.interface, commands.items, json_config) catch |err| {
            reportJsonFileError(path, err);
            return error.CliReported;
        };
        file_writer.flush() catch |err| {
            reportJsonFileError(path, err);
            return error.CliReported;
        };
        atomic_file.replace(io) catch |err| {
            reportJsonFileError(path, err);
            return error.CliReported;
        };
        if (!quiet) try stdout_w.print("results written to {s}\n", .{path});
    }

    try stdout_w.flush();
}

pub fn main(init: process.Init) void {
    runMain(init) catch |err| {
        if (err != error.CliReported) reportUnhandledCliError(err);
        process.exit(1);
    };
}

const json_schema_version = 1;

const JsonRunConfig = struct {
    duration_ms: u64,
    min_samples: u64,
    max_samples: u64,
    max_samples_requested: ?u64,
    warmup: usize,
    allow_failures: bool,
};

fn printJsonOutput(w: *Io.Writer, commands: []Command, config: JsonRunConfig) !void {
    var s = std.json.Stringify{
        .writer = w,
        .options = .{ .whitespace = .indent_2 },
    };
    try s.beginObject();
    try s.objectField("schema_version");
    try s.write(json_schema_version);
    try s.objectField("zebrac_version");
    try s.write(help.version);
    try s.objectField("config");
    try writeJsonConfig(&s, config);
    try s.objectField("results");
    try s.beginArray();
    for (commands) |cmd| {
        try s.beginObject();
        try s.objectField("command");
        try s.write(cmd.raw_cmd);
        try s.objectField("sample_count");
        try s.write(cmd.sample_count);
        try s.objectField("failed_sample_count");
        try s.write(cmd.failed_sample_count);
        try s.objectField("argv");
        try s.write(cmd.argv);
        inline for (@typeInfo(Command.Measurements).@"struct".fields) |field| {
            try s.objectField(field.name);
            try writeJsonMeasurement(&s, @field(cmd.measurements, field.name));
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
}

fn writeJsonConfig(s: *std.json.Stringify, config: JsonRunConfig) !void {
    try s.beginObject();
    try s.objectField("duration_ms");
    try s.write(config.duration_ms);
    try s.objectField("min_samples");
    try s.write(config.min_samples);
    try s.objectField("max_samples");
    try s.write(config.max_samples);
    try s.objectField("max_samples_cap");
    try s.write(help.max_samples_cap);
    try s.objectField("max_samples_requested");
    try s.write(config.max_samples_requested);
    try s.objectField("warmup");
    try s.write(config.warmup);
    try s.objectField("allow_failures");
    try s.write(config.allow_failures);
    try s.endObject();
}

fn writeJsonMeasurement(s: *std.json.Stringify, m: Measurement) !void {
    try s.beginObject();
    const fields = .{ "mean", "std_dev", "min", "max", "median", "q1", "q3", "outlier_count", "sample_count" };
    inline for (fields) |name| {
        try s.objectField(name);
        try s.write(@field(m, name));
    }
    try s.objectField("unit");
    try s.write(@tagName(m.unit));
    try s.endObject();
}

const StderrCapture = struct {
    bytes: []const u8,
    truncated: bool,
};

const StderrCaptureBuf = struct {
    storage: []u8,
    len: usize = 0,
    truncated: bool = false,

    fn reset(self: *StderrCaptureBuf) void {
        self.len = 0;
        self.truncated = false;
    }

    fn append(self: *StderrCaptureBuf, data: []const u8) void {
        if (self.truncated) return;
        const room = self.storage.len -| self.len;
        if (room == 0) {
            self.truncated = true;
            return;
        }
        const take = @min(data.len, room);
        @memcpy(self.storage[self.len..][0..take], data[0..take]);
        self.len += take;
        if (take < data.len) self.truncated = true;
    }

    fn view(self: *const StderrCaptureBuf) StderrCapture {
        return .{
            .bytes = self.storage[0..self.len],
            .truncated = self.truncated,
        };
    }
};

fn posixWaitStatusToTerm(status: u32) process.Child.Term {
    const W = std.os.linux.W;
    return if (W.IFEXITED(status))
        .{ .exited = W.EXITSTATUS(status) }
    else if (W.IFSIGNALED(status))
        .{ .signal = W.TERMSIG(status) }
    else if (W.IFSTOPPED(status))
        .{ .stopped = W.STOPSIG(status) }
    else
        .{ .unknown = status };
}

fn closeChildPipes(child: *process.Child) void {
    if (child.stdin) |stdin_file| {
        _ = std.os.linux.close(stdin_file.handle);
        child.stdin = null;
    }
    if (child.stdout) |stdout_file| {
        _ = std.os.linux.close(stdout_file.handle);
        child.stdout = null;
    }
    if (child.stderr) |stderr_file| {
        _ = std.os.linux.close(stderr_file.handle);
        child.stderr = null;
    }
    child.id = null;
}

fn spawnMeasuredTarget(
    io: Io,
    argv: []const []const u8,
    pipe_stderr: bool,
) process.SpawnError!process.Child {
    return process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .ignore,
        .stderr = if (pipe_stderr) .pipe else .ignore,
        .request_resource_usage_statistics = true,
    });
}

fn spawnWarmupTarget(
    io: Io,
    argv: []const []const u8,
    pipe_stderr: bool,
) process.SpawnError!process.Child {
    return process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .ignore,
        .stderr = if (pipe_stderr) .pipe else .ignore,
        .request_resource_usage_statistics = false,
    });
}

fn waitMeasuredChild(
    io: Io,
    child: *process.Child,
    start: Io.Timestamp,
) !TargetWaitResult {
    const waited = try waitChild(io, child);
    return .{
        .term = waited.term,
        .duration = start.durationTo(waited.ended),
    };
}

const DirectChildWait = struct {
    term: process.Child.Term,
    ended: Io.Timestamp,
};

fn waitChild(io: Io, child: *process.Child) !DirectChildWait {
    return waitChildWith(io, child, {}, struct {
        fn wait(_: void, waiting_child: *process.Child) !process.Child.Term {
            return (try wait4Child(waiting_child, 0)) orelse error.TargetWaitFailed;
        }
    }.wait);
}

fn waitChildWith(
    io: Io,
    child: *process.Child,
    context: anytype,
    comptime wait_fn: anytype,
) !DirectChildWait {
    errdefer child.kill(io);
    const term = try wait_fn(context, child);
    const ended: Io.Timestamp = .now(io, .awake);
    closeChildPipes(child);
    return .{ .term = term, .ended = ended };
}

fn readAvailableStderr(stderr_fd: fd_t, buf: *StderrCaptureBuf) !bool {
    var scratch: [stderr_pipe_read_scratch]u8 = undefined;
    var drained: usize = 0;
    while (drained < max_stderr_drain_per_poll) {
        const n = std.posix.read(stderr_fd, &scratch) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => return err,
        };
        if (n == 0) return true;
        buf.append(scratch[0..n]);
        drained += n;
    }
    return false;
}

const FcntlError = error{FcntlFailed};
const PidfdError = error{PidfdOpenFailed};
const ChildExitNotifierError = error{ChildExitNotifierFailed};

// Kernels without pidfd support cannot put the direct child in poll. SIGCHLD
// writes one byte here instead. The child's pipe copies close when it calls exec.
fn notifyChildExit(_: std.os.linux.SIG) callconv(.c) void {
    const fd = sigchld_notification_fd.load(.monotonic);
    if (fd == -1) return;
    const byte = [_]u8{1};
    _ = std.os.linux.write(fd, &byte, byte.len);
}

const ChildExitNotifier = struct {
    read_fd: fd_t,
    write_fd: fd_t,
    previous_action: std.posix.Sigaction,

    fn init() ChildExitNotifierError!ChildExitNotifier {
        std.debug.assert(sigchld_notification_fd.load(.monotonic) == -1);
        var fds: [2]fd_t = undefined;
        const pipe_result = std.os.linux.pipe2(&fds, .{
            .NONBLOCK = true,
            .CLOEXEC = true,
        });
        if (std.os.linux.errno(pipe_result) != .SUCCESS)
            return error.ChildExitNotifierFailed;
        errdefer {
            _ = std.os.linux.close(fds[0]);
            _ = std.os.linux.close(fds[1]);
        }

        var previous_action: std.posix.Sigaction = undefined;
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = notifyChildExit },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.NOCLDSTOP | std.posix.SA.RESTART,
        };
        sigchld_notification_fd.store(fds[1], .monotonic);
        std.posix.sigaction(.CHLD, &action, &previous_action);
        return .{
            .read_fd = fds[0],
            .write_fd = fds[1],
            .previous_action = previous_action,
        };
    }

    fn deinit(self: *ChildExitNotifier) void {
        sigchld_notification_fd.store(-1, .monotonic);
        std.posix.sigaction(.CHLD, &self.previous_action, null);
        _ = std.os.linux.close(self.read_fd);
        _ = std.os.linux.close(self.write_fd);
        self.* = undefined;
    }

    fn prepare(self: *ChildExitNotifier) ChildExitNotifierError!void {
        var buf: [64]u8 = undefined;
        while (true) {
            _ = std.posix.read(self.read_fd, &buf) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return error.ChildExitNotifierFailed,
            };
        }
    }
};

fn openPidfd(pid: std.os.linux.pid_t) PidfdError!fd_t {
    const result = std.os.linux.pidfd_open(pid, 0);
    return switch (std.os.linux.errno(result)) {
        .SUCCESS => @intCast(result),
        else => error.PidfdOpenFailed,
    };
}

fn pidfdAvailable() bool {
    const fd = openPidfd(std.os.linux.getpid()) catch return false;
    _ = std.os.linux.close(fd);
    return true;
}

fn getFileStatusFlags(fd: fd_t) FcntlError!u32 {
    const rc = std.os.linux.fcntl(fd, std.os.linux.F.GETFL, 0);
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => error.FcntlFailed,
    };
}

fn setFileStatusFlags(fd: fd_t, flags: u32) FcntlError!void {
    const rc = std.os.linux.fcntl(fd, std.os.linux.F.SETFL, flags);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        else => return error.FcntlFailed,
    }
}

fn wait4Child(
    child: *process.Child,
    flags: u32,
) error{TargetWaitFailed}!?process.Child.Term {
    const pid: std.os.linux.pid_t = @intCast(child.id.?);
    while (true) {
        var status: u32 = undefined;
        var ru: std.os.linux.rusage = undefined;
        const ru_ptr: ?*std.os.linux.rusage = if (child.request_resource_usage_statistics) &ru else null;
        const waited = std.os.linux.wait4(pid, &status, flags, ru_ptr);
        switch (std.os.linux.errno(waited)) {
            .SUCCESS => {
                if (waited == 0) return null;
                if (child.request_resource_usage_statistics) child.resource_usage_statistics.rusage = ru;
                return posixWaitStatusToTerm(status);
            },
            .INTR => continue,
            else => return error.TargetWaitFailed,
        }
    }
}

// Under -f, poll blocks until stderr changes. The parent does not spin while
// the target runs. wait4 records the end time before any post-exit drain.
fn waitChildAndDrainStderr(
    io: Io,
    child: *process.Child,
    start: Io.Timestamp,
    capture_buf: *StderrCaptureBuf,
    child_exit_notifier: ?*ChildExitNotifier,
) !TargetWaitResult {
    return waitChildAndDrainStderrWithPidfd(
        io,
        child,
        start,
        capture_buf,
        true,
        child_exit_notifier,
    );
}

fn waitChildAndDrainStderrWithPidfd(
    io: Io,
    child: *process.Child,
    start: Io.Timestamp,
    capture_buf: *StderrCaptureBuf,
    try_pidfd: bool,
    child_exit_notifier: ?*ChildExitNotifier,
) !TargetWaitResult {
    var child_reaped = false;
    errdefer if (child_reaped) closeChildPipes(child) else child.kill(io);
    const stderr_fd = child.stderr.?.handle;
    const pid: std.os.linux.pid_t = @intCast(child.id.?);
    const pidfd: ?fd_t = if (try_pidfd) openPidfd(pid) catch null else null;
    defer if (pidfd) |fd| {
        _ = std.os.linux.close(fd);
    };
    const exit_fd = pidfd orelse if (child_exit_notifier) |notifier|
        notifier.read_fd
    else
        return error.TargetWaitFailed;
    const initial_flags = getFileStatusFlags(stderr_fd) catch return error.TargetWaitFailed;
    const nonblock: u32 = @bitCast(std.os.linux.O{ .NONBLOCK = true });
    setFileStatusFlags(stderr_fd, initial_flags | nonblock) catch
        return error.TargetWaitFailed;

    var term: process.Child.Term = undefined;
    var duration: Io.Duration = undefined;

    while (!child_reaped) {
        var poll_fds = [_]std.posix.pollfd{
            .{
                .fd = stderr_fd,
                .events = std.posix.POLL.IN | std.posix.POLL.HUP,
                .revents = 0,
            },
            .{
                .fd = exit_fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };
        _ = try std.posix.poll(&poll_fds, -1);
        if (poll_fds[0].revents & std.posix.POLL.NVAL != 0 or
            poll_fds[1].revents & std.posix.POLL.NVAL != 0)
        {
            return error.TargetWaitFailed;
        }
        if (pidfd == null and poll_fds[1].revents != 0) {
            try child_exit_notifier.?.prepare();
        }

        if (try wait4Child(child, std.os.linux.W.NOHANG)) |waited_term| {
            term = waited_term;
            duration = start.untilNow(io, .awake);
            child_reaped = true;
        }

        const pipe_eof = try readAvailableStderr(stderr_fd, capture_buf);
        if (pipe_eof and !child_reaped) {
            term = (try wait4Child(child, 0)).?;
            duration = start.untilNow(io, .awake);
            child_reaped = true;
        }
    }

    try setFileStatusFlags(stderr_fd, initial_flags);
    closeChildPipes(child);

    return .{
        .term = term,
        .duration = duration,
    };
}

fn writeCapturedStderr(w: *Io.Writer, bytes: []const u8, truncated: bool) !void {
    if (bytes.len == 0 and !truncated) return;
    if (truncated) {
        try w.print(
            \\────────────── truncated stderr ──────────────
            \\{s}
            \\──────────────────────────────────────────────
            \\
        , .{bytes});
    } else {
        try w.print(
            \\─────────────────── stderr ───────────────────
            \\{s}
            \\──────────────────────────────────────────────
            \\
        , .{bytes});
    }
}

fn writeAllowedFailureNote(w: *Io.Writer, command: Command) !void {
    const sample_index = command.first_failure_sample orelse return;
    try w.print("\nnote: sample {d} for '{s}' exited {d}\n", .{
        sample_index,
        command.raw_cmd,
        command.first_failure_exit_code,
    });
    const captured = command.first_failure_stderr.?;
    try writeCapturedStderr(w, captured.bytes, captured.truncated);

    const later_failures = command.failed_sample_count - 1;
    if (later_failures == 1) {
        try w.print("\nnote: 1 more failed sample for '{s}' (stderr omitted)\n", .{command.raw_cmd});
    } else if (later_failures > 1) {
        try w.print("\nnote: {d} more failed samples for '{s}' (stderr omitted)\n", .{
            later_failures,
            command.raw_cmd,
        });
    }
}

fn writeAllowedFailureNotes(w: *Io.Writer, commands: []const Command) !void {
    for (commands) |command| {
        try writeAllowedFailureNote(w, command);
    }
    try w.flush();
}

const PerfSampleResetError = error{
    BadLeaderFd,
    DisableBeforeSpawnFailed,
    ResetFailed,
};

const PerfSampleDisableError = error{
    BadLeaderFd,
    DisableAfterSpawnFailed,
};

fn perfGroupIoctl(leader_fd: fd_t, request: u32) error{IoctlFailed}!void {
    const rc = std.os.linux.ioctl(leader_fd, request, PERF.IOC_FLAG_GROUP);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        else => return error.IoctlFailed,
    }
}

fn resetPerfGroupBeforeSample(leader_fd: fd_t) PerfSampleResetError!void {
    if (leader_fd == -1) return error.BadLeaderFd;
    perfGroupIoctl(leader_fd, PERF.EVENT_IOC.DISABLE) catch return error.DisableBeforeSpawnFailed;
    perfGroupIoctl(leader_fd, PERF.EVENT_IOC.RESET) catch return error.ResetFailed;
}

fn disablePerfGroupAfterSample(leader_fd: fd_t) PerfSampleDisableError!void {
    if (leader_fd == -1) return error.BadLeaderFd;
    perfGroupIoctl(leader_fd, PERF.EVENT_IOC.DISABLE) catch return error.DisableAfterSpawnFailed;
}

fn perfSetupFailureDetail(err: PerfSampleResetError) []const u8 {
    return switch (err) {
        error.BadLeaderFd => "perf group leader is not open",
        error.DisableBeforeSpawnFailed => "PERF_EVENT_IOC.DISABLE failed",
        error.ResetFailed => "PERF_EVENT_IOC.RESET failed",
    };
}

fn writePerfSetupFailuresExcept(
    w: *Io.Writer,
    commands: []const Command,
    skip_command_index: ?usize,
) !void {
    for (commands, 0..) |command, command_index| {
        if (skip_command_index == command_index) continue;
        const err = command.perf_setup_first_error orelse continue;
        const noun = if (command.perf_setup_skip_count == 1) "attempt" else "attempts";
        try w.print(
            "note: {d} earlier measurement setup {s} for '{s}' failed before target start: {s}\n",
            .{
                command.perf_setup_skip_count,
                noun,
                command.raw_cmd,
                perfSetupFailureDetail(err),
            },
        );
    }
}

fn printCollectionNotesOnStop(
    stderr_w: *Io.Writer,
    commands: []const Command,
) void {
    printCollectionNotesOnStopExceptPerf(stderr_w, commands, null);
}

fn printCollectionNotesOnStopExceptPerf(
    stderr_w: *Io.Writer,
    commands: []const Command,
    skip_command_index: ?usize,
) void {
    for (commands) |command| {
        writeAllowedFailureNote(stderr_w, command) catch {};
    }
    writePerfSetupFailuresExcept(stderr_w, commands, skip_command_index) catch {};
    stderr_w.flush() catch {};
}

fn perfIoctlSkipLimit(max_samples: u64) u32 {
    const scaled = max_samples *| 2;
    return @intCast(@max(perf_ioctl_skip_limit_min, @min(scaled, perf_ioctl_skip_limit_max)));
}

fn printPerfReadFailure(failure: PerfReadFailure) void {
    const counter_name = perf_measurements[failure.counter_index].name;
    switch (failure.reason) {
        .read => |err| switch (err) {
            error.ShortPerfRead => {
                std.debug.print(
                    "\nerror: incomplete read from perf counter '{s}' (expected {d} bytes)\n",
                    .{ counter_name, @sizeOf(PerfCounterRead) },
                );
                std.debug.print(
                    \\hint: perf counter was reset or closed before the value could be read; close other perf tools or try again
                    \\
                , .{});
            },
            else => std.debug.print(
                "\nerror: cannot read perf counter '{s}': {t}\n",
                .{ counter_name, err },
            ),
        },
        .schedule => |timing| {
            if (timing.time_running == 0) {
                std.debug.print(
                    "\nerror: perf counter '{s}' never ran; the five counters may not fit on this CPU or another perf tool may be using them\n",
                    .{counter_name},
                );
            } else {
                std.debug.print(
                    "\nerror: perf counter '{s}' ran for only {d} of {d} enabled ns; zebrac will not report an estimated count\n",
                    .{ counter_name, timing.time_running, timing.time_enabled },
                );
            }
        },
    }
}

fn printSampleMeasurementFailure(failure: SampleMeasurementFailure) void {
    switch (failure) {
        .perf_disable => |err| {
            const detail: []const u8 = switch (err) {
                error.BadLeaderFd => "perf group leader is not open",
                error.DisableAfterSpawnFailed => "PERF_EVENT_IOC.DISABLE failed",
            };
            std.debug.print("\nerror: cannot finish perf measurement: {s}\n", .{detail});
        },
        .perf_read => |read_failure| printPerfReadFailure(read_failure),
        .missing_resource_usage => std.debug.print(
            "\nerror: wait4 returned no resource-use data for the measured target\n",
            .{},
        ),
    }
}

fn printPerfOpenError(err: std.posix.PerfEventOpenError, counter_name: []const u8) void {
    std.debug.print("\nerror: cannot open perf counter '{s}': ", .{counter_name});
    switch (err) {
        error.PermissionDenied => std.debug.print(
            \\permission denied (check /proc/sys/kernel/perf_event_paranoid; try: echo -1 | sudo tee /proc/sys/kernel/perf_event_paranoid)
            \\
        , .{}),
        error.ProcessResources => std.debug.print(
            \\too many open perf events or file descriptors
            \\
        , .{}),
        error.DeviceBusy => std.debug.print(
            \\PMU is in exclusive use by another process
            \\
        , .{}),
        error.EventNotSupported => std.debug.print(
            \\counter not supported on this CPU
            \\
        , .{}),
        else => |e| std.debug.print("{t}\n", .{e}),
    }
}

fn perfEventAttrForGroupMember(config: PERF.COUNT.HW, is_leader: bool) std.os.linux.perf_event_attr {
    return .{
        .type = PERF.TYPE.HARDWARE,
        .config = @intFromEnum(config),
        .read_format = perf_read_total_time_enabled | perf_read_total_time_running,
        .flags = .{
            .disabled = is_leader,
            .exclude_kernel = true,
            .exclude_hv = true,
            .inherit = true,
            .enable_on_exec = true,
        },
    };
}

fn closePerfFds(fds: []fd_t) void {
    for (fds) |*fd| {
        if (fd.* != -1) {
            _ = std.os.linux.close(fd.*);
            fd.* = -1;
        }
    }
}

const PerfGroupOpenFailure = struct {
    counter_index: usize,
    err: std.posix.PerfEventOpenError,
};

fn openPerfEvent(
    _: void,
    attr: *std.os.linux.perf_event_attr,
    group_fd: fd_t,
) std.posix.PerfEventOpenError!fd_t {
    return std.posix.perf_event_open(attr, 0, -1, group_fd, PERF.FLAG.FD_CLOEXEC);
}

fn openPerfGroupWith(
    fds: *[perf_measurements.len]fd_t,
    context: anytype,
    comptime open_fn: anytype,
) ?PerfGroupOpenFailure {
    for (perf_measurements, fds, 0..) |measurement, *perf_fd, i| {
        var attr = perfEventAttrForGroupMember(measurement.config, i == 0);
        perf_fd.* = open_fn(context, &attr, fds[0]) catch |err| {
            closePerfFds(fds);
            return .{ .counter_index = i, .err = err };
        };
    }
    return null;
}

fn openPerfGroup(fds: *[perf_measurements.len]fd_t) error{PerfOpenFailed}!void {
    if (openPerfGroupWith(fds, {}, openPerfEvent)) |failure| {
        printPerfOpenError(failure.err, perf_measurements[failure.counter_index].name);
        return error.PerfOpenFailed;
    }
}

const PerfReadResult = union(enum) {
    values: [perf_measurements.len]u64,
    failure: PerfReadFailure,
};

fn readSamplePerfCounters(fds: *const [perf_measurements.len]fd_t) PerfReadResult {
    var values: [perf_measurements.len]u64 = undefined;
    for (0..perf_measurements.len) |i| {
        const result = readPerfFd(fds[i]) catch |err| {
            return .{ .failure = .{
                .counter_index = i,
                .reason = .{ .read = err },
            } };
        };
        values[i] = perfCounterValue(result) catch {
            return .{ .failure = .{
                .counter_index = i,
                .reason = .{ .schedule = .{
                    .time_enabled = result.time_enabled,
                    .time_running = result.time_running,
                } },
            } };
        };
    }
    return .{ .values = values };
}

const PerfCounterRead = extern struct {
    value: u64,
    time_enabled: u64,
    time_running: u64,
};

fn perfCounterValue(result: PerfCounterRead) error{ NotScheduled, Multiplexed }!u64 {
    if (result.time_running == 0) return error.NotScheduled;
    if (result.time_running != result.time_enabled) return error.Multiplexed;
    return result.value;
}

fn readPerfFd(fd: fd_t) PerfFdReadError!PerfCounterRead {
    // The three read fields stay u64 on supported 32-bit x86.
    var result: PerfCounterRead = undefined;
    const n = try std.posix.read(fd, std.mem.asBytes(&result));
    if (n != @sizeOf(PerfCounterRead)) return error.ShortPerfRead;
    return result;
}

const Measurement = struct {
    q1: u64,
    median: u64,
    q3: u64,
    min: u64,
    max: u64,
    mean: f64,
    std_dev: f64,
    outlier_count: u64,
    sample_count: u64,
    unit: Unit,

    const Unit = enum {
        nanoseconds,
        bytes,
        count,
    };

    const StatsError = error{
        NoSamples,
        ScratchTooSmall,
    };

    fn errorMessage(err: StatsError) []const u8 {
        return switch (err) {
            error.NoSamples => "no samples to summarize",
            error.ScratchTooSmall => "sort scratch buffer is shorter than the sample list",
        };
    }

    fn summarizeAll(samples: []const Sample, sort_scratch: []Sample) StatsError!Command.Measurements {
        if (samples.len == 0) return error.NoSamples;
        if (sort_scratch.len < samples.len) return error.ScratchTooSmall;
        const work = sort_scratch[0..samples.len];
        var out: Command.Measurements = undefined;
        inline for (@typeInfo(Command.Measurements).@"struct".fields) |field| {
            const meta = measurementFieldMeta(field.name);
            @field(out, field.name) = try summarizeField(samples, work, field.name, meta.unit);
        }
        return out;
    }

    // Sort a copy; leave the original sample list in run order.
    fn summarizeField(
        samples: []const Sample,
        work: []Sample,
        comptime field: []const u8,
        unit: Unit,
    ) StatsError!Measurement {
        if (samples.len == 0) return error.NoSamples;
        if (work.len < samples.len) return error.ScratchTooSmall;
        const work_slice = work[0..samples.len];
        @memcpy(work_slice, samples);
        std.mem.sort(Sample, work_slice, {}, Sample.lessThanContext(field).lessThan);
        var total: f64 = 0;
        var min: u64 = std.math.maxInt(u64);
        var max: u64 = 0;
        for (work_slice) |s| {
            const v = @field(s, field);
            total += @floatFromInt(v);
            if (v < min) min = v;
            if (v > max) max = v;
        }
        const mean = total / @as(f64, @floatFromInt(work_slice.len));
        var std_dev: f64 = 0;
        for (work_slice) |s| {
            const v = @field(s, field);
            const delta: f64 = @as(f64, @floatFromInt(v)) - mean;
            std_dev += delta * delta;
        }
        if (work_slice.len > 1) {
            std_dev /= @floatFromInt(work_slice.len - 1);
            std_dev = @sqrt(std_dev);
        }

        const q1 = @field(work_slice[work_slice.len / 4], field);
        const q3 = if (work_slice.len < 4)
            @field(work_slice[work_slice.len - 1], field)
        else
            @field(work_slice[work_slice.len - work_slice.len / 4], field);
        var outlier_count: u64 = 0;
        const iqr: f64 = @floatFromInt(q3 - q1);
        const low_fence = @as(f64, @floatFromInt(q1)) - 1.5 * iqr;
        const high_fence = @as(f64, @floatFromInt(q3)) + 1.5 * iqr;
        for (work_slice) |s| {
            const v: f64 = @floatFromInt(@field(s, field));
            if (v < low_fence or v > high_fence) outlier_count += 1;
        }
        return .{
            .q1 = q1,
            .median = @field(work_slice[work_slice.len / 2], field),
            .q3 = q3,
            .mean = mean,
            .min = min,
            .max = max,
            .std_dev = std_dev,
            .outlier_count = outlier_count,
            .sample_count = work_slice.len,
            .unit = unit,
        };
    }
};

fn printMeasurement(
    terminal: Io.Terminal,
    layout: TableLayout,
    m: Measurement,
    name: []const u8,
    first_m: ?Measurement,
    with_delta: bool,
    all_commands_have_two_samples: bool,
) !void {
    const w = terminal.writer;
    const color_enabled = terminal.mode != .no_color;
    var vis: usize = 0;
    var unit_buf: [32]u8 = undefined;

    try w.splatByteAll(' ', row_indent);
    try w.writeAll(name);
    vis = row_indent + name.len;
    try TableLayout.padVis(w, &vis, layout.name_w);

    try TableLayout.gap(w, &vis);
    try writeUnitAligned(terminal, w, &vis, .right, layout.meanSepVis(), m.mean, m.unit, .bright_green, color_enabled, &unit_buf);
    try w.writeAll(sep_mean);
    vis = layout.meanSepVis() + visibleLen(sep_mean);
    try writeUnitAligned(terminal, w, &vis, .left, 0, m.std_dev, m.unit, .green, color_enabled, &unit_buf);
    try TableLayout.padVis(w, &vis, layout.stdColEndVis());

    try TableLayout.gap(w, &vis);
    try writeUnitAligned(terminal, w, &vis, .right, layout.minSepVis(), @floatFromInt(m.min), m.unit, .cyan, color_enabled, &unit_buf);
    try w.writeAll(sep_minmax);
    vis = layout.minSepVis() + visibleLen(sep_minmax);
    try writeUnitAligned(terminal, w, &vis, .left, 0, @floatFromInt(m.max), m.unit, .magenta, color_enabled, &unit_buf);
    try TableLayout.padVis(w, &vis, layout.minMaxColEndVis());

    try TableLayout.gap(w, &vis);
    try TableLayout.padVis(w, &vis, layout.outlierStartVis());
    var outlier_buf: [32]u8 = undefined;
    const outlier_line = try formatOutlierLine(&outlier_buf, m.outlier_count, m.sample_count);
    if (metricExceedsOutlierRateThreshold(m))
        try terminal.setColor(.yellow)
    else
        try terminal.setColor(.dim);
    try w.writeAll(outlier_line);
    try terminal.setColor(.reset);
    vis = layout.outlierStartVis() + visibleLen(outlier_line);
    try TableLayout.padVis(w, &vis, layout.outlierStartVis() + layout.outlier_w);

    if (with_delta) {
        try TableLayout.gap(w, &vis);
        try TableLayout.padVis(w, &vis, layout.deltaStartVis());
        try writeDelta(
            w,
            terminal,
            &vis,
            layout,
            m,
            first_m,
            all_commands_have_two_samples,
            color_enabled,
        );
    }

    try terminal.setColor(.reset);
    try w.writeAll("\n");
}

fn printNum3SigFigs(w: *std.Io.Writer, num: f64) !void {
    if (!std.math.isFinite(num)) {
        try w.writeAll("n/a");
        return;
    }
    if (num >= 100) {
        try w.print("{d:.0}", .{num});
    } else if (num >= 10) {
        try w.print("{d:.1}", .{num});
    } else {
        try w.print("{d:.2}", .{num});
    }
}

// --- Tests ---

fn sampleWith(comptime field: []const u8, value: u64) Sample {
    var s = std.mem.zeroes(Sample);
    @field(s, field) = value;
    return s;
}

fn testMeasurement(unit: Measurement.Unit) Measurement {
    return .{
        .q1 = 1,
        .median = 2,
        .q3 = 3,
        .min = 1,
        .max = 3,
        .mean = 2,
        .std_dev = 0,
        .outlier_count = 0,
        .sample_count = 2,
        .unit = unit,
    };
}

fn measurementsFill(each: Measurement) Command.Measurements {
    var out: Command.Measurements = undefined;
    inline for (@typeInfo(Command.Measurements).@"struct".fields) |field| {
        @field(out, field.name) = each;
    }
    return out;
}

fn measurementsFromParts(wall: Measurement, rss: Measurement, count: Measurement) Command.Measurements {
    return .{
        .wall_time = wall,
        .peak_rss = rss,
        .minor_faults = count,
        .major_faults = count,
        .cpu_cycles = count,
        .instructions = count,
        .cache_references = count,
        .cache_misses = count,
        .branch_misses = count,
    };
}

fn expectScaledDisplay(x: f64, unit: Measurement.Unit, want: []const u8) !void {
    var buf: [32]u8 = undefined;
    const s = scaleUnit(x, unit);
    var w = std.Io.Writer.fixed(&buf);
    try printNum3SigFigs(&w, s.val);
    try w.writeAll(s.suffix);
    try std.testing.expectEqualStrings(want, w.buffered());
}

fn commandWithOnlyWallOutlierPct(sample_count: u64, outlier_count: u64) Command {
    var wall = testMeasurement(.nanoseconds);
    wall.sample_count = sample_count;
    wall.outlier_count = outlier_count;
    const normal = testMeasurement(.count);
    return .{
        .raw_cmd = "cmd",
        .argv = &.{},
        .measurements = measurementsFromParts(wall, normal, normal),
        .sample_count = @intCast(sample_count),
        .failed_sample_count = 0,
    };
}

fn withPipe(comptime op: *const fn (fd_t) anyerror!void) !void {
    var pipefd: [2]i32 = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.pipe(&pipefd)));
    defer {
        _ = std.os.linux.close(pipefd[0]);
        _ = std.os.linux.close(pipefd[1]);
    }
    try op(pipefd[0]);
}

fn summarizeWallTime(values: []const u64) !Measurement {
    var samples: [32]Sample = undefined;
    for (values, 0..) |v, i| samples[i] = sampleWith("wall_time", v);
    var scratch: [32]Sample = undefined;
    return try Measurement.summarizeField(samples[0..values.len], scratch[0..values.len], "wall_time", .nanoseconds);
}

fn measurementForDeltaTest(mean: f64, std_dev: f64, sample_count: u64) Measurement {
    return .{
        .q1 = 0,
        .median = 0,
        .q3 = 0,
        .min = 0,
        .max = 0,
        .mean = mean,
        .std_dev = std_dev,
        .outlier_count = 0,
        .sample_count = sample_count,
        .unit = .count,
    };
}

fn stripAnsiForTest(input: []const u8, out: *[256]u8) []const u8 {
    var o: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\x1b') {
            i += 1;
            while (i < input.len and input[i] != 'm') : (i += 1) {}
            if (i < input.len) i += 1;
            continue;
        }
        out[o] = input[i];
        o += 1;
        i += 1;
    }
    return out[0..o];
}

fn expectDeltaPlain(
    want: []const u8,
    m: Measurement,
    first_m: ?Measurement,
    all_commands_have_two_samples: bool,
) !void {
    var buf: [64]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    try writeDeltaPlain(&w, m, first_m, all_commands_have_two_samples);
    try std.testing.expectEqualStrings(want, w.buffered());
}

fn tableFixture(
    q1: u64,
    median: u64,
    q3: u64,
    min: u64,
    max: u64,
    mean: f64,
    std_dev: f64,
    unit: Measurement.Unit,
) Measurement {
    return .{
        .q1 = q1,
        .median = median,
        .q3 = q3,
        .min = min,
        .max = max,
        .mean = mean,
        .std_dev = std_dev,
        .outlier_count = 0,
        .sample_count = 8,
        .unit = unit,
    };
}

const TableFixtures = struct {
    const wall = tableFixture(640_000, 659_000, 677_000, 638_000, 719_000, 659_000, 27_800, .nanoseconds);
    const rss = tableFixture(1_150_000, 1_150_000, 1_150_000, 1_150_000, 1_220_000, 1_160_000, 23_200, .bytes);
    const faults = tableFixture(60, 62, 63, 60, 63, 62.3, 0.58, .count);
    const cycles = tableFixture(400_000, 584_000, 700_000, 334_000, 795_000, 584_000, 233_000, .count);
    const zero_delta_rss = tableFixture(1_200_000, 1_220_000, 1_240_000, 1_190_000, 1_300_000, 1_220_000, 25_000, .bytes);
};

fn tableFixtureMeasurements(major_faults: Measurement) Command.Measurements {
    var out = measurementsFill(TableFixtures.wall);
    out.peak_rss = TableFixtures.rss;
    out.minor_faults = TableFixtures.faults;
    out.cpu_cycles = TableFixtures.cycles;
    out.major_faults = major_faults;
    return out;
}

fn renderResultsTableForTest(
    buf: *[8192]u8,
    measurements: Command.Measurements,
    baseline: ?Command.Measurements,
    mode: Io.Terminal.Mode,
    show_major_faults: bool,
) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    const term = Io.Terminal{ .writer = &w, .mode = mode };
    try printResultsTable(
        &w,
        term,
        measurements,
        baseline,
        baseline != null,
        show_major_faults,
        true,
    );
    return w.buffered();
}

fn visibleIndexOfUtf8(haystack: []const u8, needle: []const u8) ?usize {
    var vis: usize = 0;
    var i: usize = 0;
    while (i < haystack.len) {
        if (std.mem.startsWith(u8, haystack[i..], needle)) return vis;
        advanceVisibleColumn(haystack, &i, &vis);
    }
    return null;
}

fn advanceVisibleColumn(s: []const u8, i: *usize, vis: *usize) void {
    if (i.* >= s.len) return;
    if (s[i.*] == '\x1b' and i.* + 1 < s.len and s[i.* + 1] == '[') {
        i.* += 2;
        while (i.* < s.len and s[i.*] != 'm') i.* += 1;
        if (i.* < s.len) i.* += 1;
        return;
    }
    const cp_len = std.unicode.utf8CodepointSequenceLength(s[i.*]) catch 1;
    i.* += cp_len;
    vis.* += 1;
}

fn isTableDataRow(vis_line: []const u8) bool {
    return std.mem.startsWith(u8, vis_line, "  wall_") or
        std.mem.startsWith(u8, vis_line, "  peak_") or
        std.mem.startsWith(u8, vis_line, "  minor_") or
        std.mem.startsWith(u8, vis_line, "  major_") or
        std.mem.startsWith(u8, vis_line, "  cpu_") or
        std.mem.startsWith(u8, vis_line, "  instr") or
        std.mem.startsWith(u8, vis_line, "  cache_") or
        std.mem.startsWith(u8, vis_line, "  branch_");
}

fn scanTableSeparatorAlignment(out: []const u8, layout: TableLayout, check_zero_delta_order: bool) !void {
    const expect_mean_sep = layout.meanSepVis();
    const expect_min_sep = layout.minSepVis();
    const expect_outlier_start = layout.outlierStartVis();
    var line_start: usize = 0;
    while (line_start < out.len) {
        const line_end = std.mem.indexOfScalarPos(u8, out, line_start, '\n') orelse out.len;
        const line = out[line_start..line_end];
        var plain_buf: [256]u8 = undefined;
        const vis_line = stripAnsiForTest(line, &plain_buf);
        if (std.mem.startsWith(u8, vis_line, "  measurement")) {
            try std.testing.expectEqual(expect_mean_sep, visibleIndexOfUtf8(line, sep_mean));
            try std.testing.expectEqual(expect_min_sep, visibleIndexOfUtf8(line, sep_minmax));
            try std.testing.expectEqual(expect_outlier_start, visibleIndexOfUtf8(line, "outliers"));
        }
        if (isTableDataRow(vis_line)) {
            if (check_zero_delta_order and std.mem.startsWith(u8, vis_line, "  wall_time")) {
                try std.testing.expect(std.mem.indexOf(u8, vis_line, "-  0.0%") == null);
                const delta_pct = std.mem.lastIndexOf(u8, vis_line, "0%") orelse unreachable;
                const outlier_pct = std.mem.indexOf(u8, vis_line, "0 (0%)") orelse unreachable;
                try std.testing.expect(delta_pct > outlier_pct);
            }
            try std.testing.expectEqual(expect_mean_sep, visibleIndexOfUtf8(line, sep_mean));
            try std.testing.expectEqual(expect_min_sep, visibleIndexOfUtf8(line, sep_minmax));
            const outlier_at = visibleIndexOfUtf8(line, "0 (0%)") orelse visibleIndexOfUtf8(line, "outliers");
            if (outlier_at) |at| try std.testing.expectEqual(expect_outlier_start, at);
        }
        if (line_end == out.len) break;
        line_start = line_end + 1;
    }
}

fn scanSingleSpaceBeforeSep(out: []const u8, sep: []const u8, sep_vis: usize) !void {
    std.debug.assert(sep.len > 0 and sep[0] == ' ');
    var line_start: usize = 0;
    while (line_start < out.len) {
        const line_end = std.mem.indexOfScalarPos(u8, out, line_start, '\n') orelse out.len;
        const line = out[line_start..line_end];
        var plain_buf: [256]u8 = undefined;
        const vis_line = stripAnsiForTest(line, &plain_buf);
        if (isTableDataRow(vis_line)) {
            const sep_at = visibleIndexOfUtf8(line, sep) orelse return error.TestExpectedEqual;
            try std.testing.expectEqual(sep_vis, sep_at);
            if (sep_at > 0) {
                var vis: usize = 0;
                var i: usize = 0;
                while (i < line.len and vis < sep_at) advanceVisibleColumn(line, &i, &vis);
                try std.testing.expect(vis == sep_at);
                try std.testing.expect(i > 0 and line[i - 1] != ' ');
            }
        }
        if (line_end == out.len) break;
        line_start = line_end + 1;
    }
}

fn scanTableInvariants(out: []const u8, layout: TableLayout, check_zero_delta_order: bool) !void {
    try scanTableSeparatorAlignment(out, layout, check_zero_delta_order);
    try scanSingleSpaceBeforeSep(out, sep_mean, layout.meanSepVis());
    try scanSingleSpaceBeforeSep(out, sep_minmax, layout.minSepVis());
}

const TableAlignmentCase = enum { mixed_units, zero_delta };

fn tableAlignmentInvariantsTest(mode: Io.Terminal.Mode, case: TableAlignmentCase) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const term = Io.Terminal{ .writer = &w, .mode = mode };
    const f = TableFixtures;

    switch (case) {
        .mixed_units => {
            const measurements = tableFixtureMeasurements(f.wall);
            const layout = TableLayout.compute(measurements, measurements, true, true, true);
            try TableLayout.printHeader(&w, term, layout, true);
            try printMeasurement(term, layout, f.wall, "wall_time", null, true, true);
            try printMeasurement(term, layout, f.rss, "peak_rss", f.wall, true, true);
            try printMeasurement(term, layout, f.faults, "minor_faults", f.wall, true, true);
            try printMeasurement(term, layout, f.cycles, "cpu_cycles", f.wall, true, true);
            try scanTableInvariants(w.buffered(), layout, false);
        },
        .zero_delta => {
            const baseline = tableFixtureMeasurements(f.wall);
            const compare = Command.Measurements{
                .wall_time = f.wall,
                .peak_rss = f.zero_delta_rss,
                .minor_faults = f.faults,
                .major_faults = f.wall,
                .cpu_cycles = f.wall,
                .instructions = f.wall,
                .cache_references = f.wall,
                .cache_misses = f.wall,
                .branch_misses = f.wall,
            };
            const layout = TableLayout.compute(compare, baseline, true, true, true);
            try TableLayout.printHeader(&w, term, layout, true);
            try printMeasurement(term, layout, compare.wall_time, "wall_time", baseline.wall_time, true, true);
            try printMeasurement(term, layout, compare.peak_rss, "peak_rss", baseline.peak_rss, true, true);
            try printMeasurement(term, layout, compare.minor_faults, "minor_faults", baseline.minor_faults, true, true);
            try scanTableInvariants(w.buffered(), layout, true);
        },
    }
}

fn checkSummarizeFieldInvariants(n: u8, samples: []const Sample, scratch: []Sample) !void {
    const m = try Measurement.summarizeField(samples[0..n], scratch[0..n], "wall_time", .nanoseconds);
    try std.testing.expectEqual(n, m.sample_count);
    try std.testing.expect(m.min <= m.max);
    try std.testing.expect(m.outlier_count <= n);
    try std.testing.expect(m.q1 <= m.median or n == 1);
    try std.testing.expect(m.median <= m.q3 or n == 1);
    for (samples[0..n]) |s| {
        try std.testing.expect(s.wall_time >= m.min);
        try std.testing.expect(s.wall_time <= m.max);
    }

    try std.testing.expectError(error.NoSamples, Measurement.summarizeField(samples[0..0], scratch[0..0], "wall_time", .nanoseconds));
    if (n > 0) {
        try std.testing.expectError(error.ScratchTooSmall, Measurement.summarizeField(samples[0..n], scratch[0 .. n - 1], "wall_time", .nanoseconds));
    }
}

fn fuzzSummarizeField(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    const n = smith.valueRangeAtMost(u8, 1, 32);
    var samples: [32]Sample = undefined;
    for (0..n) |i| {
        samples[i] = sampleWith("wall_time", smith.valueRangeAtMost(u64, 0, std.math.maxInt(u32)));
    }
    var scratch: [32]Sample = undefined;
    try checkSummarizeFieldInvariants(n, &samples, &scratch);
}

test "[unit] - [JSON v1]: keeps the exact schema, fields, and raw units" {
    const json_cases = [_]struct { arg: []const u8, want: ?[]const u8 }{
        .{ .arg = "--json=out.json", .want = "out.json" },
        .{ .arg = "--json=", .want = default_json_output_path },
        .{ .arg = "--json", .want = null },
    };
    for (json_cases) |c| {
        const got = jsonPathFromEqualsArg(c.arg);
        if (c.want) |want| try std.testing.expectEqualStrings(want, got.?) else try std.testing.expect(got == null);
    }

    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const wall = testMeasurement(.nanoseconds);
    const count = testMeasurement(.count);
    const measurements = measurementsFromParts(wall, testMeasurement(.bytes), count);
    var commands = [_]Command{.{
        .raw_cmd = "/bin/true",
        .argv = &.{"/bin/true"},
        .measurements = measurements,
        .sample_count = 5,
        .failed_sample_count = 2,
    }};
    const config = JsonRunConfig{
        .duration_ms = 500,
        .min_samples = 2,
        .max_samples = help.max_samples_cap,
        .max_samples_requested = 50_000,
        .warmup = 1,
        .allow_failures = false,
    };

    try printJsonOutput(&w, &commands, config);

    const JsonMeasurementV1 = struct {
        mean: f64,
        std_dev: f64,
        min: u64,
        max: u64,
        median: u64,
        q1: u64,
        q3: u64,
        outlier_count: u64,
        sample_count: u64,
        unit: []const u8,
    };
    const JsonResultV1 = struct {
        command: []const u8,
        sample_count: usize,
        failed_sample_count: u64,
        argv: []const []const u8,
        wall_time: JsonMeasurementV1,
        peak_rss: JsonMeasurementV1,
        minor_faults: JsonMeasurementV1,
        major_faults: JsonMeasurementV1,
        cpu_cycles: JsonMeasurementV1,
        instructions: JsonMeasurementV1,
        cache_references: JsonMeasurementV1,
        cache_misses: JsonMeasurementV1,
        branch_misses: JsonMeasurementV1,
    };
    const Parsed = struct {
        schema_version: u32,
        zebrac_version: []const u8,
        config: struct {
            duration_ms: u64,
            min_samples: u64,
            max_samples: u64,
            max_samples_cap: u64,
            max_samples_requested: ?u64,
            warmup: usize,
            allow_failures: bool,
        },
        results: []JsonResultV1,
    };
    const parsed = try std.json.parseFromSlice(Parsed, std.testing.allocator, w.buffered(), .{});
    defer parsed.deinit();

    try std.testing.expectEqual(json_schema_version, parsed.value.schema_version);
    try std.testing.expectEqualStrings(help.version, parsed.value.zebrac_version);
    try std.testing.expectEqual(@as(u64, 500), parsed.value.config.duration_ms);
    try std.testing.expectEqual(@as(u64, 2), parsed.value.config.min_samples);
    try std.testing.expectEqual(help.max_samples_cap, parsed.value.config.max_samples);
    try std.testing.expectEqual(help.max_samples_cap, parsed.value.config.max_samples_cap);
    try std.testing.expectEqual(@as(?u64, 50_000), parsed.value.config.max_samples_requested);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.config.warmup);
    try std.testing.expect(!parsed.value.config.allow_failures);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.results.len);
    const result = parsed.value.results[0];
    try std.testing.expectEqualStrings("/bin/true", result.command);
    try std.testing.expectEqual(@as(usize, 5), result.sample_count);
    try std.testing.expectEqual(@as(u64, 2), result.failed_sample_count);
    try std.testing.expectEqual(@as(usize, 1), result.argv.len);
    try std.testing.expectEqualStrings("/bin/true", result.argv[0]);
    inline for (@typeInfo(Command.Measurements).@"struct".fields) |field| {
        const measurement = @field(result, field.name);
        try std.testing.expectEqual(@as(f64, 2), measurement.mean);
        try std.testing.expectEqual(@as(f64, 0), measurement.std_dev);
        try std.testing.expectEqual(@as(u64, 1), measurement.min);
        try std.testing.expectEqual(@as(u64, 3), measurement.max);
        try std.testing.expectEqual(@as(u64, 2), measurement.median);
        try std.testing.expectEqual(@as(u64, 1), measurement.q1);
        try std.testing.expectEqual(@as(u64, 3), measurement.q3);
        try std.testing.expectEqual(@as(u64, 0), measurement.outlier_count);
        try std.testing.expectEqual(@as(u64, 2), measurement.sample_count);
        try std.testing.expectEqualStrings(
            @tagName(measurementFieldMeta(field.name).unit),
            measurement.unit,
        );
    }
}

test "[failure] - [JSON output]: stops on a failed write and explains file errors" {
    const measurement = testMeasurement(.count);
    var commands = [_]Command{.{
        .raw_cmd = "/bin/true",
        .argv = &.{"/bin/true"},
        .measurements = measurementsFill(measurement),
        .sample_count = 2,
        .failed_sample_count = 0,
    }};
    const config = JsonRunConfig{
        .duration_ms = 0,
        .min_samples = 2,
        .max_samples = 2,
        .max_samples_requested = null,
        .warmup = 0,
        .allow_failures = false,
    };
    var failing: Io.Writer = .failing;

    try std.testing.expectError(error.WriteFailed, printJsonOutput(&failing, &commands, config));
    try std.testing.expectEqualStrings("no space left on the device", jsonFileErrorMessage(error.NoSpaceLeft));
    try std.testing.expectEqualStrings("access denied", jsonFileErrorMessage(error.AccessDenied));
    try std.testing.expectEqualStrings("the write failed", jsonFileErrorMessage(error.WriteFailed));
}

test "[unit] - [outlier note]: requires the configured rate and metric count" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("2 (20%)", try formatOutlierLine(&buf, 2, 10));
    try std.testing.expectEqualStrings("99 (n/a)", try formatOutlierLine(&buf, 99, 0));

    var meas = testMeasurement(.count);
    meas.sample_count = 10;
    meas.outlier_count = 1;
    try std.testing.expect(metricExceedsOutlierRateThreshold(meas));
    const all_high = measurementsFill(meas);
    try std.testing.expect(measurementsTriggerOutlierNote(all_high));

    meas.outlier_count = 0;
    try std.testing.expect(!metricExceedsOutlierRateThreshold(meas));

    const single_at_threshold = commandWithOnlyWallOutlierPct(10, 1);
    try std.testing.expect(metricExceedsOutlierRateThreshold(single_at_threshold.measurements.wall_time));
    try std.testing.expect(!measurementsTriggerOutlierNote(single_at_threshold.measurements));
    try std.testing.expect(!anyCommandTriggersOutlierNote(&.{single_at_threshold}));

    const single_high_rate = commandWithOnlyWallOutlierPct(10, 2);
    try std.testing.expect(metricExceedsOutlierRateThreshold(single_high_rate.measurements.wall_time));
    try std.testing.expect(!measurementsTriggerOutlierNote(single_high_rate.measurements));

    var wall = testMeasurement(.nanoseconds);
    wall.sample_count = 10;
    wall.outlier_count = 1;
    var rss = testMeasurement(.bytes);
    rss.sample_count = 10;
    rss.outlier_count = 1;
    const two_at_threshold = measurementsFromParts(wall, rss, testMeasurement(.count));
    try std.testing.expect(measurementsTriggerOutlierNote(two_at_threshold));

    wall.outlier_count = 2;
    rss.outlier_count = 2;
    const two_high = measurementsFromParts(wall, rss, testMeasurement(.count));
    try std.testing.expect(measurementsTriggerOutlierNote(two_high));
    try std.testing.expect(anyCommandTriggersOutlierNote(&.{
        .{
            .raw_cmd = "cmd",
            .argv = &.{},
            .measurements = two_high,
            .sample_count = 10,
            .failed_sample_count = 0,
        },
    }));

    var zero_n = testMeasurement(.count);
    zero_n.sample_count = 0;
    zero_n.outlier_count = 99;
    try std.testing.expect(!metricExceedsOutlierRateThreshold(zero_n));
    try std.testing.expect(!measurementsTriggerOutlierNote(measurementsFill(zero_n)));
}

test "[unit] - [stderr capture]: keeps a bounded prefix and truncation state" {
    var storage: [8]u8 = undefined;
    var buf: StderrCaptureBuf = .{ .storage = &storage };

    buf.append("abc");
    try std.testing.expectEqual(@as(usize, 3), buf.len);
    buf.append("defghij");
    try std.testing.expect(buf.truncated);
    try std.testing.expectEqualStrings("abcdefgh", buf.view().bytes);
    buf.append("zzz");
    try std.testing.expectEqual(@as(usize, 8), buf.len);

    buf.reset();
    try std.testing.expectEqual(@as(usize, 0), buf.len);
    try std.testing.expect(!buf.truncated);
}

test "[edge] - [collection mapping]: checks size and cleans up failed setup" {
    const page_size = std.heap.pageSize();
    try std.testing.expectEqual(page_size, try DontForkMapping.roundedLength(1));
    try std.testing.expectEqual(page_size, try DontForkMapping.roundedLength(page_size));
    try std.testing.expectEqual(page_size * 2, try DontForkMapping.roundedLength(page_size + 1));
    try std.testing.expectError(error.EmptyMapping, DontForkMapping.roundedLength(0));
    try std.testing.expectError(
        error.MappingSizeOverflow,
        DontForkMapping.roundedLength(std.math.maxInt(usize)),
    );
    try std.testing.expectError(
        error.CollectionSizeOverflow,
        CollectionStorage.checkedBytes(std.math.maxInt(usize), 2),
    );

    var map_failure = struct {
        map_calls: usize = 0,
        advise_calls: usize = 0,
        unmap_calls: usize = 0,

        fn map(self: *@This(), _: usize) error{OutOfMemory}![]align(std.heap.page_size_min) u8 {
            self.map_calls += 1;
            return error.OutOfMemory;
        }

        fn advise(self: *@This(), _: []align(std.heap.page_size_min) u8) !void {
            self.advise_calls += 1;
        }

        fn unmap(self: *@This(), _: []align(std.heap.page_size_min) u8) void {
            self.unmap_calls += 1;
        }
    }{};
    try std.testing.expectError(
        error.OutOfMemory,
        DontForkMapping.initWith(
            1,
            &map_failure,
            @TypeOf(map_failure).map,
            @TypeOf(map_failure).advise,
            @TypeOf(map_failure).unmap,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), map_failure.map_calls);
    try std.testing.expectEqual(@as(usize, 0), map_failure.advise_calls);
    try std.testing.expectEqual(@as(usize, 0), map_failure.unmap_calls);

    var advice_failure = struct {
        backing: [std.heap.page_size_max]u8 align(std.heap.page_size_min) = undefined,
        map_calls: usize = 0,
        advise_calls: usize = 0,
        unmap_calls: usize = 0,

        fn map(self: *@This(), len: usize) ![]align(std.heap.page_size_min) u8 {
            self.map_calls += 1;
            return self.backing[0..len];
        }

        fn advise(self: *@This(), _: []align(std.heap.page_size_min) u8) error{InvalidSyscall}!void {
            self.advise_calls += 1;
            return error.InvalidSyscall;
        }

        fn unmap(self: *@This(), _: []align(std.heap.page_size_min) u8) void {
            self.unmap_calls += 1;
        }
    }{};
    try std.testing.expectError(
        error.InvalidSyscall,
        DontForkMapping.initWith(
            1,
            &advice_failure,
            @TypeOf(advice_failure).map,
            @TypeOf(advice_failure).advise,
            @TypeOf(advice_failure).unmap,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), advice_failure.map_calls);
    try std.testing.expectEqual(@as(usize, 1), advice_failure.advise_calls);
    try std.testing.expectEqual(@as(usize, 1), advice_failure.unmap_calls);
}

test "[integration] - [collection mapping]: touched pages are absent after fork" {
    var mapping = try DontForkMapping.init(std.heap.pageSize());
    defer mapping.deinit();
    @memset(mapping.memory, 0xA5);

    const fork_result = std.os.linux.fork();
    switch (std.os.linux.errno(fork_result)) {
        .SUCCESS => {},
        else => return error.ForkFailed,
    }
    if (fork_result == 0) {
        var resident: [1]u8 = undefined;
        const result = std.os.linux.mincore(mapping.memory.ptr, mapping.memory.len, &resident);
        const exit_code: i32 = if (std.os.linux.errno(result) == .NOMEM) 0 else 1;
        std.os.linux.exit(exit_code);
    }

    var status: u32 = undefined;
    const waited = std.os.linux.waitpid(@intCast(fork_result), &status, 0);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(waited));
    try std.testing.expect(std.os.linux.W.IFEXITED(status));
    try std.testing.expectEqual(@as(u8, 0), std.os.linux.W.EXITSTATUS(status));
}

test "[unit] - [collection storage]: gives each command separate sample and stderr space" {
    var storage = try CollectionStorage.init(3, 5, true);
    defer storage.deinit();

    const first_samples = storage.samplesFor(0);
    const third_samples = storage.samplesFor(2);
    try std.testing.expectEqual(@as(usize, 5), first_samples.len);
    try std.testing.expectEqual(@as(usize, 5), third_samples.len);
    try std.testing.expect(@intFromPtr(first_samples.ptr) != @intFromPtr(third_samples.ptr));

    var buffers = storage.failureBuffersFor(1);
    buffers.first.append("first");
    buffers.second.append("second");
    try std.testing.expectEqualStrings("first", buffers.first.view().bytes);
    try std.testing.expectEqualStrings("second", buffers.second.view().bytes);
    try std.testing.expect(@intFromPtr(buffers.first.storage.ptr) != @intFromPtr(buffers.second.storage.ptr));
}

test "[unit] - [perf counters]: validates setup, reads, and schedule times" {
    try std.testing.expectError(error.BadLeaderFd, resetPerfGroupBeforeSample(-1));
    try std.testing.expectError(error.BadLeaderFd, disablePerfGroupAfterSample(-1));

    const leader = perfEventAttrForGroupMember(PERF.COUNT.HW.CPU_CYCLES, true);
    const child = perfEventAttrForGroupMember(PERF.COUNT.HW.INSTRUCTIONS, false);
    const expected_read_format = perf_read_total_time_enabled | perf_read_total_time_running;
    try std.testing.expectEqual(expected_read_format, leader.read_format);
    try std.testing.expectEqual(expected_read_format, child.read_format);
    try std.testing.expect(leader.flags.disabled);
    try std.testing.expect(!child.flags.disabled);

    try withPipe(struct {
        fn disableOnPipe(fd: fd_t) !void {
            try std.testing.expectError(error.DisableAfterSpawnFailed, disablePerfGroupAfterSample(fd));
        }
    }.disableOnPipe);
    try withPipe(struct {
        fn resetOnPipe(fd: fd_t) !void {
            resetPerfGroupBeforeSample(fd) catch |err| switch (err) {
                error.DisableBeforeSpawnFailed, error.ResetFailed => {},
                else => return err,
            };
        }
    }.resetOnPipe);

    const limit_cases = [_]struct { max_samples: u64, want: u32 }{
        .{ .max_samples = 5, .want = perf_ioctl_skip_limit_min },
        .{ .max_samples = 20, .want = 40 },
        .{ .max_samples = 10_000, .want = perf_ioctl_skip_limit_max },
    };
    for (limit_cases) |c| try std.testing.expectEqual(c.want, perfIoctlSkipLimit(c.max_samples));

    var pipefd: [2]i32 = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.pipe(&pipefd)));
    _ = std.os.linux.close(pipefd[1]);
    defer _ = std.os.linux.close(pipefd[0]);
    try std.testing.expectError(error.ShortPerfRead, readPerfFd(pipefd[0]));
    var short_fds: [perf_measurements.len]fd_t = @splat(-1);
    short_fds[0] = pipefd[0];
    switch (readSamplePerfCounters(&short_fds)) {
        .failure => |failure| {
            try std.testing.expectEqual(@as(usize, 0), failure.counter_index);
            switch (failure.reason) {
                .read => |err| try std.testing.expectEqual(error.ShortPerfRead, err),
                .schedule => return error.TestUnexpectedResult,
            }
        },
        .values => return error.TestUnexpectedResult,
    }

    var value_pipe: [2]i32 = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.pipe(&value_pipe)));
    defer {
        _ = std.os.linux.close(value_pipe[0]);
        _ = std.os.linux.close(value_pipe[1]);
    }
    const expected = PerfCounterRead{
        .value = 0xFEED_BEEF_0123_4567,
        .time_enabled = 1234,
        .time_running = 1234,
    };
    const expected_bytes = std.mem.asBytes(&expected);
    try std.testing.expectEqual(
        @sizeOf(PerfCounterRead),
        std.os.linux.write(value_pipe[1], expected_bytes.ptr, expected_bytes.len),
    );
    try std.testing.expectEqual(expected, try readPerfFd(value_pipe[0]));
    try std.testing.expectEqual(expected.value, try perfCounterValue(expected));
    try std.testing.expectError(error.NotScheduled, perfCounterValue(.{
        .value = 10,
        .time_enabled = 100,
        .time_running = 0,
    }));
    try std.testing.expectError(error.Multiplexed, perfCounterValue(.{
        .value = 10,
        .time_enabled = 100,
        .time_running = 90,
    }));

    const not_scheduled = PerfCounterRead{
        .value = 10,
        .time_enabled = 100,
        .time_running = 0,
    };
    const not_scheduled_bytes = std.mem.asBytes(&not_scheduled);
    try std.testing.expectEqual(
        @sizeOf(PerfCounterRead),
        std.os.linux.write(value_pipe[1], not_scheduled_bytes.ptr, not_scheduled_bytes.len),
    );
    var schedule_fds: [perf_measurements.len]fd_t = @splat(-1);
    schedule_fds[0] = value_pipe[0];
    switch (readSamplePerfCounters(&schedule_fds)) {
        .failure => |failure| {
            try std.testing.expectEqual(@as(usize, 0), failure.counter_index);
            switch (failure.reason) {
                .schedule => |timing| {
                    try std.testing.expectEqual(@as(u64, 100), timing.time_enabled);
                    try std.testing.expectEqual(@as(u64, 0), timing.time_running);
                },
                .read => return error.TestUnexpectedResult,
            }
        },
        .values => return error.TestUnexpectedResult,
    }
}

test "[regression] - [perf setup warnings]: keeps an earlier command warning when a later command stops" {
    const commands = [_]Command{
        .{
            .raw_cmd = "first command",
            .argv = &.{},
            .measurements = undefined,
            .sample_count = 1,
            .failed_sample_count = 0,
            .perf_setup_skip_count = 1,
            .perf_setup_first_error = error.ResetFailed,
        },
        .{
            .raw_cmd = "second command",
            .argv = &.{},
            .measurements = undefined,
            .failed_sample_count = 0,
            .perf_setup_skip_count = 2,
            .perf_setup_first_error = error.DisableBeforeSpawnFailed,
        },
    };
    var output_buf: [512]u8 = undefined;
    var output = Io.Writer.fixed(&output_buf);

    try writePerfSetupFailuresExcept(&output, &commands, null);

    try std.testing.expectEqualStrings(
        \\note: 1 earlier measurement setup attempt for 'first command' failed before target start: PERF_EVENT_IOC.RESET failed
        \\note: 2 earlier measurement setup attempts for 'second command' failed before target start: PERF_EVENT_IOC.DISABLE failed
        \\
    , output.buffered());

    output.end = 0;
    try writePerfSetupFailuresExcept(&output, &commands, 1);
    try std.testing.expectEqualStrings(
        \\note: 1 earlier measurement setup attempt for 'first command' failed before target start: PERF_EVENT_IOC.RESET failed
        \\
    , output.buffered());
}

test "[failure] - [measured sample decision]: target result wins over a perf-disable failure" {
    var pipefd: [2]fd_t = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.pipe(&pipefd)));
    defer {
        _ = std.os.linux.close(pipefd[0]);
        _ = std.os.linux.close(pipefd[1]);
    }
    var fds: [perf_measurements.len]fd_t = @splat(-1);
    fds[0] = pipefd[0];
    const perf_disable_failure = finishSampleMeasurement(
        .fromNanoseconds(1),
        .{},
        &fds,
    );
    switch (perf_disable_failure) {
        .failure => |failure| switch (failure) {
            .perf_disable => |err| try std.testing.expectEqual(
                error.DisableAfterSpawnFailed,
                err,
            ),
            else => return error.TestUnexpectedResult,
        },
        .sample => return error.TestUnexpectedResult,
    }

    try std.testing.expectEqual(
        MeasuredSampleDecision.rejected_exit,
        decideMeasuredSample(.{ .exited = 7 }, false, perf_disable_failure),
    );
    try std.testing.expectEqual(
        MeasuredSampleDecision.rejected_termination,
        decideMeasuredSample(.{ .signal = .TERM }, true, perf_disable_failure),
    );
    try std.testing.expectEqual(
        MeasuredSampleDecision.measurement_failed,
        decideMeasuredSample(.{ .exited = 0 }, false, perf_disable_failure),
    );
    try std.testing.expectEqual(
        MeasuredSampleDecision.measurement_failed,
        decideMeasuredSample(.{ .exited = 7 }, true, perf_disable_failure),
    );

    const complete: SampleMeasurementResult = .{ .sample = std.mem.zeroes(Sample) };
    try std.testing.expectEqual(
        MeasuredSampleDecision.accepted,
        decideMeasuredSample(.{ .exited = 0 }, false, complete),
    );
    try std.testing.expectEqual(
        MeasuredSampleDecision.accepted_failure,
        decideMeasuredSample(.{ .exited = 7 }, true, complete),
    );
}

test "[failure] - [resource use]: missing wait4 data is not a zero sample" {
    try std.testing.expectError(error.MissingResourceUsage, sampleResourceUsage(.{}));

    var ru: std.posix.rusage = std.mem.zeroes(std.posix.rusage);
    const zero_faults = try sampleResourceUsage(.{ .rusage = ru });
    try std.testing.expectEqual(@as(u64, 0), zero_faults.peak_rss);
    try std.testing.expectEqual(@as(u64, 0), zero_faults.minor_faults);
    try std.testing.expectEqual(@as(u64, 0), zero_faults.major_faults);

    if (builtin.cpu.arch == .x86) {
        var x86_ru: X86KernelRusage = std.mem.zeroes(X86KernelRusage);
        x86_ru.maxrss = 4;
        x86_ru.minflt = 2;
        x86_ru.majflt = 1;
        @memcpy(
            std.mem.asBytes(&ru)[0..@sizeOf(X86KernelRusage)],
            std.mem.asBytes(&x86_ru),
        );
    } else {
        ru.maxrss = 4;
        ru.minflt = 2;
        ru.majflt = 1;
    }
    const nonzero = try sampleResourceUsage(.{ .rusage = ru });
    try std.testing.expectEqual(@as(u64, 4096), nonzero.peak_rss);
    try std.testing.expectEqual(@as(u64, 2), nonzero.minor_faults);
    try std.testing.expectEqual(@as(u64, 1), nonzero.major_faults);
}

test "[failure] - [perf group open]: closes earlier file descriptors after a later open fails" {
    var first_pipe: [2]fd_t = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.pipe(&first_pipe)));
    defer closePerfFds(&first_pipe);

    var second_pipe: [2]fd_t = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.pipe(&second_pipe)));
    defer closePerfFds(&second_pipe);

    const first_opened_fd = first_pipe[0];
    const second_opened_fd = second_pipe[0];
    var fake = struct {
        fds: [perf_measurements.len]fd_t,
        next: usize = 0,
        fail_at: usize,

        fn open(
            self: *@This(),
            _: *std.os.linux.perf_event_attr,
            _: fd_t,
        ) std.posix.PerfEventOpenError!fd_t {
            const i = self.next;
            self.next += 1;
            if (i == self.fail_at) return error.EventNotSupported;
            const fd = self.fds[i];
            self.fds[i] = -1;
            return fd;
        }
    }{
        .fds = .{ first_pipe[0], second_pipe[0], -1, -1, -1 },
        .fail_at = 2,
    };
    first_pipe[0] = -1;
    second_pipe[0] = -1;
    defer closePerfFds(&fake.fds);

    var perf_fds: [perf_measurements.len]fd_t = @splat(-1);
    defer closePerfFds(&perf_fds);
    const failure = openPerfGroupWith(&perf_fds, &fake, @TypeOf(fake).open).?;

    try std.testing.expectEqual(@as(usize, 2), failure.counter_index);
    try std.testing.expectEqual(error.EventNotSupported, failure.err);
    try std.testing.expectEqual(@as(usize, 3), fake.next);
    for (perf_fds) |fd| try std.testing.expectEqual(@as(fd_t, -1), fd);
    try std.testing.expectEqual(
        std.os.linux.E.BADF,
        std.os.linux.errno(std.os.linux.fcntl(first_opened_fd, std.os.linux.F.GETFD, 0)),
    );
    try std.testing.expectEqual(
        std.os.linux.E.BADF,
        std.os.linux.errno(std.os.linux.fcntl(second_opened_fd, std.os.linux.F.GETFD, 0)),
    );
}

test "[integration] - [target start]: returns an error for a missing executable" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const argv = [_][]const u8{"/zebrac-test-target-does-not-exist"};
    try std.testing.expectError(error.FileNotFound, spawnMeasuredTarget(io, &argv, false));
}

test "[failure] - [warmup wait]: kills the child when waiting fails" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const argv = [_][]const u8{ "/bin/sleep", "30" };
    var child = try spawnMeasuredTarget(io, &argv, false);
    defer child.kill(io);
    const child_pid: std.posix.pid_t = @intCast(child.id.?);

    try std.testing.expectError(
        error.TargetWaitFailed,
        waitChildWith(io, &child, {}, struct {
            fn fail(_: void, _: *process.Child) error{TargetWaitFailed}!process.Child.Term {
                return error.TargetWaitFailed;
            }
        }.fail),
    );
    try std.testing.expectEqual(@as(?process.Child.Id, null), child.id);
    try std.testing.expectEqual(@as(?Io.File, null), child.stdin);
    try std.testing.expectEqual(@as(?Io.File, null), child.stdout);
    try std.testing.expectEqual(@as(?Io.File, null), child.stderr);
    try std.testing.expectError(
        error.ProcessNotFound,
        std.posix.kill(child_pid, @enumFromInt(0)),
    );
}

test "[integration] - [allowed failure wait]: drains bounded stderr without spinning" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var notifier = try ChildExitNotifier.init();
    defer notifier.deinit();
    try notifier.prepare();
    const argv = [_][]const u8{ "/bin/sh", "-c", "printf 12345678901234567890 >&2; exit 7" };
    var child = try spawnWarmupTarget(io, &argv, true);
    var storage: [8]u8 = undefined;
    var capture: StderrCaptureBuf = .{ .storage = &storage };

    const waited = try waitChildAndDrainStderr(
        io,
        &child,
        .now(io, .awake),
        &capture,
        &notifier,
    );

    try std.testing.expectEqual(process.Child.Term{ .exited = 7 }, waited.term);
    try std.testing.expectEqualStrings("12345678", capture.view().bytes);
    try std.testing.expect(capture.truncated);
    try std.testing.expectEqual(@as(?process.Child.Id, null), child.id);
    try std.testing.expectError(error.FcntlFailed, getFileStatusFlags(-1));
    try std.testing.expectError(error.FcntlFailed, setFileStatusFlags(-1, 0));
    if (openPidfd(std.os.linux.getpid())) |self_pidfd| {
        defer _ = std.os.linux.close(self_pidfd);
    } else |err| {
        try std.testing.expectEqual(error.PidfdOpenFailed, err);
    }
    try std.testing.expectError(error.PidfdOpenFailed, openPidfd(-1));
}

test "[integration] - [allowed failure wait]: no-pidfd fallback stops at the direct child" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var notifier = try ChildExitNotifier.init();
    defer notifier.deinit();
    try notifier.prepare();
    const argv = [_][]const u8{ "/bin/sh", "-c", "sleep 30 & echo $! >&2; exit 9" };
    var child = try spawnWarmupTarget(io, &argv, true);
    var storage: [32]u8 = undefined;
    var capture: StderrCaptureBuf = .{ .storage = &storage };

    var exit_poll = [_]std.posix.pollfd{.{
        .fd = notifier.read_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&exit_poll, 5_000));

    const wait_start: Io.Timestamp = .now(io, .awake);
    const waited = try waitChildAndDrainStderrWithPidfd(
        io,
        &child,
        wait_start,
        &capture,
        false,
        &notifier,
    );
    const wait_duration = wait_start.untilNow(io, .awake);
    const background_pid = try std.fmt.parseInt(
        std.posix.pid_t,
        std.mem.trim(u8, capture.view().bytes, " \r\n"),
        10,
    );
    defer std.posix.kill(background_pid, .KILL) catch {};

    try std.testing.expectEqual(process.Child.Term{ .exited = 9 }, waited.term);
    try std.testing.expect(waited.duration.toMilliseconds() < 25);
    try std.testing.expect(wait_duration.toMilliseconds() < 25);
}

test "[integration] - [allowed failure wait]: reports a target crash" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const argv = [_][]const u8{ "/bin/sh", "-c", "kill -SEGV $$" };
    var child = try spawnWarmupTarget(io, &argv, true);
    var storage: [16]u8 = undefined;
    var capture: StderrCaptureBuf = .{ .storage = &storage };

    const waited = try waitChildAndDrainStderr(
        io,
        &child,
        .now(io, .awake),
        &capture,
        null,
    );

    try std.testing.expectEqual(process.Child.Term{ .signal = .SEGV }, waited.term);
}

test "[unit] - [allowed failure notes]: writes saved text only after collection" {
    const saved = "first failure\n";
    const commands = [_]Command{
        .{
            .raw_cmd = "first",
            .argv = &.{},
            .measurements = undefined,
            .failed_sample_count = 3,
            .first_failure_sample = 2,
            .first_failure_exit_code = 7,
            .first_failure_stderr = .{ .bytes = saved, .truncated = false },
        },
        .{
            .raw_cmd = "second",
            .argv = &.{},
            .measurements = undefined,
            .failed_sample_count = 0,
        },
    };
    var output_storage: [1024]u8 = undefined;
    var output = Io.Writer.fixed(&output_storage);

    try writeAllowedFailureNotes(&output, &commands);

    const text = output.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "note: sample 2 for 'first' exited 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, saved) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2 more failed samples for 'first'") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "second") == null);
}

test "[failure] - [allowed failure notes]: a stopping error prints retained notes" {
    const commands = [_]Command{
        .{
            .raw_cmd = "completed",
            .argv = &.{},
            .measurements = undefined,
            .failed_sample_count = 1,
            .first_failure_sample = 1,
            .first_failure_exit_code = 3,
            .first_failure_stderr = .{ .bytes = "completed stderr\n", .truncated = false },
        },
        .{
            .raw_cmd = "current",
            .argv = &.{},
            .measurements = undefined,
            .failed_sample_count = 1,
            .first_failure_sample = 2,
            .first_failure_exit_code = 4,
            .first_failure_stderr = .{ .bytes = "current stderr\n", .truncated = false },
        },
    };
    var output_storage: [2048]u8 = undefined;
    var output = Io.Writer.fixed(&output_storage);

    printCollectionNotesOnStop(&output, &commands);

    const text = output.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "sample 1 for 'completed' exited 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sample 2 for 'current' exited 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "completed stderr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "current stderr") != null);
}

test "[unit] - [metric summary]: calculates values without changing samples" {
    const samples_empty: []const Sample = &.{};
    var scratch_one: [1]Sample = undefined;
    try std.testing.expectError(error.NoSamples, Measurement.summarizeAll(samples_empty, &scratch_one));
    const one = [_]Sample{sampleWith("wall_time", 1)};
    var tiny: [0]Sample = undefined;
    try std.testing.expectError(error.ScratchTooSmall, Measurement.summarizeAll(&one, &tiny));
    try std.testing.expectError(error.ScratchTooSmall, Measurement.summarizeField(&one, &tiny, "wall_time", .nanoseconds));

    {
        var samples = [_]Sample{
            sampleWith("wall_time", 30),
            sampleWith("wall_time", 10),
            sampleWith("wall_time", 20),
            sampleWith("wall_time", 40),
        };
        var scratch: [4]Sample = undefined;
        const m = try Measurement.summarizeField(&samples, &scratch, "wall_time", .nanoseconds);
        try std.testing.expectEqual(@as(u64, 10), m.min);
        try std.testing.expectEqual(@as(u64, 40), m.max);
        try std.testing.expectEqual(@as(u64, 30), m.median);
        try std.testing.expectApproxEqAbs(@as(f64, 25), m.mean, 0.001);
        try std.testing.expectEqual(@as(u64, 30), samples[0].wall_time);
    }

    const stat_cases = [_]struct {
        values: []const u64,
        q1: u64,
        median: u64,
        q3: u64,
        outliers: u64,
        std_dev_zero: bool,
    }{
        .{ .values = &.{42}, .q1 = 42, .median = 42, .q3 = 42, .outliers = 0, .std_dev_zero = true },
        .{ .values = &.{ 200, 100 }, .q1 = 100, .median = 200, .q3 = 200, .outliers = 0, .std_dev_zero = false },
        .{ .values = &.{ 300, 100, 200 }, .q1 = 100, .median = 200, .q3 = 300, .outliers = 0, .std_dev_zero = false },
        .{ .values = &.{ 400, 100, 300, 200 }, .q1 = 200, .median = 300, .q3 = 400, .outliers = 0, .std_dev_zero = false },
        .{ .values = &.{ 100, 100, 100 }, .q1 = 100, .median = 100, .q3 = 100, .outliers = 0, .std_dev_zero = true },
        .{ .values = &.{ 12, 1, 100, 6, 3, 9, 4, 11, 2, 8, 5, 10, 7 }, .q1 = 4, .median = 7, .q3 = 11, .outliers = 1, .std_dev_zero = false },
    };
    for (stat_cases) |c| {
        const m = try summarizeWallTime(c.values);
        try std.testing.expectEqual(c.q1, m.q1);
        try std.testing.expectEqual(c.median, m.median);
        try std.testing.expectEqual(c.q3, m.q3);
        try std.testing.expectEqual(c.outliers, m.outlier_count);
        if (c.std_dev_zero) try std.testing.expectApproxEqAbs(@as(f64, 0), m.std_dev, 0.001);
    }
}

test "[unit] - [command summary]: covers every measurement field" {
    const samples = [_]Sample{
        .{ .wall_time = 100, .peak_rss = 1000, .minor_faults = 10, .major_faults = 0, .cpu_cycles = 50, .instructions = 40, .cache_references = 30, .cache_misses = 20, .branch_misses = 5 },
        .{ .wall_time = 200, .peak_rss = 2000, .minor_faults = 30, .major_faults = 2, .cpu_cycles = 60, .instructions = 50, .cache_references = 35, .cache_misses = 25, .branch_misses = 6 },
    };
    var scratch: [2]Sample = undefined;
    const m = try Measurement.summarizeAll(&samples, &scratch);

    try std.testing.expectEqual(@as(u64, 30), m.minor_faults.median);
    try std.testing.expectEqual(@as(u64, 2), m.major_faults.max);
    try std.testing.expectEqual(Measurement.Unit.nanoseconds, m.wall_time.unit);
    try std.testing.expectEqual(Measurement.Unit.bytes, m.peak_rss.unit);
    try std.testing.expectEqual(Measurement.Unit.count, m.cpu_cycles.unit);
}

test "[unit] - [comparison delta]: shows only a signed change in command means" {
    try expectDeltaPlain("0%", measurementForDeltaTest(100, 10, 10), null, true);
    try expectDeltaPlain("n/a", measurementForDeltaTest(100, 10, 10), null, false);
    try expectDeltaPlain("n/a", measurementForDeltaTest(0, 0, 10), null, true);
    try expectDeltaPlain("n/a", measurementForDeltaTest(5, 1, 10), measurementForDeltaTest(0, 0, 10), true);
    try expectDeltaPlain("0%", measurementForDeltaTest(100, 10, 10), measurementForDeltaTest(100, 10, 10), true);
    try expectDeltaPlain("0%", measurementForDeltaTest(100.04, 10, 10), measurementForDeltaTest(100, 10, 10), true);
    try expectDeltaPlain("0%", measurementForDeltaTest(99.96, 10, 10), measurementForDeltaTest(100, 10, 10), true);
    try expectDeltaPlain("+10.0%", measurementForDeltaTest(110, 999, 2), measurementForDeltaTest(100, 1, 7), true);
    try expectDeltaPlain("-10.0%", measurementForDeltaTest(90, 1, 9), measurementForDeltaTest(100, 999, 2), true);
}

fn expectRoundPermutation(order: CommandRoundOrder) !void {
    var seen: [64]bool = @splat(false);
    std.debug.assert(order.command_count <= seen.len);
    for (0..order.command_count) |position| {
        const command_index = order.commandAt(position);
        try std.testing.expect(command_index < order.command_count);
        try std.testing.expect(!seen[command_index]);
        seen[command_index] = true;
    }
}

fn expectCommandOrderPrefixLimits(
    command_count: usize,
    round_count: usize,
    include_warmup_boundary: bool,
    previous_pair_limit: u64,
) !u64 {
    const max_test_commands = 64;
    std.debug.assert(command_count <= max_test_commands);
    var position_counts: [max_test_commands][max_test_commands]u64 = @splat(@splat(0));
    var pair_counts: [max_test_commands][max_test_commands]u64 = @splat(@splat(0));
    var previous: ?usize = if (include_warmup_boundary)
        CommandRoundOrder.beforeFirstMeasured(command_count, 1).commandAt(command_count - 1)
    else
        null;

    for (0..round_count) |round_index| {
        const order = CommandRoundOrder.measured(command_count, @intCast(round_index));
        try expectRoundPermutation(order);
        for (0..command_count) |position| {
            const command_index = order.commandAt(position);
            position_counts[command_index][position] += 1;
            if (previous) |before| pair_counts[before][command_index] += 1;
            previous = command_index;
        }

        for (0..command_count) |command_index| {
            var least = position_counts[command_index][0];
            var most = least;
            for (position_counts[command_index][0..command_count]) |count| {
                least = @min(least, count);
                most = @max(most, count);
            }
            try std.testing.expect(most - least <= 1);
        }

        var least_pair = pair_counts[0][0];
        var most_pair = least_pair;
        for (pair_counts[0..command_count]) |row| {
            for (row[0..command_count]) |count| {
                least_pair = @min(least_pair, count);
                most_pair = @max(most_pair, count);
            }
        }
        try std.testing.expect(most_pair - least_pair <= previous_pair_limit);
    }

    var least_pair = pair_counts[0][0];
    var most_pair = least_pair;
    for (pair_counts[0..command_count]) |row| {
        for (row[0..command_count]) |count| {
            least_pair = @min(least_pair, count);
            most_pair = @max(most_pair, count);
        }
    }
    return most_pair - least_pair;
}

test "[property] - [command order]: balances positions and previous commands" {
    const expected_three = [6][3]usize{
        .{ 0, 1, 2 },
        .{ 2, 0, 1 },
        .{ 1, 2, 0 },
        .{ 0, 2, 1 },
        .{ 1, 0, 2 },
        .{ 2, 1, 0 },
    };
    for (expected_three, 0..) |expected, round_index| {
        const order = CommandRoundOrder.measured(3, round_index);
        for (expected, 0..) |command_index, position| {
            try std.testing.expectEqual(command_index, order.commandAt(position));
        }
    }

    for (1..13) |command_count| {
        const expected_pair_limit: u64 = switch (command_count) {
            1 => 0,
            2, 3, 4 => @intCast(command_count - 1),
            else => if (command_count % 2 == 1)
                @intCast(command_count - 1)
            else
                @intCast(2 * (command_count - 1)),
        };
        const period_rounds: usize = @intCast(
            commandOrderCycleCount(command_count) * @as(u128, command_count),
        );
        try std.testing.expectEqual(
            @as(u64, 0),
            try expectCommandOrderPrefixLimits(
                command_count,
                period_rounds,
                true,
                expected_pair_limit,
            ),
        );
        _ = try expectCommandOrderPrefixLimits(
            command_count,
            period_rounds + command_count + 1,
            false,
            expected_pair_limit,
        );
    }

    for ([_]usize{ 13, 16, 31, 32, 63, 64 }) |command_count| {
        const expected_pair_limit: u64 = if (command_count % 2 == 1)
            @intCast(command_count - 1)
        else
            @intCast(2 * (command_count - 1));
        _ = try expectCommandOrderPrefixLimits(
            command_count,
            2 * command_count + 1,
            true,
            expected_pair_limit,
        );
    }
}

test "[property] - [command order]: circles balance every distinct command pair" {
    for (5..33) |command_count| {
        var pair_counts: [32][32]u32 = @splat(@splat(0));
        const cycle_count: usize = @intCast(commandOrderCycleCount(command_count));
        for (0..cycle_count) |cycle_index| {
            const order = CommandRoundOrder.init(command_count, cycle_index, 0);
            var seen: [32]bool = @splat(false);
            for (0..command_count) |position| {
                const before = order.commandAt(position);
                const after = order.commandAt((position + 1) % command_count);
                try std.testing.expect(!seen[before]);
                seen[before] = true;
                pair_counts[before][after] += 1;
            }
        }

        const expected: u32 = @intCast(cycle_count / (command_count - 1));
        for (pair_counts[0..command_count], 0..) |row, before| {
            for (row[0..command_count], 0..) |count, after| {
                try std.testing.expectEqual(
                    if (before == after) @as(u32, 0) else expected,
                    count,
                );
            }
        }
    }
}

test "[property] - [command order]: warmups lead into measured round zero" {
    for (1..13) |command_count| {
        for (1..2 * command_count + 2) |warmup_count| {
            var previous_order: ?CommandRoundOrder = null;
            for (0..warmup_count) |warmup_round| {
                const order = CommandRoundOrder.beforeFirstMeasured(
                    command_count,
                    warmup_count - warmup_round,
                );
                try expectRoundPermutation(order);
                if (previous_order) |before| {
                    try std.testing.expectEqual(
                        before.commandAt(command_count - 1),
                        order.commandAt(0),
                    );
                }
                previous_order = order;
            }
            try std.testing.expectEqual(
                previous_order.?.commandAt(command_count - 1),
                CommandRoundOrder.measured(command_count, 0).commandAt(0),
            );
        }
    }
}

test "[unit] - [round stop]: checks time only at equal-count boundaries" {
    try std.testing.expect(shouldRunAnotherRound(0, 1, 10, 500, 0));
    try std.testing.expect(!shouldRunAnotherRound(1, 1, 10, 500, 0));
    try std.testing.expect(shouldRunAnotherRound(1, 2, 10, 500, 100));
    try std.testing.expect(shouldRunAnotherRound(2, 2, 10, 99, 100));
    try std.testing.expect(!shouldRunAnotherRound(2, 2, 10, 100, 100));
    try std.testing.expect(!shouldRunAnotherRound(3, 1, 3, 0, 100));
}

test "[regression] - [duration parser]: rejects group budget overflow" {
    const max_duration_ms = std.math.maxInt(u64) / std.time.ns_per_ms;
    try std.testing.expectEqual(
        max_duration_ms * std.time.ns_per_ms,
        try durationNsFromMs(max_duration_ms),
    );
    try std.testing.expectError(error.DurationTooLarge, durationNsFromMs(max_duration_ms + 1));

    const two_command_max = maximumDurationMs(2);
    _ = try groupDurationNsFromMs(two_command_max, 2);
    try std.testing.expectError(
        error.DurationTooLarge,
        groupDurationNsFromMs(two_command_max + 1, 2),
    );
    try std.testing.expectError(
        error.DurationTooLarge,
        groupDurationNsFromMs(max_duration_ms, 2),
    );
}

test "[regression] - [run input]: command and sample errors win before duration overflow" {
    const overflow_ms = std.math.maxInt(u64) / std.time.ns_per_ms + 1;
    const cases = [_]struct {
        command_count: usize,
        min_samples: u64,
        max_samples: u64,
        expected: RunInputError,
    }{
        .{ .command_count = 0, .min_samples = 0, .max_samples = 0, .expected = error.MissingCommand },
        .{ .command_count = 1, .min_samples = 0, .max_samples = 1, .expected = error.MinSamplesZero },
        .{ .command_count = 1, .min_samples = 1, .max_samples = 0, .expected = error.MaxSamplesZero },
        .{ .command_count = 1, .min_samples = 2, .max_samples = 1, .expected = error.MinSamplesExceedsMax },
        .{ .command_count = 1, .min_samples = 1, .max_samples = 1, .expected = error.DurationTooLarge },
    };
    for (cases) |case| {
        try std.testing.expectError(
            case.expected,
            validateRunInput(
                case.command_count,
                case.min_samples,
                case.max_samples,
                overflow_ms,
            ),
        );
    }
}

test "[unit] - [optional table row]: uses one major-fault choice for every command" {
    const zero_faults = Measurement{
        .q1 = 0,
        .median = 0,
        .q3 = 0,
        .min = 0,
        .max = 0,
        .mean = 0,
        .std_dev = 0,
        .outlier_count = 0,
        .sample_count = 8,
        .unit = .count,
    };
    const zero_measurements = tableFixtureMeasurements(zero_faults);
    const fault_measurements = tableFixtureMeasurements(TableFixtures.faults);
    var commands = [_]Command{
        .{
            .raw_cmd = "first",
            .argv = &.{},
            .measurements = zero_measurements,
            .failed_sample_count = 0,
        },
        .{
            .raw_cmd = "second",
            .argv = &.{},
            .measurements = zero_measurements,
            .failed_sample_count = 0,
        },
        .{
            .raw_cmd = "third",
            .argv = &.{},
            .measurements = zero_measurements,
            .failed_sample_count = 0,
        },
    };

    try std.testing.expect(!anyCommandHasMajorFaults(&commands));
    var out_buf: [8192]u8 = undefined;
    const out = try renderResultsTableForTest(
        &out_buf,
        zero_measurements,
        null,
        .no_color,
        false,
    );
    try std.testing.expect(std.mem.indexOf(u8, out, "major_faults") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "minor_faults") != null);

    commands[2].measurements = fault_measurements;
    const show_major_faults = anyCommandHasMajorFaults(&commands);
    try std.testing.expect(show_major_faults);
    for (commands, 0..) |command, command_index| {
        var table_buf: [8192]u8 = undefined;
        const baseline: ?Command.Measurements = if (command_index == 0) null else commands[0].measurements;
        const table = try renderResultsTableForTest(
            &table_buf,
            command.measurements,
            baseline,
            .no_color,
            show_major_faults,
        );
        try std.testing.expect(std.mem.indexOf(u8, table, "major_faults") != null);
    }

    commands[0].measurements = fault_measurements;
    commands[2].measurements = zero_measurements;
    try std.testing.expect(anyCommandHasMajorFaults(&commands));
    for (commands, 0..) |command, command_index| {
        var table_buf: [8192]u8 = undefined;
        const baseline: ?Command.Measurements = if (command_index == 0) null else commands[0].measurements;
        const table = try renderResultsTableForTest(
            &table_buf,
            command.measurements,
            baseline,
            .no_color,
            true,
        );
        try std.testing.expect(std.mem.indexOf(u8, table, "major_faults") != null);
    }
}

test "[unit] - [comparison table]: renders signed, zero, and unavailable deltas" {
    const baseline = measurementsFill(measurementForDeltaTest(100, 999, 2));
    const compare = measurementsFill(measurementForDeltaTest(110, 1, 7));
    var out_buf: [8192]u8 = undefined;
    const out = try renderResultsTableForTest(
        &out_buf,
        compare,
        baseline,
        .no_color,
        true,
    );

    try std.testing.expectEqual(@as(usize, 9), std.mem.count(u8, out, "+10.0%"));
    try std.testing.expectEqual(@as(usize, 10), std.mem.count(u8, out, sep_mean));
    try std.testing.expect(std.mem.indexOf(u8, out, "! +") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "* -") == null);

    const one_sample = measurementsFill(measurementForDeltaTest(90, 1, 1));
    var baseline_buf: [8192]u8 = undefined;
    var baseline_writer = Io.Writer.fixed(&baseline_buf);
    const baseline_term = Io.Terminal{ .writer = &baseline_writer, .mode = .no_color };
    try printResultsTable(
        &baseline_writer,
        baseline_term,
        baseline,
        null,
        true,
        true,
        false,
    );
    try std.testing.expectEqual(
        @as(usize, 9),
        std.mem.count(u8, baseline_writer.buffered(), "n/a"),
    );

    var candidate_buf: [8192]u8 = undefined;
    var candidate_writer = Io.Writer.fixed(&candidate_buf);
    const candidate_term = Io.Terminal{ .writer = &candidate_writer, .mode = .no_color };
    try printResultsTable(
        &candidate_writer,
        candidate_term,
        one_sample,
        baseline,
        true,
        true,
        false,
    );
    try std.testing.expectEqual(
        @as(usize, 9),
        std.mem.count(u8, candidate_writer.buffered(), "n/a"),
    );

    for (&[_]Io.Terminal.Mode{ .no_color, .escape_codes }) |mode| {
        try tableAlignmentInvariantsTest(mode, .mixed_units);
        try tableAlignmentInvariantsTest(mode, .zero_delta);
    }
}

test "[unit] - [number formatting]: scales units and preserves table alignment" {
    const scale_cases = [_]struct { x: f64, unit: Measurement.Unit, suffix: []const u8, val: f64 }{
        .{ .x = 5.0 * 1_000_000_000.0, .unit = .nanoseconds, .suffix = "s", .val = 5.0 },
        .{ .x = 1.5 * 1_000_000.0, .unit = .nanoseconds, .suffix = "ms", .val = 1.5 },
        .{ .x = 1.5 * 1_000.0, .unit = .nanoseconds, .suffix = "µs", .val = 1.5 },
        .{ .x = 60.0 * 1_000_000_000.0, .unit = .nanoseconds, .suffix = "m", .val = 1.0 },
        .{ .x = 3600.0 * 1_000_000_000.0, .unit = .nanoseconds, .suffix = "h", .val = 1.0 },
        .{ .x = 2048, .unit = .bytes, .suffix = "KB", .val = 2.048 },
        .{ .x = 42, .unit = .count, .suffix = plain_unit_suffix, .val = 42 },
    };
    for (scale_cases) |c| {
        const s = scaleUnit(c.x, c.unit);
        try std.testing.expectEqualStrings(c.suffix, s.suffix);
        try std.testing.expectApproxEqAbs(c.val, s.val, 0.001);
    }

    const display_cases = [_]struct { x: f64, unit: Measurement.Unit, want: []const u8 }{
        .{ .x = 999_499.0, .unit = .bytes, .want = "999KB" },
        .{ .x = 999_999.0, .unit = .bytes, .want = "1.00MB" },
        .{ .x = 999_499_999.0, .unit = .bytes, .want = "999MB" },
        .{ .x = 999_500_000.0, .unit = .bytes, .want = "1.00GB" },
        .{ .x = 999_499_999_999.0, .unit = .bytes, .want = "999GB" },
        .{ .x = 999_500_000_000.0, .unit = .bytes, .want = "1.00TB" },
        .{ .x = 999_499_999.0, .unit = .nanoseconds, .want = "999ms" },
        .{ .x = 999_999_999.0, .unit = .nanoseconds, .want = "1.00s" },
        .{ .x = 59_999_999_999.0, .unit = .nanoseconds, .want = "1.00m" },
    };
    for (display_cases) |c| try expectScaledDisplay(c.x, c.unit, c.want);

    var buf: [32]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), measureUnit(&buf, 1.5 * 1_000.0, .nanoseconds));
    try std.testing.expectEqual(measureScaledValueVis(&buf, 62.3), measureUnit(&buf, 62.3, .count));

    var w = std.Io.Writer.fixed(&buf);
    try printNum3SigFigs(&w, 5.0);
    try std.testing.expectEqualStrings("5.00", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try printNum3SigFigs(&w, 1234);
    try std.testing.expectEqualStrings("1234", w.buffered());

    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |n| {
        w = std.Io.Writer.fixed(&buf);
        try printNum3SigFigs(&w, n);
        try std.testing.expectEqualStrings("n/a", w.buffered());
    }
    try std.testing.expectEqual(@as(usize, 3), measureScaledValueVis(&buf, std.math.nan(f64)));
    try std.testing.expectEqual(@as(usize, 5), measureUnit(&buf, std.math.inf(f64), .bytes));
}

test "[fuzz] - [metric summary]: keeps bounds and counts valid" {
    try std.testing.fuzz({}, fuzzSummarizeField, .{});
}
