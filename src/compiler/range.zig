const std = @import("std");
const Writer = std.Io.Writer;
const regent = @import("regent");
const Scanner = @import("scanner.zig");

min: usize,
max: usize,

const Range = @This();

pub const Error = error{
    SyntaxError,
    StartSmallerThanEnd,
} ||
    Scanner.ConsumeError ||
    std.fmt.ParseIntError;

const State = enum {
    init,

    initStartParse,
    startParse,

    seekComma,

    initEndParse,
    endParse,

    end,
};

pub fn parseRange(self: *Range, scanner: *Scanner) Error!void {
    var state: State = .init;
    var digitsIdx: usize = undefined;

    stateLoop: while (true) {
        switch (state) {
            .init => {
                try scanner.ensureByte();
                switch (scanner.peek()) {
                    '{',
                    => {
                        scanner.consume();
                        state = .initStartParse;
                        continue :stateLoop;
                    },
                    else => return Error.SyntaxError,
                }
            },
            .initStartParse => {
                try scanner.consumeWhite();
                switch (scanner.peek()) {
                    '0',
                    => {
                        scanner.consume();
                        self.min = 0;
                        try scanner.consumeWhite();
                        state = .seekComma;
                        continue :stateLoop;
                    },
                    '1'...'9',
                    => {
                        digitsIdx = scanner.i;
                        scanner.consume();
                        state = .startParse;
                        continue :stateLoop;
                    },
                    ',' => {
                        self.min = 0;
                        try scanner.consumeWhite();
                        state = .seekComma;
                        continue :stateLoop;
                    },
                    else => return Error.SyntaxError,
                }
            },
            .startParse => {
                try scanner.consumeDigits();
                const digits = scanner.sliceFrom(digitsIdx);
                try scanner.consumeWhite();
                self.min = try std.fmt.parseInt(usize, digits, 10);
                state = .seekComma;
                continue :stateLoop;
            },
            .seekComma => {
                switch (scanner.peek()) {
                    ',',
                    => {
                        scanner.consume();
                        state = .initEndParse;
                        continue :stateLoop;
                    },
                    '}',
                    => {
                        self.max = self.min;
                        state = .end;
                    },
                    else => return Error.SyntaxError,
                }
            },
            .initEndParse => {
                try scanner.consumeWhite();
                switch (scanner.peek()) {
                    '0',
                    => {
                        scanner.consume();
                        self.max = 0;
                        try scanner.consumeWhite();
                        state = .end;
                        continue :stateLoop;
                    },
                    '1'...'9',
                    => {
                        digitsIdx = scanner.i;
                        scanner.consume();
                        state = .endParse;
                        continue :stateLoop;
                    },
                    '}' => {
                        self.max = std.math.maxInt(usize);
                        state = .end;
                        try scanner.consumeWhite();
                        continue :stateLoop;
                    },
                    else => return Error.SyntaxError,
                }
            },
            .endParse => {
                try scanner.consumeDigits();
                const digits = scanner.sliceFrom(digitsIdx);
                try scanner.consumeWhite();
                self.max = try std.fmt.parseInt(usize, digits, 10);
                state = .end;
                continue :stateLoop;
            },
            .end => {
                if (self.min > self.max) return Error.StartSmallerThanEnd;
                switch (scanner.peek()) {
                    '}',
                    => {
                        scanner.consume();
                        return;
                    },
                    else => return Error.SyntaxError,
                }
            },
        }
    }
    unreachable;
}

pub fn format(self: *const Range, w: *Writer) Writer.Error!void {
    const buffSize = comptime std.fmt.count("{d}", .{std.math.maxInt(usize)});
    var startIntBuff: [buffSize]u8 = undefined;
    var endIntBuff: [buffSize]u8 = undefined;

    const startLen = std.fmt.printInt(&startIntBuff, self.min, 10, .lower, .{});
    const endLen = std.fmt.printInt(&endIntBuff, self.max, 10, .lower, .{});

    try w.writeAll("{");
    try w.writeAll(startIntBuff[0..startLen]);
    try w.writeAll(",");
    try w.writeAll(endIntBuff[0..endLen]);
    try w.writeAll("}");
}

fn testParse(scanner: *Scanner, pattern: []const u8) !Range {
    var range: Range = undefined;

    scanner.pattern = pattern;
    scanner.state = .branchStart;
    scanner.i = 0;

    range.parseRange(scanner) catch |e| {
        scanner.report(e, "Failed parsing range") catch |ee| {
            if (scanner.diagnostics) |diagnostics| {
                try diagnostics.printRaise(ee);
            } else return ee;
        };
    };

    return range;
}

