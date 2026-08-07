//! Spawn commands, collect samples, print stats or JSON.

const std = @import("std");
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
const default_json_output_path = "zebrac-results.json";
const default_duration_ms: u64 = 5000;
const default_min_samples: u64 = 5;
const default_warmup: usize = 3;
const perf_ioctl_skip_limit_min: u32 = 32;
const perf_ioctl_skip_limit_max: u32 = 1024;

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
    sample_count: usize,
    failed_sample_count: u64,

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

    pub fn lessThanContext(comptime field: []const u8) type {
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
            if (measurementRowVisible(measurementFieldMeta(field.name).visibility, m)) {
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
                    layout.delta_w = @max(layout.delta_w, measureDelta(&delta_buf, m, first_m));
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
const unit_suffix_max_vis_w: usize = 2;

const UnitScaled = struct {
    val: f64,
    suffix: []const u8,
};

const scale_threshold = struct {
    min: f64,
    div: f64,
    ns_suffix: []const u8 = "",
    count_suffix: []const u8 = "",
    byte_suffix: []const u8 = "",
};

fn unitScaleMin(div: f64) f64 {
    return div - div / 2000.0;
}

const ns_unit_thresholds = [_]scale_threshold{
    .{ .min = unitScaleMin(3600.0 * 1_000_000_000), .div = 3600.0 * 1_000_000_000, .ns_suffix = "h" },
    .{ .min = unitScaleMin(60.0 * 1_000_000_000), .div = 60.0 * 1_000_000_000, .ns_suffix = "m" },
    .{ .min = unitScaleMin(1_000_000_000.0), .div = 1_000_000_000.0, .ns_suffix = "s" },
    .{ .min = unitScaleMin(1_000_000.0), .div = 1_000_000.0, .ns_suffix = "ms" },
    .{ .min = 1_000.0, .div = 1_000.0, .ns_suffix = "µs" },
};

const qty_unit_thresholds = [_]scale_threshold{
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

comptime {
    for (ns_unit_thresholds) |t| {
        if (t.ns_suffix.len > 0 and visibleLen(t.ns_suffix) > unit_suffix_max_vis_w) {
            @compileError(std.fmt.comptimePrint(
                "unit suffix '{s}' is wider than unit_suffix_max_vis_w ({d})",
                .{ t.ns_suffix, unit_suffix_max_vis_w },
            ));
        }
    }
    for (qty_unit_thresholds) |t| {
        if (visibleLen(t.count_suffix) > unit_suffix_max_vis_w or visibleLen(t.byte_suffix) > unit_suffix_max_vis_w) {
            @compileError("qty threshold suffix exceeds unit_suffix_max_vis_w");
        }
    }
    if (visibleLen("ns") > unit_suffix_max_vis_w) {
        @compileError("plain ns suffix exceeds unit_suffix_max_vis_w");
    }
}

fn measureUnitValueVis(buf: *[32]u8, x: f64, unit: Measurement.Unit) usize {
    const s = scaleUnit(x, unit);
    var fbs = std.Io.Writer.fixed(buf);
    printNum3SigFigs(&fbs, s.val) catch return 0;
    return visibleLen(fbs.buffered());
}

fn measureUnit(buf: *[32]u8, x: f64, unit: Measurement.Unit) usize {
    const s = scaleUnit(x, unit);
    return measureUnitValueVis(buf, x, unit) + visibleLen(s.suffix);
}

fn measureOutlier(buf: *[32]u8, count: u64, sample_count: u64) usize {
    const line = formatOutlierLine(buf, count, sample_count) catch return 0;
    return visibleLen(line);
}

const delta_baseline_epsilon: f64 = 1e-9;

const MeasurementFieldMeta = struct {
    visibility: MeasurementRowVisibility,
    unit: Measurement.Unit,
};

const MeasurementRowVisibility = enum {
    always,
    hide_when_max_is_zero,
};

fn measurementFieldMeta(comptime field_name: []const u8) MeasurementFieldMeta {
    if (comptime std.mem.eql(u8, field_name, "wall_time"))
        return .{ .visibility = .always, .unit = .nanoseconds };
    if (comptime std.mem.eql(u8, field_name, "peak_rss"))
        return .{ .visibility = .always, .unit = .bytes };
    if (comptime std.mem.eql(u8, field_name, "major_faults"))
        return .{ .visibility = .hide_when_max_is_zero, .unit = .count };
    return .{ .visibility = .always, .unit = .count };
}

fn measurementRowVisible(visibility: MeasurementRowVisibility, m: Measurement) bool {
    return switch (visibility) {
        .always => true,
        .hide_when_max_is_zero => m.max > 0,
    };
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

fn readPageFaults(rus: process.Child.ResourceUsageStatistics) struct { minor: u64, major: u64 } {
    const ru = rus.rusage orelse return .{ .minor = 0, .major = 0 };
    return .{
        .minor = @intCast(@max(ru.minflt, 0)),
        .major = @intCast(@max(ru.majflt, 0)),
    };
}

fn measureDelta(buf: *[64]u8, m: Measurement, first_m: ?Measurement) usize {
    var w = std.Io.Writer.fixed(buf);
    writeDeltaPlain(&w, m, first_m) catch return 0;
    return visibleLen(w.buffered());
}

fn deltaIsDefined(m: Measurement, f: Measurement) bool {
    if (@abs(f.mean) < delta_baseline_epsilon) return false;
    if (m.sample_count + f.sample_count < 4) return false;
    return true;
}

fn writeDeltaPlain(w: *Io.Writer, m: Measurement, first_m: ?Measurement) !void {
    if (first_m == null) {
        try w.writeAll("0%");
        return;
    }
    const f = first_m.?;
    if (@abs(f.mean) < delta_baseline_epsilon) {
        try w.writeAll("n/a");
        return;
    }
    const diff_mean_percent = (m.mean - f.mean) * 100 / f.mean;
    if (@abs(diff_mean_percent) < delta_baseline_epsilon) {
        if (!deltaIsDefined(m, f)) {
            try w.writeAll("n/a");
        } else {
            try w.writeAll("0%");
        }
        return;
    }
    const half = deltaHalfWidth(m, f) orelse {
        try w.writeAll("n/a");
        return;
    };
    const is_sig = deltaIsSignificant(diff_mean_percent, half);
    if (m.mean > f.mean) {
        try w.writeAll(if (is_sig) "! " else "  ");
        try w.writeAll("+");
    } else {
        try w.writeAll(if (is_sig) "* " else "  ");
        try w.writeAll("-");
    }
    try w.print("{d: >5.1}% ± {d: >4.1}%", .{ @abs(diff_mean_percent), half });
}

fn deltaHalfWidth(m: Measurement, f: Measurement) ?f64 {
    if (!deltaIsDefined(m, f)) return null;
    const z = getStatScore95(m.sample_count + f.sample_count - 2);
    const n1: f64 = @floatFromInt(m.sample_count);
    const n2: f64 = @floatFromInt(f.sample_count);
    const normer = std.math.sqrt(1.0 / n1 + 1.0 / n2);
    const numer1 = (n1 - 1) * (m.std_dev * m.std_dev);
    const numer2 = (n2 - 1) * (f.std_dev * f.std_dev);
    const df = n1 + n2 - 2;
    const sp = std.math.sqrt((numer1 + numer2) / df);
    return (z * sp * normer) * 100 / f.mean;
}

fn deltaIsSignificant(diff_mean_percent: f64, half: f64) bool {
    if (diff_mean_percent >= 1 and (diff_mean_percent - half) >= 1) return true;
    if (diff_mean_percent <= -1 and (diff_mean_percent + half) <= -1) return true;
    return false;
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
    const value_vis = measureUnitValueVis(buf, x, unit);
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

fn writeDeltaColored(
    w: *Io.Writer,
    terminal: Io.Terminal,
    text: []const u8,
    color_enabled: bool,
) !void {
    if (!color_enabled) {
        try w.writeAll(text);
        return;
    }
    if (std.mem.eql(u8, text, "0%") or std.mem.eql(u8, text, "n/a") or std.mem.startsWith(u8, text, "  ")) {
        try terminal.setColor(.dim);
        try w.writeAll(text);
        try terminal.setColor(.reset);
        return;
    }
    if (std.mem.startsWith(u8, text, "! ")) {
        try w.writeAll("! ");
        try terminal.setColor(.bright_red);
        try w.writeAll(text[2..]);
        try terminal.setColor(.reset);
        return;
    }
    if (std.mem.startsWith(u8, text, "* ")) {
        try terminal.setColor(.bright_yellow);
        try w.writeAll("* ");
        try terminal.setColor(.bright_green);
        try w.writeAll(text[2..]);
        try terminal.setColor(.reset);
        return;
    }
    try w.writeAll(text);
}

fn writeDelta(
    w: *Io.Writer,
    terminal: Io.Terminal,
    vis: *usize,
    layout: TableLayout,
    m: Measurement,
    first_m: ?Measurement,
    color_enabled: bool,
) !void {
    const col_start = layout.deltaStartVis();
    var buf: [64]u8 = undefined;
    var plain = Io.Writer.fixed(&buf);
    try writeDeltaPlain(&plain, m, first_m);
    const text = plain.buffered();
    try writeDeltaColored(w, terminal, text, color_enabled);
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

fn nextFlagArg(args: []const []const u8, arg_i: *usize, flag: []const u8, number: bool) []const u8 {
    arg_i.* += 1;
    if (arg_i.* >= args.len) {
        if (number) exitRequiresNumber(flag);
        std.debug.print("'{s}' requires a value.\n{s}", .{ flag, help.short_usage });
        process.exit(1);
    }
    return args[arg_i.*];
}

fn parseFlagU64(args: []const []const u8, arg_i: *usize, flag: []const u8, number: bool) u64 {
    const next = nextFlagArg(args, arg_i, flag, number);
    return std.fmt.parseInt(u64, next, 10) catch exitRequiresNumber(flag);
}

fn parseFlagUsized(args: []const []const u8, arg_i: *usize, flag: []const u8) usize {
    const next = nextFlagArg(args, arg_i, flag, true);
    return std.fmt.parseInt(usize, next, 10) catch exitRequiresNumber(flag);
}

fn printResultsTable(
    w: *Io.Writer,
    terminal: Io.Terminal,
    measurements: Command.Measurements,
    baseline: ?Command.Measurements,
    with_delta: bool,
) !void {
    const layout = TableLayout.compute(measurements, baseline, with_delta);
    try TableLayout.printHeader(w, terminal, layout, with_delta);
    inline for (@typeInfo(Command.Measurements).@"struct".fields) |field| {
        const m = @field(measurements, field.name);
        if (measurementRowVisible(measurementFieldMeta(field.name).visibility, m)) {
            const first_m = if (baseline) |b| @as(?Measurement, @field(b, field.name)) else null;
            try printMeasurement(terminal, layout, m, field.name, first_m, with_delta);
        }
    }
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
        .sample_count = undefined,
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

fn countMetricsExceedingOutlierRateThreshold(m: Command.Measurements) u32 {
    var count: u32 = 0;
    inline for (@typeInfo(Command.Measurements).@"struct".fields) |field| {
        if (metricExceedsOutlierRateThreshold(@field(m, field.name))) count += 1;
    }
    return count;
}

fn measurementsTriggerOutlierNote(m: Command.Measurements) bool {
    return countMetricsExceedingOutlierRateThreshold(m) >= outlier_note_min_metrics;
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
    max_nano_seconds: u64,
    allow_failures: bool,
    warmup: usize,
};

fn benchmarkCommand(
    io: Io,
    arena: std.mem.Allocator,
    command: *Command,
    command_n: usize,
    config: CommandBenchmarkConfig,
    bar: ?*progress.ProgressBar,
    stderr_w: *Io.Writer,
    stderr_capture_buf: *?StderrCaptureBuf,
) !void {
    var samples: std.ArrayList(Sample) = .empty;
    try samples.ensureTotalCapacity(arena, @intCast(config.max_samples));
    for (0..config.warmup) |_| {
        var child = process.spawn(io, .{
            .argv = command.argv,
            .stdin = .inherit,
            .stdout = .ignore,
            .stderr = .ignore,
            .request_resource_usage_statistics = false,
        }) catch |err| {
            std.debug.print("\nerror: Couldn't execute {s}: {t}\n", .{ command.argv[0], err });
            process.exit(1);
        };
        const term = child.wait(io) catch |err| {
            std.debug.print("\nerror: warmup for '{s}': {t}\n", .{ command.raw_cmd, err });
            process.exit(1);
        };
        switch (term) {
            .exited => |code| {
                if (code != 0 and !config.allow_failures) {
                    std.debug.print("\nerror: warmup for '{s}' failed with exit code {d}\n", .{ command.raw_cmd, code });
                    process.exit(1);
                }
            },
            else => {
                std.debug.print("error: warmup terminated unexpectedly\n", .{});
                process.exit(1);
            },
        }
    }

    var perf_fds: [perf_measurements.len]fd_t = @splat(-1);
    openPerfGroup(&perf_fds);
    defer closePerfFds(&perf_fds);

    const first_start: Io.Timestamp = .now(io, .awake);
    var sample_index: usize = 0;
    var failure_stderr_verbose_shown = false;
    var suppressed_failure_notes: u64 = 0;
    var perf_ioctl_warned = false;
    var perf_ioctl_skips: u32 = 0;
    const perf_ioctl_skip_limit = perfIoctlSkipLimit(config.max_samples);
    while ((sample_index < config.min_samples or
        first_start.untilNow(io, .awake).toNanoseconds() < config.max_nano_seconds) and
        sample_index < config.max_samples)
    {
        resetPerfGroupBeforeSample(perf_fds[0]) catch |err| {
            onPerfIoctlSkip(err, command.raw_cmd, &perf_ioctl_warned, &perf_ioctl_skips, perf_ioctl_skip_limit);
            continue;
        };

        const start: Io.Timestamp = .now(io, .awake);
        const capture_failure_stderr = config.allow_failures and !failure_stderr_verbose_shown;

        var child = process.spawn(io, .{
            .argv = command.argv,
            .stdin = .inherit,
            .stdout = .ignore,
            .stderr = if (capture_failure_stderr) .pipe else .ignore,
            .request_resource_usage_statistics = true,
        }) catch |err| {
            std.debug.print("\nerror: Couldn't execute {s}: {t}\n", .{ command.argv[0], err });
            process.exit(1);
        };

        var stderr_bytes: []const u8 = "";
        var stderr_truncated = false;
        var term: process.Child.Term = undefined;
        var duration: Io.Duration = undefined;

        if (capture_failure_stderr) {
            if (stderr_capture_buf.* == null) {
                stderr_capture_buf.* = .{
                    .storage = try arena.alloc(u8, max_stderr_bytes),
                };
            }
            const capture_buf = &stderr_capture_buf.*.?;
            capture_buf.reset();
            const measured = try waitChildAndCaptureStderr(io, &child, start, capture_buf);
            term = measured.term;
            duration = measured.duration;
            const capture = capture_buf.view();
            stderr_bytes = capture.bytes;
            stderr_truncated = capture.truncated;
        } else {
            term = child.wait(io) catch |err| {
                std.debug.print("\nerror: Couldn't execute {s}: {t}\n", .{ command.argv[0], err });
                process.exit(1);
            };
            duration = start.untilNow(io, .awake);
        }

        disablePerfGroupAfterSample(perf_fds[0]) catch |err| {
            onPerfIoctlSkip(err, command.raw_cmd, &perf_ioctl_warned, &perf_ioctl_skips, perf_ioctl_skip_limit);
            continue;
        };

        const usage = child.resource_usage_statistics;
        const peak_rss = usage.getMaxRss() orelse 0;
        const faults = readPageFaults(usage);

        switch (term) {
            .exited => |code| {
                if (code != 0 and !config.allow_failures) {
                    if (bar) |b| b.clear() catch {};
                    std.debug.print("\nerror: Benchmark {d} command '{s}' failed with exit code {d}\n", .{
                        command_n,
                        command.raw_cmd,
                        code,
                    });
                    std.debug.print("hint: pass --allow-failures to capture stderr from failing runs\n", .{});
                    process.exit(1);
                }
                if (code != 0 and config.allow_failures) {
                    command.failed_sample_count += 1;
                    if (!failure_stderr_verbose_shown) {
                        failure_stderr_verbose_shown = true;
                        std.debug.print("\nnote: sample {d} for '{s}' exited {d}\n", .{
                            sample_index + 1,
                            command.raw_cmd,
                            code,
                        });
                        printCapturedStderr(stderr_bytes, stderr_truncated);
                    } else {
                        suppressed_failure_notes += 1;
                    }
                }
            },
            else => {
                std.debug.print("error: terminated unexpectedly\n", .{});
                process.exit(1);
            },
        }

        const perf_values = try readSamplePerfCounters(&perf_fds);

        try samples.append(arena, .{
            .wall_time = @intCast(duration.toNanoseconds()),
            .peak_rss = peak_rss,
            .minor_faults = faults.minor,
            .major_faults = faults.major,
            .cpu_cycles = perf_values[0],
            .instructions = perf_values[1],
            .cache_references = perf_values[2],
            .cache_misses = perf_values[3],
            .branch_misses = perf_values[4],
        });

        sample_index += 1;

        if (bar) |b| {
            b.estimate = est_total: {
                const cur_samples: u64 = sample_index;
                var ns_per_sample: u64 = @intCast(@divTrunc((first_start.untilNow(io, .awake).toNanoseconds()), cur_samples));
                if (ns_per_sample == 0) ns_per_sample = 1;
                const estimate = std.math.divCeil(u64, config.max_nano_seconds, ns_per_sample) catch unreachable;
                break :est_total @intCast(@min(config.max_samples, @max(cur_samples, estimate, config.min_samples)));
            };
            b.current += 1;
            try b.render(io);
        }
    }

    if (suppressed_failure_notes > 0) {
        if (suppressed_failure_notes == 1) {
            std.debug.print("\nnote: 1 more failed sample for '{s}' (stderr omitted)\n", .{command.raw_cmd});
        } else {
            std.debug.print("\nnote: {d} more failed samples for '{s}' (stderr omitted)\n", .{
                suppressed_failure_notes,
                command.raw_cmd,
            });
        }
    }

    if (bar) |b| {
        b.estimate = b.current;
        try b.render(io);
        try b.clear();
        try stderr_w.writeAll("\n");
        try stderr_w.flush();
        b.current = 0;
        b.estimate = 1;
    }

    const all_samples = samples.items;
    if (all_samples.len == 0) {
        std.debug.print("\nerror: no samples collected for '{s}' (try longer --duration or more --min-samples)\n", .{
            command.raw_cmd,
        });
        process.exit(1);
    }
    const sort_scratch = try arena.alloc(Sample, all_samples.len);
    command.measurements = Measurement.summarizeAll(all_samples, sort_scratch) catch |err| {
        std.debug.print("\nerror: stats for '{s}': {s}\n", .{
            command.raw_cmd,
            Measurement.errorMessage(err),
        });
        process.exit(1);
    };
    command.sample_count = all_samples.len;
}

pub fn main(init: process.Init) !void {
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
    var max_nano_seconds: u64 = default_duration_ms * std.time.ns_per_ms;
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
            max_nano_seconds = std.time.ns_per_ms * parseFlagU64(args, &arg_i, arg, true);
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
            min_samples = parseFlagU64(args, &arg_i, arg, true);
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--max-samples")) {
            const parsed_max = parseFlagU64(args, &arg_i, arg, true);
            if (parsed_max > help.max_samples_cap) {
                max_samples_clamped_from = parsed_max;
                max_samples = help.max_samples_cap;
            } else {
                max_samples = parsed_max;
            }
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--warmup")) {
            warmup = parseFlagUsized(args, &arg_i, arg);
        } else {
            std.debug.print("unrecognized argument: '{s}'\n{s}", .{ arg, help.usage_text });
            process.exit(1);
        }
    }

    if (commands.items.len == 0) {
        @branchHint(.cold);
        try stdout_w.writeAll(help.usage_text);
        try stdout_w.flush();
        process.exit(1);
    }

    help.validateSampleLimits(min_samples, max_samples) catch |err| {
        @branchHint(.cold);
        std.debug.print("error: {s}\n", .{help.errorMessage(err)});
        process.exit(1);
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

    var bar: ?progress.ProgressBar = null;
    var terminal: ?Io.Terminal = null;
    if (!quiet) {
        terminal = Io.Terminal{
            .writer = stdout_w,
            .mode = switch (color) {
                .auto => try Io.Terminal.detect(
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
            .auto => try Io.Terminal.detect(
                io,
                .stderr(),
                no_color_env,
                clicolor_force_env,
            ),
            .never => .no_color,
            .ansi => .escape_codes,
        };
        bar = try progress.ProgressBar.init(io, arena, stderr_w, bar_mode, Io.File.stderr());
    }
    defer if (bar) |*b| b.deinit();

    var stderr_capture_buf: ?StderrCaptureBuf = null;
    const bench_config = CommandBenchmarkConfig{
        .min_samples = min_samples,
        .max_samples = max_samples,
        .max_nano_seconds = max_nano_seconds,
        .allow_failures = allow_failures,
        .warmup = warmup,
    };

    for (commands.items, 1..) |*command, command_n| {
        try benchmarkCommand(
            io,
            arena,
            command,
            command_n,
            bench_config,
            if (bar) |*b| b else null,
            stderr_w,
            &stderr_capture_buf,
        );
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

    for (commands.items, 1..) |*command, command_n| {
        if (terminal) |t| {
            try t.setColor(.bold);
            try stdout_w.print("Benchmark {d}", .{command_n});
            try t.setColor(.dim);
            if (command.failed_sample_count > 0) {
                try stdout_w.print(" ({d} runs, {d} failed)", .{
                    command.sample_count,
                    command.failed_sample_count,
                });
            } else {
                try stdout_w.print(" ({d} runs)", .{command.sample_count});
            }
            try t.setColor(.reset);
            try stdout_w.writeAll(":");
            for (command.argv) |arg| try stdout_w.print(" {s}", .{arg});
            try stdout_w.writeAll("\n");

            const with_delta = commands.items.len >= 2;
            const baseline: ?Command.Measurements = if (command_n == 1) null else commands.items[0].measurements;
            try printResultsTable(stdout_w, t, command.measurements, baseline, with_delta);

            try stdout_w.flush();
        }
    }

    if (json_path) |path| {
        var file_buf: [json_file_buf_len]u8 = undefined;
        var file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
            std.debug.print("\nerror: cannot write JSON to '{s}': {t}\n", .{ path, err });
            process.exit(1);
        };
        defer file.close(io);
        var file_writer = file.writerStreaming(io, &file_buf);
        const json_config = JsonRunConfig{
            .duration_ms = max_nano_seconds / std.time.ns_per_ms,
            .min_samples = min_samples,
            .max_samples = max_samples,
            .max_samples_requested = max_samples_clamped_from,
            .warmup = warmup,
            .allow_failures = allow_failures,
        };
        try printJsonOutput(&file_writer.interface, commands.items, json_config);
        try file_writer.flush();
        if (!quiet) try stdout_w.print("results written to {s}\n", .{path});
    }

    try stdout_w.flush();
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

fn readStderrFd(stderr_fd: fd_t, buf: *StderrCaptureBuf) !void {
    var scratch: [stderr_pipe_read_scratch]u8 = undefined;
    while (true) {
        const n = std.posix.read(stderr_fd, &scratch) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        if (n == 0) return;
        buf.append(scratch[0..n]);
        if (buf.truncated and buf.len >= max_stderr_bytes) {
            buf.len = max_stderr_bytes;
            discardStderrRemainder(stderr_fd);
            return;
        }
    }
}

fn discardStderrRemainder(stderr_fd: fd_t) void {
    var buf: [stderr_pipe_read_scratch]u8 = undefined;
    while (std.posix.read(stderr_fd, &buf)) |_| {} else |_| return;
}

// With -f: wall time ends when the child exits; stderr drain after that is extra.
// Read stderr while the child runs so a full pipe can't block wait.
fn waitChildAndCaptureStderr(
    io: Io,
    child: *process.Child,
    start: Io.Timestamp,
    capture_buf: *StderrCaptureBuf,
) !struct { term: process.Child.Term, duration: Io.Duration } {
    const stderr_fd = child.stderr.?.handle;
    const pid: std.os.linux.pid_t = @intCast(child.id.?);

    const initial_flags: u32 = blk: {
        const r = std.os.linux.fcntl(stderr_fd, std.os.linux.F.GETFL, 0);
        switch (std.os.linux.errno(r)) {
            .SUCCESS => break :blk @intCast(r),
            else => |err| {
                std.debug.print("\nerror: fcntl on child stderr: {t}\n", .{err});
                process.exit(1);
            },
        }
    };
    const nonblock: u32 = @bitCast(std.os.linux.O{ .NONBLOCK = true });
    _ = std.os.linux.fcntl(stderr_fd, std.os.linux.F.SETFL, initial_flags | nonblock);

    var term: process.Child.Term = undefined;
    var duration: Io.Duration = undefined;

    var child_done = false;
    while (!child_done) {
        try readStderrFd(stderr_fd, capture_buf);

        var status: u32 = undefined;
        var ru: std.os.linux.rusage = undefined;
        const ru_ptr: ?*std.os.linux.rusage = if (child.request_resource_usage_statistics) &ru else null;

        const w = std.os.linux.wait4(pid, &status, std.os.linux.W.NOHANG, ru_ptr);
        switch (std.os.linux.errno(w)) {
            .SUCCESS => {
                if (w == 0) {
                    std.Thread.yield() catch {};
                    continue;
                }
                duration = start.untilNow(io, .awake);
                term = posixWaitStatusToTerm(status);
                if (child.request_resource_usage_statistics) child.resource_usage_statistics.rusage = ru;
                child_done = true;
            },
            .INTR => continue,
            else => |err| {
                std.debug.print("\nerror: wait for child: {t}\n", .{err});
                process.exit(1);
            },
        }
    }

    _ = std.os.linux.fcntl(stderr_fd, std.os.linux.F.SETFL, initial_flags);
    if (!capture_buf.truncated) {
        readStderrFd(stderr_fd, capture_buf) catch {};
    } else {
        discardStderrRemainder(stderr_fd);
    }

    closeChildPipes(child);

    return .{
        .term = term,
        .duration = duration,
    };
}

fn printCapturedStderr(bytes: []const u8, truncated: bool) void {
    if (bytes.len == 0 and !truncated) return;
    if (truncated) {
        std.debug.print(
            \\────────────── truncated stderr ──────────────
            \\{s}
            \\──────────────────────────────────────────────
            \\
        , .{bytes});
    } else {
        std.debug.print(
            \\─────────────────── stderr ───────────────────
            \\{s}
            \\──────────────────────────────────────────────
            \\
        , .{bytes});
    }
}

const PerfSampleResetError = error{
    BadLeaderFd,
    DisableFailed,
    ResetFailed,
};

const PerfSampleDisableError = error{
    BadLeaderFd,
    DisableFailed,
};

fn perfGroupIoctl(leader_fd: fd_t, request: u32) (error{ BadLeaderFd, IoctlFailed })!void {
    if (leader_fd == -1) return error.BadLeaderFd;
    const rc = std.os.linux.ioctl(leader_fd, request, PERF.IOC_FLAG_GROUP);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        else => return error.IoctlFailed,
    }
}

fn resetPerfGroupBeforeSample(leader_fd: fd_t) PerfSampleResetError!void {
    if (leader_fd == -1) return error.BadLeaderFd;
    perfGroupIoctl(leader_fd, PERF.EVENT_IOC.DISABLE) catch return error.DisableFailed;
    perfGroupIoctl(leader_fd, PERF.EVENT_IOC.RESET) catch return error.ResetFailed;
}

fn disablePerfGroupAfterSample(leader_fd: fd_t) PerfSampleDisableError!void {
    if (leader_fd == -1) return error.BadLeaderFd;
    perfGroupIoctl(leader_fd, PERF.EVENT_IOC.DISABLE) catch return error.DisableFailed;
}

fn printPerfIoctlSkipWarn(err: anyerror, command: []const u8) void {
    const detail: []const u8 = switch (err) {
        error.BadLeaderFd => "perf group leader is not open",
        error.DisableFailed => "PERF_EVENT_IOC.DISABLE failed",
        error.ResetFailed => "PERF_EVENT_IOC.RESET failed",
        error.IoctlFailed => "perf ioctl failed",
        else => "perf ioctl failed",
    };
    std.debug.print(
        "\nwarn: skipping measured sample for '{s}': {s}; remaining samples continue\n",
        .{ command, detail },
    );
}

fn perfIoctlSkipLimit(max_samples: u64) u32 {
    const scaled = max_samples *| 2;
    return @intCast(@max(perf_ioctl_skip_limit_min, @min(scaled, perf_ioctl_skip_limit_max)));
}

fn onPerfIoctlSkip(
    err: anyerror,
    command: []const u8,
    perf_ioctl_warned: *bool,
    perf_ioctl_skips: *u32,
    skip_limit: u32,
) void {
    if (!perf_ioctl_warned.*) {
        printPerfIoctlSkipWarn(err, command);
        perf_ioctl_warned.* = true;
    }
    perf_ioctl_skips.* +%= 1;
    if (perf_ioctl_skips.* >= skip_limit) {
        std.debug.print(
            "\nerror: perf ioctl failed {d} times for '{s}'; aborting command\n",
            .{ perf_ioctl_skips.*, command },
        );
        process.exit(1);
    }
}

fn printShortPerfReadError(counter_name: []const u8) noreturn {
    std.debug.print(
        "\nerror: incomplete read from perf counter '{s}' (expected {d} bytes)\n",
        .{ counter_name, @sizeOf(u64) },
    );
    std.debug.print(
        \\hint: perf counter was reset or closed before the value could be read; close other perf tools or try again
        \\
    , .{});
    process.exit(1);
}

fn printPerfOpenError(err: std.posix.PerfEventOpenError, counter_name: []const u8) noreturn {
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
    process.exit(1);
}

fn perfEventAttrForGroupMember(config: PERF.COUNT.HW, is_leader: bool) std.os.linux.perf_event_attr {
    return .{
        .type = PERF.TYPE.HARDWARE,
        .config = @intFromEnum(config),
        .read_format = 0,
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

fn openPerfGroup(fds: *[perf_measurements.len]fd_t) void {
    // Reopen perf fds once per command, not per sample.
    for (perf_measurements, fds, 0..) |measurement, *perf_fd, i| {
        var attr = perfEventAttrForGroupMember(measurement.config, i == 0);
        perf_fd.* = std.posix.perf_event_open(&attr, 0, -1, fds[0], PERF.FLAG.FD_CLOEXEC) catch |err| {
            closePerfFds(fds);
            printPerfOpenError(err, measurement.name);
        };
    }
}

fn readSamplePerfCounters(fds: *const [perf_measurements.len]fd_t) ![perf_measurements.len]u64 {
    var values: [perf_measurements.len]u64 = undefined;
    for (0..perf_measurements.len) |i| {
        values[i] = readPerfFd(fds[i]) catch |err| switch (err) {
            error.ShortPerfRead => printShortPerfReadError(perf_measurements[i].name),
            else => return err,
        };
    }
    return values;
}

fn readPerfFd(fd: fd_t) !u64 {
    // With read_format=0, a perf event fd returns one u64 counter value.
    // Keep this independent of usize: supported 32-bit x86 has 32-bit usize.
    var result: u64 = 0;
    const n = try std.posix.read(fd, std.mem.asBytes(&result));
    if (n != @sizeOf(u64)) return error.ShortPerfRead;
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

    pub const StatsError = error{
        NoSamples,
        ScratchTooSmall,
    };

    pub fn errorMessage(err: StatsError) []const u8 {
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
            // Even count: use the upper of the two middle values.
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

comptime {
    for (std.meta.fieldNames(Measurement.StatsError)) |name| {
        _ = Measurement.errorMessage(@field(Measurement.StatsError, name));
    }
}

fn printMeasurement(
    terminal: Io.Terminal,
    layout: TableLayout,
    m: Measurement,
    name: []const u8,
    first_m: ?Measurement,
    with_delta: bool,
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
        try writeDelta(w, terminal, &vis, layout, m, first_m, color_enabled);
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

pub fn getStatScore95(df: ?u64) f64 {
    if (df) |dff| {
        const dfv: usize = @intCast(dff);
        if (dfv == 0) return 1.96;
        if (dfv <= 30) {
            return t_table95_1to30[dfv - 1];
        } else if (dfv <= 120) {
            const idx_10s = @divFloor(dfv, 10);
            return t_table95_10s_10to120[idx_10s - 1];
        }
    }
    return 1.96;
}

const t_table95_1to30 = [_]f64{
    12.706,
    4.303,
    3.182,
    2.776,
    2.571,
    2.447,
    2.365,
    2.306,
    2.262,
    2.228,
    2.201,
    2.179,
    2.16,
    2.145,
    2.131,
    2.12,
    2.11,
    2.101,
    2.093,
    2.086,
    2.08,
    2.074,
    2.069,
    2.064,
    2.06,
    2.056,
    2.052,
    2.048,
    2.045,
    2.042,
};

const t_table95_10s_10to120 = [_]f64{
    2.228,
    2.086,
    2.042,
    2.021,
    2.009,
    2,
    1.994,
    1.99,
    1.987,
    1.984,
    1.982,
    1.98,
};

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

fn stripAnsiForTest(input: []const u8) []const u8 {
    var out: [256]u8 = undefined;
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

fn writeDeltaPlainToBuf(m: Measurement, first_m: ?Measurement) ![]const u8 {
    var buf: [64]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    try writeDeltaPlain(&w, m, first_m);
    return buf[0..w.end];
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
    measurements: Command.Measurements,
    baseline: ?Command.Measurements,
    mode: Io.Terminal.Mode,
) ![]const u8 {
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const term = Io.Terminal{ .writer = &w, .mode = mode };
    try printResultsTable(&w, term, measurements, baseline, baseline != null);
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
        const vis_line = stripAnsiForTest(line);
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
        const vis_line = stripAnsiForTest(line);
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
            const layout = TableLayout.compute(measurements, measurements, true);
            try TableLayout.printHeader(&w, term, layout, true);
            try printMeasurement(term, layout, f.wall, "wall_time", null, true);
            try printMeasurement(term, layout, f.rss, "peak_rss", f.wall, true);
            try printMeasurement(term, layout, f.faults, "minor_faults", f.wall, true);
            try printMeasurement(term, layout, f.cycles, "cpu_cycles", f.wall, true);
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
            const layout = TableLayout.compute(compare, baseline, true);
            try TableLayout.printHeader(&w, term, layout, true);
            try printMeasurement(term, layout, compare.wall_time, "wall_time", baseline.wall_time, true);
            try printMeasurement(term, layout, compare.peak_rss, "peak_rss", baseline.peak_rss, true);
            try printMeasurement(term, layout, compare.minor_faults, "minor_faults", baseline.minor_faults, true);
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

test "main.jsonOutput" {
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

    const Parsed = struct {
        schema_version: u32,
        zebrac_version: []const u8,
        config: struct {
            duration_ms: u64,
            min_samples: u64,
            max_samples_cap: u64,
            max_samples_requested: ?u64,
        },
        results: []struct {
            command: []const u8,
            sample_count: usize,
            failed_sample_count: u64,
            wall_time: struct { mean: f64, unit: []const u8 },
            major_faults: struct { mean: f64, unit: []const u8 },
        },
    };
    const parsed = try std.json.parseFromSlice(Parsed, std.testing.allocator, w.buffered(), .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(json_schema_version, parsed.value.schema_version);
    try std.testing.expectEqualStrings(help.version, parsed.value.zebrac_version);
    try std.testing.expectEqual(@as(u64, 500), parsed.value.config.duration_ms);
    try std.testing.expectEqual(@as(?u64, 50_000), parsed.value.config.max_samples_requested);
    try std.testing.expectEqual(@as(u64, 2), parsed.value.results[0].failed_sample_count);
    try std.testing.expectEqualStrings("nanoseconds", parsed.value.results[0].wall_time.unit);
    try std.testing.expectEqualStrings("count", parsed.value.results[0].major_faults.unit);
}

test "main.outlierRateThreshold" {
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

test "main.stderrCaptureBuf" {
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

test "main.perf" {
    try std.testing.expectError(error.BadLeaderFd, resetPerfGroupBeforeSample(-1));
    try std.testing.expectError(error.BadLeaderFd, disablePerfGroupAfterSample(-1));

    const leader = perfEventAttrForGroupMember(PERF.COUNT.HW.CPU_CYCLES, true);
    const child = perfEventAttrForGroupMember(PERF.COUNT.HW.INSTRUCTIONS, false);
    try std.testing.expectEqual(@as(u64, 0), leader.read_format);
    try std.testing.expectEqual(@as(u64, 0), child.read_format);
    try std.testing.expect(leader.flags.disabled);
    try std.testing.expect(!child.flags.disabled);

    try withPipe(struct {
        fn disableOnPipe(fd: fd_t) !void {
            try std.testing.expectError(error.DisableFailed, disablePerfGroupAfterSample(fd));
        }
    }.disableOnPipe);
    try withPipe(struct {
        fn resetOnPipe(fd: fd_t) !void {
            resetPerfGroupBeforeSample(fd) catch |err| switch (err) {
                error.DisableFailed, error.ResetFailed => {},
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

    var value_pipe: [2]i32 = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.pipe(&value_pipe)));
    defer {
        _ = std.os.linux.close(value_pipe[0]);
        _ = std.os.linux.close(value_pipe[1]);
    }
    const expected: u64 = 0xFEED_BEEF_0123_4567;
    const expected_bytes = std.mem.asBytes(&expected);
    try std.testing.expectEqual(
        @sizeOf(u64),
        std.os.linux.write(value_pipe[1], expected_bytes.ptr, expected_bytes.len),
    );
    try std.testing.expectEqual(expected, try readPerfFd(value_pipe[0]));
}

test "main.getStatScore95" {
    const cases = [_]struct { df: ?u64, want: f64 }{
        .{ .df = null, .want = 1.96 },
        .{ .df = 0, .want = 1.96 },
        .{ .df = 200, .want = 1.96 },
        .{ .df = 1, .want = 12.706 },
        .{ .df = 30, .want = 2.042 },
        .{ .df = 28, .want = 2.048 },
        .{ .df = 29, .want = 2.045 },
    };
    for (cases) |c| try std.testing.expectApproxEqAbs(c.want, getStatScore95(c.df), 0.001);
}

test "main.summarize.field" {
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

test "main.summarize.all" {
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

test "main.compareDelta" {
    const m = measurementForDeltaTest(10, 1, 10);
    try std.testing.expect(deltaHalfWidth(m, measurementForDeltaTest(0, 1, 10)) == null);
    try std.testing.expect(deltaHalfWidth(
        measurementForDeltaTest(10, 0, 1),
        measurementForDeltaTest(10, 0, 1),
    ) == null);

    const half = deltaHalfWidth(
        measurementForDeltaTest(110, 10, 10),
        measurementForDeltaTest(100, 10, 10),
    ).?;
    try std.testing.expect(half > 0);

    const sig_cases = [_]struct { diff: f64, band: f64, want: bool }{
        .{ .diff = 2, .band = 1, .want = true },
        .{ .diff = 2, .band = 1.01, .want = false },
        .{ .diff = 1, .band = 0, .want = true },
        .{ .diff = 0.99, .band = 0, .want = false },
        .{ .diff = -2, .band = 1, .want = true },
        .{ .diff = -1, .band = 0.01, .want = false },
    };
    for (sig_cases) |c| try std.testing.expectEqual(c.want, deltaIsSignificant(c.diff, c.band));

    try std.testing.expectEqualStrings("n/a", try writeDeltaPlainToBuf(measurementForDeltaTest(5, 1, 10), measurementForDeltaTest(0, 0, 10)));
    try std.testing.expectEqualStrings("n/a", try writeDeltaPlainToBuf(measurementForDeltaTest(10, 1, 1), measurementForDeltaTest(10, 1, 1)));
    try std.testing.expectEqualStrings("0%", try writeDeltaPlainToBuf(measurementForDeltaTest(100, 10, 10), measurementForDeltaTest(100, 10, 10)));

    const m_up = measurementForDeltaTest(110, 10, 10);
    const f_up = measurementForDeltaTest(100, 10, 10);
    try std.testing.expectEqualStrings("  + 10.0% ±  9.4%", try writeDeltaPlainToBuf(m_up, f_up));

    const m_dn = measurementForDeltaTest(90, 10, 10);
    const f_dn = measurementForDeltaTest(100, 10, 10);
    try std.testing.expectEqualStrings("  - 10.0% ±  9.4%", try writeDeltaPlainToBuf(m_dn, f_dn));
}

test "main.resultsTable" {
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
    const out = try renderResultsTableForTest(tableFixtureMeasurements(zero_faults), null, .no_color);
    try std.testing.expect(std.mem.indexOf(u8, out, "major_faults") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "minor_faults") != null);
    try std.testing.expectEqual(
        MeasurementRowVisibility.hide_when_max_is_zero,
        measurementFieldMeta("major_faults").visibility,
    );

    for (&[_]Io.Terminal.Mode{ .no_color, .escape_codes }) |mode| {
        try tableAlignmentInvariantsTest(mode, .mixed_units);
        try tableAlignmentInvariantsTest(mode, .zero_delta);
    }
}

test "main.unitFormat" {
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
    try std.testing.expectEqual(measureUnitValueVis(&buf, 62.3, .count), measureUnit(&buf, 62.3, .count));

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
    try std.testing.expectEqual(@as(usize, 3), measureUnitValueVis(&buf, std.math.nan(f64), .count));
    try std.testing.expectEqual(@as(usize, 5), measureUnit(&buf, std.math.inf(f64), .bytes));
}

test "main.summarizeField.fuzz" {
    try std.testing.fuzz({}, fuzzSummarizeField, .{});
}
