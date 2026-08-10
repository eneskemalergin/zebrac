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

const min_term_cols: usize = 23;
const default_term_cols: usize = 80;
const render_throttle_ms: i64 = 50;
const max_term_cols: usize = std.math.maxInt(u16);
const max_glyph_bytes: usize = @max(bar_char.len, half_bar_left.len, half_bar_right.len);
pub const max_buffer_bytes: usize = max_term_cols * max_glyph_bytes + 1024;

const spinner_cols: usize = 1;
const min_run_count_digits: usize = 5;
const max_pct_field = std.fmt.comptimePrint(" {d: >3.0}% ", .{100});

fn decimalDigitCount(value: u64) usize {
    var remaining = value;
    var digits: usize = 1;
    while (remaining >= 10) : (digits += 1) remaining /= 10;
    return digits;
}

fn runSuffix(current: u64) []const u8 {
    return if (current == 1) " run " else " runs ";
}

fn barSlotCount(term_cols: usize, current: u64) usize {
    const run_count_cols = 1 + @max(min_run_count_digits, decimalDigitCount(current)) + runSuffix(current).len;
    const fixed_cols = spinner_cols + run_count_cols + max_pct_field.len;
    return term_cols -| fixed_cols;
}

pub fn samplingShowsProgressBar(quiet: bool, stderr_is_tty: bool) bool {
    return !quiet and stderr_is_tty;
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

const BarLayout = struct {
    full_bars_len: usize,
    show_half_left: bool,
    show_half_right: bool,
    empty_bars: usize,

    fn visualWidth(self: BarLayout) usize {
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
    screen: Io.File,
    colors: ColorCodes,
    buf: Io.Writer,
    last_rendered: Io.Timestamp,

    pub fn init(
        io: Io,
        storage: []u8,
        writer: *Io.Writer,
        mode: Io.Terminal.Mode,
        screen: Io.File,
    ) ProgressBar {
        return .{
            .spinner = .init(),
            .last_rendered = .now(io, .awake),
            .current = 0,
            .estimate = 1,
            .writer = writer,
            .screen = screen,
            .colors = ColorCodes.init(mode),
            .buf = Io.Writer.fixed(storage),
        };
    }

    fn formatLine(
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
        const bar_slots = barSlotCount(term_cols, current);
        if (bar_slots == 0) return;
        const layout = computeBarLayout(bar_slots, current, estimate);

        try bw.print("{s}{s}{s} {d: >5}{s}", .{
            colors.cyan, spinner_frame,      colors.reset,
            current,     runSuffix(current),
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
        try self.renderWidth(getScreenWidth(io, self.screen));
    }

    pub fn renderFinal(self: *ProgressBar, io: Io) !void {
        try self.clear();
        try self.renderWidth(getScreenWidth(io, self.screen));
    }

    fn renderWidth(self: *ProgressBar, width: usize) !void {
        if (width < min_term_cols) {
            @branchHint(.cold);
            return;
        }
        const bw = &self.buf;
        const spinner_frame = self.spinner.get();
        try ProgressBar.formatLine(bw, self.colors, width, spinner_frame, self.current, self.estimate);
        self.spinner.next();

        try self.writer.writeAll(self.buf.buffered());
        try self.writer.flush();
    }

    pub fn clear(self: *ProgressBar) !void {
        try self.writer.writeAll(self.colors.erase_line);
        try self.writer.flush();
        self.buf.end = 0;
    }
};

comptime {
    if (barSlotCount(default_term_cols, 10_000) < 1)
        @compileError("barSlotCount must leave room for bar glyphs at default_term_cols");
}

// --- Tests ---

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

test "[property] - [progress layout]: fills every bar width without underflow" {
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

test "[unit] - [progress line]: formats counts, width, percentage, and colors" {
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
            .segment_total = barSlotCount(80, 0),
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
            .segment_total = barSlotCount(100, 25),
            .want_ansi = false,
        },
        .{
            .mode = .no_color,
            .cols = 100,
            .current = 50,
            .estimate = 50,
            .runs = "    50 runs ",
            .pct = " 100% ",
            .bar_chars = barSlotCount(100, 50),
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
            .segment_total = barSlotCount(100, 50),
            .want_ansi = true,
        },
        .{
            .mode = .no_color,
            .cols = 80,
            .current = 100_000,
            .estimate = 100_000,
            .runs = " 100000 runs ",
            .pct = " 100% ",
            .bar_chars = barSlotCount(80, 100_000),
            .half_left = 0,
            .half_right = 0,
            .segment_total = null,
            .want_ansi = false,
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
        } else {
            try std.testing.expectEqual(c.cols, try std.unicode.utf8CountCodepoints(line));
        }
    }
}

test "[regression] - [progress cleanup]: clears the row before a benchmark heading" {
    const colors = ColorCodes.init(.no_color);
    try std.testing.expectEqualStrings("\x1b[2K\r", colors.erase_line);

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var out_buf: [4096]u8 = undefined;
    var out_writer = Io.Writer.fixed(&out_buf);
    var bar_storage: [4096]u8 = undefined;
    var bar = ProgressBar.init(io, &bar_storage, &out_writer, .no_color, Io.File.stdout());
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

test "[unit] - [progress throttle]: suppresses rapid updates" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var out_buf: [4096]u8 = undefined;
    var out_writer = Io.Writer.fixed(&out_buf);
    var bar_storage: [4096]u8 = undefined;
    var bar = ProgressBar.init(io, &bar_storage, &out_writer, .no_color, Io.File.stdout());
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

test "[regression] - [final progress]: renders completion inside the throttle interval" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var out_buf: [4096]u8 = undefined;
    var out_writer = Io.Writer.fixed(&out_buf);
    var bar_storage: [4096]u8 = undefined;
    var bar = ProgressBar.init(io, &bar_storage, &out_writer, .no_color, Io.File.stdout());
    bar.last_rendered = .now(io, .awake);
    bar.current = 1;
    bar.estimate = 1;

    try bar.renderFinal(io);

    try std.testing.expect(std.mem.indexOf(u8, out_writer.buffered(), "     1 run ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_writer.buffered(), " 100% ") != null);
}

test "[regression] - [progress buffer]: terminal resize keeps fixed storage" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var out_buf: [4096]u8 = undefined;
    var out_writer = Io.Writer.fixed(&out_buf);
    var bar_storage: [4096]u8 = undefined;
    var bar = ProgressBar.init(io, &bar_storage, &out_writer, .no_color, Io.File.stdout());
    const storage_address = @intFromPtr(bar.buf.buffer.ptr);
    bar.current = 1;
    bar.estimate = 2;

    try bar.renderWidth(40);
    try bar.clear();
    try bar.renderWidth(200);

    try std.testing.expectEqual(storage_address, @intFromPtr(bar.buf.buffer.ptr));
    try std.testing.expect(bar.buf.end > 0);
}

test "[edge] - [progress buffer]: maximum terminal width fits the fixed buffer" {
    const storage = try std.testing.allocator.alloc(u8, max_buffer_bytes);
    defer std.testing.allocator.free(storage);
    var writer = Io.Writer.fixed(storage);

    try ProgressBar.formatLine(
        &writer,
        ColorCodes.init(.escape_codes),
        max_term_cols,
        Spinner.init().get(),
        10_000,
        10_000,
    );

    try std.testing.expect(writer.end <= max_buffer_bytes);
}

test "[unit] - [progress visibility]: follows quiet and stderr terminal state" {
    const show_cases = [_]struct { quiet: bool, tty: bool, want: bool }{
        .{ .quiet = true, .tty = true, .want = false },
        .{ .quiet = true, .tty = false, .want = false },
        .{ .quiet = false, .tty = true, .want = true },
        .{ .quiet = false, .tty = false, .want = false },
    };
    for (show_cases) |c| {
        try std.testing.expectEqual(c.want, samplingShowsProgressBar(c.quiet, c.tty));
    }
}
