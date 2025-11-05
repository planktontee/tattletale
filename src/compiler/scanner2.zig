const std = @import("std");
const regent = @import("regent");
const Writer = std.Io.Writer;
const assert = std.debug.assert;
const Range = @import("range.zig");
const Allocator = std.mem.Allocator;

pub const Diagnostics = struct {
    allocator: Allocator,
    idx: *const usize,
    pattern: []const u8,
    buff: ?[]u8 = null,
    message: ?[]const u8 = null,

    pub const MakeBuff = Allocator.Error;
    pub fn makeBuff(self: *@This(), size: usize) MakeBuff![]u8 {
        if (self.buff) |buff| {
            if (buff.len <= size) {
                return buff[0..size];
            } else {
                self.buff = self.allocator.remap(buff, size) orelse return Allocator.Error.OutOfMemory;
                return self.buff.?;
            }
        } else {
            self.buff = try self.allocator.alloc(u8, size);
            return self.buff.?;
        }
    }

    pub fn printRaise(self: *const @This(), e: anyerror) anyerror!noreturn {
        std.debug.print("{s}\n", .{self.message.?});
        return e;
    }

    pub fn deinit(self: *@This()) void {
        if (self.buff) |buff| {
            self.allocator.free(buff);
        }
        self.buff = undefined;
    }
};

pub fn initWithDiag(
    self: *@This(),
    allocator: Allocator,
    diag: *Diagnostics,
    pattern: []const u8,
) !void {
    self.* = .{
        .pattern = pattern,
        .allocator = allocator,
        .tokens = try std.ArrayListUnmanaged(*Token).initCapacity(allocator, 8),
    };
    diag.* = .{
        .allocator = allocator,
        .idx = &self.i,
        .pattern = pattern,
    };
    self.diagnostics = diag;
}

pub const Group = struct {
    n: u16,
    tokens: []const *Token,
};

pub const Repeatable = struct {
    range: *Range,
    token: *Token,
    flavour: RepeatableFlavour,
};

pub const RepeatableFlavour = enum {
    greedy,
    lazy,
};

pub const Token = union(enum) {
    group0: []const *Token,
    group: *Group,
    literal: []const u8,
    repeatable: *Repeatable,
};

pub const TokenTag = @typeInfo(Token).@"union".tag_type.?;

state: State = .init,
pattern: []const u8,
i: usize = 0,
diagnostics: ?*Diagnostics = null,
allocator: Allocator,

tokens: std.ArrayListUnmanaged(*Token),
currToken: usize = 0,

startIdx: usize = 0,

pub const Error = error{
    TBA,

    EmptyPattern,
    PrematureEnd,

    NestedQuantifier,

    Bad2ByteUTF8Start,
    InvalidUTF8Byte1,
} ||
    std.mem.Allocator.Error ||
    Range.Error ||
    Diagnostics.MakeBuff ||
    std.fmt.BufPrintError;

const State = union(enum) {
    init,
    detectToken,

    literalMatch,

    repeatTokenMatch,
    postRepeat,

    end,
};

