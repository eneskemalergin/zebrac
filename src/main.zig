const std = @import("std");
const Io = std.Io;
const process = std.process;
const PERF = std.os.linux.PERF;
const fd_t = std.posix.fd_t;
const assert = std.debug.assert;
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

    const Measurements = struct {
        wall_time: Measurement,
        peak_rss: Measurement,
        cpu_cycles: Measurement,
        instructions: Measurement,
        cache_references: Measurement,
        cache_misses: Measurement,
        branch_misses: Measurement,
    };
};

const Sample = struct {
    wall_time: u64,
    cpu_cycles: u64,
    instructions: u64,
    cache_references: u64,
    cache_misses: u64,
    branch_misses: u64,
    peak_rss: u64,

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

fn formatUnitVisibleLen(w: *std.Io.Writer, x: f64, unit: Measurement.Unit) !usize {
    const s = scaleUnit(x, unit);
    try printNum3SigFigs(w, s.val);
    const n = w.end;
    try w.writeAll(s.suffix);
    return n + s.suffix.len;
}

fn measureUnit(buf: *[32]u8, x: f64, unit: Measurement.Unit) usize {
    var w = std.Io.Writer.fixed(buf);
    return formatUnitVisibleLen(&w, x, unit) catch 0;
}

fn measureOutlier(buf: *[32]u8, count: u64, sample_count: u64) usize {
    var w = std.Io.Writer.fixed(buf);
    const pct = @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(sample_count)) * 100;
    w.print("{d} ({d:.0}%)", .{ count, pct }) catch return 0;
    return visibleLen(w.buffered());
}

fn measureDelta(buf: *[64]u8, m: Measurement, first_m: ?Measurement) usize {
    var w = std.Io.Writer.fixed(buf);
    writeDeltaPlain(&w, m, first_m) catch return 0;
    return visibleLen(w.buffered());
}

