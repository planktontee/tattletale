const std = @import("std");
const tat = @import("tattletale");
const Token = tat.Token;
const Quantifier = tat.Quantifier;
const Literal = tat.Literal;
const Compiler = tat.Compiler;
const RgxNode = tat.RgxNode;
const LiteralRgxNode = tat.LiteralRgxNode;
const QuantifierRgxNode = tat.QuantifierRgxNode;
const Cursor = tat.Cursor;

// test "compiler literal" {
//     const t = std.testing;
//
//     const target = "testmatch";
//     var litNode: LiteralRgxNode = .init(target);
//     var rgx: RgxNode = .{ .literal = &litNode };
//     var cursor: Cursor = .{ .data = "testmatch" };
//
//     switch (rgx.next(&cursor)) {
//         .finished => |end| try t.expectEqualDeep(
//             target,
//             cursor.slice(0, end),
//         ),
//         .failed,
//         .partial,
//         => try t.expect(false),
//     }
// }
//
// test "compiler range" {
//     const t = std.testing;
//
//     const quantifier: Quantifier = .{
//         .flavour = .greedy,
//         .range = &.{
//             .min = 1,
//             .max = 3,
//         },
//         .token = &.{ .literal = "abc" },
//     };
//     var litNode: LiteralRgxNode = .init(quantifier.token.literal);
//     var repNode: QuantifierRgxNode = .init(&quantifier, .{ .literal = &litNode });
//
//     const target = "abcabc";
//     var rgx: RgxNode = .{ .quantifier = &repNode };
//     var cursor: Cursor = .{ .data = "abcabca" };
//
//     var start: usize = 0;
//     var matches: usize = 0;
//
//     loop: switch (rgx.next(&cursor)) {
//         .finished => |end| {
//             // No advancement on failure after partials converted to finished
//             try t.expectEqual(start, end);
//             try t.expectEqualDeep(
//                 target,
//                 cursor.slice(0, start),
//             );
//             matches += 1;
//             try t.expect(quantifier.range.in(matches));
//         },
//         .partial => |end| {
//             try t.expectEqualDeep(
//                 litNode.target,
//                 cursor.slice(start, end),
//             );
//             start = end;
//             matches += 1;
//             try t.expect(quantifier.range.in(matches));
//             continue :loop rgx.next(&cursor);
//         },
//         .failed => try t.expect(false),
//     }
// }
