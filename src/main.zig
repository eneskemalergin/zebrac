const std = @import("std");
const Io = std.Io;
const process = std.process;
const PERF = std.os.linux.PERF;
const fd_t = std.posix.fd_t;
const assert = std.debug.assert;
const progress = @import("progress.zig");
const argv_parse = @import("argv_parse.zig");
const MAX_SAMPLES = 10000;
const max_stderr_bytes = 1024 * 1024;

const usage_text =
    \\Usage: zebrac [options] <command1> ... <commandN>
    \\
    \\Compares the performance of the provided commands.
    \\
    \\Sampling:
    \\  -d, --duration <ms>    sampling duration per command (default: 5000)
    \\  -i, --min-samples <n>  minimum samples per command (default: 5)
    \\  -a, --max-samples <n>  maximum samples per command (default: 10000)
    \\  -w, --warmup <n>       warmup runs before measurement (default: 3)
    \\
    \\Output:
    \\  --color <when>         color mode: auto, never, ansi (default: auto)
    \\  -f, --allow-failures   benchmark despite non-zero exit codes
    \\  --json [<path>]        write results as JSON (default: zebrac-results.json)
    \\  -q, --quiet            suppress terminal output
    \\
;

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
    var max_samples: u64 = MAX_SAMPLES;
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
            try stdout_w.writeAll(usage_text);
            try stdout_w.flush();
            return process.cleanExit(io);
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--duration")) {
            arg_i += 1;
            if (arg_i >= args.len) {
                std.debug.print("'{s}' requires a duration in milliseconds.\n{s}", .{ arg, usage_text });
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
                std.debug.print("'{s}' requires a mode; options are 'auto', 'never', and 'ansi'.\n{s}", .{ arg, usage_text });
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
                std.debug.print("'{s}' requires a number.\n{s}", .{ arg, usage_text });
                process.exit(1);
            }
            min_samples = std.fmt.parseInt(u64, args[arg_i], 10) catch |err| {
                std.debug.print("unable to parse --min-samples argument '{s}': {t}\n", .{ args[arg_i], err });
                process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--max-samples")) {
            arg_i += 1;
            if (arg_i >= args.len) {
                std.debug.print("'{s}' requires a number.\n{s}", .{ arg, usage_text });
                process.exit(1);
            }
            max_samples = std.fmt.parseInt(u64, args[arg_i], 10) catch |err| {
                std.debug.print("unable to parse --max-samples argument '{s}': {t}\n", .{ args[arg_i], err });
                process.exit(1);
            };
            if (max_samples > MAX_SAMPLES) max_samples = MAX_SAMPLES;
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--warmup")) {
            arg_i += 1;
            if (arg_i >= args.len) {
                std.debug.print("'{s}' requires a number.\n{s}", .{ arg, usage_text });
                process.exit(1);
            }
            warmup = std.fmt.parseInt(usize, args[arg_i], 10) catch |err| {
                std.debug.print("unable to parse --warmup argument '{s}': {t}\n", .{ args[arg_i], err });
                process.exit(1);
            };
        } else {
            std.debug.print("unrecognized argument: '{s}'\n{s}", .{ arg, usage_text });
            process.exit(1);
        }
    }

    if (commands.items.len == 0) {
        try stdout_w.writeAll(usage_text);
        try stdout_w.flush();
        process.exit(1);
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

        if (terminal) |t| {
            try t.setColor(.bold);
            try stdout_w.print("Benchmark {d}", .{command_n});
            try t.setColor(.dim);
            try stdout_w.print(" ({d} runs)", .{command.sample_count});
            try t.setColor(.reset);
            try stdout_w.writeAll(":");
            for (command.argv) |arg| try stdout_w.print(" {s}", .{arg});
            try stdout_w.writeAll("\n");

            try t.setColor(.bold);
            try stdout_w.writeAll("  measurement");
            try stdout_w.splatByteAll(' ', 23 - "  measurement".len);
            try t.setColor(.bright_green);
            try stdout_w.writeAll("mean");
            try t.setColor(.reset);
            try t.setColor(.bold);
            try stdout_w.writeAll(" ± ");
            try t.setColor(.green);
            try stdout_w.writeAll("σ");
            try t.setColor(.reset);

            try t.setColor(.bold);
            try stdout_w.splatByteAll(' ', 12);
            try t.setColor(.cyan);
            try stdout_w.writeAll("min");
            try t.setColor(.reset);
            try t.setColor(.bold);
            try stdout_w.writeAll(" … ");
            try t.setColor(.magenta);
            try stdout_w.writeAll("max");
            try t.setColor(.reset);

            try t.setColor(.bold);
            try stdout_w.splatByteAll(' ', 20 - " outliers".len);
            try t.setColor(.bright_yellow);
            try stdout_w.writeAll("outliers");
            try t.setColor(.reset);

            if (commands.items.len >= 2) {
                try t.setColor(.bold);
                try stdout_w.splatByteAll(' ', 9);
                try stdout_w.writeAll("delta");
                try t.setColor(.reset);
            }

            try stdout_w.writeAll("\n");

            inline for (@typeInfo(Command.Measurements).@"struct".fields) |field| {
                const measurement = @field(command.measurements, field.name);
                const first_measurement = if (command_n == 1)
                    null
                else
                    @field(commands.items[0].measurements, field.name);
                try printMeasurement(t, measurement, field.name, first_measurement, commands.items.len);
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
    m: Measurement,
    name: []const u8,
    first_m: ?Measurement,
    command_count: usize,
) !void {
    const w = terminal.writer;
    try w.print("  {s}", .{name});

    var buf: [200]u8 = undefined;
    var fbs: std.Io.Writer = .fixed(&buf);
    var count: usize = 0;

    const color_enabled = terminal.mode != .no_color;
    const ansi_overhead: usize = if (color_enabled) 13 else 0;
    const spaces = 21 -| name.len;
    try w.splatByteAll(' ', spaces);
    try terminal.setColor(.bright_green);
    try printUnit(&fbs, m.mean, m.unit, m.std_dev, color_enabled);
    try w.writeAll(fbs.buffered());
    count += fbs.end -| ansi_overhead;
    fbs.end = 0;
    try terminal.setColor(.reset);
    try w.writeAll(" ± ");
    try terminal.setColor(.green);
    try printUnit(&fbs, m.std_dev, m.unit, 0, color_enabled);
    try w.writeAll(fbs.buffered());
    count += fbs.end -| ansi_overhead;
    fbs.end = 0;
    try terminal.setColor(.reset);

    try w.splatByteAll(' ', 17 -| count);
    count = 0;

    try terminal.setColor(.cyan);
    try printUnit(&fbs, @floatFromInt(m.min), m.unit, m.std_dev, color_enabled);
    try w.writeAll(fbs.buffered());
    count += fbs.end -| ansi_overhead;
    fbs.end = 0;
    try terminal.setColor(.reset);
    try w.writeAll(" … ");
    try terminal.setColor(.magenta);
    try printUnit(&fbs, @floatFromInt(m.max), m.unit, m.std_dev, color_enabled);
    try w.writeAll(fbs.buffered());
    count += fbs.end -| ansi_overhead;
    fbs.end = 0;
    try terminal.setColor(.reset);

    try w.splatByteAll(' ', 17 -| count);
    count = 0;

    const outlier_percent = @as(f64, @floatFromInt(m.outlier_count)) / @as(f64, @floatFromInt(m.sample_count)) * 100;
    if (outlier_percent >= 10)
        try terminal.setColor(.yellow)
    else
        try terminal.setColor(.dim);
    try fbs.print("{d: >4.0} ({d: >2.0}%)", .{ m.outlier_count, outlier_percent });
    try w.writeAll(fbs.buffered());
    count += fbs.end;
    fbs.end = 0;
    try terminal.setColor(.reset);

    try w.splatByteAll(' ', 19 - (count + 1));

    // ratio
    if (command_count > 1) {
        if (first_m) |f| {
            const half = blk: {
                const z = getStatScore95(m.sample_count + f.sample_count - 2);
                const n1: f64 = @floatFromInt(m.sample_count);
                const n2: f64 = @floatFromInt(f.sample_count);
                const normer = std.math.sqrt(1.0 / n1 + 1.0 / n2);
                const numer1 = (n1 - 1) * (m.std_dev * m.std_dev);
                const numer2 = (n2 - 1) * (f.std_dev * f.std_dev);
                const df = n1 + n2 - 2;
                const sp = std.math.sqrt((numer1 + numer2) / df);
                break :blk (z * sp * normer) * 100 / f.mean;
            };
            const diff_mean_percent = (m.mean - f.mean) * 100 / f.mean;
            // significant only if full interval is beyond abs 1% with the same sign
            const is_sig = blk: {
                if (diff_mean_percent >= 1 and (diff_mean_percent - half) >= 1) {
                    break :blk true;
                } else if (diff_mean_percent <= -1 and (diff_mean_percent + half) <= -1) {
                    break :blk true;
                } else {
                    break :blk false;
                }
            };
            if (m.mean > f.mean) {
                if (is_sig) {
                    try w.writeAll("! ");
                    try terminal.setColor(.bright_red);
                } else {
                    try terminal.setColor(.dim);
                    try w.writeAll("  ");
                }
                try w.writeAll("+");
            } else {
                if (is_sig) {
                    try terminal.setColor(.bright_yellow);
                    try w.writeAll("* ");
                    try terminal.setColor(.bright_green);
                } else {
                    try terminal.setColor(.dim);
                    try w.writeAll("  ");
                }
                try w.writeAll("-");
            }
            try fbs.print("{d: >5.1}% ± {d: >4.1}%", .{ @abs(diff_mean_percent), half });
            try w.writeAll(fbs.buffered());
            count += fbs.end;
            fbs.end = 0;
        } else {
            try terminal.setColor(.dim);
            try w.writeAll("0%");
        }
    }

    try terminal.setColor(.reset);
    try w.writeAll("\n");
}

fn printNum3SigFigs(w: *std.Io.Writer, num: f64) !void {
    if (num >= 1000) {
        try w.print("{d: >4.0}", .{num});
    } else if (num >= 100) {
        try w.print("{d: >4.0}", .{num});
    } else if (num >= 10) {
        try w.print("{d: >3.1}", .{num});
    } else {
        try w.print("{d: >3.2}", .{num});
    }
}

fn printUnit(w: *std.Io.Writer, x: f64, unit: Measurement.Unit, std_dev: f64, color_enabled: bool) !void {
    _ = std_dev;
    const num = x;
    var val: f64 = 0;
    var ustr: []const u8 = "  ";
    if (num >= 1000_000_000_000) {
        val = num / 1000_000_000_000;
        ustr = switch (unit) {
            .count => "T ",
            .nanoseconds => "ks",
            .bytes => "TB",
        };
    } else if (num >= 1000_000_000) {
        val = num / 1000_000_000;
        ustr = switch (unit) {
            .count => "G ",
            .nanoseconds => "s ",
            .bytes => "GB",
        };
    } else if (num >= 1000_000) {
        val = num / 1000_000;
        ustr = switch (unit) {
            .count => "M ",
            .nanoseconds => "ms",
            .bytes => "MB",
        };
    } else if (num >= 1000) {
        val = num / 1000;
        ustr = switch (unit) {
            .count => "K ",
            .nanoseconds => "us",
            .bytes => "KB",
        };
    } else {
        val = num;
        ustr = switch (unit) {
            .count => "  ",
            .nanoseconds => "ns",
            .bytes => "  ",
        };
    }
    try printNum3SigFigs(w, val);
    if (color_enabled) {
        try w.print("\x1b[2m\x1b[37m{s}\x1b[0m", .{ustr});
    } else {
        try w.writeAll(ustr);
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
