//! --help, --version, sample limits, run notes.

const std = @import("std");

pub const version = "0.6.0";

/// Re-wrap help text when this changes.
pub const wrap_width: usize = 78;

pub const max_samples_cap: u64 = 10_000;

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

const max_samples_cap_text = std.fmt.comptimePrint("{d}", .{max_samples_cap});
const max_samples_hard_cap_phrase = std.fmt.comptimePrint("hard cap {d}", .{max_samples_cap});
const max_samples_default_bracket = std.fmt.comptimePrint("[{d}]", .{max_samples_cap});

const usage_rest =
    \\Linux only. Runs your command in a loop and reads perf counters.
    \\Wall time, peak RSS, five hardware counters per sample.
    \\
    \\Fork of poop by Andrew Kelley: https://github.com/andrewrk/poop
    \\Measurement and stats mostly upstream. zebrac adds quoting, JSON
    \\export, warmup runs, and min/max sample flags.
    \\
    \\Usage:
    \\  zebrac [options] <command> [<command> ...]
    \\
    \\Commands:
    \\  One program plus args, written as a single string. No /bin/sh
    \\  (same as poop). zebrac splits the string itself (see Quoting).
    \\  poop could not handle spaced paths; quote them here.
    \\
    \\  Two or more commands: first is the baseline, rest show delta %.
    \\
    \\What gets measured (each run):
    \\  wall_time        elapsed time, nanoseconds
    \\  peak_rss         peak resident set size, bytes
    \\  minor_faults     page faults not requiring disk I/O
    \\  major_faults     page faults requiring disk I/O (table row hidden
    \\                   when max is 0; always present in --json output)
    \\  cpu_cycles       perf hardware counter
    \\  instructions     perf hardware counter
    \\  cache_references perf hardware counter
    \\  cache_misses     perf hardware counter
    \\  branch_misses    perf hardware counter
    \\
    \\Sampling:
    \\  Warmup first (no counters, not counted). Then measured runs until
    \\  min-samples and --duration are both met, or max-samples stops it
    \\  (hard cap 10000). /bin/true at 500 ms can still yield hundreds of
    \\  samples. A slow command may run past the duration to reach min.
    \\  min/max-samples must be at least 1; min above max: exit before
    \\  spawn. Notes (clamp, 2+ metric outlier rate, --warmup 0) print on stderr
    \\  once before the results table. Piped stdout (not a TTY) skips the
    \\  progress bar during sampling; the results table still prints unless -q.
    \\
    \\  -f (--allow-failures): non-zero exit on a measured run does not
    \\  stop the benchmark. Failed runs stay in means. Warmup is not
    \\  counted in failed_sample_count. wall_time ends when the child
    \\  exits; post-exit stderr drain for the first failure note is not
    \\  included. First failure prints captured stderr on stderr; later
    \\  failures summarize there. After that note, later samples do not
    \\  pipe stderr (normal wait). Table header and --json report
    \\  failed_sample_count.
    \\
    \\Options:
    \\  Sampling:
    \\    -d, --duration <ms>      sampling time budget per command [5000]
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
    \\  No $VAR, backticks, globs, or pipes. Direct exec.
    \\
    \\  Examples:
    \\    zebrac './build/my app' './build/my app --release'
    \\    zebrac "curl -s https://example.com"
    \\
    \\Comparison (two or more commands; delta logic from poop):
    \\  Vs the first command. Spread within one command; delta ± is
    \\  compare uncertainty (nonzero diffs only). Equal means: 0% with no
    \\  ± band. Too few samples or ~zero baseline mean: n/a.
    \\  95% CI on deltas; marks a change only when the interval clears
    \\  +/-1% (tiny shifts stay dim):
    \\    ! +N%   likely slower
    \\    * -N%   likely faster
    \\    dim     probably noise
    \\
    \\Environment:
    \\  NO_COLOR          if set (even empty), disables color in auto mode
    \\  CLICOLOR_FORCE    if set (even empty), forces color in auto mode
    \\
    \\Requirements:
    \\  Linux, perf_event_open. Not macOS or Windows. If counters fail,
    \\  check perf_event_paranoid; the error prints a sysctl hint.
    \\
    \\Examples:
    \\  zebrac ./app-old ./app-new
    \\  zebrac --duration 2000 --warmup 5 './myapp --flag'
    \\  zebrac --quiet --json ./ci.json './myapp'
    \\
    \\zebrac: https://github.com/eneskemalergin/zebrac
    \\poop:  https://github.com/andrewrk/poop
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
    for (std.meta.fieldNames(SampleLimitsError)) |name| {
        _ = errorMessage(@field(SampleLimitsError, name));
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

test "help.usageText_contains" {
    const cases = [_]struct {
        haystack: []const u8,
        needle: []const u8,
    }{
        .{ .haystack = usage_text, .needle = version_line },
        .{ .haystack = usage_text, .needle = "first is the baseline" },
        .{ .haystack = usage_text, .needle = "perf_event_paranoid" },
        .{ .haystack = usage_text, .needle = "--version" },
        .{ .haystack = usage_text, .needle = "NO_COLOR" },
        .{ .haystack = usage_text, .needle = max_samples_cap_text },
        .{ .haystack = usage_text, .needle = "https://github.com/andrewrk/poop" },
        .{ .haystack = short_usage, .needle = "zebrac --help" },
    };

    for (cases) |c| {
        try std.testing.expect(std.mem.indexOf(u8, c.haystack, c.needle) != null);
    }
}

test "validateSampleLimits" {
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
        .{ .min = 0, .max = 10, .err = error.MinSamplesZero },
        .{ .min = 5, .max = 0, .err = error.MaxSamplesZero },
    };

    for (ok_cases) |c| try validateSampleLimits(c.min, c.max);
    for (err_cases) |c| try std.testing.expectError(c.err, validateSampleLimits(c.min, c.max));
}