pub fn collect(self: *@This()) Error!*Token {
    // TODO: move .startIdx to len so asserts catch it when match is done
    stateLoop: while (true) {
        switch (self.state) {
            .init => {
                if (self.finished()) return Error.EmptyPattern;
                _ = try self.punchToken(.group0);

                self.state = .detectToken;

                continue :stateLoop;
            },
            .detectToken => {
                if (self.finished()) {
                    self.state = .end;
                    continue :stateLoop;
                }
                switch (self.peek()) {
                    '$',
                    '^',
                    '.',
                    '(',
                    '[',
                    '|',
                    '\\',
                    => return Error.TBA,

                    // Non-printables
                    0x00...0x1F,
                    // [ !"#]
                    0x20...0x23,
                    // [%&']
                    0x25...0x27,
                    // [,-]
                    0x2C...0x2D,
                    // 0x2F
                    '/',
                    // 0x30 - 0x39
                    '0'...'9',
                    // [:;<=>]
                    0x3A...0x3E,
                    // 0x40
                    '@',
                    // 0x41 - 0x5A
                    'A'...'Z',
                    // 0x5F
                    '_',
                    // 0x60
                    '`',
                    // 0x61 - 7A
                    'a'...'z',
                    // 0x7E
                    '~',
                    0x7F,
                    => {
                        self.state = .literalMatch;
                        self.startIdx = self.i;
                        self.i += 1;
                        continue :stateLoop;
                    },

                    // invalid continuation in utf8 in this state
                    0x80...0xBF => return Error.Bad2ByteUTF8Start,
                    // Those violate shortest encoding rules for 2 bytes
                    0xC0...0xC1 => return Error.TBA,
                    // 2 bytes utf8
                    0xC2...0xDF => return Error.TBA,
                    // 3 bytes utf8
                    0xE0...0xEF => return Error.TBA,
                    // 4 bytes utf8
                    0xF0...0xF4 => return Error.TBA,
                    0xF5...0xFF => return Error.InvalidUTF8Byte1,

                    // Unmatched errors
                    ')',
                    ']',
                    '{',
                    '}',
                    '*',
                    '+',
                    '?',
                    => return Error.SyntaxError,
                }
            },
            .literalMatch => {
                literalLoop: while (true) {
                    if (self.finished()) {
                        const literal = try self.punchToken(.literal);
                        literal.literal = self.slice();
                        self.state = .end;
                        continue :stateLoop;
                    }
                    switch (self.peek()) {
                        // ranges
                        '{',
                        '?',
                        '*',
                        '+',
                        => {
                            try self.punchLiterals();
                            self.state = .repeatTokenMatch;
                            continue :stateLoop;
                        },

                        // Unmatched errors
                        '}',
                        ']',
                        => return Error.SyntaxError,

                        // TODO: decide what to do with utf8 in middle of literal
                        0x80...0xFF => return Error.TBA,
                        // TODO: decide what to do with scaping in middle of literal
                        '\\' => return Error.TBA,

                        '$',
                        '(',
                        ')',
                        '[',
                        '^',
                        '|',
                        => {
                            try self.punchLiterals();
                            self.state = .detectToken;
                            continue :stateLoop;
                        },

                        else => {
                            self.consume();
                            continue :literalLoop;
                        },
                    }
                }
            },
            .repeatTokenMatch => {
                switch (self.peek()) {
                    '{' => return Error.TBA,
                    '?' => {
                        const repeatable = try self.makeRepeatable();
                        repeatable.range.* = .{ .min = 0, .max = 1 };
                        self.consume();
                        self.state = .postRepeat;
                        continue :stateLoop;
                    },
                    '*' => {
                        const repeatable = try self.makeRepeatable();
                        repeatable.range.* = .{ .min = 0, .max = Range.Unlimited };
                        self.consume();
                        self.state = .postRepeat;
                        continue :stateLoop;
                    },
                    '+' => {
                        const repeatable = try self.makeRepeatable();
                        repeatable.range.* = .{ .min = 1, .max = Range.Unlimited };
                        self.consume();
                        self.state = .postRepeat;
                        continue :stateLoop;
                    },
                    else => return Error.SyntaxError,
                }
            },
            .postRepeat => {
                switch (self.peek()) {
                    '?' => {
                        const last = self.lastTokenAs(.repeatable);
                        last.repeatable.flavour = .lazy;
                        self.consume();
                        continue :stateLoop;
                    },
                    '{',
                    '*',
                    => return Error.NestedQuantifier,
                    // Possessive quantifier
                    '+' => return Error.TBA,
                    else => {
                        self.state = .detectToken;
                        continue :stateLoop;
                    },
                }
            },
            .end => {
                if (!self.finished()) return Error.PrematureEnd;
                self.finishGroup0();
                return self.group0();
            },
        }
        return Error.TBA;
    }
    unreachable;
}

test "test collect" {
    const t = std.testing;
    const tt = regent.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const pattern: []const u8 = "ab+cd?efgh*ij+?klmn*?opq";
    var scanner: Scanner = undefined;
    var diag: Diagnostics = undefined;
    defer diag.deinit();
    try scanner.initWithDiag(allocator, &diag, pattern);
    const group0T = try scanner.collect();

    try tt.expectEqualDeep(*const Token, &.{
        // TODO: add something in regent to make this not stupid
        .group0 = &.{
            @constCast(@as(*const Token, &.{ .literal = "a" })),
            @constCast(@as(*const Token, &.{
                .repeatable = @constCast(@as(*const Repeatable, &.{
                    .range = @constCast(@as(*const Range, &.{
                        .min = 1,
                        .max = Range.Unlimited,
                    })),
                    .token = @constCast(@as(*const Token, &.{
                        .literal = "b",
                    })),
                    .flavour = .greedy,
                })),
            })),
            @constCast(@as(*const Token, &.{ .literal = "c" })),
            @constCast(@as(*const Token, &.{
                .repeatable = @constCast(@as(*const Repeatable, &.{
                    .range = @constCast(@as(*const Range, &.{
                        .min = 0,
                        .max = 1,
                    })),
                    .token = @constCast(@as(*const Token, &.{
                        .literal = "d",
                    })),
                    .flavour = .greedy,
                })),
            })),
            @constCast(@as(*const Token, &.{ .literal = "efg" })),
            @constCast(@as(*const Token, &.{
                .repeatable = @constCast(@as(*const Repeatable, &.{
                    .range = @constCast(@as(*const Range, &.{
                        .min = 0,
                        .max = Range.Unlimited,
                    })),
                    .token = @constCast(@as(*const Token, &.{
                        .literal = "h",
                    })),
                    .flavour = .greedy,
                })),
            })),
            @constCast(@as(*const Token, &.{ .literal = "i" })),
            @constCast(@as(*const Token, &.{
                .repeatable = @constCast(@as(*const Repeatable, &.{
                    .range = @constCast(@as(*const Range, &.{
                        .min = 1,
                        .max = Range.Unlimited,
                    })),
                    .token = @constCast(@as(*const Token, &.{
                        .literal = "j",
                    })),
                    .flavour = .lazy,
                })),
            })),
            @constCast(@as(*const Token, &.{ .literal = "klm" })),
            @constCast(@as(*const Token, &.{
                .repeatable = @constCast(@as(*const Repeatable, &.{
                    .range = @constCast(@as(*const Range, &.{
                        .min = 0,
                        .max = Range.Unlimited,
                    })),
                    .token = @constCast(@as(*const Token, &.{
                        .literal = "n",
                    })),
                    .flavour = .lazy,
                })),
            })),
            @constCast(@as(*const Token, &.{ .literal = "opq" })),
        },
    }, group0T);
}