fn writeDeltaPlain(w: *Io.Writer, m: Measurement, first_m: ?Measurement) !void {
    if (first_m == null) {
        try w.writeAll("0%");
        return;
    }
    const f = first_m.?;
    const half = deltaHalfWidth(m, f);
    const diff_mean_percent = (m.mean - f.mean) * 100 / f.mean;
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

fn deltaHalfWidth(m: Measurement, f: Measurement) f64 {
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
    var fbs = std.Io.Writer.fixed(buf);
    const len = try formatUnitVisibleLen(&fbs, x, unit);
    try TableLayout.padVis(w, vis, end_vis - len);
    try terminal.setColor(color);
    fbs.end = 0;
    try printUnit(&fbs, x, unit, 0, color_enabled);
    try w.writeAll(fbs.buffered());
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
    var fbs = std.Io.Writer.fixed(buf);
    try terminal.setColor(color);
    try printUnit(&fbs, x, unit, 0, color_enabled);
    try w.writeAll(fbs.buffered());
    try terminal.setColor(.reset);
    vis.* += visibleLen(fbs.buffered());
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
    try TableLayout.padVis(w, vis, layout.deltaStartVis());
    const col_start = layout.deltaStartVis();

    if (first_m == null) {
        if (color_enabled) try terminal.setColor(.dim);
        try w.writeAll("0%");
        if (color_enabled) try terminal.setColor(.reset);
        vis.* = col_start + visibleLen("0%");
        try TableLayout.padVis(w, vis, col_start + layout.delta_w);
        return;
    }
    const f = first_m.?;
    const half_val = deltaHalfWidth(m, f);
    const diff_mean_percent = (m.mean - f.mean) * 100 / f.mean;
    const is_sig = deltaIsSignificant(diff_mean_percent, half_val);

    var tail_buf: [32]u8 = undefined;
    var tail_w = std.Io.Writer.fixed(&tail_buf);
    if (m.mean > f.mean) {
        if (is_sig) {
            try w.writeAll("! ");
            if (color_enabled) try terminal.setColor(.bright_red);
        } else {
            if (color_enabled) try terminal.setColor(.dim);
            try w.writeAll("  ");
        }
        try w.writeAll("+");
    } else {
        if (is_sig) {
            if (color_enabled) try terminal.setColor(.bright_yellow);
            try w.writeAll("* ");
            if (color_enabled) try terminal.setColor(.bright_green);
        } else {
            if (color_enabled) try terminal.setColor(.dim);
            try w.writeAll("  ");
        }
        try w.writeAll("-");
    }
    try tail_w.print("{d: >5.1}% ± {d: >4.1}%", .{ @abs(diff_mean_percent), half_val });
    try w.writeAll(tail_w.buffered());
    if (color_enabled) try terminal.setColor(.reset);

    var measure_buf: [64]u8 = undefined;
    var measure_w = std.Io.Writer.fixed(&measure_buf);
    writeDeltaPlain(&measure_w, m, first_m) catch {};
    vis.* = col_start + visibleLen(measure_w.buffered());
    try TableLayout.padVis(w, vis, col_start + layout.delta_w);
}

pub fn main(init: process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdout_w = &stdout_writer.interface;

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

    var arg_i: usize = 1;
    while (arg_i < args.len) : (arg_i += 1) {
        const arg = args[arg_i];
        if (!std.mem.startsWith(u8, arg, "-")) {
            var cmd_argv: std.ArrayList([]const u8) = .empty;
            argv_parse.parseCommandLine(arena, &cmd_argv, arg) catch |err| {
                std.debug.print("could not parse command '{s}': {s}\n", .{
                    arg,
                    argv_parse.errorMessage(err),
                });
                process.exit(1);
            };
            try commands.append(arena, .{
                .raw_cmd = arg,
                .argv = try cmd_argv.toOwnedSlice(arena),
                .measurements = undefined,
                .sample_count = undefined,
            });
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
        bar = try progress.ProgressBar.init(io, arena, stdout_w, terminal.?.mode);
    }
    defer if (bar) |*b| b.deinit();

    var perf_fds: [perf_measurements.len]fd_t = @splat(-1);

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

        const first_start: Io.Timestamp = .now(io, .awake);
        var sample_index: usize = 0;
        while ((sample_index < min_samples or
            first_start.untilNow(io, .awake).toNanoseconds() < max_nano_seconds) and
            sample_index < max_samples) : (sample_index += 1)
        {
            if (!quiet) try bar.?.render(io);
            openPerfGroup(&perf_fds);
            defer closePerfFds(&perf_fds);

            _ = std.os.linux.ioctl(perf_fds[0], PERF.EVENT_IOC.DISABLE, PERF.IOC_FLAG_GROUP);
            _ = std.os.linux.ioctl(perf_fds[0], PERF.EVENT_IOC.RESET, PERF.IOC_FLAG_GROUP);

            const start: Io.Timestamp = .now(io, .awake);

            var child = try process.spawn(io, .{
                .argv = command.argv,
                .stdin = .inherit,
                .stdout = .ignore,
                .stderr = .pipe,
                .request_resource_usage_statistics = true,
            });

            var stderr_pipe_buf: [4096]u8 = undefined;
            var child_stderr = child.stderr.?.readerStreaming(io, &stderr_pipe_buf);

            var stderr_list: std.ArrayList(u8) = .empty;
            try stderr_list.ensureTotalCapacity(arena, 4096);
            var stderr_capture = Io.Writer.Allocating.fromArrayList(arena, &stderr_list);
            var stderr_truncated = false;

            while (true) {
                _ = child_stderr.interface.stream(&stderr_capture.writer, .unlimited) catch |err| switch (err) {
                    error.ReadFailed => return child_stderr.err.?,
                    error.WriteFailed => {
                        stderr_truncated = true;
                        _ = try child_stderr.interface.discardRemaining();
                        break;
                    },
                    error.EndOfStream => break,
                };
                if (stderr_list.items.len >= max_stderr_bytes) {
                    stderr_list.items.len = max_stderr_bytes;
                    stderr_truncated = true;
                    _ = try child_stderr.interface.discardRemaining();
                    break;
                }
            }
            stderr_list = stderr_capture.toArrayList();

            const term = child.wait(io) catch |err| {
                std.debug.print("\nerror: Couldn't execute {s}: {t}\n", .{ command.argv[0], err });
                process.exit(1);
            };
            const duration = start.untilNow(io, .awake);
            _ = std.os.linux.ioctl(perf_fds[0], PERF.EVENT_IOC.DISABLE, PERF.IOC_FLAG_GROUP);
            const peak_rss = child.resource_usage_statistics.getMaxRss() orelse 0;

            switch (term) {
                .exited => |code| {
                    if (code != 0 and !allow_failures) {
                        if (!quiet)
                            bar.?.clear(io) catch {};
                        std.debug.print("\nerror: Benchmark {d} command '{s}' failed with exit code {d}:\n", .{
                            command_n,
                            command.raw_cmd,
                            code,
                        });
                        if (stderr_truncated) {
                            std.debug.print(
                                \\────────────── truncated stderr ──────────────
                                \\{s}
                                \\──────────────────────────────────────────────
                                \\
                            ,
                                .{stderr_list.items},
                            );
                        } else {
                            std.debug.print(
                                \\─────────────────── stderr ───────────────────
                                \\{s}
                                \\──────────────────────────────────────────────
                                \\
                            ,
                                .{stderr_list.items},
                            );
                        }
                        process.exit(1);
                    }
                },
                else => {
                    std.debug.print("error: terminated unexpectedly\n", .{});
                    process.exit(1);
                },
            }

            try samples.append(arena, .{
                .wall_time = @intCast(duration.toNanoseconds()),
                .peak_rss = peak_rss,
                .cpu_cycles = try readPerfFd(perf_fds[0]),
                .instructions = try readPerfFd(perf_fds[1]),
                .cache_references = try readPerfFd(perf_fds[2]),
                .cache_misses = try readPerfFd(perf_fds[3]),
                .branch_misses = try readPerfFd(perf_fds[4]),
            });

            if (!quiet) {
                bar.?.estimate = est_total: {
                    const cur_samples: u64 = sample_index + 1;
                    var ns_per_sample: u64 = @intCast(@divTrunc((first_start.untilNow(io, .awake).toNanoseconds()), cur_samples));
                    if (ns_per_sample == 0) ns_per_sample = 1;
                    const estimate = std.math.divCeil(u64, max_nano_seconds, ns_per_sample) catch unreachable;
                    break :est_total @intCast(@min(max_samples, @max(cur_samples, estimate, min_samples)));
                };
                bar.?.current += 1;
            }
        }

        if (!quiet) {
            try bar.?.clear(io);
            bar.?.current = 0;
            bar.?.estimate = 1;
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

    help.printRunNotes(run_notes.items);

    for (commands.items, 1..) |*command, command_n| {
        if (terminal) |t| {
            try t.setColor(.bold);
            try stdout_w.print("Benchmark {d}", .{command_n});
            try t.setColor(.dim);
            try stdout_w.print(" ({d} runs)", .{command.sample_count});
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
                const first_measurement = if (command_n == 1)
                    null
                else
                    @field(commands.items[0].measurements, field.name);
                try printMeasurement(t, layout, measurement, field.name, first_measurement, with_delta);
            }

            try stdout_w.flush();
        }
    }

    if (json_path) |path| {
        var file_buf: [4096]u8 = undefined;
        var file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var file_writer = file.writerStreaming(io, &file_buf);
        try printJsonOutput(&file_writer.interface, commands.items);
        try file_writer.flush();
        if (!quiet) try stdout_w.print("results written to {s}\n", .{path});
    }

    try stdout_w.flush();
}

fn printJsonOutput(w: *Io.Writer, commands: []Command) !void {
    var s = std.json.Stringify{
        .writer = w,
        .options = .{ .whitespace = .indent_2 },
    };
    try s.beginObject();
    try s.objectField("results");
    try s.beginArray();
    for (commands) |cmd| {
        try s.beginObject();
        try s.objectField("command");
        try s.write(cmd.raw_cmd);
        try s.objectField("sample_count");
        try s.write(cmd.sample_count);
        try s.objectField("argv");
        try s.write(cmd.argv);
        try s.objectField("wall_time");
        try writeJsonMeasurement(&s, cmd.measurements.wall_time);
        try s.objectField("peak_rss");
        try writeJsonMeasurement(&s, cmd.measurements.peak_rss);
        try s.objectField("cpu_cycles");
        try writeJsonMeasurement(&s, cmd.measurements.cpu_cycles);
        try s.objectField("instructions");
        try writeJsonMeasurement(&s, cmd.measurements.instructions);
        try s.objectField("cache_references");
        try writeJsonMeasurement(&s, cmd.measurements.cache_references);
        try s.objectField("cache_misses");
        try writeJsonMeasurement(&s, cmd.measurements.cache_misses);
        try s.objectField("branch_misses");
        try writeJsonMeasurement(&s, cmd.measurements.branch_misses);
        try s.endObject();
    }
    try s.endArray();
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

fn openPerfGroup(fds: *[perf_measurements.len]fd_t) void {
    for (perf_measurements, fds) |measurement, *perf_fd| {
        var attr: std.os.linux.perf_event_attr = .{
            .type = PERF.TYPE.HARDWARE,
            .config = @intFromEnum(measurement.config),
            .flags = .{
                .disabled = true,
                .exclude_kernel = true,
                .exclude_hv = true,
                .inherit = true,
                .enable_on_exec = true,
            },
        };
        perf_fd.* = std.posix.perf_event_open(&attr, 0, -1, fds[0], PERF.FLAG.FD_CLOEXEC) catch |err| {
            closePerfFds(fds);
            printPerfOpenError(err, measurement.name);
        };
    }
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

    /// One scratch slice for the whole command; seven sorts, no hidden allocations.
    fn summarizeAll(samples: []const Sample, sort_scratch: []Sample) StatsError!Command.Measurements {
        if (samples.len == 0) return error.NoSamples;
        if (sort_scratch.len < samples.len) return error.ScratchTooSmall;
        const work = sort_scratch[0..samples.len];
        var out: Command.Measurements = undefined;
        inline for (@typeInfo(Command.Measurements).@"struct".fields) |field| {
            const unit: Unit = if (std.mem.eql(u8, field.name, "wall_time"))
                .nanoseconds
            else if (std.mem.eql(u8, field.name, "peak_rss"))
                .bytes
            else
                .count;
            @field(out, field.name) = try summarizeField(samples, work, field.name, unit);
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
    const outlier_percent = @as(f64, @floatFromInt(m.outlier_count)) / @as(f64, @floatFromInt(m.sample_count)) * 100;
    var outlier_buf: [32]u8 = undefined;
    var outlier_writer = std.Io.Writer.fixed(&outlier_buf);
    try outlier_writer.print("{d} ({d:.0}%)", .{ m.outlier_count, outlier_percent });
    if (outlier_percent >= 10)
        try terminal.setColor(.yellow)
    else
        try terminal.setColor(.dim);
    try w.writeAll(outlier_writer.buffered());
    try terminal.setColor(.reset);
    vis = layout.outlierStartVis() + visibleLen(outlier_writer.buffered());
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
    if (num >= 1000) {
        try w.print("{d:.0}", .{num});
    } else if (num >= 100) {
        try w.print("{d:.0}", .{num});
    } else if (num >= 10) {
        try w.print("{d:.1}", .{num});
    } else {
        try w.print("{d:.2}", .{num});
    }
}

fn printUnit(w: *std.Io.Writer, x: f64, unit: Measurement.Unit, std_dev: f64, color_enabled: bool) !void {
    _ = std_dev;
    const s = scaleUnit(x, unit);
    try printNum3SigFigs(w, s.val);
    if (color_enabled) {
        try w.print("\x1b[2m\x1b[37m{s}\x1b[0m", .{s.suffix});
    } else {
        try w.writeAll(s.suffix);
    }
}

// Gets either the T or Z score for 95% confidence.
// If no `df` variable is provided, Z score is provided.
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
        .cpu_cycles = 0,
        .instructions = 0,
        .cache_references = 0,
        .cache_misses = 0,
        .branch_misses = 0,
        .peak_rss = 0,
    };
    @field(s, field) = value;
    return s;
}

test "getStatScore95_dfZero_usesZScore" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.96), getStatScore95(0), 0.001);
}

