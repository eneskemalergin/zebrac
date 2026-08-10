//! Splits a command operand into argv for direct execution. No shell expansion.
//!
//! Plain words borrow from the command input. Quoted or escaped words use the
//! caller's arena. Both must outlive the returned argv. A parse error clears argv.

const std = @import("std");

const ParseError = error{
    UnclosedSingleQuote,
    UnclosedDoubleQuote,
    TrailingBackslash,
    EmptyCommand,
};

pub const ParseCommandLineError = ParseError || error{OutOfMemory};

pub fn parseCommandLine(arena: std.mem.Allocator, argv: *std.ArrayList([]const u8), cmd: []const u8) ParseCommandLineError!void {
    argv.clearRetainingCapacity();
    errdefer argv.clearRetainingCapacity();

    var mode: QuoteMode = .bare;
    var i: usize = 0;
    var word = Word{
        .cmd = cmd,
        .slice_start = 0,
        .buf = .empty,
        .materialized = false,
        .active = false,
    };
    defer word.buf.deinit(arena);

    while (i < cmd.len) {
        const c = cmd[i];
        switch (mode) {
            .bare => {
                if (std.ascii.isWhitespace(c)) {
                    try pushWord(arena, argv, &word, i);
                    i += 1;
                    continue;
                }
                switch (c) {
                    '\'' => try openQuote(&word, &mode, arena, &i, .single),
                    '"' => try openQuote(&word, &mode, arena, &i, .double),
                    '\\' => {
                        if (!word.active) word.begin(i);
                        try word.materializePrefix(arena, i);
                        i += 1;
                        if (i >= cmd.len) {
                            @branchHint(.cold);
                            return error.TrailingBackslash;
                        }
                        try word.buf.append(arena, cmd[i]);
                        i += 1;
                    },
                    else => {
                        if (!word.active) {
                            word.begin(i);
                        } else if (word.materialized) {
                            try word.buf.append(arena, c);
                        }
                        i += 1;
                    },
                }
            },
            .single, .double => {
                const close: u8 = if (mode == .single) '\'' else '"';
                if (c == close) mode = .bare else try word.pushQuoted(arena, c, i);
                i += 1;
            },
        }
    }

    switch (mode) {
        .single => {
            @branchHint(.cold);
            return error.UnclosedSingleQuote;
        },
        .double => {
            @branchHint(.cold);
            return error.UnclosedDoubleQuote;
        },
        .bare => {},
    }

    try pushWord(arena, argv, &word, cmd.len);
    if (argv.items.len == 0) {
        @branchHint(.cold);
        return error.EmptyCommand;
    }
}

pub fn errorMessage(err: ParseCommandLineError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory",
        error.UnclosedSingleQuote => "missing closing single quote (')",
        error.UnclosedDoubleQuote => "missing closing double quote (\")",
        error.TrailingBackslash => "trailing backslash with nothing to escape",
        error.EmptyCommand => "empty command (only whitespace, or nothing to run)",
    };
}

const QuoteMode = enum { bare, single, double };

const Word = struct {
    cmd: []const u8,
    slice_start: usize,
    buf: std.ArrayList(u8),
    materialized: bool,
    active: bool,

    fn begin(self: *Word, index: usize) void {
        self.active = true;
        self.slice_start = index;
        self.materialized = false;
        self.buf.clearRetainingCapacity();
    }

    fn materializePrefix(self: *Word, arena: std.mem.Allocator, end: usize) !void {
        if (!self.materialized) {
            try self.buf.appendSlice(arena, self.cmd[self.slice_start..end]);
            self.materialized = true;
        }
    }

    fn pushQuoted(self: *Word, arena: std.mem.Allocator, byte: u8, index: usize) !void {
        try self.materializePrefix(arena, index);
        try self.buf.append(arena, byte);
    }

    fn finish(self: *Word, arena: std.mem.Allocator, end: usize) ![]const u8 {
        self.active = false;
        if (!self.materialized) return self.cmd[self.slice_start..end];
        return try self.buf.toOwnedSlice(arena);
    }
};

fn isMeta(c: u8) bool {
    return std.ascii.isWhitespace(c) or c == '"' or c == '\'' or c == '\\';
}

fn pushWord(arena: std.mem.Allocator, argv: *std.ArrayList([]const u8), word: *Word, end: usize) !void {
    if (!word.active) return;
    try argv.append(arena, try word.finish(arena, end));
}

