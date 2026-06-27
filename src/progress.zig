//! Progress bar on stderr during sampling. Fixed-width layout for tests.
const std = @import("std");
const Io = std.Io;

const Spinner = struct {
    pub const frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";
    pub const frame1 = "⠋";
    pub const frame_count = frames.len / frame1.len;

    frame_idx: usize,

    pub fn init() Spinner {
        return .{ .frame_idx = 0 };
    }

    pub fn get(self: *const Spinner) []const u8 {
        return frames[self.frame_idx * frame1.len ..][0..frame1.len];
    }

    pub fn next(self: *Spinner) void {
        self.frame_idx = (self.frame_idx + 1) % frame_count;
    }
};

const bar_char = "━";
const half_bar_left = "╸";
const half_bar_right = "╺";
const WIDTH_PADDING: usize = 100;
const progress_run_suffix = " runs ";

/// True when the progress bar should run during sampling (`!quiet` and stdout is a TTY).
pub fn samplingShowsProgressBar(quiet: bool, stdout_is_tty: bool) bool {
    return !quiet and stdout_is_tty;
}

/// Heuristic for tests and smoke: progress lines contain a run count and percent field.
pub fn outputLooksLikeProgressLine(buf: []const u8) bool {
    return std.mem.indexOf(u8, buf, progress_run_suffix) != null and
        std.mem.indexOf(u8, buf, "%") != null;
}

fn getScreenWidth(io: Io, file: Io.File) usize {
    var winsize: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const err = (io.operate(.{ .device_io_control = .{
        .file = file,
        .code = std.posix.T.IOCGWINSZ,
        .arg = &winsize,
    } }) catch return 80).device_io_control;
    if (err >= 0 and winsize.col > 0) return winsize.col;
    return 80;
}

const ColorCodes = struct {
    dim: []const u8,
    pink: []const u8,
    white: []const u8,
    green: []const u8,
    magenta: []const u8,
    cyan: []const u8,
    reset: []const u8,
    erase_line: []const u8,

    fn init(mode: Io.Terminal.Mode) ColorCodes {
        return switch (mode) {
            .no_color => .{
                .dim = "",
                .pink = "",
                .white = "",
                .green = "",
                .magenta = "",
                .cyan = "",
                .reset = "",
                // `\r` alone leaves stale bar glyphs. EL clears the row. Bar on stderr, table on stdout.
                .erase_line = "\x1b[2K\r",
            },
            .escape_codes => .{
                .dim = "\x1b[2m",
                .pink = "\x1b[38;5;205m",
                .white = "\x1b[37m",
                .green = "\x1b[32m",
                .magenta = "\x1b[35m",
                .cyan = "\x1b[36m",
                .reset = "\x1b[0m",
                .erase_line = "\x1b[2K\r",
            },
            .windows_api => .{
                .dim = "",
                .pink = "",
                .white = "",
                .green = "",
                .magenta = "",
                .cyan = "",
                .reset = "",
                .erase_line = "\x1b[2K\r",
            },
        };
    }
};

/// Visual segments for the animated bar. `visualWidth` always equals `bar_width`.
pub const BarLayout = struct {
    bar_width: usize,
    full_bars_len: usize,
    show_half_left: bool,
    show_half_right: bool,
    empty_bars: usize,

    pub fn visualWidth(self: BarLayout) usize {
        return self.full_bars_len +
            @as(usize, @intFromBool(self.show_half_left)) +
            @as(usize, @intFromBool(self.show_half_right)) +
            self.empty_bars;
    }
};

/// Maps run progress to bar segments. Cap at 100% so a full bar cannot underflow `empty_bars`.
fn computeBarLayout(bar_width: usize, current: u64, estimate: u64) BarLayout {
    if (bar_width == 0) {
        return .{
            .bar_width = 0,
            .full_bars_len = 0,
            .show_half_left = false,
            .show_half_right = false,
            .empty_bars = 0,
        };
    }
    const est = @max(estimate, 1);
    const prog_len_raw = (@as(u64, @intCast(bar_width)) * 2) * current / est;
    const prog_len_max: u64 = @intCast(bar_width * 2);
    const prog_len = @min(prog_len_raw, prog_len_max);
    const full_bars_len: usize = @intCast(prog_len / 2);
    const show_half_left = prog_len % 2 == 1;
    const show_half_right = prog_len % 2 == 0 and full_bars_len < bar_width;
    const used = full_bars_len +
        @as(usize, @intFromBool(show_half_left)) +
        @as(usize, @intFromBool(show_half_right));
    const empty_bars = if (used >= bar_width) 0 else bar_width - used;
    return .{
        .bar_width = bar_width,
        .full_bars_len = full_bars_len,
        .show_half_left = show_half_left,
        .show_half_right = show_half_right,
        .empty_bars = empty_bars,
    };
}

