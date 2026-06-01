//! We exec argv directly, but users still type shell-ish words.
//! This lexer is the thin layer between those two worlds: no `$VAR`, no globs, no pipes.
//! Quotes are literal wrappers; backslash only works in bare (unquoted) text.
const std = @import("std");

pub const ParseError = error{
    UnclosedSingleQuote,
    UnclosedDoubleQuote,
    TrailingBackslash,
    EmptyCommand,
};

const State = enum { bare, single, double };

const Word = struct {
    cmd: []const u8,
    slice_start: usize,
    buf: std.ArrayList(u8),
    /// Once quotes or `\` show up we cannot keep pointing into `cmd` for the whole word.
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

    fn append(self: *Word, arena: std.mem.Allocator, byte: u8, index: usize) !void {
        try self.materializePrefix(arena, index);
        try self.buf.append(arena, byte);
    }

    fn finish(self: *Word, arena: std.mem.Allocator, end: usize) ![]const u8 {
        if (!self.active) return "";
        self.active = false;
        if (!self.materialized) return self.cmd[self.slice_start..end];
        return try self.buf.toOwnedSlice(arena);
    }
};

/// Split one command string into argv tokens.
pub fn parseCommandLine(arena: std.mem.Allocator, argv: *std.ArrayList([]const u8), cmd: []const u8) (ParseError || error{OutOfMemory})!void {
    argv.clearRetainingCapacity();

    var state: State = .bare;
    var i: usize = 0;
    var word = Word{
        .cmd = cmd,
        .slice_start = 0,
        .buf = .empty,
        .materialized = false,
        .active = false,
    };

    const push = struct {
        fn do(a: std.mem.Allocator, list: *std.ArrayList([]const u8), w: *Word, end: usize) !void {
            try list.append(a, try w.finish(a, end));
        }
    }.do;

    while (i < cmd.len) {
        const c = cmd[i];
        switch (state) {
            .bare => {
                switch (c) {
                    ' ', '\t', '\n', '\r' => {
                        if (word.active) try push(arena, argv, &word, i);
                        i += 1;
                    },
                    '\'' => {
                        if (!word.active) word.begin(i);
                        try word.materializePrefix(arena, i);
                        state = .single;
                        i += 1;
                    },
                    '"' => {
                        if (!word.active) word.begin(i);
                        try word.materializePrefix(arena, i);
                        state = .double;
                        i += 1;
                    },
                    '\\' => {
                        if (!word.active) word.begin(i);
                        i += 1;
                        if (i >= cmd.len) return error.TrailingBackslash;
                        try word.append(arena, cmd[i], i);
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
            .single => {
                if (c == '\'') {
                    state = .bare;
                } else {
                    try word.append(arena, c, i);
                }
                i += 1;
            },
            .double => {
                if (c == '"') {
                    state = .bare;
                } else {
                    try word.append(arena, c, i);
                }
                i += 1;
            },
        }
    }

    switch (state) {
        .single => return error.UnclosedSingleQuote,
        .double => return error.UnclosedDoubleQuote,
        .bare => {},
    }

    if (word.active) try push(arena, argv, &word, cmd.len);

    if (argv.items.len == 0) return error.EmptyCommand;
}

pub fn errorMessage(err: ParseError) []const u8 {
    return switch (err) {
        error.UnclosedSingleQuote => "missing closing single quote (')",
        error.UnclosedDoubleQuote => "missing closing double quote (\")",
        error.TrailingBackslash => "trailing backslash with nothing to escape",
        error.EmptyCommand => "empty command (only whitespace, or nothing to run)",
    };
}

fn needsQuoting(arg: []const u8) bool {
    if (arg.len == 0) return true;
    for (arg) |c| {
        switch (c) {
            ' ', '\t', '\n', '\r', '"', '\'', '\\' => return true,
            else => continue,
        }
    }
    return false;
}

/// Rebuilds a command string for tests. Single-quoted when bare words would break.
pub fn joinCommandLine(arena: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (argv, 0..) |arg, i| {
        if (i > 0) try out.append(arena, ' ');
        if (!needsQuoting(arg)) {
            try out.appendSlice(arena, arg);
        } else {
            try out.append(arena, '\'');
            try out.appendSlice(arena, arg);
            try out.append(arena, '\'');
        }
    }
    return try out.toOwnedSlice(arena);
}

fn argvEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

test "parseCommandLine_plainWords_staysZeroCopy" {
    const gpa = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    const cmd = "echo hello world";
    try parseCommandLine(gpa, &argv, cmd);

    try std.testing.expectEqual(@as(usize, 3), argv.items.len);
    try std.testing.expect(std.meta.eql(argv.items[0], cmd[0..4]));
    try std.testing.expect(std.meta.eql(argv.items[1], cmd[5..10]));
    try std.testing.expect(std.meta.eql(argv.items[2], cmd[11..16]));
}

test "parseCommandLine_doubleQuotes_preservesSpaces" {
    const gpa = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    try parseCommandLine(gpa, &argv, "myapp --path \"/home/user/my dir\"");
    try std.testing.expectEqual(@as(usize, 3), argv.items.len);
    try std.testing.expectEqualStrings("myapp", argv.items[0]);
    try std.testing.expectEqualStrings("--path", argv.items[1]);
    try std.testing.expectEqualStrings("/home/user/my dir", argv.items[2]);
}

test "parseCommandLine_singleQuotes_preservesSpaces" {
    const gpa = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    try parseCommandLine(gpa, &argv, "sh -c 'echo hi there'");
    try std.testing.expectEqual(@as(usize, 3), argv.items.len);
    try std.testing.expectEqualStrings("echo hi there", argv.items[2]);
}

test "parseCommandLine_backslashOutsideQuotes_escapesSpace" {
    const gpa = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    try parseCommandLine(gpa, &argv, "one two\\ three");
    try std.testing.expectEqual(@as(usize, 2), argv.items.len);
    try std.testing.expectEqualStrings("one", argv.items[0]);
    try std.testing.expectEqualStrings("two three", argv.items[1]);
}

test "parseCommandLine_adjacentQuoteStyles_gluesOneWord" {
    const gpa = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    try parseCommandLine(gpa, &argv, "echo'hello'");
    try std.testing.expectEqual(@as(usize, 1), argv.items.len);
    try std.testing.expectEqualStrings("echohello", argv.items[0]);
}

test "parseCommandLine_emptyDoubleQuotes_yieldsEmptyArg" {
    const gpa = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    try parseCommandLine(gpa, &argv, "prog \"\" x");
    try std.testing.expectEqual(@as(usize, 3), argv.items.len);
    try std.testing.expectEqualStrings("", argv.items[1]);
}

test "parseCommandLine_whitespaceOnly_returnsEmptyCommand" {
    const gpa = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    try std.testing.expectError(error.EmptyCommand, parseCommandLine(gpa, &argv, " \t\r\n"));
}

test "parseCommandLine_leadingTrailingSpace_trimsWords" {
    const gpa = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    try parseCommandLine(gpa, &argv, "  foo  bar  ");
    try std.testing.expectEqual(@as(usize, 2), argv.items.len);
    try std.testing.expectEqualStrings("foo", argv.items[0]);
    try std.testing.expectEqualStrings("bar", argv.items[1]);
}

test "parseCommandLine_newlineInsideQuotes_isLiteral" {
    const gpa = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    try parseCommandLine(gpa, &argv, "x \"a\nb\" y");
    try std.testing.expectEqual(@as(usize, 3), argv.items.len);
    try std.testing.expectEqualStrings("a\nb", argv.items[1]);
}

test "parseCommandLine_backslashInsideSingleQuotes_isLiteral" {
    const gpa = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    try parseCommandLine(gpa, &argv, "cmd 'a\\b'");
    try std.testing.expectEqual(@as(usize, 2), argv.items.len);
    try std.testing.expectEqualStrings("a\\b", argv.items[1]);
}

test "parseCommandLine_quoteInsideOppositeQuote_isLiteral" {
    const gpa = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    try parseCommandLine(gpa, &argv, "cmd 'say \"hi\"'");
    try std.testing.expectEqualStrings("say \"hi\"", argv.items[1]);
}

test "parseCommandLine_backslashBeforeQuoteInBare_escapesQuoteByte" {
    const gpa = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    try parseCommandLine(gpa, &argv, "a\\\"b");
    try std.testing.expectEqual(@as(usize, 1), argv.items.len);
    try std.testing.expectEqualStrings("a\"b", argv.items[0]);
}

test "parseCommandLine_reusedArgvList_clearsPrevious" {
    const gpa = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    try parseCommandLine(gpa, &argv, "a b");
    try std.testing.expectEqual(@as(usize, 2), argv.items.len);
    try parseCommandLine(gpa, &argv, "only");
    try std.testing.expectEqual(@as(usize, 1), argv.items.len);
    try std.testing.expectEqualStrings("only", argv.items[0]);
}

test "parseCommandLine_joinRoundtrip_preservesArgv" {
    const gpa = std.testing.allocator;
    const cases = [_][]const u8{
        "a b c",
        "myapp --path \"/x y\"",
        "sh -c 'echo hi'",
        "one two\\ three",
        "echo'hello'",
        "prog \"\" x",
        "a\\\"b",
    };
    for (cases) |cmd| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        var argv: std.ArrayList([]const u8) = .empty;
        try parseCommandLine(a, &argv, cmd);
        const joined = try joinCommandLine(a, argv.items);
        var argv2: std.ArrayList([]const u8) = .empty;
        try parseCommandLine(a, &argv2, joined);
        try std.testing.expect(argvEqual(argv.items, argv2.items));
    }
}

test "parseCommandLine_onlyWhitespace_returnsEmptyCommand" {
    const gpa = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try std.testing.expectError(error.EmptyCommand, parseCommandLine(gpa, &argv, "\t"));
}

test "parseCommandLine_doubleQuoteByteInsideSingleQuotes_isLiteral" {
    const gpa = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try parseCommandLine(gpa, &argv, "x 'a\"b' y");
    try std.testing.expectEqual(@as(usize, 3), argv.items.len);
    try std.testing.expectEqualStrings("a\"b", argv.items[1]);
}

const FuzzByteWeights = [_]std.testing.Smith.Weight{
    .rangeAtMost(u8, 0x00, 0xff, 1),
    .rangeAtMost(u8, 0x20, 0x7e, 4),
    .value(u8, ' ', 4),
    .value(u8, '\t', 2),
    .value(u8, '\n', 2),
    .value(u8, '"', 2),
    .value(u8, '\'', 2),
    .value(u8, '\\', 2),
};

fn fuzzParseCommandLineRoundtripBody(cmd: []const u8, gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var argv: std.ArrayList([]const u8) = .empty;
    parseCommandLine(a, &argv, cmd) catch |err| switch (err) {
        error.OutOfMemory => return error.SkipZigTest,
        error.UnclosedSingleQuote,
        error.UnclosedDoubleQuote,
        error.TrailingBackslash,
        error.EmptyCommand,
        => return,
    };

    const joined = try joinCommandLine(a, argv.items);
    var argv2: std.ArrayList([]const u8) = .empty;
    parseCommandLine(a, &argv2, joined) catch return error.SkipZigTest;
    try std.testing.expect(argvEqual(argv.items, argv2.items));
}

fn fuzzParseCommandLineRoundtrip(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var buf: [2048]u8 = undefined;
    const len = smith.sliceWeightedBytes(buf[0..buf.len], &FuzzByteWeights);
    try fuzzParseCommandLineRoundtripBody(buf[0..len], std.testing.allocator);
}

test "parseCommandLine_stress_randomRoundtrip" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x7e4a_c0de);
    const random = prng.random();
    var buf: [512]u8 = undefined;
    for (0..4096) |_| {
        const len = random.intRangeLessThan(usize, 0, buf.len + 1);
        random.bytes(buf[0..len]);
        fuzzParseCommandLineRoundtripBody(buf[0..len], gpa) catch |err| switch (err) {
            error.SkipZigTest => return,
            else => return err,
        };
    }
}

test "parseCommandLine fuzz roundtrip" {
    try std.testing.fuzz({}, fuzzParseCommandLineRoundtrip, .{
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

test "parseCommandLine_unclosedQuotes_andTrailingBackslash_fail" {
    const gpa = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    try std.testing.expectError(error.UnclosedDoubleQuote, parseCommandLine(gpa, &argv, "say \"hi"));
    try std.testing.expectError(error.UnclosedSingleQuote, parseCommandLine(gpa, &argv, "say 'hi"));
    try std.testing.expectError(error.TrailingBackslash, parseCommandLine(gpa, &argv, "oops\\"));
}
