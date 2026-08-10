//! Owns zebrac's version, CLI help text, sample limits, and run notes.

const std = @import("std");

pub const version = "0.6.2";

pub const max_samples_cap: u64 = 10_000;
const wrap_width: usize = 78;

pub const SampleLimitsError = error{
    MinSamplesZero,
    MaxSamplesZero,
    MinSamplesExceedsMax,
};

pub fn validateSampleLimits(min_samples: u64, max_samples: u64) SampleLimitsError!void {
    if (min_samples == 0) return error.MinSamplesZero;
    if (max_samples == 0) return error.MaxSamplesZero;
    if (min_samples > max_samples) return error.MinSamplesExceedsMax;
}

pub fn errorMessage(err: SampleLimitsError) []const u8 {
    return switch (err) {
        error.MinSamplesZero => "--min-samples must be at least 1",
        error.MaxSamplesZero => "--max-samples must be at least 1",
        error.MinSamplesExceedsMax => "--min-samples cannot be greater than --max-samples",
    };
}

pub fn printRunNotes(w: *std.Io.Writer, notes: []const []const u8) !void {
    if (notes.len == 0) return;
    try w.print("note:\n", .{});
    for (notes) |line| try w.print("  {s}\n", .{line});
    try w.flush();
}

pub const short_usage =
    \\Usage: zebrac [options] <command> [<command> ...]
    \\
    \\Run 'zebrac --help' for full usage.
    \\
;

const max_samples_hard_cap_phrase = std.fmt.comptimePrint("hard cap {d}", .{max_samples_cap});
const max_samples_default_bracket = std.fmt.comptimePrint("[{d}]", .{max_samples_cap});

