//! Loop commands, sample perf counters and rusage, emit a stats table or JSON.
const std = @import("std");
const Io = std.Io;
const process = std.process;
const PERF = std.os.linux.PERF;
const fd_t = std.posix.fd_t;
const progress = @import("progress.zig");
const argv_parse = @import("argv_parse.zig");
const help = @import("help.zig");
const max_stderr_bytes = 1024 * 1024;

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

/// Fixed visible column starts (bytes, no ANSI). Header and rows share these.
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
                layout.name_w = @max(layout.name_w, row_indent + visibleLen(field.name));
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

    fn minSepVis(self: TableLayout) usize {
        return self.name_w + col_gap + self.mean_w + visibleLen(sep_mean) + self.std_w + col_gap + self.min_w;
    }

    fn outlierStartVis(self: TableLayout) usize {
        return self.minSepVis() + visibleLen(sep_minmax) + self.max_w + col_gap;
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

    fn printHeader(w: *Io.Writer, t: Io.Terminal, layout: TableLayout, with_delta: bool) !void {
        var vis: usize = 0;
        try w.splatByteAll(' ', row_indent);
        try w.writeAll("measurement");
        vis = row_indent + visibleLen("measurement");
        try padVis(w, &vis, layout.name_w);

        try gap(w, &vis);
        try padVis(w, &vis, layout.meanSepVis() - visibleLen("mean"));
        try t.setColor(.bright_green);
        try w.writeAll("mean");
        try t.setColor(.reset);
        vis = layout.meanSepVis();
        try t.setColor(.bold);
        try w.writeAll(sep_mean);
        try t.setColor(.reset);
        vis += visibleLen(sep_mean);
        try t.setColor(.green);
        try w.writeAll("σ");
        try t.setColor(.reset);
        vis += visibleLen("σ");
        try padVis(
            w,
            &vis,
            layout.name_w + col_gap + layout.mean_w + visibleLen(sep_mean) + layout.std_w,
        );

        try gap(w, &vis);
        try padVis(w, &vis, layout.minSepVis() - visibleLen("min"));
        try t.setColor(.bold);
        try t.setColor(.cyan);
        try w.writeAll("min");
        try t.setColor(.reset);
        vis = layout.minSepVis();
        try t.setColor(.bold);
        try w.writeAll(sep_minmax);
        try t.setColor(.reset);
        try t.setColor(.magenta);
        try w.writeAll("max");
        try t.setColor(.reset);
        vis = layout.minSepVis() + visibleLen(sep_minmax) + visibleLen("max");
        try padVis(
            w,
            &vis,
            layout.name_w + col_gap + layout.mean_w + visibleLen(sep_mean) + layout.std_w + col_gap + layout.min_w + visibleLen(sep_minmax) + layout.max_w,
        );

        try gap(w, &vis);
        try padVis(w, &vis, layout.outlierStartVis());
        try t.setColor(.bold);
        try t.setColor(.bright_yellow);
        try w.writeAll("outliers");
        try t.setColor(.reset);
        vis = layout.outlierStartVis() + visibleLen("outliers");
        try padVis(w, &vis, layout.outlierStartVis() + layout.outlier_w);

        if (with_delta) {
            try gap(w, &vis);
            try padVis(w, &vis, layout.deltaStartVis());
            try t.setColor(.bold);
            try w.writeAll("delta");
            try t.setColor(.reset);
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

const UnitScaled = struct {
    val: f64,
    suffix: []const u8,
};

fn scaleUnit(x: f64, unit: Measurement.Unit) UnitScaled {
    if (unit == .nanoseconds) {
        if (x >= 3600 * 1_000_000_000) {
            return .{ .val = x / (3600 * 1_000_000_000), .suffix = "h " };
        }
        if (x >= 60 * 1_000_000_000) {
            return .{ .val = x / (60 * 1_000_000_000), .suffix = "m " };
        }
        if (x >= 1_000_000_000) {
            return .{ .val = x / 1_000_000_000, .suffix = "s " };
        }
        if (x >= 1_000_000) {
            return .{ .val = x / 1_000_000, .suffix = "ms" };
        }
        if (x >= 1_000) {
            return .{ .val = x / 1_000, .suffix = "us" };
        }
        return .{ .val = x, .suffix = "ns" };
    }
    if (x >= 1000_000_000_000) {
        return .{ .val = x / 1000_000_000_000, .suffix = switch (unit) {
            .count => "T ",
            .bytes => "TB",
            .nanoseconds => unreachable,
        } };
    }
    if (x >= 1000_000_000) {
        return .{ .val = x / 1000_000_000, .suffix = switch (unit) {
            .count => "G ",
            .bytes => "GB",
            .nanoseconds => unreachable,
        } };
    }
    if (x >= 1000_000) {
        return .{ .val = x / 1000_000, .suffix = switch (unit) {
            .count => "M ",
            .bytes => "MB",
            .nanoseconds => unreachable,
        } };
    }
    if (x >= 1000) {
        return .{ .val = x / 1000, .suffix = switch (unit) {
            .count => "K ",
            .bytes => "KB",
            .nanoseconds => unreachable,
        } };
    }
    return .{ .val = x, .suffix = switch (unit) {
        .count => "  ",
        .bytes => "  ",
        .nanoseconds => unreachable,
    } };
}

fn formatUnitPlain(w: *std.Io.Writer, x: f64, unit: Measurement.Unit) !void {
    const s = scaleUnit(x, unit);
    try printNum3SigFigs(w, s.val);
    try w.writeAll(s.suffix);
}

fn formatUnitVisibleLen(w: *std.Io.Writer, x: f64, unit: Measurement.Unit) !usize {
    const prev = w.end;
    try formatUnitPlain(w, x, unit);
    return w.end - prev;
}

fn measureUnit(buf: *[32]u8, x: f64, unit: Measurement.Unit) usize {
    var w = std.Io.Writer.fixed(buf);
    return formatUnitVisibleLen(&w, x, unit) catch 0;
}

fn measureOutlier(buf: *[32]u8, count: u64, sample_count: u64) usize {
    const line = formatOutlierLine(buf, count, sample_count) catch return 0;
    return visibleLen(line);
}

const delta_baseline_epsilon: f64 = 1e-9;

/// Table yellow outlier column and stderr hint both use this rate (percent).
const outlier_highlight_threshold_percent: f64 = 10.0;

/// Per-field CLI table metadata (comptime). JSON always emits every summarized field.
const MeasurementFieldMeta = struct {
    visibility: MeasurementRowVisibility,
    unit: Measurement.Unit,
};

const MeasurementRowVisibility = enum {
    always,
    hide_when_max_is_zero,
};

fn measurementFieldMeta(comptime field_name: []const u8) MeasurementFieldMeta {
    if (comptime std.mem.eql(u8, field_name, "wall_time")) {
        return .{ .visibility = .always, .unit = .nanoseconds };
    }
    if (comptime std.mem.eql(u8, field_name, "peak_rss")) {
        return .{ .visibility = .always, .unit = .bytes };
    }
    if (comptime std.mem.eql(u8, field_name, "major_faults")) {
        return .{ .visibility = .hide_when_max_is_zero, .unit = .count };
    }
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
    const pct = @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(sample_count)) * 100;
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

fn diffMeanPercent(m: Measurement, f: Measurement) f64 {
    return (m.mean - f.mean) * 100 / f.mean;
}

fn isZeroDiffPercent(diff_mean_percent: f64) bool {
    return @abs(diff_mean_percent) < delta_baseline_epsilon;
}

/// Equal means: bare `0%` when compare is defined; `n/a` when CI cannot be computed.
fn writeZeroDiffDeltaPlain(w: *Io.Writer, m: Measurement, f: Measurement) !void {
    if (!deltaIsDefined(m, f)) {
        try w.writeAll("n/a");
    } else {
        try w.writeAll("0%");
    }
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
    const diff_mean_percent = diffMeanPercent(m, f);
    if (isZeroDiffPercent(diff_mean_percent)) {
        try writeZeroDiffDeltaPlain(w, m, f);
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

fn writeUnitRightAligned(
    terminal: Io.Terminal,
    w: *Io.Writer,
    vis: *usize,
    end_vis: usize,
    x: f64,
    unit: Measurement.Unit,
    color: Io.Terminal.Color,
    color_enabled: bool,
    buf: *[32]u8,
) !void {
    const s = scaleUnit(x, unit);
    var fbs = std.Io.Writer.fixed(buf);
    const len = try formatUnitVisibleLen(&fbs, x, unit);
    try TableLayout.padVis(w, vis, end_vis - len);
    try terminal.setColor(color);
    try printNum3SigFigs(w, s.val);
    if (color_enabled) try terminal.setColor(.dim);
    try w.writeAll(s.suffix);
    try terminal.setColor(.reset);
    vis.* = end_vis;
}

fn writeUnitLeftAligned(
    terminal: Io.Terminal,
    w: *Io.Writer,
    vis: *usize,
    x: f64,
    unit: Measurement.Unit,
    color: Io.Terminal.Color,
    color_enabled: bool,
    buf: *[32]u8,
) !void {
    const s = scaleUnit(x, unit);
    var fbs = std.Io.Writer.fixed(buf);
    const len = try formatUnitVisibleLen(&fbs, x, unit);
    try terminal.setColor(color);
    try printNum3SigFigs(w, s.val);
    if (color_enabled) try terminal.setColor(.dim);
    try w.writeAll(s.suffix);
    try terminal.setColor(.reset);
    vis.* += len;
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
    if (path.len == 0) return "zebrac-results.json";
    return path;
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

fn measurementsHaveHighOutlierRate(m: Command.Measurements) bool {
    inline for (@typeInfo(Command.Measurements).@"struct".fields) |field| {
        const meas = @field(m, field.name);
        if (meas.sample_count != 0) {
            const pct = @as(f64, @floatFromInt(meas.outlier_count)) /
                @as(f64, @floatFromInt(meas.sample_count)) * 100;
            if (pct >= outlier_highlight_threshold_percent) return true;
        }
    }
    return false;
}

fn anyCommandHighOutlierRate(commands: []const Command) bool {
    for (commands) |cmd| {
        if (measurementsHaveHighOutlierRate(cmd.measurements)) return true;
    }
    return false;
}

pub fn main(init: process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdout_w = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writerStreaming(io, &stderr_buffer);
    const stderr_w = &stderr_writer.interface;

    var commands: std.ArrayList(Command) = .empty;
    var max_nano_seconds: u64 = std.time.ns_per_s * 5;
    var color: ColorMode = .auto;
    var allow_failures = false;
    var json_path: ?[]const u8 = null;
    var quiet = false;
    var min_samples: u64 = 5;
    var max_samples: u64 = help.max_samples_cap;
    var max_samples_clamped_from: ?u64 = null;
    var warmup: usize = 3;

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
            try stdout_w.print("zebrac {s}\n", .{help.version});
            try stdout_w.flush();
            return process.cleanExit(io);
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--duration")) {
            arg_i += 1;
            if (arg_i >= args.len) {
                std.debug.print("'{s}' requires a duration in milliseconds.\n{s}", .{ arg, help.short_usage });
                process.exit(1);
            }
            const next = args[arg_i];
            const max_ms = std.fmt.parseInt(u64, next, 10) catch |err| {
                std.debug.print("unable to parse --duration argument '{s}': {t}\n", .{
                    next, err,
                });
                process.exit(1);
            };
            max_nano_seconds = std.time.ns_per_ms * max_ms;
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
                json_path = "zebrac-results.json";
            }
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--min-samples")) {
            arg_i += 1;
            if (arg_i >= args.len) {
                std.debug.print("'{s}' requires a number.\n{s}", .{ arg, help.short_usage });
                process.exit(1);
            }
            min_samples = std.fmt.parseInt(u64, args[arg_i], 10) catch |err| {
                std.debug.print("unable to parse --min-samples argument '{s}': {t}\n", .{ args[arg_i], err });
                process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--max-samples")) {
            arg_i += 1;
            if (arg_i >= args.len) {
                std.debug.print("'{s}' requires a number.\n{s}", .{ arg, help.short_usage });
                process.exit(1);
            }
            const parsed_max = std.fmt.parseInt(u64, args[arg_i], 10) catch |err| {
                std.debug.print("unable to parse --max-samples argument '{s}': {t}\n", .{ args[arg_i], err });
                process.exit(1);
            };
            if (parsed_max > help.max_samples_cap) {
                max_samples_clamped_from = parsed_max;
                max_samples = help.max_samples_cap;
            } else {
                max_samples = parsed_max;
            }
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--warmup")) {
            arg_i += 1;
            if (arg_i >= args.len) {
                std.debug.print("'{s}' requires a number.\n{s}", .{ arg, help.short_usage });
                process.exit(1);
            }
            warmup = std.fmt.parseInt(usize, args[arg_i], 10) catch |err| {
                std.debug.print("unable to parse --warmup argument '{s}': {t}\n", .{ args[arg_i], err });
                process.exit(1);
            };
        } else {
            std.debug.print("unrecognized argument: '{s}'\n{s}", .{ arg, help.usage_text });
            process.exit(1);
        }
    }

    if (commands.items.len == 0) {
        try stdout_w.writeAll(help.usage_text);
        try stdout_w.flush();
        process.exit(1);
    }

    help.validateSampleLimits(min_samples, max_samples) catch |err| {
        std.debug.print("error: {s}\n", .{help.sampleLimitsErrorMessage(err, min_samples, max_samples)});
        process.exit(1);
    };

    var run_notes: std.ArrayList([]const u8) = .empty;
    if (max_samples_clamped_from) |requested| {
        try run_notes.append(arena, try std.fmt.allocPrint(arena, "--max-samples {d} capped at {d}", .{
            requested, help.max_samples_cap,
        }));
    }

    const stdout_is_tty = Io.File.stdout().isTty(io) catch false;

    var bar: ?progress.ProgressBar = null;
    var terminal: ?Io.Terminal = null;
    if (!quiet) {
        terminal = Io.Terminal{
            .writer = stdout_w,
            .mode = switch (color) {
                .auto => try .detect(
                    io,
                    .stdout(),
                    if (init.environ_map.get("NO_COLOR")) |_| true else false,
                    if (init.environ_map.get("CLICOLOR_FORCE")) |_| true else false,
                ),
                .never => .no_color,
                .ansi => .escape_codes,
            },
        };
    }
    if (progress.samplingShowsProgressBar(quiet, stdout_is_tty)) {
        bar = try progress.ProgressBar.init(io, arena, stderr_w, terminal.?.mode, Io.File.stderr());
    }
    defer if (bar) |*b| b.deinit();

    var perf_fds: [perf_measurements.len]fd_t = @splat(-1);

    var stderr_capture_buf: ?StderrCaptureBuf = null;

    for (commands.items, 1..) |*command, command_n| {
        var samples: std.ArrayList(Sample) = .empty;
        try samples.ensureTotalCapacity(arena, @intCast(max_samples));
        for (0..warmup) |_| {
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
                    if (code != 0 and !allow_failures) {
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

        openPerfGroup(&perf_fds);
        defer closePerfFds(&perf_fds);

        const first_start: Io.Timestamp = .now(io, .awake);
        var sample_index: usize = 0;
        var failure_stderr_verbose_shown = false;
        var suppressed_failure_notes: u64 = 0;
        var perf_ioctl_warned = false;
        var perf_ioctl_skips: u32 = 0;
        const perf_ioctl_skip_limit = perfIoctlSkipLimit(max_samples);
        while ((sample_index < min_samples or
            first_start.untilNow(io, .awake).toNanoseconds() < max_nano_seconds) and
            sample_index < max_samples)
        {
            resetPerfGroupBeforeSample(perf_fds[0]) catch |err| {
                onPerfIoctlSkip(err, command.raw_cmd, &perf_ioctl_warned, &perf_ioctl_skips, perf_ioctl_skip_limit);
                continue;
            };

            const start: Io.Timestamp = .now(io, .awake);

            const capture_failure_stderr = allow_failures and !failure_stderr_verbose_shown;

            var child = try process.spawn(io, .{
                .argv = command.argv,
                .stdin = .inherit,
                .stdout = .ignore,
                .stderr = if (capture_failure_stderr) .pipe else .ignore,
                .request_resource_usage_statistics = true,
            });

            var stderr_bytes: []const u8 = "";
            var stderr_truncated = false;
            var term: process.Child.Term = undefined;
            var duration: Io.Duration = undefined;

            if (capture_failure_stderr) {
                if (stderr_capture_buf == null) {
                    stderr_capture_buf = .{
                        .storage = try arena.alloc(u8, max_stderr_bytes),
                    };
                }
                const capture_buf = &stderr_capture_buf.?;
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
                    if (code != 0 and !allow_failures) {
                        if (bar) |*b|
                            b.clear(io) catch {};
                        std.debug.print("\nerror: Benchmark {d} command '{s}' failed with exit code {d}\n", .{
                            command_n,
                            command.raw_cmd,
                            code,
                        });
                        std.debug.print("hint: pass --allow-failures to capture stderr from failing runs\n", .{});
                        process.exit(1);
                    }
                    if (code != 0 and allow_failures) {
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

            if (bar) |*b| {
                b.estimate = est_total: {
                    const cur_samples: u64 = sample_index;
                    var ns_per_sample: u64 = @intCast(@divTrunc((first_start.untilNow(io, .awake).toNanoseconds()), cur_samples));
                    if (ns_per_sample == 0) ns_per_sample = 1;
                    const estimate = std.math.divCeil(u64, max_nano_seconds, ns_per_sample) catch unreachable;
                    break :est_total @intCast(@min(max_samples, @max(cur_samples, estimate, min_samples)));
                };
                b.current += 1;
                try b.render(io);
            }
        }

        if (suppressed_failure_notes > 0) {
            if (suppressed_failure_notes == 1) {
                std.debug.print("\nnote: 1 more failed sample for '{s}' (stderr omitted)\n", .{
                    command.raw_cmd,
                });
            } else {
                std.debug.print("\nnote: {d} more failed samples for '{s}' (stderr omitted)\n", .{
                    suppressed_failure_notes,
                    command.raw_cmd,
                });
            }
        }

        if (bar) |*b| {
            b.estimate = b.current;
            try b.render(io);
            try b.clear(io);
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
                Measurement.statsErrorMessage(err),
            });
            process.exit(1);
        };
        command.sample_count = all_samples.len;
    }

    if (warmup == 0) {
        try run_notes.append(arena, "--warmup 0; first measured run may include cold-start effects");
    }
    if (anyCommandHighOutlierRate(commands.items)) {
        try run_notes.append(arena, "outlier rate >=10% on at least one metric; check system load or raise --warmup");
    }

    help.printRunNotes(run_notes.items);

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
            const layout = TableLayout.compute(command.measurements, baseline, with_delta);
            try TableLayout.printHeader(stdout_w, t, layout, with_delta);

            inline for (@typeInfo(Command.Measurements).@"struct".fields) |field| {
                const measurement = @field(command.measurements, field.name);
                if (measurementRowVisible(measurementFieldMeta(field.name).visibility, measurement)) {
                    const first_measurement = if (command_n == 1)
                        null
                    else
                        @field(commands.items[0].measurements, field.name);
                    try printMeasurement(t, layout, measurement, field.name, first_measurement, with_delta);
                }
            }

            try stdout_w.flush();
        }
    }

    if (json_path) |path| {
        var file_buf: [4096]u8 = undefined;
        var file = try std.Io.Dir.cwd().createFile(io, path, .{});
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
    try s.objectField("mean");
    try s.write(m.mean);
    try s.objectField("std_dev");
    try s.write(m.std_dev);
    try s.objectField("min");
    try s.write(m.min);
    try s.objectField("max");
    try s.write(m.max);
    try s.objectField("median");
    try s.write(m.median);
    try s.objectField("q1");
    try s.write(m.q1);
    try s.objectField("q3");
    try s.write(m.q3);
    try s.objectField("outlier_count");
    try s.write(m.outlier_count);
    try s.objectField("sample_count");
    try s.write(m.sample_count);
    try s.objectField("unit");
    try s.write(@tagName(m.unit));
    try s.endObject();
}

fn closePerfFds(fds: []fd_t) void {
    for (fds) |*fd| {
        if (fd.* != -1) {
            _ = std.os.linux.close(fd.*);
            fd.* = -1;
        }
    }
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
    var scratch: [4096]u8 = undefined;
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
    var buf: [4096]u8 = undefined;
    while (std.posix.read(stderr_fd, &buf)) |_| {} else |_| return;
}

/// Under `-f`: reap the child, end wall time at exit, then drain stderr (post-exit
/// drain is not counted). Interleaves stderr reads while the child runs so a full
/// pipe cannot deadlock `wait`.
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
    return @intCast(@max(@as(u32, 32), @min(scaled, 1024)));
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
        .{ counter_name, @sizeOf(usize) },
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
        .flags = .{
            .disabled = is_leader,
            .exclude_kernel = true,
            .exclude_hv = true,
            .inherit = true,
            .enable_on_exec = true,
        },
    };
}

fn openPerfGroup(fds: *[perf_measurements.len]fd_t) void {
    // One perf group per command. Opening all five fds every sample was pure syscall tax.
    // Each sample: DISABLE, RESET, spawn child, read counters, DISABLE again.
    for (perf_measurements, fds, 0..) |measurement, *perf_fd, i| {
        var attr = perfEventAttrForGroupMember(measurement.config, i == 0);
        perf_fd.* = std.posix.perf_event_open(&attr, 0, -1, fds[0], PERF.FLAG.FD_CLOEXEC) catch |err| {
            closePerfFds(fds);
            printPerfOpenError(err, measurement.name);
        };
    }
}

fn readSamplePerfCounters(fds: *const [perf_measurements.len]fd_t) ![perf_measurements.len]usize {
    var values: [perf_measurements.len]usize = undefined;
    for (0..perf_measurements.len) |i| {
        values[i] = readPerfFd(fds[i]) catch |err| switch (err) {
            error.ShortPerfRead => printShortPerfReadError(perf_measurements[i].name),
            else => return err,
        };
    }
    return values;
}

fn readPerfFd(fd: fd_t) !usize {
    var result: usize = 0;
    const n = try std.posix.read(fd, std.mem.asBytes(&result));
    if (n != @sizeOf(usize)) return error.ShortPerfRead;
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

    pub fn statsErrorMessage(err: StatsError) []const u8 {
        return switch (err) {
            error.NoSamples => "no samples to summarize",
            error.ScratchTooSmall => "sort scratch buffer is shorter than the sample list",
        };
    }

    /// One scratch slice for the whole command; sorts once per metric via inline loop.
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

    /// Caller owns `work`; we memcpy+sort in place so the sample list stays untouched.
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
            // Upper middle index; even-length runs use the higher of the two middles.
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
) !void {
    const w = terminal.writer;
    const color_enabled = terminal.mode != .no_color;
    var vis: usize = 0;
    var unit_buf: [32]u8 = undefined;

    try w.splatByteAll(' ', row_indent);
    try w.writeAll(name);
    vis = row_indent + visibleLen(name);
    try TableLayout.padVis(w, &vis, layout.name_w);

    try TableLayout.gap(w, &vis);
    try writeUnitRightAligned(terminal, w, &vis, layout.meanSepVis(), m.mean, m.unit, .bright_green, color_enabled, &unit_buf);
    try w.writeAll(sep_mean);
    vis = layout.meanSepVis() + visibleLen(sep_mean);
    try writeUnitLeftAligned(terminal, w, &vis, m.std_dev, m.unit, .green, color_enabled, &unit_buf);
    try TableLayout.padVis(
        w,
        &vis,
        layout.name_w + col_gap + layout.mean_w + visibleLen(sep_mean) + layout.std_w,
    );

    try TableLayout.gap(w, &vis);
    try writeUnitRightAligned(terminal, w, &vis, layout.minSepVis(), @floatFromInt(m.min), m.unit, .cyan, color_enabled, &unit_buf);
    try w.writeAll(sep_minmax);
    vis = layout.minSepVis() + visibleLen(sep_minmax);
    try writeUnitLeftAligned(terminal, w, &vis, @floatFromInt(m.max), m.unit, .magenta, color_enabled, &unit_buf);
    try TableLayout.padVis(
        w,
        &vis,
        layout.name_w + col_gap + layout.mean_w + visibleLen(sep_mean) + layout.std_w + col_gap + layout.min_w + visibleLen(sep_minmax) + layout.max_w,
    );

    try TableLayout.gap(w, &vis);
    try TableLayout.padVis(w, &vis, layout.outlierStartVis());
    var outlier_buf: [32]u8 = undefined;
    const outlier_line = try formatOutlierLine(&outlier_buf, m.outlier_count, m.sample_count);
    const outlier_percent = @as(f64, @floatFromInt(m.outlier_count)) / @as(f64, @floatFromInt(m.sample_count)) * 100;
    if (outlier_percent >= outlier_highlight_threshold_percent)
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
    if (num >= 100) {
        try w.print("{d:.0}", .{num});
    } else if (num >= 10) {
        try w.print("{d:.1}", .{num});
    } else {
        try w.print("{d:.2}", .{num});
    }
}

/// 95% critical value for compare deltas. Pass `df` for Student-t; `null` uses the normal approximation (1.96).
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
    var s: Sample = .{
        .wall_time = 0,
        .peak_rss = 0,
        .minor_faults = 0,
        .major_faults = 0,
        .cpu_cycles = 0,
        .instructions = 0,
        .cache_references = 0,
        .cache_misses = 0,
        .branch_misses = 0,
    };
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

test "printJsonOutput writes schema envelope and config" {
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const wall = testMeasurement(.nanoseconds);
    const measurements: Command.Measurements = .{
        .wall_time = wall,
        .peak_rss = testMeasurement(.bytes),
        .minor_faults = testMeasurement(.count),
        .major_faults = testMeasurement(.count),
        .cpu_cycles = testMeasurement(.count),
        .instructions = testMeasurement(.count),
        .cache_references = testMeasurement(.count),
        .cache_misses = testMeasurement(.count),
        .branch_misses = testMeasurement(.count),
    };
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
            max_samples: u64,
            max_samples_cap: u64,
            max_samples_requested: ?u64,
            warmup: usize,
            allow_failures: bool,
        },
        results: []struct {
            command: []const u8,
            sample_count: usize,
            failed_sample_count: u64,
            wall_time: struct { mean: f64, unit: []const u8 },
            minor_faults: struct { mean: f64, unit: []const u8 },
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
    try std.testing.expectEqual(@as(u64, 2), parsed.value.config.min_samples);
    try std.testing.expectEqual(@as(u64, help.max_samples_cap), parsed.value.config.max_samples_cap);
    try std.testing.expectEqual(@as(?u64, 50_000), parsed.value.config.max_samples_requested);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.results.len);
    try std.testing.expectEqualStrings("/bin/true", parsed.value.results[0].command);
    try std.testing.expectEqual(@as(usize, 5), parsed.value.results[0].sample_count);
    try std.testing.expectEqual(@as(u64, 2), parsed.value.results[0].failed_sample_count);
    try std.testing.expectEqual(@as(f64, 2), parsed.value.results[0].wall_time.mean);
    try std.testing.expectEqualStrings("nanoseconds", parsed.value.results[0].wall_time.unit);
    try std.testing.expectEqual(@as(f64, 2), parsed.value.results[0].minor_faults.mean);
    try std.testing.expectEqualStrings("count", parsed.value.results[0].minor_faults.unit);
    try std.testing.expectEqual(@as(f64, 2), parsed.value.results[0].major_faults.mean);
    try std.testing.expectEqualStrings("count", parsed.value.results[0].major_faults.unit);
}

test "jsonPathFromEqualsArg parses --json=path" {
    try std.testing.expectEqualStrings("out.json", jsonPathFromEqualsArg("--json=out.json").?);
    try std.testing.expectEqualStrings("zebrac-results.json", jsonPathFromEqualsArg("--json=").?);
    try std.testing.expect(jsonPathFromEqualsArg("--json") == null);
}

test "anyCommandHighOutlierRate at 10% threshold" {
    var low = testMeasurement(.count);
    low.sample_count = 10;
    low.outlier_count = 0;
    var border = testMeasurement(.count);
    border.sample_count = 10;
    border.outlier_count = 1;
    var high = testMeasurement(.count);
    high.sample_count = 10;
    high.outlier_count = 2;

    const low_only: Command.Measurements = .{
        .wall_time = low,
        .peak_rss = low,
        .minor_faults = low,
        .major_faults = low,
        .cpu_cycles = low,
        .instructions = low,
        .cache_references = low,
        .cache_misses = low,
        .branch_misses = low,
    };
    var border_meas = low_only;
    border_meas.wall_time = border;
    var high_meas = low_only;
    high_meas.wall_time = high;

    const cmds = [_]Command{
        .{ .raw_cmd = "a", .argv = &.{}, .measurements = low_only, .sample_count = 10, .failed_sample_count = 0 },
        .{ .raw_cmd = "b", .argv = &.{}, .measurements = border_meas, .sample_count = 10, .failed_sample_count = 0 },
        .{ .raw_cmd = "c", .argv = &.{}, .measurements = high_meas, .sample_count = 10, .failed_sample_count = 0 },
    };
    try std.testing.expect(!anyCommandHighOutlierRate(cmds[0..1]));
    try std.testing.expect(anyCommandHighOutlierRate(cmds[1..2]));
    try std.testing.expect(anyCommandHighOutlierRate(cmds[2..3]));
}

test "StderrCaptureBuf caps append and resets" {
    var storage: [8]u8 = undefined;
    var buf: StderrCaptureBuf = .{ .storage = &storage };
    buf.append("abc");
    try std.testing.expectEqual(@as(usize, 3), buf.len);
    try std.testing.expect(!buf.truncated);
    buf.append("defghij");
    try std.testing.expect(buf.truncated);
    try std.testing.expectEqual(@as(usize, 8), buf.len);
    const view = buf.view();
    try std.testing.expectEqualStrings("abcdefgh", view.bytes);
    buf.reset();
    try std.testing.expectEqual(@as(usize, 0), buf.len);
    try std.testing.expect(!buf.truncated);
}

test "resetPerfGroupBeforeSample rejects closed leader fd" {
    try std.testing.expectError(error.BadLeaderFd, resetPerfGroupBeforeSample(-1));
    try std.testing.expectError(error.BadLeaderFd, disablePerfGroupAfterSample(-1));
}

test "resetPerfGroupBeforeSample fails on non-perf fd" {
    var pipefd: [2]i32 = undefined;
    const pr = std.os.linux.pipe(&pipefd);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(pr));
    defer {
        _ = std.os.linux.close(pipefd[0]);
        _ = std.os.linux.close(pipefd[1]);
    }
    resetPerfGroupBeforeSample(pipefd[0]) catch |err| switch (err) {
        error.DisableFailed, error.ResetFailed => return,
        else => return err,
    };
    return error.TestUnexpectedError;
}

test "disablePerfGroupAfterSample fails on non-perf fd" {
    var pipefd: [2]i32 = undefined;
    const pr = std.os.linux.pipe(&pipefd);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(pr));
    defer {
        _ = std.os.linux.close(pipefd[0]);
        _ = std.os.linux.close(pipefd[1]);
    }
    try std.testing.expectError(error.DisableFailed, disablePerfGroupAfterSample(pipefd[0]));
}

