//! Progress bar on stderr while samples run.

const std = @import("std");
const Io = std.Io;

const Spinner = struct {
    const frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";
    const frame1 = "⠋";
    const frame_count = frames.len / frame1.len;

    frame_idx: usize,

    fn init() Spinner {
        return .{ .frame_idx = 0 };
    }

    fn get(self: *const Spinner) []const u8 {
        return frames[self.frame_idx * frame1.len ..][0..frame1.len];
    }

    fn next(self: *Spinner) void {
        self.frame_idx = (self.frame_idx + 1) % frame_count;
    }
};

const bar_char = "━";
const half_bar_left = "╸";
const half_bar_right = "╺";

const progress_run_suffix = " runs ";
const min_term_cols: usize = 23;
const default_term_cols: usize = 80;
const render_throttle_ms: i64 = 50;
// ANSI sequences can be wider than visible columns; pad past ioctl width.
const width_padding: usize = 100;

// Widest run count and percent strings; keep in sync with formatLine.
const max_run_count_field = std.fmt.comptimePrint(" {d: >5}{s}", .{ 10_000, progress_run_suffix });
const max_pct_field = std.fmt.comptimePrint(" {d: >3.0}% ", .{100});

fn barSlotCount(term_cols: usize) usize {
    return term_cols - Spinner.frame1.len - max_run_count_field.len - max_pct_field.len;
}

pub fn samplingShowsProgressBar(quiet: bool, stdout_is_tty: bool) bool {
    return !quiet and stdout_is_tty;
}

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
    } }) catch return default_term_cols).device_io_control;
    if (err >= 0 and winsize.col > 0) return winsize.col;
    return default_term_cols;
}

const ColorCodes = struct {
    dim: []const u8,
    pink: []const u8,
    white: []const u8,
    cyan: []const u8,
    reset: []const u8,
    erase_line: []const u8,

    fn init(mode: Io.Terminal.Mode) ColorCodes {
        return switch (mode) {
            .escape_codes => .{
                .dim = "\x1b[2m",
                .pink = "\x1b[38;5;205m",
                .white = "\x1b[37m",
                .cyan = "\x1b[36m",
                .reset = "\x1b[0m",
                .erase_line = "\x1b[2K\r",
            },
            .no_color, .windows_api => .{
                .dim = "",
                .pink = "",
                .white = "",
                .cyan = "",
                .reset = "",
                // CR alone leaves junk on the line; clear the row first. Bar on stderr, table on stdout.
                .erase_line = "\x1b[2K\r",
            },
        };
    }
};

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

// Half-column steps so the bar can move smoothly between full blocks.
// Clamp at 100% so empty_bars can't underflow.
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

fn writeGlyphRepeat(w: *Io.Writer, glyph: []const u8, count: usize) !void {
    var n: usize = 0;
    while (n < count) : (n += 1) try w.writeAll(glyph);
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
        const buf: Io.Writer.Allocating = try .initCapacity(allocator, term_cols + width_padding);
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

    pub fn formatLine(
        bw: *Io.Writer,
        colors: ColorCodes,
        term_cols: usize,
        spinner_frame: []const u8,
        current: u64,
        estimate: u64,
    ) !void {
        if (term_cols < min_term_cols) {
            @branchHint(.cold);
            return;
        }
        const layout = computeBarLayout(barSlotCount(term_cols), current, estimate);

        try bw.print("{s}{s}{s} {d: >5}{s}", .{
            colors.cyan, spinner_frame,       colors.reset,
            current,     progress_run_suffix,
        });

        try bw.print("{s}", .{colors.pink});
        try writeGlyphRepeat(bw, bar_char, layout.full_bars_len);
        if (layout.show_half_left) try bw.writeAll(half_bar_left);
        try bw.print("{s}{s}", .{ colors.white, colors.dim });
        if (layout.show_half_right) try bw.writeAll(half_bar_right);
        try writeGlyphRepeat(bw, bar_char, layout.empty_bars);
        try bw.print("{s}", .{colors.reset});
        try bw.print(" {d: >3.0}% ", .{
            @as(f64, @floatFromInt(current)) * 100 / @as(f64, @floatFromInt(@max(estimate, 1))),
        });
    }

    pub fn render(self: *ProgressBar, io: Io) !void {
        const now: Io.Timestamp = .now(io, .awake);
        if (self.last_rendered.durationTo(now).toMilliseconds() < render_throttle_ms) return;
        try self.clear();
        self.last_rendered = now;
        const width = self.term_cols;
        if (width < min_term_cols) {
            @branchHint(.cold);
            return;
        }
        try self.buf.ensureTotalCapacity(width + width_padding);
        const bw = &self.buf.writer;
        const spinner_frame = self.spinner.get();
        try ProgressBar.formatLine(bw, self.colors, width, spinner_frame, self.current, self.estimate);
        self.spinner.next();

        try self.writer.writeAll(self.buf.written());
        try self.writer.flush();
    }

    pub fn clear(self: *ProgressBar) !void {
        try self.writer.writeAll(self.colors.erase_line);
        try self.writer.flush();
        self.buf.clearRetainingCapacity();
    }
};

