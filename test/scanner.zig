const std = @import("std");
const regent = @import("regent");
const tat = @import("tattletale");
const asPtrConCast = regent.ergo.asPtrConCast;
const Scanner = tat.Scanner;
const Diagnostics = tat.Diagnostics;
const Token = tat.Token;
const Quantifier = tat.Quantifier;
const Range = tat.Range;

// test "test collect" {
//     const t = std.testing;
//     const tt = regent.testing;
//     var arena = std.heap.ArenaAllocator.init(t.allocator);
//     defer arena.deinit();
//     const allocator = arena.allocator();
//
//     const pattern: []const u8 = "ab+cd?efgh*ij+?klmn*?opqrs{1,3}tuvw{1}?x";
//     var scanner: Scanner = undefined;
//     var diag: Diagnostics = undefined;
//     defer diag.deinit();
//     try scanner.initWithDiag(allocator, &diag, pattern);
//     const group0T = try scanner.collect();
//
//     try tt.expectEqualDeep(*const Token, &.{
//         .group = &.{
//             .n = 0,
//             .tokens = &.{
//                 &.{ .literal = "a" },
//                 &.{
//                     .quantifier = asPtrConCast(Quantifier, &.{
//                         .range = Range.OneOrMore,
//                         .token = &.{ .literal = "b" },
//                         .flavour = .greedy,
//                     }),
//                 },
//                 &.{ .literal = "c" },
//                 &.{
//                     .quantifier = asPtrConCast(Quantifier, &.{
//                         .range = Range.Optional,
//                         .token = &.{ .literal = "d" },
//                         .flavour = .greedy,
//                     }),
//                 },
//                 &.{ .literal = "efg" },
//                 &.{
//                     .quantifier = asPtrConCast(Quantifier, &.{
//                         .range = Range.Any,
//                         .token = &.{ .literal = "h" },
//                         .flavour = .greedy,
//                     }),
//                 },
//                 &.{ .literal = "i" },
//                 &.{
//                     .quantifier = asPtrConCast(Quantifier, &.{
//                         .range = Range.OneOrMore,
//                         .token = &.{ .literal = "j" },
//                         .flavour = .lazy,
//                     }),
//                 },
//                 &.{ .literal = "klm" },
//                 &.{
//                     .quantifier = asPtrConCast(Quantifier, &.{
//                         .range = Range.Any,
//                         .token = &.{ .literal = "n" },
//                         .flavour = .lazy,
//                     }),
//                 },
//                 &.{ .literal = "opqr" },
//                 &.{
//                     .quantifier = asPtrConCast(Quantifier, &.{
//                         .range = &.{ .min = 1, .max = 3 },
//                         .token = &.{ .literal = "s" },
//                         .flavour = .greedy,
//                     }),
//                 },
//                 &.{ .literal = "tuv" },
//                 &.{
//                     .quantifier = asPtrConCast(Quantifier, &.{
//                         .range = &.{ .min = 1, .max = 1 },
//                         .token = &.{ .literal = "w" },
//                         .flavour = .lazy,
//                     }),
//                 },
//                 &.{ .literal = "x" },
//             },
//         },
//     }, group0T);
// }

test "collect groups" {
    const t = std.testing;
    const tt = regent.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const pattern: []const u8 = "(a(bc)()c)(a){1,2}";
    var scanner: Scanner = undefined;
    var diag: Diagnostics = undefined;
    defer diag.deinit();
    try scanner.initWithDiag(allocator, &diag, pattern);
    scanner.collectWithReport() catch |e| {
        try scanner.diagnostics.?.printRaise(e);
    };

    for (scanner.tokens.items) |tk| {
        std.debug.print("Token {s}\n", .{@tagName(tk.*)});
    }

    try tt.expectEqualDeep([]const *const Token, &.{
        &.{ .group = &.{ .n = 0 } },
        &.{ .group = &.{ .n = 1 } },
        &.{ .literal = "a" },
        &.{ .group = &.{ .n = 2 } },
        &.{ .literal = "bc" },
        &.{ .groupEnd = asPtrConCast(usize, &3) },
        &.{ .group = &.{ .n = 3 } },
        &.{ .groupEnd = asPtrConCast(usize, &6) },
        &.{ .literal = "c" },
        &.{ .groupEnd = asPtrConCast(usize, &1) },
        &.{
            .quantifier = asPtrConCast(Quantifier, &.{
                .range = &.{ .min = 1, .max = 2 },
                .flavour = .greedy,
            }),
        },
        &.{ .group = &.{ .n = 4 } },
        &.{ .literal = "a" },
        &.{ .groupEnd = asPtrConCast(usize, &11) },
        &.quantifierEnd,
        &.{ .groupEnd = asPtrConCast(usize, &0) },
    }, scanner.tokens.items);
}