const usage_rest =
    \\Linux only. Runs your command in a loop and reads perf counters.
    \\Wall time, peak RSS, page faults, and five hardware counters per sample.
    \\
    \\Fork of poop by Andrew Kelley: https://github.com/andrewrk/poop
    \\
    \\Usage:
    \\  zebrac [options] <command> [<command> ...]
    \\
    \\Commands:
    \\  One program and its arguments, written as a single string. Zebrac
    \\  does not start /bin/sh. It splits the string itself (see Quoting).
    \\  Program paths with spaces need quotes inside the command string.
    \\  Zebrac waits only for the program it starts. If that program starts
    \\  background work, it must wait for that work before it exits. Otherwise
    \\  the work can overlap later samples. peak_rss covers only that program,
    \\  not every process that it starts.
    \\
    \\  Two or more commands: first is the baseline, rest show delta %.
    \\
    \\What gets measured (each measured run):
    \\  wall_time        elapsed time, nanoseconds
    \\  peak_rss         peak resident set size, bytes
    \\  minor_faults     page faults not requiring disk I/O
    \\  major_faults     page faults requiring disk I/O (table row hidden
    \\                   only when every command's max is 0; always in JSON)
    \\  cpu_cycles       perf hardware counter
    \\  instructions     perf hardware counter
    \\  cache_references perf hardware counter
    \\  cache_misses     perf hardware counter
    \\  branch_misses    perf hardware counter
    \\
    \\Sampling:
    \\  Commands run in complete rounds. Each round runs every command once
    \\  in a changing order. This spreads positions and which command ran
    \\  just before another command. Warmups use the same order, have no
    \\  counters, and are not counted. Measured rounds continue until
    \\  min-samples and --duration are both met, or max-samples stops them
    \\  (hard cap 10000). A slow command may run past the duration to reach
    \\  the minimum or finish a round.
    \\
    \\  With two or more commands, the total time budget is --duration times
    \\  the number of commands. The clock starts after warmups. Zebrac finishes
    \\  a round before checking time, so every command has the same count and
    \\  appears in every completed round. Equal min/max limits give an exact
    \\  sample count.
    \\  min/max-samples must be at least 1; min above max: exit before
    \\  spawn. Notes (clamp, 2+ metric outlier rate, --warmup 0) print on stderr
    \\  once before the results table. Non-TTY stderr skips the progress bar
    \\  during sampling; the results table still prints unless -q.
    \\
    \\  -f (--allow-failures): a non-zero exit during warmup or measurement
    \\  does not stop the benchmark. Failed measured runs stay in means.
    \\  Warmup failures are not counted in failed_sample_count. wall_time ends
    \\  when the program exits; reading any remaining stderr afterward is not
    \\  included. Every run uses the same limited stderr capture and waiting
    \\  code.
    \\  After normal collection, the first measured failure per command
    \\  prints captured stderr; later failures print one summary. If an
    \\  error stops collection, saved failure text prints before exit.
    \\  Table header and --json report failed_sample_count.
    \\
    \\Options:
    \\  Sampling:
    \\    -d, --duration <ms>      base sampling time [5000]
    \\    -i, --min-samples <n>    minimum measured runs per command [5]
    \\    -a, --max-samples <n>    maximum measured runs per command [10000]
    \\    -w, --warmup <n>         unmeasured runs before sampling [3]
    \\
    \\  Output:
    \\    --color <mode>           auto, never, or ansi [auto]
    \\    -q, --quiet              no progress bar or results table
    \\    --json [<path>]          write results JSON [zebrac-results.json]
    \\    --json=<path>            same as --json <path>
    \\                             (summaries only; no compare deltas)
    \\    -f, --allow-failures     keep sampling on non-zero exit
    \\
    \\  Operand separator:
    \\    --                       end options; following args are commands
    \\
    \\  Information:
    \\    -h, --help               show this help
    \\    --version                show version
    \\
    \\Quoting (command strings, not zebrac flags):
    \\  'literal'     no escapes inside
    \\  "literal"     no escapes inside
    \\  foo\ bar      backslash escapes the next character (outside quotes)
    \\  $VAR, backticks, and globs stay literal. Pipes and redirects do not run.
    \\
    \\  Examples:
    \\    zebrac "'./build/my app'" "'./build/my app' --release"
    \\    zebrac "curl -s https://example.com"
    \\
    \\Comparison (two or more commands):
    \\  Each command keeps its own samples and summary. The first command is
    \\  the baseline. Each later command shows the difference between its mean
    \\  and the baseline mean as a signed percentage:
    \\    +N%   higher mean; more of that measurement
    \\    -N%   lower mean; less of that measurement
    \\  For wall_time only, higher means slower and lower means faster. For
    \\  memory, faults, instructions, and hardware counters, the sign does
    \\  not by itself mean better or worse. The percentage has no uncertainty
    \\  range or warning mark. If any command has fewer than two samples, all
    \\  tables show n/a. A baseline mean near zero also shows n/a.
    \\
    \\Environment:
    \\  NO_COLOR          if set (even empty), disables color in auto mode
    \\  CLICOLOR_FORCE    if set (even empty), forces color in auto mode
    \\
    \\Requirements:
    \\  Linux, perf_event_open. Not macOS or Windows. A denied perf counter
    \\  names perf_event_paranoid and prints a sysctl hint.
    \\
    \\Examples:
    \\  zebrac ./app-old ./app-new
    \\  zebrac --duration 2000 --warmup 5 './myapp --flag'
    \\  zebrac --json -- './myapp'
    \\  zebrac --quiet --json ./ci.json './myapp'
    \\
    \\zebrac: https://github.com/eneskemalergin/zebrac
    \\
;

pub const version_line: []const u8 = "zebrac " ++ version ++ "\n";
pub const usage_text: []const u8 = version_line ++ usage_rest;

comptime {
    @setEvalBranchQuota(100_000);
    assertMaxLineWidth(usage_text, wrap_width);
    assertMaxLineWidth(short_usage, wrap_width);

    if (std.mem.indexOf(u8, usage_rest, max_samples_hard_cap_phrase) == null)
        @compileError("usage_rest hard-cap phrase must match max_samples_cap");
    if (std.mem.indexOf(u8, usage_rest, max_samples_default_bracket) == null)
        @compileError("usage_rest --max-samples default must match max_samples_cap");

    const measured_metrics = [_][]const u8{
        "wall_time",     "peak_rss",     "minor_faults",     "major_faults",
        "cpu_cycles",    "instructions", "cache_references", "cache_misses",
        "branch_misses",
    };
    for (measured_metrics) |name| {
        if (std.mem.indexOf(u8, usage_rest, name) == null)
            @compileError(std.fmt.comptimePrint("usage_rest must mention metric '{s}'", .{name}));
    }
}

fn assertMaxLineWidth(comptime text: []const u8, comptime max: usize) void {
    @setEvalBranchQuota(10_000);
    var line_start: usize = 0;
    while (line_start <= text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line = text[line_start..line_end];
        if (line.len > max) {
            @compileError(std.fmt.comptimePrint(
                "help line exceeds wrap_width ({d}): '{s}'",
                .{ max, line },
            ));
        }
        if (line_end == text.len) break;
        line_start = line_end + 1;
    }
}

// --- Tests ---

test "[unit] - [help text]: includes current commands, limits, and output rules" {
    const max_samples_cap_text = std.fmt.comptimePrint("{d}", .{max_samples_cap});
    const cases = [_]struct {
        haystack: []const u8,
        needle: []const u8,
    }{
        .{ .haystack = usage_text, .needle = version_line },
        .{ .haystack = usage_text, .needle = "first is the baseline" },
        .{ .haystack = usage_text, .needle = "waits only for the program it starts" },
        .{ .haystack = usage_text, .needle = "not every process that it starts" },
        .{ .haystack = usage_text, .needle = "perf_event_paranoid" },
        .{ .haystack = usage_text, .needle = "--version" },
        .{ .haystack = usage_text, .needle = "NO_COLOR" },
        .{ .haystack = usage_text, .needle = "saved failure text prints before exit" },
        .{ .haystack = usage_text, .needle = "more of that measurement" },
        .{ .haystack = usage_text, .needle = "For wall_time only" },
        .{ .haystack = usage_text, .needle = "no uncertainty" },
        .{ .haystack = usage_text, .needle = "fewer than two samples" },
        .{ .haystack = usage_text, .needle = "all\n  tables show n/a" },
        .{ .haystack = usage_text, .needle = "baseline mean near zero" },
        .{ .haystack = usage_text, .needle = "Pipes and redirects do not run" },
        .{ .haystack = usage_text, .needle = "zebrac --json -- './myapp'" },
        .{
            .haystack = usage_text,
            .needle = "zebrac \"'./build/my app'\" \"'./build/my app' --release\"",
        },
        .{ .haystack = usage_text, .needle = max_samples_cap_text },
        .{ .haystack = usage_text, .needle = "https://github.com/andrewrk/poop" },
        .{ .haystack = short_usage, .needle = "zebrac --help" },
    };

    for (cases) |c| {
        try std.testing.expect(std.mem.indexOf(u8, c.haystack, c.needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "likely slower") == null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "likely faster") == null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "zebrac './build/my app'") == null);
}

