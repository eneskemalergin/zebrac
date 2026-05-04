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

const bar = "━";
const half_bar_left = "╸";
const half_bar_right = "╺";
const WIDTH_PADDING: usize = 100;

pub fn getScreenWidth(io: Io, file: Io.File) usize {
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
                .erase_line = "\r",
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
                .erase_line = "\r",
            },
        };
    }
};

pub const ProgressBar = struct {
    spinner: Spinner,
    current: u64,
    estimate: u64,
    writer: *Io.Writer,
    colors: ColorCodes,
    buf: Io.Writer.Allocating,
    last_rendered: Io.Timestamp,

    pub fn init(
        io: Io,
        allocator: std.mem.Allocator,
        writer: *Io.Writer,
        mode: Io.Terminal.Mode,
    ) !ProgressBar {
        const width = getScreenWidth(io, Io.File.stdout());
        const buf: Io.Writer.Allocating = try .initCapacity(allocator, width + WIDTH_PADDING);
        return .{
            .spinner = .init(),
            .last_rendered = .now(io, .awake),
            .current = 0,
            .estimate = 1,
            .writer = writer,
            .colors = ColorCodes.init(mode),
            .buf = buf,
        };
    }

    pub fn deinit(self: *ProgressBar) void {
        self.buf.deinit();
    }

    pub fn render(self: *ProgressBar, io: Io) !void {
        const now: Io.Timestamp = .now(io, .awake);
        if (self.last_rendered.durationTo(now).toMilliseconds() < 50) {
            return;
        }
        try self.clear(io);
        self.last_rendered = now;
        const width = getScreenWidth(io, Io.File.stdout());
        if (width < 23) return;
        try self.buf.ensureTotalCapacity(width + WIDTH_PADDING);
        const bw = &self.buf.writer;
        const bar_width = width - Spinner.frame1.len - " 10000 runs ".len - " 100% ".len;
        const prog_len = (bar_width * 2) * self.current / self.estimate;
        const full_bars_len: usize = @intCast(prog_len / 2);

        try bw.print("{s}{s}{s} {d: >5} runs ", .{
            self.colors.cyan, self.spinner.get(), self.colors.reset,
            self.current,
        });
        self.spinner.next();

        try bw.print("{s}", .{self.colors.pink});
        for (0..full_bars_len) |_| {
            try bw.print(bar, .{});
        }
        if (prog_len % 2 == 1) {
            try bw.print(half_bar_left, .{});
        }
        try bw.print("{s}{s}", .{ self.colors.white, self.colors.dim });
        if (prog_len % 2 == 0) {
            try bw.print(half_bar_right, .{});
        }
        for (0..(bar_width - full_bars_len - 1)) |_| {
            try bw.print(bar, .{});
        }
        try bw.print("{s}", .{self.colors.reset});
        try bw.print(" {d: >3.0}% ", .{
            @as(f64, @floatFromInt(self.current)) * 100 / @as(f64, @floatFromInt(self.estimate)),
        });
        try self.writer.writeAll(self.buf.written());
        try self.writer.flush();
    }

    pub fn clear(self: *ProgressBar, io: Io) !void {
        _ = io;
        try self.writer.writeAll(self.colors.erase_line);
        self.buf.clearRetainingCapacity();
    }
};
