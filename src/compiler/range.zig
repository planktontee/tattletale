const std = @import("std");
const Writer = std.Io.Writer;
const regent = @import("regent");
const Scanner = @import("scanner.zig");

min: usize,
max: usize,

const Range = @This();

pub const Unlimited = std.math.maxInt(usize);

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

pub const Any: *const Range = &.{
    .min = 0,
    .max = Unlimited,
};

pub const OneOrMore: *const Range = &.{
    .min = 1,
    .max = Unlimited,
};

pub const Optional: *const Range = &.{
    .min = 0,
    .max = 1,
};

pub fn parseRange(self: *Range, scanner: *Scanner) Error!void {
    var digitsIdx: usize = undefined;

    stateLoop: switch (State.init) {
        .init => {
            try scanner.ensureByte();
            switch (scanner.peek()) {
                '{',
                => {
                    scanner.consume();
                    continue :stateLoop .initStartParse;
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
                    continue :stateLoop .seekComma;
                },
                '1'...'9',
                => {
                    digitsIdx = scanner.i;
                    scanner.consume();
                    continue :stateLoop .startParse;
                },
                ',' => {
                    self.min = 0;
                    try scanner.consumeWhite();
                    continue :stateLoop .seekComma;
                },
                else => return Error.SyntaxError,
            }
        },
        .startParse => {
            try scanner.consumeDigits();
            const digits = scanner.sliceFrom(digitsIdx);
            try scanner.consumeWhite();
            self.min = try std.fmt.parseInt(usize, digits, 10);
            continue :stateLoop .seekComma;
        },
        .seekComma => {
            switch (scanner.peek()) {
                ',',
                => {
                    scanner.consume();
                    continue :stateLoop .initEndParse;
                },
                '}',
                => {
                    self.max = self.min;
                    continue :stateLoop .end;
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
                    continue :stateLoop .end;
                },
                '1'...'9',
                => {
                    digitsIdx = scanner.i;
                    scanner.consume();
                    continue :stateLoop .endParse;
                },
                '}' => {
                    self.max = std.math.maxInt(usize);
                    try scanner.consumeWhite();
                    continue :stateLoop .end;
                },
                else => return Error.SyntaxError,
            }
        },
        .endParse => {
            try scanner.consumeDigits();
            const digits = scanner.sliceFrom(digitsIdx);
            try scanner.consumeWhite();
            self.max = try std.fmt.parseInt(usize, digits, 10);
            continue :stateLoop .end;
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
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var diag: Scanner.Diagnostics = undefined;
    var scanner: Scanner = undefined;
    try scanner.initWithDiag(allocator, &diag, "");
    defer diag.deinit();

    try tt.expectEqual(Range, .{ .min = 0, .max = 0 }, try testParse(&scanner, "{0}"));
    try tt.expectEqual(Range, .{ .min = 0, .max = 0 }, try testParse(&scanner, "{ 0}"));
    try tt.expectEqual(Range, .{ .min = 0, .max = 0 }, try testParse(&scanner, "{0 }"));
    try tt.expectEqual(Range, .{ .min = 0, .max = 0 }, try testParse(&scanner, "{ 0 }"));
    try tt.expectEqual(Range, .{ .min = 1, .max = 1 }, try testParse(&scanner, "{1}"));
    try tt.expectEqual(Range, .{ .min = 1, .max = 1 }, try testParse(&scanner, "{ 1}"));
    try tt.expectEqual(Range, .{ .min = 1, .max = 1 }, try testParse(&scanner, "{1 }"));
    try tt.expectEqual(Range, .{ .min = 1, .max = 1 }, try testParse(&scanner, "{ 1 }"));
    try tt.expectEqual(Range, .{ .min = 0, .max = Unlimited }, try testParse(&scanner, "{,}"));
    try tt.expectEqual(Range, .{ .min = 0, .max = Unlimited }, try testParse(&scanner, "{ ,}"));
    try tt.expectEqual(Range, .{ .min = 0, .max = Unlimited }, try testParse(&scanner, "{, }"));
    try tt.expectEqual(Range, .{ .min = 0, .max = Unlimited }, try testParse(&scanner, "{ , }"));
    try tt.expectEqual(Range, .{ .min = 12, .max = Unlimited }, try testParse(&scanner, "{12,}"));
    try tt.expectEqual(Range, .{ .min = 42, .max = Unlimited }, try testParse(&scanner, "{ 42,}"));
    try tt.expectEqual(Range, .{ .min = 73, .max = Unlimited }, try testParse(&scanner, "{ 73 ,}"));
    try tt.expectEqual(Range, .{ .min = 123, .max = Unlimited }, try testParse(&scanner, "{ 123 , }"));
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

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scanner: Scanner = undefined;
    try scanner.init(allocator, "");

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
