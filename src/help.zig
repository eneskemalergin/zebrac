//! CLI help text and version string.
//! Single source for --help, --version, and error footers in main.zig.

const std = @import("std");

/// Bump with each release. Also appears in the help header and (later) JSON output.
pub const version = "0.5.3";

/// Maximum line length for help prose. Change this one constant to re-wrap.
pub const wrap_width: usize = 78;

/// Shown when a flag is missing a value. Full help is too noisy for that case.
pub const short_usage =
    \\Usage: zebrac [options] <command> [<command> ...]
    \\
    \\Run 'zebrac --help' for full usage.
    \\
;

const usage_rest =
    \\Linux-only. Compares commands by spawning them over and over.
    \\Reports wall time, peak RSS, and five hardware perf counters.
    \\
    \\Fork of poop by Andrew Kelley: https://github.com/andrewrk/poop
    \\Most of the measurement and stats code is upstream. zebrac adds
    \\shell-like quoting, JSON export, warmup runs, and min/max sample limits.
    \\
    \\Usage:
    \\  zebrac [options] <command> [<command> ...]
    \\
    \\Commands:
    \\  Each <command> is one program plus args, as a single string. No
    \\  /bin/sh (same as poop). zebrac splits command strings with a small
    \\  lexer (see Quoting). poop did not; quote paths that contain spaces.
    \\
    \\  Two or more commands: first is the baseline, rest show delta %.
    \\
    \\What gets measured (each run):
    \\  wall_time        elapsed time, nanoseconds
    \\  peak_rss         peak resident set size, bytes
    \\  cpu_cycles       perf hardware counter
    \\  instructions     perf hardware counter
    \\  cache_references perf hardware counter
    \\  cache_misses     perf hardware counter
    \\  branch_misses    perf hardware counter
    \\
    \\Sampling:
    \\  Warmup runs first (no counters, not counted; zebrac-only). Then
    \\  measured runs until min-samples AND --duration are both satisfied,
    \\  or max-samples is hit (hard cap 10000). Fast commands rack up many
    \\  samples in the time window. Slow ones may run past the duration to
    \\  reach min-samples.
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
    \\    -f, --allow-failures     keep going if a command exits non-zero
    \\
    \\  Information:
    \\    -h, --help               show this help
    \\    --version                show version
    \\
    \\Quoting (command strings only, not zebrac flags; zebrac-only):
    \\  'literal'     no escapes inside
    \\  "literal"     no escapes inside
    \\  foo\ bar      backslash escapes the next character (outside quotes)
    \\  No $VAR, no backticks, no globs, no pipes. Direct exec only.
    \\
    \\  Examples:
    \\    zebrac './build/my app' './build/my app --release'
    \\    zebrac "curl -s https://example.com"
    \\
    \\Comparison output (needs two or more commands; from poop):
    \\  Deltas vs the first command. Uses a 95% CI; marks a change only if
    \\  the interval clears +/-1% (stops noise from looking important):
    \\    ! +N%   likely slower
    \\    * -N%   likely faster
    \\    dim     probably noise
    \\
    \\Environment:
    \\  NO_COLOR          if set (even empty), disables color in auto mode
    \\  CLICOLOR_FORCE    if set (even empty), forces color in auto mode
    \\
    \\Requirements:
    \\  Linux with perf_event_open. Not macOS, not Windows. If counters
    \\  fail on first run, check perf_event_paranoid; the error message
    \\  prints a sysctl hint.
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