pub inline fn makeRepeatable(self: *Scanner) Allocator.Error!*Repeatable {
    const range = try self.allocator.create(Range);

    const lastToken = self.popToken();
    const repeatable = try self.allocator.create(Repeatable);
    repeatable.* = .{
        .range = range,
        .token = lastToken,
        .flavour = .greedy,
    };

    const repeatableT = try self.punchToken(.repeatable);
    repeatableT.repeatable = repeatable;

    return repeatable;
}

pub inline fn punchLiterals(self: *Scanner) Allocator.Error!void {
    const sequence = try self.punchToken(.literal);
    sequence.literal = self.sliceTo(self.i - 1);

    const literal = try self.punchToken(.literal);
    literal.literal = self.sliceFrom(self.i - 1);
}

pub inline fn slice(self: *Scanner) []const u8 {
    assert(self.startIdx <= self.i);
    assert(self.i <= self.pattern.len);

    return self.pattern[self.startIdx..self.i];
}

pub inline fn sliceTo(self: *Scanner, end: usize) []const u8 {
    assert(self.startIdx <= end);
    assert(end <= self.pattern.len);

    return self.pattern[self.startIdx..end];
}

pub inline fn finishGroup0(self: *Scanner) void {
    self.group0().group0 = self.tokens.items[1..];
}

pub inline fn lastTokenAs(self: *Scanner, comptime tokenTag: TokenTag) *Token {
    assert(self.currToken > 0);
    const token = self.tokens.items[self.currToken - 1];
    // Should this be an actual error check?
    assert(token.* == tokenTag);
    return token;
}

pub inline fn group0(self: *Scanner) *Token {
    assert(self.tokens.items.len > 0);
    const group0Token = self.tokens.items[0];
    assert(group0Token.* == .group0);
    return group0Token;
}

pub inline fn punchToken(self: *Scanner, comptime tokenTag: TokenTag) Allocator.Error!*Token {
    const newToken = try self.allocator.create(Token);
    try self.tokens.append(self.allocator, newToken);
    self.currToken += 1;
    newToken.* = @unionInit(Token, @tagName(tokenTag), undefined);
    return newToken;
}

pub inline fn popToken(self: *Scanner) *Token {
    // Cannot pop group0
    assert(self.currToken > 1);
    self.currToken -= 1;
    return self.tokens.pop().?;
}

pub inline fn finished(self: *const Scanner) bool {
    return self.i >= self.pattern.len;
}

pub inline fn hasNext(self: *const Scanner) bool {
    return self.i < self.pattern.len;
}

pub inline fn consume(self: *Scanner) void {
    assert(self.hasNext());
    self.i += 1;
}

pub inline fn peek(self: *const Scanner) u8 {
    assert(self.hasNext());
    return self.pattern[self.i];
}

pub inline fn sliceFrom(self: *const Scanner, start: usize) []const u8 {
    assert(start < self.pattern.len);
    assert(start < self.i);
    return self.pattern[start..self.i];
}

pub inline fn ensureByte(self: *const Scanner) ConsumeError!void {
    if (self.finished()) return Error.UnexpectedEnd;
}

pub const ConsumeError = error{
    UnexpectedEnd,
};

pub fn consumeWhite(self: *Scanner) ConsumeError!void {
    while (self.hasNext()) : (self.consume()) {
        switch (self.peek()) {
            ' ',
            '\t',
            => continue,
            else => break,
        }
    } else return ConsumeError.UnexpectedEnd;
}

pub fn consumeDigits(self: *Scanner) ConsumeError!void {
    while (self.hasNext()) : (self.consume()) {
        switch (self.peek()) {
            '0'...'9',
            => continue,
            else => break,
        }
    } else return ConsumeError.UnexpectedEnd;
}

const Scanner = @This();

pub fn report(self: *Scanner, e: Error, comptime message: []const u8) Error!noreturn {
    if (self.diagnostics == null) return e;
    var diag = self.diagnostics.?;
    const buff: []u8 = try diag.makeBuff(4098);
    diag.message = try std.fmt.bufPrint(
        buff,
        "{s} - {s}<{c}>{s} - " ++ message,
        .{
            @errorName(e),
            if (self.i == 0) "" else self.pattern[0..self.i],
            if (self.i == 0 or self.finished()) 0x00 else self.pattern[self.i],
            if (self.i + 1 >= self.pattern.len) "" else self.pattern[self.i + 1 ..],
        },
    );
    return e;
}
