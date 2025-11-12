const std = @import("std");
const tat = @import("tattletale");
const Token = tat.Token;
const Repeatable = tat.Repeatable;
const Literal = tat.Literal;
const Compiler = tat.Compiler;
const RgxNode = tat.RgxNode;
const LiteralRgxNode = tat.LiteralRgxNode;
const RepeatableRgxNode = tat.RepeatableRgxNode;
const Cursor = tat.Cursor;

test "compiler literal" {
    const t = std.testing;

    const target = "testmatch";
    var litNode: LiteralRgxNode = .init(target, 0);
    var rgx: RgxNode = .{ .literal = &litNode };
    var cursor: Cursor = .{ .data = "testmatch" };

    switch (rgx.next(&cursor)) {
        .match => |node| try t.expectEqualDeep(
            target,
            node.slice(&cursor),
        ),
        .group,
        .repeatable,
        .failed,
        .literal,
        => try t.expect(false),
    }
}

test "compiler range" {
    const t = std.testing;

    const repeatable: Repeatable = .{
        .flavour = .greedy,
        .range = &.{
            .min = 1,
            .max = 3,
        },
        .token = &.{ .literal = "abc" },
    };
    var litNode: LiteralRgxNode = .init(repeatable.token.literal, 0);
    var repNode: RepeatableRgxNode = .init(&repeatable, .{ .literal = &litNode }, 0);

    const target = "abcabc";
    var rgx: RgxNode = .{ .repeatable = &repNode };
    var cursor: Cursor = .{ .data = "abcabca" };

    stateLoop: switch (rgx.next(&cursor)) {
        .literal => |node| continue :stateLoop node.next(&cursor),
        .match => |node| try t.expectEqualDeep(
            target,
            node.slice(&cursor),
        ),
        .group,
        .repeatable,
        .failed,
        => try t.expect(false),
    }
}