test "getStatScore95_dfAbove120_usesZScore" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.96), getStatScore95(200), 0.001);
}

test "getStatScore95_nullDf_usesZScore" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.96), getStatScore95(null), 0.001);
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

test "printNum3SigFigs_smallValue_keepsDecimals" {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try printNum3SigFigs(&w, 5.0);
    try std.testing.expectEqualStrings("5.00", w.buffered());
}

test "printNum3SigFigs_largeValue_usesIntegerWidth" {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try printNum3SigFigs(&w, 1234);
    try std.testing.expectEqualStrings("1234", w.buffered());
}

test "results table: separators align across rows" {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const term = Io.Terminal{ .writer = &w, .mode = .no_color };

    const wall = Measurement{
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
    const rss = Measurement{
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
    const measurements: Command.Measurements = .{
        .wall_time = wall,
        .peak_rss = rss,
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
    const byte_idx = std.mem.indexOf(u8, haystack, needle) orelse return null;
    var vis: usize = 0;
    var i: usize = 0;
    while (i < byte_idx) {
        const cp_len = std.unicode.utf8CodepointSequenceLength(haystack[i]) catch 1;
        i += cp_len;
        vis += 1;
    }
    return vis;
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

test "summarizeField_stress_randomInvariants" {
    var prng = std.Random.DefaultPrng.init(0x5a1d_cafe);
    const random = prng.random();
    var samples: [32]Sample = undefined;
    var scratch: [32]Sample = undefined;
    for (0..2048) |_| {
        const n: u8 = random.intRangeAtMost(u8, 1, 32);
        for (0..n) |i| {
            samples[i] = sampleWith("wall_time", random.int(u64));
        }
        try checkSummarizeFieldInvariants(n, &samples, &scratch);
    }
}

test "summarizeField fuzz invariants" {
    try std.testing.fuzz({}, fuzzSummarizeField, .{});
}