test "perfIoctlSkipLimit scales with max_samples" {
    try std.testing.expectEqual(@as(u32, 32), perfIoctlSkipLimit(5));
    try std.testing.expectEqual(@as(u32, 40), perfIoctlSkipLimit(20));
    try std.testing.expectEqual(@as(u32, 1024), perfIoctlSkipLimit(10_000));
}

test "perf group leader opens disabled, children enabled" {
    const leader = perfEventAttrForGroupMember(PERF.COUNT.HW.CPU_CYCLES, true);
    const child = perfEventAttrForGroupMember(PERF.COUNT.HW.INSTRUCTIONS, false);
    try std.testing.expect(leader.flags.disabled);
    try std.testing.expect(!child.flags.disabled);
    try std.testing.expect(leader.flags.enable_on_exec);
    try std.testing.expect(child.flags.enable_on_exec);
}

test "readPerfFd returns ShortPerfRead on empty pipe" {
    var pipefd: [2]i32 = undefined;
    const pr = std.os.linux.pipe(&pipefd);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(pr));
    _ = std.os.linux.close(pipefd[1]);
    defer _ = std.os.linux.close(pipefd[0]);
    try std.testing.expectError(error.ShortPerfRead, readPerfFd(pipefd[0]));
}

test "getStatScore95 z-score fallback for null, low, and high df" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.96), getStatScore95(null), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.96), getStatScore95(0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.96), getStatScore95(200), 0.001);
}

