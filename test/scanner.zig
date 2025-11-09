const std = @import("std");
const regent = @import("regent");
const tat = @import("tattletale");
const asPtrConCast = regent.ergo.asPtrConCast;
const Scanner = tat.Scanner;
const Diagnostics = tat.Diagnostics;
const Token = tat.Token;
const Repeatable = tat.Repeatable;
const Range = tat.Range;

test "test collect" {
    const t = std.testing;
    const tt = regent.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const pattern: []const u8 = "ab+cd?efgh*ij+?klmn*?opqrs{1,3}tuvw{1}?x";
    var scanner: Scanner = undefined;
    var diag: Diagnostics = undefined;
    defer diag.deinit();
    try scanner.initWithDiag(allocator, &diag, pattern);
    const group0T = try scanner.collect();

    try tt.expectEqualDeep(*const Token, &.{
        .group = &.{
            .n = 0,
            .tokens = &.{
                &.{ .literal = "a" },
                &.{
                    .repeatable = asPtrConCast(Repeatable, &.{
                        .range = Range.OneOrMore,
                        .token = &.{ .literal = "b" },
                        .flavour = .greedy,
                    }),
                },
                &.{ .literal = "c" },
                &.{
                    .repeatable = asPtrConCast(Repeatable, &.{
                        .range = Range.Optional,
                        .token = &.{ .literal = "d" },
                        .flavour = .greedy,
                    }),
                },
                &.{ .literal = "efg" },
                &.{
                    .repeatable = asPtrConCast(Repeatable, &.{
                        .range = Range.Any,
                        .token = &.{ .literal = "h" },
                        .flavour = .greedy,
                    }),
                },
                &.{ .literal = "i" },
                &.{
                    .repeatable = asPtrConCast(Repeatable, &.{
                        .range = Range.OneOrMore,
                        .token = &.{ .literal = "j" },
                        .flavour = .lazy,
                    }),
                },
                &.{ .literal = "klm" },
                &.{
                    .repeatable = asPtrConCast(Repeatable, &.{
                        .range = Range.Any,
                        .token = &.{ .literal = "n" },
                        .flavour = .lazy,
                    }),
                },
                &.{ .literal = "opqr" },
                &.{
                    .repeatable = asPtrConCast(Repeatable, &.{
                        .range = &.{ .min = 1, .max = 3 },
                        .token = &.{ .literal = "s" },
                        .flavour = .greedy,
                    }),
                },
                &.{ .literal = "tuv" },
                &.{
                    .repeatable = asPtrConCast(Repeatable, &.{
                        .range = &.{ .min = 1, .max = 1 },
                        .token = &.{ .literal = "w" },
                        .flavour = .lazy,
                    }),
                },
                &.{ .literal = "x" },
            },
        },
    }, group0T);
}

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
    const group0T = scanner.collectWithReport() catch |e| {
        try scanner.diagnostics.?.printRaise(e);
    };

    try tt.expectEqualDeep(*const Token, &.{
        .group = &.{
            .n = 0,
            .tokens = &.{
                &.{
                    .group = &.{
                        .n = 1,
                        .tokens = &.{
                            &.{ .literal = "a" },
                            &.{
                                .group = &.{
                                    .n = 2,
                                    .tokens = &.{&.{ .literal = "bc" }},
                                },
                            },
                            &.{
                                .group = &.{
                                    .n = 3,
                                    .tokens = &.{},
                                },
                            },
                            &.{ .literal = "c" },
                        },
                    },
                },
                &.{
                    .repeatable = asPtrConCast(Repeatable, &.{
                        .range = &.{ .min = 1, .max = 2 },
                        .token = &.{
                            .group = &.{
                                .n = 4,
                                .tokens = &.{&.{ .literal = "a" }},
                            },
                        },
                        .flavour = .greedy,
                    }),
                },
            },
        },
    }, group0T);
}