pub const ProgressBar = struct {
    spinner: Spinner,
    current: u64,
    estimate: u64,
    writer: *Io.Writer,
    term_cols: usize,
    colors: ColorCodes,
    buf: Io.Writer.Allocating,
    last_rendered: Io.Timestamp,

    pub fn init(
        io: Io,
        allocator: std.mem.Allocator,
        writer: *Io.Writer,
        mode: Io.Terminal.Mode,
        screen: Io.File,
    ) !ProgressBar {
        const term_cols = getScreenWidth(io, screen);
        const buf: Io.Writer.Allocating = try .initCapacity(allocator, term_cols + WIDTH_PADDING);
        return .{
            .spinner = .init(),
            .last_rendered = .now(io, .awake),
            .current = 0,
            .estimate = 1,
            .writer = writer,
            .term_cols = term_cols,
            .colors = ColorCodes.init(mode),
            .buf = buf,
        };
    }

    pub fn deinit(self: *ProgressBar) void {
        self.buf.deinit();
    }

    /// Writes one progress line into `bw`. `term_cols` is full terminal width (used to derive bar width).
    pub fn formatLine(
        bw: *Io.Writer,
        colors: ColorCodes,
        term_cols: usize,
        spinner_frame: []const u8,
        current: u64,
        estimate: u64,
    ) !void {
        if (term_cols < 23) return;
        const bar_width = term_cols - Spinner.frame1.len - " 10000 runs ".len - " 100% ".len;
        const layout = computeBarLayout(bar_width, current, estimate);

        try bw.print("{s}{s}{s} {d: >5}{s}", .{
            colors.cyan, spinner_frame, colors.reset,
            current, progress_run_suffix,
        });

        try bw.print("{s}", .{colors.pink});
        for (0..layout.full_bars_len) |_| {
            try bw.print(bar_char, .{});
        }
        if (layout.show_half_left) {
            try bw.print(half_bar_left, .{});
        }
        try bw.print("{s}{s}", .{ colors.white, colors.dim });
        if (layout.show_half_right) {
            try bw.print(half_bar_right, .{});
        }
        for (0..layout.empty_bars) |_| {
            try bw.print(bar_char, .{});
        }
        try bw.print("{s}", .{colors.reset});
        try bw.print(" {d: >3.0}% ", .{
            @as(f64, @floatFromInt(current)) * 100 / @as(f64, @floatFromInt(@max(estimate, 1))),
        });
    }

    pub fn render(self: *ProgressBar, io: Io) !void {
        const now: Io.Timestamp = .now(io, .awake);
        if (self.last_rendered.durationTo(now).toMilliseconds() < 50) {
            return;
        }
        try self.clear(io);
        self.last_rendered = now;
        const width = self.term_cols;
        if (width < 23) return;
        try self.buf.ensureTotalCapacity(width + WIDTH_PADDING);
        const bw = &self.buf.writer;
        const spinner_frame = self.spinner.get();
        try ProgressBar.formatLine(bw, self.colors, width, spinner_frame, self.current, self.estimate);
        self.spinner.next();

        try self.writer.writeAll(self.buf.written());
        try self.writer.flush();
    }

    pub fn clear(self: *ProgressBar, io: Io) !void {
        _ = io;
        try self.writer.writeAll(self.colors.erase_line);
        try self.writer.flush();
        self.buf.clearRetainingCapacity();
    }
};

/// Format a single progress line into `buf` (fixed terminal width for tests and previews).
fn formatPreviewLine(
    buf: []u8,
    mode: Io.Terminal.Mode,
    term_cols: usize,
    current: u64,
    estimate: u64,
) !usize {
    var w = Io.Writer.fixed(buf);
    const colors = ColorCodes.init(mode);
    try ProgressBar.formatLine(&w, colors, term_cols, Spinner.frame1, current, estimate);
    return w.end;
}

fn countSubstring(hay: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, hay, i, needle)) |at| {
        n += 1;
        i = at + needle.len;
    }
    return n;
}

fn barSlotCount(term_cols: usize) usize {
    return term_cols - Spinner.frame1.len - " 10000 runs ".len - " 100% ".len;
}