test "getStatScore95: df 1 and 30" {
    try std.testing.expectApproxEqAbs(12.706, getStatScore95(1), 0.001);
    try std.testing.expectApproxEqAbs(2.042, getStatScore95(30), 0.001);
}

test "getStatScore95: df 28 and 29 not swapped" {
    try std.testing.expectApproxEqAbs(2.048, getStatScore95(28), 0.001);
    try std.testing.expectApproxEqAbs(2.045, getStatScore95(29), 0.001);
}

test "summarizeAll_zeroSamples_returnsNoSamples" {
    const samples: []const Sample = &.{};
    var scratch: [1]Sample = undefined;
    try std.testing.expectError(error.NoSamples, Measurement.summarizeAll(samples, &scratch));
}

test "summarizeField_scratchTooSmall_returnsError" {
    const samples = [_]Sample{sampleWith("wall_time", 1)};
    var scratch: [0]Sample = undefined;
    try std.testing.expectError(error.ScratchTooSmall, Measurement.summarizeField(&samples, &scratch, "wall_time", .nanoseconds));
}

test "summarizeField_fourSamples_computesMeanAndMedian" {
    const samples = [_]Sample{
        sampleWith("wall_time", 10),
        sampleWith("wall_time", 20),
        sampleWith("wall_time", 30),
        sampleWith("wall_time", 40),
    };
    var scratch: [4]Sample = undefined;
    const m = try Measurement.summarizeField(&samples, &scratch, "wall_time", .nanoseconds);
    try std.testing.expectEqual(@as(u64, 10), m.min);
    try std.testing.expectEqual(@as(u64, 40), m.max);
    try std.testing.expectEqual(@as(u64, 30), m.median);
    try std.testing.expectApproxEqAbs(@as(f64, 25), m.mean, 0.001);
    try std.testing.expectEqual(@as(u64, 4), m.sample_count);
}

