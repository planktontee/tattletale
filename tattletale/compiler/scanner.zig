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

pub const TokenTag = @typeInfo(RgxToken).@"union".tag_type.?;

pattern: []const u8,
i: usize = 0,
diagnostics: ?*Diagnostics = null,
allocator: Allocator,

tokens: []*const RgxToken,
tokenI: usize = 0,

groupCount: u16 = 0,
finishedGroups: u16 = 0,

startIdx: usize = 0,

pub fn init(
    self: *@This(),
    allocator: Allocator,
    pattern: []const u8,
) !void {
    try self.initAll(allocator, null, pattern);
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

fn initAll(
    self: *@This(),
    allocator: Allocator,
    diagnostics: ?*Diagnostics,
    pattern: []const u8,
) !void {
    self.* = .{
        .allocator = allocator,
        .pattern = pattern,
        .tokens = try allocator.alloc(*const RgxToken, pattern.len + 2),
        .diagnostics = diagnostics,
    };
}

pub const Quantifier = struct {
    range: *const Range,
    flavour: QuantifierType,

    pub fn format(
        self: *const @This(),
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        if (self.range == Range.Any) {
            try w.writeAll("any");
        } else if (self.range == Range.OneOrMore) {
            try w.writeAll("oneOrMore");
        } else if (self.range == Range.Optional) {
            try w.writeAll("optional");
            return;
        } else {
            try w.print("{d}..{d}", .{ self.range.min, self.range.max });
        }
        try w.print(" {s}", .{@tagName(self.flavour)});
    }
};

pub const QuantifierType = enum {
    greedy,
    lazy,
};

pub const RgxToken = union(enum) {
    group: u16,
    groupEnd,

    literal: []const u8,

    quantifier: *Quantifier,

    pub fn format(
        self: *const @This(),
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self.*) {
            inline else => {
                try w.writeAll(@tagName(self.*));
            },
        }

        switch (self.*) {
            .group => |n| try w.print(" {d}", .{n}),
            .literal => |lit| try w.print(" '{s}'", .{lit}),
            .groupEnd,
            => {},
            inline else => |t| try w.print(" {f}", .{t}),
        }
    }
};

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

pub fn collectWithReport(self: *@This()) Error![]*const RgxToken {
    return self.collect() catch |e| {
        try self.report(e, "Scan error: ");
    };
}

pub fn collect(self: *@This()) Error![]*const RgxToken {
    stateLoop: switch (State.init) {
        .init => {
            if (self.finished()) return Error.EmptyPattern;
            assert(self.groupCount == 0);

            try self.startNextGroup();
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
                    if (!self.hasOpenGroups()) return Error.UnmatchedGroup;
                    try self.finishGroup();
                    self.consume();
                    continue :stateLoop .detectToken;
                },
                '{',
                '*',
                '+',
                '?',
                => {
                    if (!self.lastIsRepeatable()) return Error.SyntaxError;
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
                    try self.makeQuantifier(range);
                    continue :stateLoop .postRepeat;
                },
                '?' => {
                    try self.makeQuantifier(Range.Optional);
                    self.consume();
                    continue :stateLoop .postRepeat;
                },
                '*' => {
                    try self.makeQuantifier(Range.Any);
                    self.consume();
                    continue :stateLoop .postRepeat;
                },
                '+' => {
                    try self.makeQuantifier(Range.OneOrMore);
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
                    const last = self.lastTokenAs(.quantifier);
                    last.quantifier.flavour = .lazy;
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
            if (self.hasOpenGroups()) return Error.UnmatchedGroup;
            try self.finishGroup0();
            assert(self.finishedGroups == self.groupCount);
            return self.collectTokens();
        },
    }
    return Error.UnhandledToken;
}

pub fn collectTokens(self: *const Scanner) []*const RgxToken {
    return self.tokens[0..self.tokenI];
}

pub fn makeQuantifier(self: *Scanner, range: *const Range) Allocator.Error!void {
    assert(self.tokenCount() > 1);

    const last = self.tokens[self.tokenI - 1];
    const quantifier = try self.allocator.create(Quantifier);
    quantifier.* = .{
        .range = range,
        .flavour = .greedy,
    };
    const quantifierT = try self.punchToken(.quantifier);
    quantifierT.quantifier = quantifier;

    switch (last.*) {
        .groupEnd,
        .literal,
        => {},
        .group,
        .quantifier,
        => assert(false),
    }
}

