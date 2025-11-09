const std = @import("std");
const regent = @import("regent");
const asPtrConCast = regent.ergo.asPtrConCast;
const Writer = std.Io.Writer;
const assert = std.debug.assert;
const Range = @import("range.zig");
const Literal = @import("literal.zig");
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

pub fn init(
    self: *@This(),
    allocator: Allocator,
    pattern: []const u8,
) !void {
    try self.initAll(allocator, null, pattern);
}

pub fn initAll(
    self: *@This(),
    allocator: Allocator,
    diagnostics: ?*Diagnostics,
    pattern: []const u8,
) !void {
    self.* = .{
        .allocator = allocator,
        .pattern = pattern,
        .tokens = try .initCapacity(allocator, 8),
        .stack = try .initCapacity(allocator, 8),
        .diagnostics = diagnostics,
    };
}

pub fn initWithDiag(
    self: *@This(),
    allocator: Allocator,
    diagnostics: *Diagnostics,
    pattern: []const u8,
) !void {
    diagnostics.* = .{
        .allocator = allocator,
        .idx = &self.i,
        .pattern = pattern,
    };
    try self.initAll(allocator, diagnostics, pattern);
}

pub const Group = struct {
    n: u16,
    tokens: []const *const Token,
};

pub const OpenGroup = struct {
    n: u16,
    start: usize,

    pub fn finishGroup(self: *OpenGroup, scanner: *Scanner) Allocator.Error!*const Token {
        const tokens = try scanner.ownedTokenSliceFrom(self.start);
        const group = try scanner.punchGroup();
        group.* = .{
            .n = self.n,
            .tokens = tokens,
        };
        return scanner.lastTokenAs(.group);
    }
};

pub const Repeatable = struct {
    range: *const Range,
    token: *const Token,
    flavour: RepeatableFlavour,
};

pub const RepeatableFlavour = enum {
    greedy,
    lazy,
};

pub const Token = union(enum) {
    group0: []const *const Token,
    group: *const Group,
    literal: []const u8,
    repeatable: *Repeatable,
};

pub const TokenTag = @typeInfo(Token).@"union".tag_type.?;

pattern: []const u8,
i: usize = 0,
diagnostics: ?*Diagnostics = null,
allocator: Allocator,

tokens: std.ArrayListUnmanaged(*const Token),
stack: std.ArrayListUnmanaged(*OpenGroup),
currGroup: u16 = 0,

startIdx: usize = 0,

