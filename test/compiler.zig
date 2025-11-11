const std = @import("std");
const tat = @import("tattletale");
const Token = tat.Token;
const Literal = tat.Literal;
const Compiler = tat.Compiler;
const RgxNode = tat.RgxNode;
const LiteralRgxNode = tat.LiteralRgxNode;

test "compiler literal" {
    const token: Token = .{ .literal = "testmatch" };
    var litNode: LiteralRgxNode = .init(&token);
    var rgx: RgxNode = .{
        .literal = &litNode,
    };

    for ("testmatch") |c| {
        switch (rgx.next(c)) {
            .literal => continue,
            .matched => {
                try std.testing.expectEqual(token.literal.len, rgx.literal.i);
            },
            .failed,
            => try std.testing.expect(false),
            else => try std.testing.expect(false),
        }
    }
}