test "summarizeField_sortsScratch_leavesInputSliceUntouched" {
    var samples = [_]Sample{
        sampleWith("wall_time", 30),
        sampleWith("wall_time", 10),
        sampleWith("wall_time", 20),
    };
    var scratch: [3]Sample = undefined;
    _ = try Measurement.summarizeField(&samples, &scratch, "wall_time", .nanoseconds);
    try std.testing.expectEqual(@as(u64, 30), samples[0].wall_time);
}

test "summarizeField_identicalSamples_zeroOutliers" {
    const samples = [_]Sample{
        sampleWith("wall_time", 100),
        sampleWith("wall_time", 100),
        sampleWith("wall_time", 100),
    };
    var scratch: [3]Sample = undefined;
    const m = try Measurement.summarizeField(&samples, &scratch, "wall_time", .nanoseconds);
    try std.testing.expectEqual(@as(u64, 0), m.outlier_count);
    try std.testing.expectApproxEqAbs(@as(f64, 0), m.std_dev, 0.001);
}

test "summarizeField_oneSample_stdDevStaysZero" {
    const samples = [_]Sample{sampleWith("wall_time", 42)};
    var scratch: [1]Sample = undefined;
    const m = try Measurement.summarizeField(&samples, &scratch, "wall_time", .nanoseconds);
    try std.testing.expectEqual(@as(u64, 42), m.median);
    try std.testing.expectApproxEqAbs(@as(f64, 42), m.mean, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), m.std_dev, 0.001);
}