fn openQuote(word: *Word, mode: *QuoteMode, arena: std.mem.Allocator, i: *usize, next: QuoteMode) !void {
    if (!word.active) word.begin(i.*);
    try word.materializePrefix(arena, i.*);
    mode.* = next;
    i.* += 1;
}

fn needsQuoting(arg: []const u8) bool {
    if (arg.len == 0) return true;
    for (arg) |c| if (isMeta(c)) return true;
    return false;
}

fn appendEscapedBare(arena: std.mem.Allocator, out: *std.ArrayList(u8), arg: []const u8) !void {
    for (arg) |c| {
        if (isMeta(c)) {
            try out.append(arena, '\\');
            try out.append(arena, c);
        } else try out.append(arena, c);
    }
}

fn joinCommandLine(arena: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    for (argv, 0..) |arg, n| {
        if (n > 0) try out.append(arena, ' ');
        if (!needsQuoting(arg)) {
            try out.appendSlice(arena, arg);
        } else if (std.mem.indexOfScalar(u8, arg, '\'') == null) {
            try out.append(arena, '\'');
            try out.appendSlice(arena, arg);
            try out.append(arena, '\'');
        } else if (std.mem.indexOfScalar(u8, arg, '"') == null) {
            try out.append(arena, '"');
            try out.appendSlice(arena, arg);
            try out.append(arena, '"');
        } else {
            try appendEscapedBare(arena, &out, arg);
        }
    }
    return try out.toOwnedSlice(arena);
}

fn argvEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

fn roundtripExpect(arena: std.mem.Allocator, cmd: []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try parseCommandLine(arena, &argv, cmd);
    const joined = try joinCommandLine(arena, argv.items);
    var again: std.ArrayList([]const u8) = .empty;
    try parseCommandLine(arena, &again, joined);
    try std.testing.expect(argvEqual(argv.items, again.items));
}

fn roundtripBody(cmd: []const u8, gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    roundtripExpect(arena.allocator(), cmd) catch |err| switch (err) {
        error.OutOfMemory => return error.SkipZigTest,
        error.UnclosedSingleQuote,
        error.UnclosedDoubleQuote,
        error.TrailingBackslash,
        error.EmptyCommand,
        => return,
        else => return err,
    };
}

fn expectBorrowedFrom(cmd: []const u8, got: []const []const u8) !void {
    for (got) |tok| {
        if (tok.len == 0) continue;
        const off = std.mem.indexOf(u8, cmd, tok) orelse return error.TestExpectedEqual;
        try std.testing.expect(tok.ptr == cmd.ptr + off);
    }
}

const fuzz_input_cap: usize = 2048;
const stress_input_cap: usize = 512;
const stress_rounds: usize = 4096;

const fuzz_byte_weights = [_]std.testing.Smith.Weight{
    .rangeAtMost(u8, 0x00, 0xff, 1),
    .rangeAtMost(u8, 0x20, 0x7e, 4),
    .value(u8, ' ', 4),
    .value(u8, '\t', 2),
    .value(u8, '\n', 2),
    .value(u8, '"', 2),
    .value(u8, '\'', 2),
    .value(u8, '\\', 2),
};

// --- Tests ---