pub fn lastIsRepeatable(self: *const Scanner) bool {
    assert(self.tokenCount() > 0);
    return switch (self.lastToken().*) {
        .groupEnd,
        .literal,
        => true,
        .group,
        .quantifier,
        => false,
    };
}

pub fn punchLiteralSeqAndTail(self: *Scanner) Allocator.Error!void {
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
    self.startIdx = self.i;
}

pub fn punchLiteral(self: *Scanner) Allocator.Error!void {
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
    self.startIdx = self.i;
}

pub fn slice(self: *const Scanner) []const u8 {
    assert(self.startIdx <= self.i);
    assert(self.i <= self.pattern.len);

    return self.pattern[self.startIdx..self.i];
}

pub fn sliceTo(self: *const Scanner, end: usize) []const u8 {
    assert(self.startIdx <= end);
    assert(end <= self.pattern.len);

    return self.pattern[self.startIdx..end];
}

pub fn sliceFrom(self: *const Scanner, start: usize) []const u8 {
    assert(start < self.pattern.len);
    assert(start < self.i);
    return self.pattern[start..self.i];
}

pub fn finishGroup(self: *Scanner) Allocator.Error!void {
    assert(self.finishedGroups < self.groupCount - 1);
    _ = try self.punchToken(.groupEnd);
    self.finishedGroups += 1;
}

pub fn finishGroup0(self: *Scanner) Allocator.Error!void {
    assert(self.finishedGroups == self.groupCount - 1);
    _ = try self.punchToken(.groupEnd);
    self.finishedGroups += 1;
}

pub fn lastToken(self: *const Scanner) *const RgxToken {
    assert(self.tokenCount() > 0);
    return self.tokens[self.currTokenIdx()];
}

pub fn lastTokenAs(self: *Scanner, comptime tokenTag: TokenTag) *const RgxToken {
    const token = self.lastToken();
    // Should this be an actual error check?
    assert(token.* == tokenTag);
    return token;
}

pub fn punchToken(self: *Scanner, comptime tokenTag: TokenTag) Allocator.Error!*RgxToken {
    const newToken = try self.createToken(tokenTag);
    try self.appendToken(newToken);
    return newToken;
}

pub fn createToken(self: *Scanner, comptime tokenTag: TokenTag) Allocator.Error!*RgxToken {
    const newToken = try self.allocator.create(RgxToken);
    newToken.* = @unionInit(RgxToken, @tagName(tokenTag), undefined);
    return newToken;
}

pub fn startNextGroup(self: *Scanner) Error!void {
    const groupTk = try self.punchToken(.group);
    groupTk.group = self.groupCount;
    self.groupCount += 1;
}

pub fn hasOpenGroups(self: *const Scanner) bool {
    return self.finishedGroups < self.groupCount - 1;
}

pub fn appendToken(self: *Scanner, token: *const RgxToken) Allocator.Error!void {
    self.tokens[self.tokenI] = token;
    self.tokenI += 1;
}

pub fn tokenCount(self: *const Scanner) usize {
    return self.tokenI;
}

pub fn currTokenIdx(self: *const Scanner) usize {
    const tokensLen = self.tokenCount();
    assert(tokensLen > 0);
    return tokensLen - 1;
}

pub fn finished(self: *const Scanner) bool {
    return self.i >= self.pattern.len;
}

pub fn hasNext(self: *const Scanner) bool {
    return self.i < self.pattern.len;
}

pub fn consume(self: *Scanner) void {
    assert(self.hasNext());
    self.i += 1;
}

pub fn tagStart(self: *Scanner) void {
    self.startIdx = self.i;
}

pub fn peekPrev(self: *const Scanner) u8 {
    return self.peekAt(self.i - 1);
}

pub fn peekAt(self: *const Scanner, i: usize) u8 {
    assert(i >= 0);
    assert(i < self.pattern.len);
    return self.pattern[i];
}

pub fn peek(self: *const Scanner) u8 {
    assert(self.hasNext());
    return self.pattern[self.i];
}

pub fn ensureByte(self: *const Scanner) ConsumeError!void {
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
        message ++ "{s} - {s}<{c}>{s}",
        .{
            @errorName(e),
            self.pattern[0..self.i],
            if (self.finished()) 0x00 else self.peek(),
            if (self.i + 1 >= self.pattern.len) "" else self.pattern[self.i + 1 ..],
        },
    );
    return e;
}
