const std = @import("std");
const regent = @import("regent");
const tat = @import("tattletale");
const asPtrConCast = regent.ergo.asPtrConCast;
const Scanner = tat.Scanner;
const Diagnostics = tat.Diagnostics;
const Token = tat.Token;
const Repeatable = tat.Repeatable;
const Range = tat.Range;
const Unlimited = Range.Unlimited;
const Error = Range.Error;

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