test "[unit] - [command parser]: splits documented examples" {
    const cases = [_]struct {
        cmd: []const u8,
        want: []const []const u8,
        borrow_cmd: bool = false,
        roundtrip: bool = false,
    }{
        .{ .cmd = "echo hello world", .want = &.{ "echo", "hello", "world" }, .borrow_cmd = true, .roundtrip = true },
        .{ .cmd = "myapp --path \"/home/user/my dir\"", .want = &.{ "myapp", "--path", "/home/user/my dir" }, .roundtrip = true },
        .{ .cmd = "sh -c 'echo hi there'", .want = &.{ "sh", "-c", "echo hi there" }, .roundtrip = true },
        .{ .cmd = "one two\\ three", .want = &.{ "one", "two three" }, .roundtrip = true },
        .{ .cmd = "echo'hello'", .want = &.{"echohello"}, .roundtrip = true },
        .{ .cmd = "prog '' x", .want = &.{ "prog", "", "x" }, .roundtrip = true },
        .{ .cmd = "prog \"\" x", .want = &.{ "prog", "", "x" }, .roundtrip = true },
        .{ .cmd = "  foo  bar  ", .want = &.{ "foo", "bar" } },
        .{ .cmd = "x \"a\nb\" y", .want = &.{ "x", "a\nb", "y" } },
        .{ .cmd = "cmd 'a\\b'", .want = &.{ "cmd", "a\\b" } },
        .{ .cmd = "x 'a\"b' y", .want = &.{ "x", "a\"b", "y" } },
        .{ .cmd = "a\\\"b", .want = &.{"a\"b"}, .roundtrip = true },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for (cases) |c| {
        var argv: std.ArrayList([]const u8) = .empty;

        try parseCommandLine(a, &argv, c.cmd);

        try std.testing.expectEqual(c.want.len, argv.items.len);
        for (c.want, argv.items) |w, got| try std.testing.expectEqualStrings(w, got);
        if (c.borrow_cmd) try expectBorrowedFrom(c.cmd, argv.items);
        if (c.roundtrip) try roundtripExpect(a, c.cmd);
    }
}

test "[failure] - [command parser]: reports invalid quotes and escapes" {
    const empty_cases = [_][]const u8{ "", "\t", " \t\r\n" };
    const fail_cases = [_]struct { cmd: []const u8, err: ParseError }{
        .{ .cmd = "say \"hi", .err = error.UnclosedDoubleQuote },
        .{ .cmd = "say 'hi", .err = error.UnclosedSingleQuote },
        .{ .cmd = "oops\\", .err = error.TrailingBackslash },
        .{ .cmd = "ok bad'", .err = error.UnclosedSingleQuote },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var argv: std.ArrayList([]const u8) = .empty;

    for (empty_cases) |cmd| {
        try std.testing.expectError(error.EmptyCommand, parseCommandLine(a, &argv, cmd));
    }
    for (fail_cases) |c| {
        try std.testing.expectError(c.err, parseCommandLine(a, &argv, c.cmd));
    }

    try std.testing.expectEqual(@as(usize, 0), argv.items.len);
}

test "[regression] - [reused argv]: clears earlier words after a parse error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var argv: std.ArrayList([]const u8) = .empty;

    try parseCommandLine(a, &argv, "a b");
    try std.testing.expectEqual(@as(usize, 2), argv.items.len);

    try std.testing.expectError(error.UnclosedSingleQuote, parseCommandLine(a, &argv, "broken '"));
    try std.testing.expectEqual(@as(usize, 0), argv.items.len);

    try parseCommandLine(a, &argv, "only");
    try std.testing.expectEqual(@as(usize, 1), argv.items.len);
    try std.testing.expectEqualStrings("only", argv.items[0]);
}

test "[unit] - [command parser]: handles quoting and joined words" {
    const cases = [_]struct {
        argv: []const []const u8,
        want_joined: ?[]const u8 = null,
    }{
        .{ .argv = &.{"it's"}, .want_joined = "\"it's\"" },
        .{ .argv = &.{"a'b\"c"} },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for (cases) |c| {
        const joined = try joinCommandLine(a, c.argv);

        if (c.want_joined) |want| try std.testing.expectEqualStrings(want, joined);

        var got: std.ArrayList([]const u8) = .empty;
        try parseCommandLine(a, &got, joined);
        try std.testing.expect(argvEqual(c.argv, got.items));
    }
}

test "[property] - [command parser]: reconstructs bounded random arguments" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x7e4a_c0de);
    const random = prng.random();
    var buf: [stress_input_cap]u8 = undefined;

    for (0..stress_rounds) |_| {
        const len = random.intRangeLessThan(usize, 0, buf.len + 1);
        random.bytes(buf[0..len]);
        roundtripBody(buf[0..len], gpa) catch |err| switch (err) {
            error.SkipZigTest => return,
            else => return err,
        };
    }
}

test "[fuzz] - [command parser]: preserves parsed arguments across reconstruction" {
    const Fuzz = struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            @disableInstrumentation();
            var buf: [fuzz_input_cap]u8 = undefined;
            const len = smith.sliceWeightedBytes(buf[0..], &fuzz_byte_weights);
            try roundtripBody(buf[0..len], std.testing.allocator);
        }
    };
    try std.testing.fuzz({}, Fuzz.run, .{
        .corpus = &.{
            "a",
            "a b",
            "'x'",
            "\"y\"",
            "one\\ two",
            "echo'hi'",
            "prog \"\" x",
        },
    });
}