test "no_color erase_line clears full row before shorter output" {
    const colors = ColorCodes.init(.no_color);
    try std.testing.expectEqualStrings("\x1b[2K\r", colors.erase_line);
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var out_buf: [4096]u8 = undefined;
    var out_writer = Io.Writer.fixed(&out_buf);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bar = try ProgressBar.init(io, arena.allocator(), &out_writer, .no_color, Io.File.stdout());
    defer bar.deinit();
    bar.last_rendered = Io.Timestamp.zero;
    bar.current = 7;
    bar.estimate = 8;
    try bar.render(io);
    const progress_len = out_writer.end;
    try bar.clear(io);
    try out_writer.writeAll("Benchmark 1 (8 runs): /bin/sleep 0.4\n");
    const final = out_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, final, "\x1b[2K\r") != null);
    const bench_start = std.mem.indexOf(u8, final, "Benchmark 1").?;
    const bench_line_end = std.mem.indexOfScalar(u8, final[bench_start..], '\n').? + bench_start;
    const bench_line = final[bench_start..bench_line_end];
    try std.testing.expectEqualStrings("Benchmark 1 (8 runs): /bin/sleep 0.4", bench_line);
    try std.testing.expect(std.mem.indexOf(u8, bench_line, bar_char) == null);
    try std.testing.expect(std.mem.indexOf(u8, bench_line, "%") == null);
    _ = progress_len;
}

test "formatLine: 100 percent fills bar slots (no_color)" {
    var buf: [512]u8 = undefined;
    const term_cols: usize = 100;
    const len = try formatPreviewLine(&buf, .no_color, term_cols, 50, 50);
    const line = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, line, "    50 runs ") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, " 100% ") != null);
    const slots = barSlotCount(term_cols);
    try std.testing.expectEqual(slots, countSubstring(line, bar_char));
    try std.testing.expect(std.mem.indexOf(u8, line, half_bar_left) == null);
    try std.testing.expect(std.mem.indexOf(u8, line, half_bar_right) == null);
}

test "formatLine: zero percent has dim tail (no_color)" {
    var buf: [512]u8 = undefined;
    const term_cols: usize = 80;
    const len = try formatPreviewLine(&buf, .no_color, term_cols, 0, 20);
    const line = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, line, "     0 runs ") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "   0% ") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, half_bar_right) != null);
    try std.testing.expectEqual(barSlotCount(term_cols), countSubstring(line, bar_char) + 1);
}

test "formatLine: fifty percent (no_color)" {
    var buf: [512]u8 = undefined;
    const len = try formatPreviewLine(&buf, .no_color, 100, 25, 50);
    const line = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, line, "    25 runs ") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "  50% ") != null);
    const slots = barSlotCount(100);
    try std.testing.expectEqual(slots, countSubstring(line, bar_char) + countSubstring(line, half_bar_left) + countSubstring(line, half_bar_right));
}

test "formatLine: escape_codes includes ANSI sequences" {
    var buf: [1024]u8 = undefined;
    const len = try formatPreviewLine(&buf, .escape_codes, 100, 50, 100);
    const line = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, line, "\x1b[36m") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\x1b[38;5;205m") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\x1b[0m") != null);
}

test "BarLayout: 100 percent matches bar_width (regression 2.0.1)" {
    const bar_width: usize = 50;
    const layout = computeBarLayout(bar_width, 100, 100);
    try std.testing.expectEqual(bar_width, layout.full_bars_len);
    try std.testing.expect(!layout.show_half_left);
    try std.testing.expect(!layout.show_half_right);
    try std.testing.expectEqual(@as(usize, 0), layout.empty_bars);
    try std.testing.expectEqual(bar_width, layout.visualWidth());
}

test "BarLayout: current equals estimate at various widths" {
    const estimates = [_]u64{ 1, 2, 5, 100, 10_000 };
    const widths = [_]usize{ 1, 10, 57, 200 };
    for (estimates) |est| {
        for (widths) |w| {
            const layout = computeBarLayout(w, est, est);
            try std.testing.expectEqual(w, layout.visualWidth());
            try std.testing.expectEqual(@as(usize, 0), layout.empty_bars);
        }
    }
}

test "BarLayout: zero and partial progress" {
    const w: usize = 20;
    const z = computeBarLayout(w, 0, 10);
    try std.testing.expectEqual(@as(usize, 0), z.full_bars_len);
    try std.testing.expect(z.show_half_right);
    try std.testing.expectEqual(w, z.visualWidth());

    const half = computeBarLayout(w, 5, 10);
    try std.testing.expectEqual(@as(usize, 10), half.full_bars_len);
    try std.testing.expectEqual(w, half.visualWidth());
}