test "summarizeField smallN_q1q3_useOrderStatIndices" {
    // Indices: q1 = sorted[n/4]; q3 = sorted[n-1] when n < 4 else sorted[n - n/4].
    {
        const values = [_]u64{ 200, 100 };
        var samples: [2]Sample = undefined;
        for (values, &samples) |v, *s| s.* = sampleWith("wall_time", v);
        var scratch: [2]Sample = undefined;
        const m = try Measurement.summarizeField(&samples, &scratch, "wall_time", .nanoseconds);
        try std.testing.expectEqual(@as(u64, 100), m.q1);
        try std.testing.expectEqual(@as(u64, 200), m.q3);
        try std.testing.expectEqual(@as(u64, 200), m.median);
    }
    {
        const values = [_]u64{ 300, 100, 200 };
        var samples: [3]Sample = undefined;
        for (values, &samples) |v, *s| s.* = sampleWith("wall_time", v);
        var scratch: [3]Sample = undefined;
        const m = try Measurement.summarizeField(&samples, &scratch, "wall_time", .nanoseconds);
        try std.testing.expectEqual(@as(u64, 100), m.q1);
        try std.testing.expectEqual(@as(u64, 300), m.q3);
        try std.testing.expectEqual(@as(u64, 200), m.median);
    }
    {
        const values = [_]u64{ 400, 100, 300, 200 };
        var samples: [4]Sample = undefined;
        for (values, &samples) |v, *s| s.* = sampleWith("wall_time", v);
        var scratch: [4]Sample = undefined;
        const m = try Measurement.summarizeField(&samples, &scratch, "wall_time", .nanoseconds);
        try std.testing.expectEqual(@as(u64, 200), m.q1);
        try std.testing.expectEqual(@as(u64, 400), m.q3);
        try std.testing.expectEqual(@as(u64, 300), m.median);
    }
}