test "[unit] - [sample limits]: accepts and rejects the exact boundaries" {
    const ok_cases = [_]struct { min: u64, max: u64 }{
        .{ .min = 5, .max = max_samples_cap },
        .{ .min = 1, .max = 1 },
    };
    const err_cases = [_]struct {
        min: u64,
        max: u64,
        err: SampleLimitsError,
    }{
        .{ .min = 100, .max = 10, .err = error.MinSamplesExceedsMax },
        .{ .min = 0, .max = 0, .err = error.MinSamplesZero },
        .{ .min = 0, .max = 10, .err = error.MinSamplesZero },
        .{ .min = 5, .max = 0, .err = error.MaxSamplesZero },
    };

    for (ok_cases) |c| try validateSampleLimits(c.min, c.max);
    for (err_cases) |c| try std.testing.expectError(c.err, validateSampleLimits(c.min, c.max));

    try std.testing.expectEqualStrings(
        "--min-samples must be at least 1",
        errorMessage(error.MinSamplesZero),
    );
    try std.testing.expectEqualStrings(
        "--max-samples must be at least 1",
        errorMessage(error.MaxSamplesZero),
    );
    try std.testing.expectEqualStrings(
        "--min-samples cannot be greater than --max-samples",
        errorMessage(error.MinSamplesExceedsMax),
    );
}

test "[unit] - [run notes]: formats empty and populated note lists exactly" {
    var empty_buffer: [1]u8 = undefined;
    var empty_writer = std.Io.Writer.fixed(&empty_buffer);
    try printRunNotes(&empty_writer, &.{});
    try std.testing.expectEqualStrings("", empty_writer.buffered());

    var output_buffer: [64]u8 = undefined;
    var output_writer = std.Io.Writer.fixed(&output_buffer);
    try printRunNotes(&output_writer, &.{ "first", "second" });
    try std.testing.expectEqualStrings(
        "note:\n  first\n  second\n",
        output_writer.buffered(),
    );
}