test "BarLayout: visual width invariant (property)" {
    var bar_width: usize = 1;
    while (bar_width <= 80) : (bar_width += 1) {
        var estimate: u64 = 1;
        while (estimate <= 64) : (estimate += 1) {
            var current: u64 = 0;
            while (current <= estimate + 2) : (current += 1) {
                const layout = computeBarLayout(bar_width, current, estimate);
                try std.testing.expectEqual(bar_width, layout.visualWidth());
            }
        }
    }
}

test "BarLayout: current above estimate caps at full bar" {
    const layout = computeBarLayout(30, 200, 100);
    try std.testing.expectEqual(@as(usize, 30), layout.full_bars_len);
    try std.testing.expectEqual(@as(usize, 0), layout.empty_bars);
}

test "BarLayout: estimate zero treated as one" {
    const layout = computeBarLayout(10, 5, 0);
    try std.testing.expectEqual(@as(usize, 10), layout.full_bars_len);
}

/// Legacy formula from pre-2.0.1. In ReleaseSmall this wraps; in Debug it panics.
fn legacyEmptySlots(bar_width: usize, full_bars_len: usize) usize {
    return bar_width - full_bars_len - 1;
}

test "legacy formula underflows at 100 percent in optimized builds" {
    const builtin = @import("builtin");
    if (builtin.mode == .Debug) return error.SkipZigTest;
    const bar_width: usize = 50;
    const full_bars_len: usize = 50;
    const remainder = legacyEmptySlots(bar_width, full_bars_len);
    try std.testing.expect(remainder > bar_width);
}

test "render at 100 percent completes without hang" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var out_buf: [8192]u8 = undefined;
    var out_writer = Io.Writer.fixed(&out_buf);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bar = try ProgressBar.init(io, arena.allocator(), &out_writer, .no_color, Io.File.stdout());
    defer bar.deinit();
    bar.last_rendered = Io.Timestamp.zero;
    bar.current = 100;
    bar.estimate = 100;
    try bar.render(io);
    const line = out_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, line, " 100% ") != null);
    try std.testing.expectEqual(countSubstring(line, bar_char), barSlotCount(bar.term_cols));
}

test "init caches terminal width for render" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var out_buf: [8192]u8 = undefined;
    var out_writer = Io.Writer.fixed(&out_buf);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bar = try ProgressBar.init(io, arena.allocator(), &out_writer, .no_color, Io.File.stdout());
    defer bar.deinit();
    const at_init = bar.term_cols;
    try std.testing.expect(at_init >= 23);
    bar.last_rendered = Io.Timestamp.zero;
    bar.current = 1;
    bar.estimate = 2;
    try bar.render(io);
    try std.testing.expectEqual(at_init, bar.term_cols);
    try std.testing.expect(std.mem.indexOf(u8, out_writer.buffered(), "     1 runs ") != null);
}

test "render with escape_codes mode" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var out_buf: [8192]u8 = undefined;
    var out_writer = Io.Writer.fixed(&out_buf);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bar = try ProgressBar.init(io, arena.allocator(), &out_writer, .escape_codes, Io.File.stdout());
    defer bar.deinit();
    bar.last_rendered = Io.Timestamp.zero;
    bar.current = 50;
    bar.estimate = 100;
    try bar.render(io);
    try std.testing.expect(std.mem.indexOf(u8, out_writer.buffered(), "\x1b[") != null);
}

test "samplingShowsProgressBar respects quiet and stdout tty" {
    try std.testing.expect(!samplingShowsProgressBar(true, true));
    try std.testing.expect(!samplingShowsProgressBar(true, false));
    try std.testing.expect(samplingShowsProgressBar(false, true));
    try std.testing.expect(!samplingShowsProgressBar(false, false));
}

test "outputLooksLikeProgressLine detects bar output" {
    try std.testing.expect(outputLooksLikeProgressLine("     3 runs 100%"));
    try std.testing.expect(!outputLooksLikeProgressLine("Benchmark 1 (3 runs): /bin/true"));
    try std.testing.expect(!outputLooksLikeProgressLine(""));
}

test "render throttled skips second write" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var out_buf: [4096]u8 = undefined;
    var out_writer = Io.Writer.fixed(&out_buf);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bar = try ProgressBar.init(io, arena.allocator(), &out_writer, .no_color, Io.File.stdout());
    defer bar.deinit();
    bar.last_rendered = Io.Timestamp.zero;
    bar.current = 2;
    bar.estimate = 5;
    try bar.render(io);
    const after_first = out_writer.end;
    try std.testing.expect(after_first > 0);
    bar.last_rendered = .now(io, .awake);
    try bar.render(io);
    try std.testing.expectEqual(after_first, out_writer.end);
}
