const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Scanner = @import("compiler/scanner.zig");
const Literal = @import("compiler/literal.zig");
const Token = Scanner.Token;
const assert = std.debug.assert;

pub fn LLNode(T: type) type {
    return struct {
        data: T,
        next: ?*@This(),
    };
}

pub fn LinkedList(T: type) type {
    return struct {
        first: ?*LLNode(T) = null,
        end: ?*LLNode(T) = null,
        size: usize = 0,

        pub fn prepend(list: *@This(), allocator: Allocator) !void {
            const newNode = try allocator.create(LLNode(T));
            newNode.next = list.first;
            list.first = newNode;
            list.size += 1;
        }

        pub fn pop(list: *@This(), allocator: Allocator) ?T {
            if (list.first == null) return null;
            const node = list.last.?;
            defer allocator.destroy(node);

            list.last = node.next;
            return node.data;
        }
    };
}

pub const State = enum {
    matching,
    succeeded,
    failed,
};

pub const RgxNode = union(enum) {
    group,
    literal: *LiteralRgxNode,
    repeatable,

    matched,
    failed,

    pub fn next(self: *@This(), c: u8) RgxNode {
        switch (self.*) {
            .literal,
            => |lit| return lit.next(c),
            .group,
            .repeatable,
            .matched,
            .failed,
            => @panic("unsupported"),
        }
    }
};

pub const LiteralRgxNode = struct {
    i: usize = 0,
    token: *const Token,

    pub fn init(token: *const Token) @This() {
        assert(token.* == .literal);
        return .{
            .i = 0,
            .token = token,
        };
    }

    pub fn next(self: *@This(), c: u8) RgxNode {
        assert(self.i < self.token.literal.len);
        // should this reset?
        if (self.token.literal[self.i] != c) return .failed;

        self.i += 1;
        if (self.i == self.token.literal.len) return .matched;
        return .{ .literal = self };
    }
};

pub fn compileWithDebug(_: *Compiler, allocator: Allocator, pattern: []const u8) !RgxNode {
    var scanner: Scanner = undefined;
    var diagnostics: Scanner.Diagnostics = undefined;
    try scanner.initWithDiag(allocator, &diagnostics, pattern);

    const root = try scanner.collectWithReport();
    var nodeOpt: ?*const Scanner.Token = root;
    while (nodeOpt) |node| {
        switch (node.*) {
            .group,
            .repeatable,
            => {},
            .literal,
            => {},
        }
        nodeOpt = null;
    }

    return;
}

const Compiler = @This();