pub const Error = error{
    TBA,
    UnhandledToken,

    EmptyPattern,
    PrematureEnd,

    NestedQuantifier,

    Bad2ByteUTF8Start,
    InvalidUTF8Byte1,

    UnmatchedGroup,
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

pub fn collectWithReport(self: *@This()) Error!*const Token {
    const token = self.collect() catch |e| {
        try self.report(e, "Failed IR");
    };
    return token;
}

pub fn collect(self: *@This()) Error!*const Token {
    stateLoop: switch (State.init) {
        .init => {
            if (self.finished()) return Error.EmptyPattern;
            assert(self.stackSize() == 0);

            _ = try self.startGroup(0);
            continue :stateLoop .detectToken;
        },
        .detectToken => {
            if (self.finished()) continue :stateLoop .end;
            switch (self.peek()) {
                '$',
                '^',
                '.',
                '[',
                '|',
                '\\',
                ']',
                => return Error.TBA,

                '(',
                => {
                    try self.startNextGroup();
                    self.consume();
                    continue :stateLoop .detectToken;
                },

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
                    self.tagStart();
                    self.consume();
                    continue :stateLoop .literalMatch;
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
                => {
                    if (self.stackSize() <= 1) return Error.UnmatchedGroup;
                    _ = try self.finishGroup();
                    self.consume();
                    continue :stateLoop .detectToken;
                },
                '{',
                '*',
                '+',
                '?',
                => {
                    if (self.tokenCount() == 0) return Error.SyntaxError;
                    if (self.lastToken().* != .group) return Error.SyntaxError;
                    continue :stateLoop .repeatTokenMatch;
                },

                '}',
                => return Error.SyntaxError,
            }
        },
        .literalMatch => {
            literalLoop: while (true) {
                if (self.finished()) {
                    try self.punchLiteral();
                    continue :stateLoop .end;
                }
                switch (self.peek()) {
                    // ranges
                    '{',
                    '?',
                    '*',
                    '+',
                    => {
                        try self.punchLiteralSeqAndTail();
                        continue :stateLoop .repeatTokenMatch;
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
                        try self.punchLiteral();
                        continue :stateLoop .detectToken;
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
                '{' => {
                    const range = try self.allocator.create(Range);
                    try range.parseRange(self);
                    try self.makeRepeatable(range);
                    continue :stateLoop .postRepeat;
                },
                '?' => {
                    try self.makeRepeatable(Range.Optional);
                    self.consume();
                    continue :stateLoop .postRepeat;
                },
                '*' => {
                    try self.makeRepeatable(Range.Any);
                    self.consume();
                    continue :stateLoop .postRepeat;
                },
                '+' => {
                    try self.makeRepeatable(Range.OneOrMore);
                    self.consume();
                    continue :stateLoop .postRepeat;
                },
                else => return Error.SyntaxError,
            }
        },
        .postRepeat => {
            if (self.finished()) continue :stateLoop .end;

            switch (self.peek()) {
                '?' => {
                    const last = self.lastTokenAs(.repeatable);
                    last.repeatable.flavour = .lazy;
                    self.consume();
                    continue :stateLoop .detectToken;
                },
                '{',
                '*',
                => return Error.NestedQuantifier,
                // Possessive quantifier
                '+' => return Error.TBA,
                else => continue :stateLoop .detectToken,
            }
        },
        .end => {
            if (!self.finished()) return Error.PrematureEnd;
            if (self.stackSize() > 1) return Error.UnmatchedGroup;
            return try self.finishGroup();
        },
    }
    return Error.UnhandledToken;
}

pub inline fn makeRepeatable(self: *Scanner, range: *const Range) Allocator.Error!void {
    const last = self.popToken();
    const repeatable = try self.allocator.create(Repeatable);
    repeatable.* = .{
        .range = range,
        .token = last,
        .flavour = .greedy,
    };

    const repeatableT = try self.punchToken(.repeatable);
    repeatableT.repeatable = repeatable;
}

pub inline fn punchLiteralSeqAndTail(self: *Scanner) Allocator.Error!void {
    // NOTE: this will not work with utf8
    switch (self.i - self.startIdx) {
        0 => {
            assert(false);
        },
        1 => {},
        2 => {
            const literal = Literal.of(self.peekAt(self.startIdx));
            try self.appendToken(literal);
        },
        else => {
            const sequence = try self.punchToken(.literal);
            sequence.literal = self.sliceTo(self.i - 1);
        },
    }

    const literal = Literal.of(self.peekPrev());
    try self.appendToken(literal);
}

pub inline fn punchLiteral(self: *Scanner) Allocator.Error!void {
    switch (self.i - self.startIdx) {
        0 => {
            assert(false);
        },
        1 => {
            const literal = Literal.of(self.peekAt(self.startIdx));
            try self.appendToken(literal);
        },
        else => {
            const sequence = try self.punchToken(.literal);
            sequence.literal = self.slice();
        },
    }
}

pub inline fn slice(self: *const Scanner) []const u8 {
    assert(self.startIdx <= self.i);
    assert(self.i <= self.pattern.len);

    return self.pattern[self.startIdx..self.i];
}

pub inline fn sliceTo(self: *const Scanner, end: usize) []const u8 {
    assert(self.startIdx <= end);
    assert(end <= self.pattern.len);

    return self.pattern[self.startIdx..end];
}

pub inline fn sliceFrom(self: *const Scanner, start: usize) []const u8 {
    assert(start < self.pattern.len);
    assert(start < self.i);
    return self.pattern[start..self.i];
}

pub inline fn ownedTokenSliceFrom(self: *Scanner, start: usize) Allocator.Error![]const *const Token {
    const newTokenSlice = try self.allocator.alloc(*const Token, self.tokenCount() - start);
    @memcpy(newTokenSlice, self.tokens.items[start..]);
    const targetLen = self.tokenCount() - newTokenSlice.len;
    self.tokens.shrinkRetainingCapacity(targetLen);
    assert(self.tokenCount() == targetLen);
    return newTokenSlice;
}

pub inline fn popNTokens(self: *Scanner, lastN: usize) void {
    assert(self.tokenCount() >= lastN);
    self.tokens.shrinkRetainingCapacity(self.tokenCount() - lastN);
}

pub inline fn finishGroup(self: *Scanner) Allocator.Error!*const Token {
    assert(self.stack.items.len > 0);
    const openGroup = self.stack.pop().?;
    return try openGroup.finishGroup(self);
}

pub inline fn lastToken(self: *Scanner) *const Token {
    assert(self.tokenCount() > 0);
    return self.tokens.items[self.currTokenIdx()];
}

pub inline fn lastTokenAs(self: *Scanner, comptime tokenTag: TokenTag) *const Token {
    const token = self.lastToken();
    // Should this be an actual error check?
    assert(token.* == tokenTag);
    return token;
}

pub inline fn punchToken(self: *Scanner, comptime tokenTag: TokenTag) Allocator.Error!*Token {
    const newToken = try self.allocator.create(Token);
    newToken.* = @unionInit(Token, @tagName(tokenTag), undefined);
    try self.appendToken(newToken);
    return newToken;
}

pub inline fn punchGroup(self: *Scanner) Allocator.Error!*Group {
    const group = try self.allocator.create(Group);
    const newToken = try self.allocator.create(Token);
    newToken.* = .{ .group = group };
    try self.appendToken(newToken);
    return group;
}

pub inline fn startNextGroup(self: *Scanner) Error!void {
    try self.startGroup(self.currGroup + 1);
}

pub inline fn startGroup(self: *Scanner, n: u16) Error!void {
    const openGroup = try self.allocator.create(OpenGroup);
    openGroup.* = .{
        .n = n,
        .start = self.tokenCount(),
    };
    try self.stackGroup(openGroup);
}

pub inline fn stackGroup(self: *Scanner, openGroup: *OpenGroup) Allocator.Error!void {
    try self.stack.append(self.allocator, openGroup);
    self.currGroup = openGroup.n;
}

pub inline fn appendToken(self: *Scanner, token: *const Token) Allocator.Error!void {
    try self.tokens.append(self.allocator, token);
}

pub inline fn popToken(self: *Scanner) *const Token {
    assert(self.currTokenIdx() > 0);
    return self.tokens.pop().?;
}

pub inline fn stackSize(self: *const Scanner) usize {
    return self.stack.items.len;
}

pub inline fn tokenCount(self: *const Scanner) usize {
    return self.tokens.items.len;
}

pub inline fn currTokenIdx(self: *const Scanner) usize {
    const tokensLen = self.tokenCount();
    assert(tokensLen > 0);
    return tokensLen - 1;
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

pub inline fn tagStart(self: *Scanner) void {
    self.startIdx = self.i;
}

pub inline fn peekPrev(self: *const Scanner) u8 {
    return self.peekAt(self.i - 1);
}

pub inline fn peekAt(self: *const Scanner, i: usize) u8 {
    assert(i >= 0);
    assert(i < self.pattern.len);
    return self.pattern[i];
}

pub inline fn peek(self: *const Scanner) u8 {
    assert(self.hasNext());
    return self.pattern[self.i];
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
            if (self.i == 0) "" else self.slice(),
            if (self.i == 0 or self.finished()) 0x00 else self.peek(),
            if (self.i + 1 >= self.pattern.len) "" else self.pattern[self.i + 1 ..],
        },
    );
    return e;
}
