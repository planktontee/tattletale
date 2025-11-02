const std = @import("std");
const Range = @import("range.zig");
const Allocator = std.mem.Allocator;

pub const Diagnostics = union(enum) {
    disabled,
    enabled: *DiagnosticTracker,
};

pub const DiagnosticTracker = struct {
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

pub const Token = union(enum) {
    branchStart,
    branchEnd,

    // 1 to 4 bytes (utf8)
    // escapings
    // single chars
    atom: u8,

    quantifier: union(enum) {
        optional,

        anyGreedy,
        anyLazy,

        moreGreedy,
        moreLazy,

        minGreedy: usize,
        minLazy: usize,

        maxGreedy: usize,
        maxLazy: usize,

        rangeGreedy: Range,
        rangeLazy: Range,
    },

    done,
};

const State = union(enum) {
    init,

    seekPiece,

    anyGreedy,
    moreGreedy,

    done,
};

state: State = .init,
pattern: []const u8,
i: usize = 0,
diagnostics: Diagnostics = .disabled,

pub fn initWithDiag(
    self: *@This(),
    allocator: Allocator,
    diag: *DiagnosticTracker,
    pattern: []const u8,
) void {
    self.* = .{ .pattern = pattern };
    diag.* = .{
        .allocator = allocator,
        .idx = &self.i,
        .pattern = pattern,
    };
    self.diagnostics = .{ .enabled = diag };
}

pub const Error = error{
    TBA,
    Bad2ByteUTF8Start,
    InvalidUTF8Byte1,

    UnexpectedRangeEnd,

    RangeEndBeforeStart,
} ||
    Range.Error ||
    DiagnosticTracker.MakeBuff ||
    std.fmt.BufPrintError;

pub fn next(self: *@This()) Error!Token {
    stateLoop: while (true) {
        switch (self.state) {
            .init => {
                if (self.i >= self.pattern.len) {
                    self.state = .done;
                    continue :stateLoop;
                }
                self.state = .seekPiece;
                return .branchStart;
            },
            .seekPiece => {
                if (self.i >= self.pattern.len) {
                    self.state = .done;
                    continue :stateLoop;
                }
                switch (self.pattern[self.i]) {
                    // 0x24
                    '$',
                    => {},
                    // 0x28
                    '(',
                    => {},
                    // 0x29
                    ')',
                    => {},

                    // Ranges
                    // 0x2A
                    '*',
                    => {
                        self.i += 1;
                        self.state = .anyGreedy;
                        continue :stateLoop;
                    },
                    // 0x2B
                    '+',
                    => {
                        self.i += 1;
                        self.state = .moreGreedy;
                        continue :stateLoop;
                    },
                    // 0x3F
                    '?',
                    => {
                        self.i += 1;
                        return .{ .quantifier = .optional };
                    },
                    // 0x7B
                    '{',
                    => {
                        self.i += 1;
                        var range: Range = undefined;
                        try range.parseRange(self);
                        self.state = .seekPiece;

                        if (self.i >= self.pattern.len) {
                            self.state = .seekPiece;
                            return .{
                                .quantifier = .{ .rangeGreedy = range },
                            };
                        }

                        switch (self.pattern[self.i]) {
                            '?' => {
                                self.i += 1;
                                return .{
                                    .quantifier = .{ .rangeLazy = range },
                                };
                            },
                            else => {
                                return .{
                                    .quantifier = .{ .rangeGreedy = range },
                                };
                            },
                        }
                    },
                    // 0x7D
                    '}' => return Error.RangeEndBeforeStart,

                    // 0x2E
                    '.',
                    => {},
                    // 0x5B
                    '[',
                    => {},
                    // 0x5C
                    '\\',
                    => {},
                    // 0x5D
                    ']',
                    => {},
                    // 0x5E
                    '^',
                    => {},
                    // 0x7C
                    '|',
                    => {},

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
                        const token: Token = .{ .atom = self.pattern[self.i] };
                        self.i += 1;
                        return token;
                    },

                    // invalid continuation in utf8 in this state
                    0x80...0xBF => return Error.Bad2ByteUTF8Start,
                    // Those violate shortest encoding rules for 2 bytes
                    0xC0...0xC1 => {},
                    // 2 bytes utf8
                    0xC2...0xDF => {},
                    // 3 bytes utf8
                    0xE0...0xEF => {},
                    // 4 bytes utf8
                    0xF0...0xF4 => {},
                    0xF5...0xFF => return Error.InvalidUTF8Byte1,
                }
            },
            .anyGreedy,
            => {
                if (self.i >= self.pattern.len) {
                    self.state = .done;
                    return .{ .quantifier = .anyGreedy };
                }
                switch (self.pattern[self.i]) {
                    '?' => {
                        self.i += 1;
                        self.state = .seekPiece;
                        return .{ .quantifier = .anyLazy };
                    },
                    else => {
                        self.state = .seekPiece;
                        return .{ .quantifier = .anyGreedy };
                    },
                }
            },
            .moreGreedy,
            => {
                if (self.i >= self.pattern.len) {
                    self.state = .done;
                    return .{ .quantifier = .moreGreedy };
                }
                switch (self.pattern[self.i]) {
                    '?' => {
                        self.i += 1;
                        self.state = .seekPiece;
                        return .{ .quantifier = .moreLazy };
                    },
                    else => {
                        self.state = .seekPiece;
                        return .{ .quantifier = .moreGreedy };
                    },
                }
            },
            .done => return .done,
        }
        return Error.TBA;
    }
    unreachable;
}

