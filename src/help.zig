//! CLI help text and version string.
//! Single source for --help, --version, and error footers in main.zig.

const std = @import("std");

/// Bump each release. Help header and JSON `zebrac_version` both read this.
pub const version = "0.5.6";

/// Maximum line length for help prose. Change this one constant to re-wrap.
pub const wrap_width: usize = 78;

/// Hard upper bound for `--max-samples` (also referenced in help text).
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

pub fn sampleLimitsErrorMessage(err: SampleLimitsError, min_samples: u64, max_samples: u64) []const u8 {
    _ = min_samples;
    _ = max_samples;
    return switch (err) {
        error.MinSamplesZero => "--min-samples must be at least 1",
        error.MaxSamplesZero => "--max-samples must be at least 1",
        error.MinSamplesExceedsMax => "--min-samples cannot be greater than --max-samples",
    };
}

/// Stderr only. Printed after measurement, before results tables on stdout.
pub fn printRunNotes(notes: []const []const u8) void {
    if (notes.len == 0) return;
    std.debug.print("note:\n", .{});
    for (notes) |line| std.debug.print("  {s}\n", .{line});
}

/// Shown when a flag is missing a value. Full help is too noisy for that case.
pub const short_usage =
    \\Usage: zebrac [options] <command> [<command> ...]
    \\
    \\Run 'zebrac --help' for full usage.
    \\
;

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
    \\  spawn. A clamp note (if any) prints on stderr once, before the
    \\  results table.
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
    \\                             (summaries only; no compare deltas)
    \\    -f, --allow-failures     keep sampling on non-zero exit
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
    \\  Vs the first command. σ is spread within one command; delta ± is
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

pub const usage_text: []const u8 = "zebrac " ++ version ++ "\n" ++ usage_rest;

comptime {
    assertMaxLineWidth(usage_text, wrap_width);
    assertMaxLineWidth(short_usage, wrap_width);
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

test "usage_text: required sections present" {
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "zebrac " ++ version) != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "first is the baseline") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "perf_event_paranoid") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "wall_time") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "peak_rss") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "minor_faults") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "major_faults") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "cpu_cycles") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "branch_misses") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "--version") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "NO_COLOR") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "hard cap 10000") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "https://github.com/andrewrk/poop") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "Andrew Kelley") != null);
}

test "usage_text: no line exceeds wrap_width" {
    var line_start: usize = 0;
    while (line_start <= usage_text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, usage_text, line_start, '\n') orelse usage_text.len;
        const line = usage_text[line_start..line_end];
        try std.testing.expect(line.len <= wrap_width);
        if (line_end == usage_text.len) break;
        line_start = line_end + 1;
    }
}

test "short_usage: points to full help" {
    try std.testing.expect(std.mem.indexOf(u8, short_usage, "zebrac --help") != null);
}

test "version: non-empty semver shape" {
    try std.testing.expect(version.len >= 5);
    try std.testing.expect(std.mem.indexOf(u8, version, ".") != null);
}

test "validateSampleLimits: accepts defaults" {
    try validateSampleLimits(5, max_samples_cap);
}

test "validateSampleLimits: rejects min above max" {
    try std.testing.expectError(error.MinSamplesExceedsMax, validateSampleLimits(100, 10));
}

test "validateSampleLimits: rejects zero min" {
    try std.testing.expectError(error.MinSamplesZero, validateSampleLimits(0, 10));
}

test "validateSampleLimits: rejects zero max" {
    try std.testing.expectError(error.MaxSamplesZero, validateSampleLimits(5, 0));
}