comptime {
    if (barSlotCount(default_term_cols) < 1)
        @compileError("barSlotCount must leave room for bar glyphs at default_term_cols");
}

fn formatPreviewLine(
    buf: []u8,
    mode: Io.Terminal.Mode,
    term_cols: usize,
    current: u64,
    estimate: u64,
) !usize {
    var w = Io.Writer.fixed(buf);
    try ProgressBar.formatLine(&w, ColorCodes.init(mode), term_cols, Spinner.init().get(), current, estimate);
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

fn legacyEmptySlots(bar_width: usize, full_bars_len: usize) usize {
    return bar_width - full_bars_len - 1;
}

test "progress.BarLayout" {
    {
        const layout = computeBarLayout(50, 100, 100);
        try std.testing.expectEqual(@as(usize, 50), layout.full_bars_len);
        try std.testing.expect(!layout.show_half_left);
        try std.testing.expect(!layout.show_half_right);
        try std.testing.expectEqual(@as(usize, 0), layout.empty_bars);
        try std.testing.expectEqual(@as(usize, 50), layout.visualWidth());
    }

    const edges = [_]struct {
        w: usize,
        cur: u64,
        est: u64,
        full: usize,
        half_l: bool,
        half_r: bool,
        empty: usize,
    }{
        .{ .w = 20, .cur = 0, .est = 10, .full = 0, .half_l = false, .half_r = true, .empty = 19 },
        .{ .w = 20, .cur = 5, .est = 10, .full = 10, .half_l = false, .half_r = true, .empty = 9 },
        .{ .w = 30, .cur = 200, .est = 100, .full = 30, .half_l = false, .half_r = false, .empty = 0 },
        .{ .w = 10, .cur = 5, .est = 0, .full = 10, .half_l = false, .half_r = false, .empty = 0 },
    };
    for (edges) |e| {
        const layout = computeBarLayout(e.w, e.cur, e.est);
        try std.testing.expectEqual(e.full, layout.full_bars_len);
        try std.testing.expectEqual(e.half_l, layout.show_half_left);
        try std.testing.expectEqual(e.half_r, layout.show_half_right);
        try std.testing.expectEqual(e.empty, layout.empty_bars);
        try std.testing.expectEqual(e.w, layout.visualWidth());
    }

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

test "progress.formatLine" {
    const cases = [_]struct {
        mode: Io.Terminal.Mode,
        cols: usize,
        current: u64,
        estimate: u64,
        runs: []const u8,
        pct: []const u8,
        bar_chars: usize,
        half_left: usize,
        half_right: usize,
        segment_total: ?usize,
        want_ansi: bool,
    }{
        .{
            .mode = .no_color,
            .cols = 80,
            .current = 0,
            .estimate = 20,
            .runs = "     0 runs ",
            .pct = "   0% ",
            .bar_chars = 0,
            .half_left = 0,
            .half_right = 1,
            .segment_total = barSlotCount(80),
            .want_ansi = false,
        },
        .{
            .mode = .no_color,
            .cols = 100,
            .current = 25,
            .estimate = 50,
            .runs = "    25 runs ",
            .pct = "  50% ",
            .bar_chars = 0,
            .half_left = 0,
            .half_right = 0,
            .segment_total = barSlotCount(100),
            .want_ansi = false,
        },
        .{
            .mode = .no_color,
            .cols = 100,
            .current = 50,
            .estimate = 50,
            .runs = "    50 runs ",
            .pct = " 100% ",
            .bar_chars = barSlotCount(100),
            .half_left = 0,
            .half_right = 0,
            .segment_total = null,
            .want_ansi = false,
        },
        .{
            .mode = .escape_codes,
            .cols = 100,
            .current = 50,
            .estimate = 100,
            .runs = "    50 runs ",
            .pct = "  50% ",
            .bar_chars = 0,
            .half_left = 0,
            .half_right = 0,
            .segment_total = barSlotCount(100),
            .want_ansi = true,
        },
    };

    for (cases) |c| {
        var buf: [1024]u8 = undefined;

        const len = try formatPreviewLine(&buf, c.mode, c.cols, c.current, c.estimate);
        const line = buf[0..len];

        try std.testing.expect(std.mem.indexOf(u8, line, c.runs) != null);
        try std.testing.expect(std.mem.indexOf(u8, line, c.pct) != null);
        const bars = countSubstring(line, bar_char);
        const halves_l = countSubstring(line, half_bar_left);
        const halves_r = countSubstring(line, half_bar_right);
        if (c.segment_total) |total| {
            try std.testing.expectEqual(total, bars + halves_l + halves_r);
        } else {
            try std.testing.expectEqual(c.bar_chars, bars);
            try std.testing.expectEqual(c.half_left, halves_l);
            try std.testing.expectEqual(c.half_right, halves_r);
        }
        if (c.want_ansi) {
            try std.testing.expect(std.mem.indexOf(u8, line, "\x1b[36m") != null);
            try std.testing.expect(std.mem.indexOf(u8, line, "\x1b[38;5;205m") != null);
            try std.testing.expect(std.mem.indexOf(u8, line, "\x1b[0m") != null);
        }
    }
}

test "progress.legacyEmptySlots_underflows" {
    const builtin = @import("builtin");
    if (builtin.mode == .Debug) return error.SkipZigTest;
    const bar_width: usize = 50;
    const full_bars_len: usize = 50;
    const remainder = legacyEmptySlots(bar_width, full_bars_len);
    try std.testing.expect(remainder > bar_width);
}

test "progress.eraseLine_clearsRowBeforeBenchmark" {
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
    try bar.clear();
    try out_writer.writeAll("Benchmark 1 (8 runs): /bin/sleep 0.4\n");

    const final = out_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, final, "\x1b[2K\r") != null);
    const bench_start = std.mem.indexOf(u8, final, "Benchmark 1").?;
    const bench_line_end = std.mem.indexOfScalar(u8, final[bench_start..], '\n').? + bench_start;
    const bench_line = final[bench_start..bench_line_end];
    try std.testing.expectEqualStrings("Benchmark 1 (8 runs): /bin/sleep 0.4", bench_line);
    try std.testing.expect(std.mem.indexOf(u8, bench_line, bar_char) == null);
    try std.testing.expect(std.mem.indexOf(u8, bench_line, "%") == null);
}

test "progress.render_throttlesRapidUpdates" {
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

test "progress.helpers" {
    const show_cases = [_]struct { quiet: bool, tty: bool, want: bool }{
        .{ .quiet = true, .tty = true, .want = false },
        .{ .quiet = true, .tty = false, .want = false },
        .{ .quiet = false, .tty = true, .want = true },
        .{ .quiet = false, .tty = false, .want = false },
    };
    for (show_cases) |c| {
        try std.testing.expectEqual(c.want, samplingShowsProgressBar(c.quiet, c.tty));
    }

    const line_cases = [_]struct { line: []const u8, want: bool }{
        .{ .line = "     3 runs 100%", .want = true },
        .{ .line = "Benchmark 1 (3 runs): /bin/true", .want = false },
        .{ .line = "", .want = false },
    };
    for (line_cases) |c| {
        try std.testing.expectEqual(c.want, outputLooksLikeProgressLine(c.line));
    }
}