pub const ConsumeError = error{
    UnexpectedEnd,
};

pub fn consumeWhite(self: *Scanner) ConsumeError!void {
    while (self.i < self.pattern.len) : (self.i += 1) {
        switch (self.pattern[self.i]) {
            ' ',
            '\t',
            => continue,
            else => break,
        }
    } else return ConsumeError.UnexpectedEnd;
}

pub fn consumeDigits(self: *Scanner) ConsumeError!void {
    while (self.i < self.pattern.len) : (self.i += 1) {
        switch (self.pattern[self.i]) {
            '0'...'9',
            => continue,
            else => break,
        }
    } else return ConsumeError.UnexpectedEnd;
}

const Scanner = @This();

pub fn report(self: *Scanner, e: Error, comptime message: []const u8) Error!noreturn {
    if (self.diagnostics == .disabled) return e;
    var diag = self.diagnostics.enabled;
    const buff: []u8 = try diag.makeBuff(4098);
    diag.message = try std.fmt.bufPrint(
        buff,
        "{s} - {s}<{c}>{s} - " ++ message,
        .{
            @errorName(e),
            self.pattern[0..self.i],
            self.pattern[self.i],
            if (self.i + 1 >= self.pattern.len) "" else self.pattern[self.i + 1 ..],
        },
    );
    return e;
}

pub fn collect(self: *Scanner, tokens: []Token) Error![]const Token {
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const token = self.next() catch |e| try self.report(e, "Failed collection");
        tokens[i] = token;
        if (token == .done) {
            i += 1;
            break;
        }
    }
    return tokens[0..i];
}

test "Parse tokens" {
    const t = std.testing;

    const pattern: []const u8 = "ab+?c?de*f*?";
    var scanner: Scanner = undefined;
    var diag: DiagnosticTracker = undefined;
    defer diag.deinit();
    scanner.initWithDiag(t.allocator, &diag, pattern);
    const expected: []const Token = &.{
        .branchStart,
        .{ .atom = 'a' },
        .{ .atom = 'b' },
        .{ .quantifier = .moreLazy },
        .{ .atom = 'c' },
        .{ .quantifier = .optional },
        .{ .atom = 'd' },
        .{ .atom = 'e' },
        .{ .quantifier = .anyGreedy },
        .{ .atom = 'f' },
        .{ .quantifier = .anyLazy },
        .done,
    };
    var tokens: [expected.len]Token = undefined;
    const result = scanner.collect(&tokens) catch |e| try diag.printRaise(e);
    try t.expectEqualDeep(expected, result);
}

test "Parse ranges" {
    const t = std.testing;

    const pattern: []const u8 = "a{,}b{12}?";
    var scanner: Scanner = undefined;
    var diag: DiagnosticTracker = undefined;
    defer diag.deinit();
    scanner.initWithDiag(t.allocator, &diag, pattern);
    const expected: []const Token = &.{
        .branchStart,
        .{ .atom = 'a' },
        .{
            .quantifier = .{
                .rangeGreedy = .{ .min = 0, .max = 0 },
            },
        },
        .{ .atom = 'b' },
        .{
            .quantifier = .{
                .rangeLazy = .{ .min = 12, .max = 12 },
            },
        },
        .done,
    };
    var tokens: [expected.len]Token = undefined;
    const result = scanner.collect(&tokens) catch |e| try diag.printRaise(e);
    try t.expectEqualDeep(expected, result);
}