test "summarizeField_tukeyCountsHighOutlier" {
    // Sorted: 1..12 plus 100. q1=4 (idx 3), q3=11 (idx 10), IQR=7, high fence=21.5 -> one outlier.
    const values = [_]u64{ 12, 1, 100, 6, 3, 9, 4, 11, 2, 8, 5, 10, 7 };
    var samples: [values.len]Sample = undefined;
    for (values, &samples) |v, *s| s.* = sampleWith("wall_time", v);
    var scratch: [values.len]Sample = undefined;
    const m = try Measurement.summarizeField(&samples, &scratch, "wall_time", .nanoseconds);
    try std.testing.expectEqual(@as(u64, 4), m.q1);
    try std.testing.expectEqual(@as(u64, 11), m.q3);
    try std.testing.expectEqual(@as(u64, 1), m.outlier_count);
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
    return w.buffered();
}

test "deltaHalfWidth undefined and valid compare" {
    const m = measurementForDeltaTest(10, 1, 10);
    try std.testing.expect(deltaHalfWidth(m, measurementForDeltaTest(0, 1, 10)) == null);
    try std.testing.expect(deltaHalfWidth(
        measurementForDeltaTest(10, 0, 1),
        measurementForDeltaTest(10, 0, 1),
    ) == null);
    try std.testing.expect(deltaHalfWidth(
        measurementForDeltaTest(10, 1, 2),
        measurementForDeltaTest(10, 1, 1),
    ) == null);

    const half = deltaHalfWidth(
        measurementForDeltaTest(110, 10, 10),
        measurementForDeltaTest(100, 10, 10),
    ).?;
    try std.testing.expect(!std.math.isNan(half));
    try std.testing.expect(!std.math.isInf(half));
    try std.testing.expect(half > 0);
}

test "deltaIsSignificant at 1% practical band" {
    try std.testing.expect(deltaIsSignificant(2, 1));
    try std.testing.expect(!deltaIsSignificant(2, 1.01));
    try std.testing.expect(deltaIsSignificant(1, 0));
    try std.testing.expect(!deltaIsSignificant(1, 0.01));
    try std.testing.expect(!deltaIsSignificant(0.99, 0));
    try std.testing.expect(deltaIsSignificant(-2, 1));
    try std.testing.expect(!deltaIsSignificant(-2, 1.01));
    try std.testing.expect(deltaIsSignificant(-1, 0));
    try std.testing.expect(!deltaIsSignificant(-1, 0.01));
    try std.testing.expect(!deltaIsSignificant(-0.99, 0));
}

