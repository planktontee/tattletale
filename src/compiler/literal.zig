const std = @import("std");
const Token = @import("scanner.zig").Token;

pub fn of(c: u8) *const Token {
    return switch (c) {
        inline else => |cC| &.{ .literal = &.{cC} },
    };
}