test "Parse ranges" {
    const t = std.testing;
    const tt = regent.testing;
    var diag: Scanner.Diagnostics = undefined;
    var scanner: Scanner = undefined;
    scanner.initWithDiag(t.allocator, &diag, "");
    defer diag.deinit();
    const MAX_USIZE = std.math.maxInt(usize);

    try tt.expectEqual(Range, .{ .min = 0, .max = 0 }, try testParse(&scanner, "{0}"));
    try tt.expectEqual(Range, .{ .min = 0, .max = 0 }, try testParse(&scanner, "{ 0}"));
    try tt.expectEqual(Range, .{ .min = 0, .max = 0 }, try testParse(&scanner, "{0 }"));
    try tt.expectEqual(Range, .{ .min = 0, .max = 0 }, try testParse(&scanner, "{ 0 }"));
    try tt.expectEqual(Range, .{ .min = 1, .max = 1 }, try testParse(&scanner, "{1}"));
    try tt.expectEqual(Range, .{ .min = 1, .max = 1 }, try testParse(&scanner, "{ 1}"));
    try tt.expectEqual(Range, .{ .min = 1, .max = 1 }, try testParse(&scanner, "{1 }"));
    try tt.expectEqual(Range, .{ .min = 1, .max = 1 }, try testParse(&scanner, "{ 1 }"));
    try tt.expectEqual(Range, .{ .min = 0, .max = MAX_USIZE }, try testParse(&scanner, "{,}"));
    try tt.expectEqual(Range, .{ .min = 0, .max = MAX_USIZE }, try testParse(&scanner, "{ ,}"));
    try tt.expectEqual(Range, .{ .min = 0, .max = MAX_USIZE }, try testParse(&scanner, "{, }"));
    try tt.expectEqual(Range, .{ .min = 0, .max = MAX_USIZE }, try testParse(&scanner, "{ , }"));
    try tt.expectEqual(Range, .{ .min = 12, .max = MAX_USIZE }, try testParse(&scanner, "{12,}"));
    try tt.expectEqual(Range, .{ .min = 42, .max = MAX_USIZE }, try testParse(&scanner, "{ 42,}"));
    try tt.expectEqual(Range, .{ .min = 73, .max = MAX_USIZE }, try testParse(&scanner, "{ 73 ,}"));
    try tt.expectEqual(Range, .{ .min = 123, .max = MAX_USIZE }, try testParse(&scanner, "{ 123 , }"));
    try tt.expectEqual(Range, .{ .min = 0, .max = 32 }, try testParse(&scanner, "{,32}"));
    try tt.expectEqual(Range, .{ .min = 0, .max = 11 }, try testParse(&scanner, "{ ,11}"));
    try tt.expectEqual(Range, .{ .min = 0, .max = 888 }, try testParse(&scanner, "{ , 888}"));
    try tt.expectEqual(Range, .{ .min = 0, .max = 999 }, try testParse(&scanner, "{ , 999 }"));
    try tt.expectEqual(Range, .{ .min = 0, .max = 0 }, try testParse(&scanner, "{0,0}"));
    try tt.expectEqual(Range, .{ .min = 0, .max = 0 }, try testParse(&scanner, "{ 0,0}"));
    try tt.expectEqual(Range, .{ .min = 0, .max = 0 }, try testParse(&scanner, "{ 0 ,0}"));
    try tt.expectEqual(Range, .{ .min = 0, .max = 0 }, try testParse(&scanner, "{ 0 , 0}"));
    try tt.expectEqual(Range, .{ .min = 0, .max = 0 }, try testParse(&scanner, "{ 0 , 0 }"));
    try tt.expectEqual(Range, .{ .min = 13, .max = 15 }, try testParse(&scanner, "{13,15}"));
    try tt.expectEqual(Range, .{ .min = 13, .max = 15 }, try testParse(&scanner, "{ 13,15}"));
    try tt.expectEqual(Range, .{ .min = 13, .max = 15 }, try testParse(&scanner, "{ 13 ,15}"));
    try tt.expectEqual(Range, .{ .min = 13, .max = 15 }, try testParse(&scanner, "{ 13 , 15}"));
    try tt.expectEqual(Range, .{ .min = 13, .max = 15 }, try testParse(&scanner, "{ 13 , 15 }"));
}

test "fail to parse range" {
    const t = std.testing;
    var scanner: Scanner = .{ .pattern = "" };

    try t.expectError(Error.UnexpectedEnd, testParse(&scanner, ""));
    try t.expectError(Error.SyntaxError, testParse(&scanner, "a"));
    try t.expectError(Error.SyntaxError, testParse(&scanner, "{a"));
    try t.expectError(Error.SyntaxError, testParse(&scanner, "{}"));
    try t.expectError(Error.UnexpectedEnd, testParse(&scanner, "{0"));
    try t.expectError(Error.UnexpectedEnd, testParse(&scanner, "{ "));
    try t.expectError(Error.UnexpectedEnd, testParse(&scanner, "{, "));
    try t.expectError(Error.SyntaxError, testParse(&scanner, "{01"));
    try t.expectError(Error.Overflow, testParse(&scanner, "{18446744073709551616,}"));
    try t.expectError(Error.UnexpectedEnd, testParse(&scanner, "{1 "));
    try t.expectError(Error.Overflow, testParse(&scanner, "{1,18446744073709551616}"));
    try t.expectError(Error.SyntaxError, testParse(&scanner, "{1x"));
    try t.expectError(Error.UnexpectedEnd, testParse(&scanner, "{1, "));
    try t.expectError(Error.UnexpectedEnd, testParse(&scanner, "{1,0 "));
    try t.expectError(Error.SyntaxError, testParse(&scanner, "{1,x"));
    try t.expectError(Error.UnexpectedEnd, testParse(&scanner, "{1,3 "));
    try t.expectError(Error.StartSmallerThanEnd, testParse(&scanner, "{3,2}"));
    try t.expectError(Error.SyntaxError, testParse(&scanner, "{2,3x"));
}