test "writeDeltaPlain compare semantics" {
    const m5 = measurementForDeltaTest(5, 1, 10);
    const f0 = measurementForDeltaTest(0, 0, 10);
    const out_undef = try writeDeltaPlainToBuf(m5, @as(?Measurement, f0));
    try std.testing.expectEqualStrings("n/a", out_undef);
    try std.testing.expect(std.mem.indexOf(u8, out_undef, "nan") == null);

    const m1 = measurementForDeltaTest(10, 0, 1);
    const f1 = measurementForDeltaTest(10, 0, 1);
    try std.testing.expectEqualStrings("n/a", try writeDeltaPlainToBuf(m1, @as(?Measurement, f1)));

    const m_up = measurementForDeltaTest(110, 10, 10);
    const f_up = measurementForDeltaTest(100, 10, 10);
    const half_up = deltaHalfWidth(m_up, f_up).?;
    const diff_up = (m_up.mean - f_up.mean) * 100 / f_up.mean;
    var expect_buf: [64]u8 = undefined;
    var expect_w = Io.Writer.fixed(&expect_buf);
    try expect_w.writeAll(if (deltaIsSignificant(diff_up, half_up)) "! " else "  ");
    try expect_w.writeAll("+");
    try expect_w.print("{d: >5.1}% ± {d: >4.1}%", .{ @abs(diff_up), half_up });
    try std.testing.expectEqualStrings(expect_w.buffered(), try writeDeltaPlainToBuf(m_up, @as(?Measurement, f_up)));

    const m_eq = measurementForDeltaTest(100, 10, 10);
    const f_eq = measurementForDeltaTest(100, 10, 10);
    const out_eq = try writeDeltaPlainToBuf(m_eq, @as(?Measurement, f_eq));
    try std.testing.expectEqualStrings("0%", out_eq);
    try std.testing.expect(std.mem.indexOf(u8, out_eq, "±") == null);

    const out_base = try writeDeltaPlainToBuf(m_eq, null);
    try std.testing.expectEqualStrings("0%", out_base);

    const m_dn = measurementForDeltaTest(90, 10, 10);
    const f_dn = measurementForDeltaTest(100, 10, 10);
    const half_dn = deltaHalfWidth(m_dn, f_dn).?;
    const diff_dn = (m_dn.mean - f_dn.mean) * 100 / f_dn.mean;
    expect_w = Io.Writer.fixed(&expect_buf);
    try expect_w.writeAll(if (deltaIsSignificant(diff_dn, half_dn)) "* " else "  ");
    try expect_w.writeAll("-");
    try expect_w.print("{d: >5.1}% ± {d: >4.1}%", .{ @abs(diff_dn), half_dn });
    try std.testing.expectEqualStrings(expect_w.buffered(), try writeDeltaPlainToBuf(m_dn, @as(?Measurement, f_dn)));
}

test "summarizeAll includes page fault fields" {
    const samples = [_]Sample{
        .{
            .wall_time = 100,
            .peak_rss = 1000,
            .minor_faults = 10,
            .major_faults = 0,
            .cpu_cycles = 50,
            .instructions = 40,
            .cache_references = 30,
            .cache_misses = 20,
            .branch_misses = 5,
        },
        .{
            .wall_time = 200,
            .peak_rss = 2000,
            .minor_faults = 30,
            .major_faults = 2,
            .cpu_cycles = 60,
            .instructions = 50,
            .cache_references = 35,
            .cache_misses = 25,
            .branch_misses = 6,
        },
    };
    var scratch: [2]Sample = undefined;
    const m = try Measurement.summarizeAll(&samples, &scratch);
    try std.testing.expectEqual(@as(u64, 30), m.minor_faults.median);
    try std.testing.expectEqual(@as(u64, 2), m.major_faults.max);
    try std.testing.expectEqual(Measurement.Unit.count, m.minor_faults.unit);
    try std.testing.expectEqual(Measurement.Unit.count, m.major_faults.unit);
}

fn tableBenchmarkWall() Measurement {
    return .{
        .q1 = 640_000,
        .median = 659_000,
        .q3 = 677_000,
        .min = 638_000,
        .max = 719_000,
        .mean = 659_000,
        .std_dev = 27_800,
        .outlier_count = 0,
        .sample_count = 8,
        .unit = .nanoseconds,
    };
}

fn tableBenchmarkRss() Measurement {
    return .{
        .q1 = 1_150_000,
        .median = 1_150_000,
        .q3 = 1_150_000,
        .min = 1_150_000,
        .max = 1_220_000,
        .mean = 1_160_000,
        .std_dev = 23_200,
        .outlier_count = 0,
        .sample_count = 8,
        .unit = .bytes,
    };
}

fn renderResultsTableForTest(
    measurements: Command.Measurements,
    baseline: ?Command.Measurements,
    mode: Io.Terminal.Mode,
) ![]const u8 {
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const term = Io.Terminal{ .writer = &w, .mode = mode };
    const with_delta = baseline != null;
    const layout = TableLayout.compute(measurements, baseline, with_delta);
    try TableLayout.printHeader(&w, term, layout, with_delta);
    inline for (@typeInfo(Command.Measurements).@"struct".fields) |field| {
        const m = @field(measurements, field.name);
        if (measurementRowVisible(measurementFieldMeta(field.name).visibility, m)) {
            const first_m = if (baseline) |b| @as(?Measurement, @field(b, field.name)) else null;
            try printMeasurement(term, layout, m, field.name, first_m, with_delta);
        }
    }
    return w.buffered();
}

test "results table omits major_faults when max is zero" {
    const wall = tableBenchmarkWall();
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
    const measurements: Command.Measurements = .{
        .wall_time = wall,
        .peak_rss = tableBenchmarkRss(),
        .minor_faults = wall,
        .major_faults = zero_faults,
        .cpu_cycles = wall,
        .instructions = wall,
        .cache_references = wall,
        .cache_misses = wall,
        .branch_misses = wall,
    };
    const out = try renderResultsTableForTest(measurements, null, .no_color);
    try std.testing.expect(std.mem.indexOf(u8, out, "major_faults") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "minor_faults") != null);
    try std.testing.expectEqual(
        MeasurementRowVisibility.hide_when_max_is_zero,
        measurementFieldMeta("major_faults").visibility,
    );
    try std.testing.expectEqual(Measurement.Unit.nanoseconds, measurementFieldMeta("wall_time").unit);
    try std.testing.expectEqual(Measurement.Unit.bytes, measurementFieldMeta("peak_rss").unit);
    try std.testing.expectEqual(Measurement.Unit.count, measurementFieldMeta("cpu_cycles").unit);
}

test "printNum3SigFigs scaling" {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try printNum3SigFigs(&w, 5.0);
    try std.testing.expectEqualStrings("5.00", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try printNum3SigFigs(&w, 1234);
    try std.testing.expectEqualStrings("1234", w.buffered());
}

test "results table: separators and zero-delta align across color modes" {
    for (&[_]Io.Terminal.Mode{ .no_color, .escape_codes }) |mode| {
        try tableSeparatorAlignmentTest(mode);
        try tableZeroDeltaAlignmentTest(mode);
    }
}

fn tableSeparatorAlignmentTest(mode: Io.Terminal.Mode) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const term = Io.Terminal{ .writer = &w, .mode = mode };

    const wall = tableBenchmarkWall();
    const rss = tableBenchmarkRss();
    const measurements: Command.Measurements = .{
        .wall_time = wall,
        .peak_rss = rss,
        .minor_faults = wall,
        .major_faults = wall,
        .cpu_cycles = wall,
        .instructions = wall,
        .cache_references = wall,
        .cache_misses = wall,
        .branch_misses = wall,
    };
    const layout = TableLayout.compute(measurements, measurements, true);
    try TableLayout.printHeader(&w, term, layout, true);
    try printMeasurement(term, layout, wall, "wall_time", null, true);
    try printMeasurement(term, layout, rss, "peak_rss", wall, true);

    const out = w.buffered();
    var mean_sep: ?usize = null;
    var min_sep: ?usize = null;
    var outlier_start: ?usize = null;
    var line_start: usize = 0;
    while (line_start < out.len) {
        const line_end = std.mem.indexOfScalarPos(u8, out, line_start, '\n') orelse out.len;
        const line = out[line_start..line_end];
        const this_mean = visibleIndexOfUtf8(line, "±");
        const this_min = visibleIndexOfUtf8(line, "…");
        if (this_mean) |m| {
            if (mean_sep) |prev| try std.testing.expectEqual(prev, m);
            mean_sep = m;
        }
        if (this_min) |m| {
            if (min_sep) |prev| try std.testing.expectEqual(prev, m);
            min_sep = m;
        }
        if (visibleIndexOfUtf8(line, "outliers")) |start| {
            if (outlier_start) |prev| try std.testing.expectEqual(prev, start);
            outlier_start = start;
        } else if (visibleIndexOfUtf8(line, "0 (0%)")) |start| {
            if (outlier_start) |prev| try std.testing.expectEqual(prev, start);
            outlier_start = start;
        }
        if (line_end == out.len) break;
        line_start = line_end + 1;
    }
    try std.testing.expect(mean_sep != null);
    try std.testing.expect(min_sep != null);
    try std.testing.expect(outlier_start != null);
}

fn tableZeroDeltaAlignmentTest(mode: Io.Terminal.Mode) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const term = Io.Terminal{ .writer = &w, .mode = mode };

    const baseline_wall = tableBenchmarkWall();
    const baseline_rss = tableBenchmarkRss();
    const compare_rss = Measurement{
        .q1 = 1_200_000,
        .median = 1_220_000,
        .q3 = 1_240_000,
        .min = 1_190_000,
        .max = 1_300_000,
        .mean = 1_220_000,
        .std_dev = 25_000,
        .outlier_count = 0,
        .sample_count = 8,
        .unit = .bytes,
    };
    const baseline: Command.Measurements = .{
        .wall_time = baseline_wall,
        .peak_rss = baseline_rss,
        .minor_faults = baseline_wall,
        .major_faults = baseline_wall,
        .cpu_cycles = baseline_wall,
        .instructions = baseline_wall,
        .cache_references = baseline_wall,
        .cache_misses = baseline_wall,
        .branch_misses = baseline_wall,
    };
    const compare: Command.Measurements = .{
        .wall_time = baseline_wall,
        .peak_rss = compare_rss,
        .minor_faults = baseline_wall,
        .major_faults = baseline_wall,
        .cpu_cycles = baseline_wall,
        .instructions = baseline_wall,
        .cache_references = baseline_wall,
        .cache_misses = baseline_wall,
        .branch_misses = baseline_wall,
    };
    const layout = TableLayout.compute(compare, baseline, true);
    try TableLayout.printHeader(&w, term, layout, true);
    try printMeasurement(term, layout, compare.wall_time, "wall_time", baseline.wall_time, true);
    try printMeasurement(term, layout, compare.peak_rss, "peak_rss", baseline.peak_rss, true);

    const out = w.buffered();
    var mean_sep: ?usize = null;
    var min_sep: ?usize = null;
    var line_start: usize = 0;
    while (line_start < out.len) {
        const line_end = std.mem.indexOfScalarPos(u8, out, line_start, '\n') orelse out.len;
        const line = out[line_start..line_end];
        const vis_line = stripAnsiForTest(line);
        if (std.mem.startsWith(u8, vis_line, "  wall_time")) {
            try std.testing.expect(std.mem.indexOf(u8, vis_line, "-  0.0%") == null);
            const delta_pct = std.mem.lastIndexOf(u8, vis_line, "0%") orelse unreachable;
            const outlier_pct = std.mem.indexOf(u8, vis_line, "0 (0%)") orelse unreachable;
            try std.testing.expect(delta_pct > outlier_pct);
        }
        if (std.mem.startsWith(u8, vis_line, "  peak_rss")) {
            try std.testing.expect(visibleIndexOfUtf8(line, "±") != null);
        }
        const this_mean = visibleIndexOfUtf8(line, "±");
        const this_min = visibleIndexOfUtf8(line, "…");
        if (this_mean) |m| {
            if (mean_sep) |prev| try std.testing.expectEqual(prev, m);
            mean_sep = m;
        }
        if (this_min) |m| {
            if (min_sep) |prev| try std.testing.expectEqual(prev, m);
            min_sep = m;
        }
        if (line_end == out.len) break;
        line_start = line_end + 1;
    }
    try std.testing.expect(mean_sep != null);
    try std.testing.expect(min_sep != null);
}

test "scaleUnit nanoseconds uses minutes and hours" {
    const one_min: f64 = 60.0 * 1_000_000_000.0;
    const one_hour: f64 = 3600.0 * 1_000_000_000.0;
    const s_min = scaleUnit(one_min, .nanoseconds);
    try std.testing.expectEqualStrings("m ", s_min.suffix);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), s_min.val, 0.001);
    const s_hour = scaleUnit(one_hour, .nanoseconds);
    try std.testing.expectEqualStrings("h ", s_hour.suffix);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), s_hour.val, 0.001);
    const s_sec = scaleUnit(5.0 * 1_000_000_000.0, .nanoseconds);
    try std.testing.expectEqualStrings("s ", s_sec.suffix);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), s_sec.val, 0.001);
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

fn checkSummarizeFieldInvariants(n: u8, samples: []const Sample, scratch: []Sample) !void {
    const m = try Measurement.summarizeField(samples[0..n], scratch[0..n], "wall_time", .nanoseconds);
    try std.testing.expectEqual(n, m.sample_count);
    try std.testing.expect(m.min <= m.max);
    try std.testing.expect(m.outlier_count <= n);
    try std.testing.expect(m.q1 <= m.median or n == 1);
    try std.testing.expect(m.median <= m.q3 or n == 1);

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

test "summarizeField fuzz invariants" {
    try std.testing.fuzz({}, fuzzSummarizeField, .{});
}
