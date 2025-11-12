const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Scanner = @import("compiler/scanner.zig");
const Literal = @import("compiler/literal.zig");
const Repeatable = Scanner.Repeatable;
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

pub const RgxNodeEnum = @typeInfo(RgxNode).@"union".tag_type.?;

pub const RgxNode = union(enum) {
    group,
    literal: *LiteralRgxNode,
    repeatable: *RepeatableRgxNode,

    match: MatchRange,
    failed: usize,

    pub fn next(self: *@This(), cursor: *Cursor) RgxNode {
        switch (self.*) {
            .literal,
            => |lit| return lit.next(cursor),
            // TODO: register to potentitial backtrack
            .repeatable,
            => |reap| return reap.next(cursor),
            .group,
            .match,
            .failed,
            => @panic("unsupported"),
        }
    }
};

pub const MatchRange = struct {
    start: usize,
    end: usize,

    pub fn slice(self: *const @This(), cursor: *const Cursor) []const u8 {
        return cursor.slice(self.start, self.end);
    }
};

pub const RepeatableRgxNode = struct {
    count: usize = 0,
    repeatable: *const Repeatable,
    node: RgxNode,
    start: usize = 0,

    pub fn init(repeatable: *const Repeatable, node: RgxNode, start: usize) @This() {
        return .{
            .count = 0,
            .repeatable = repeatable,
            .node = node,
            .start = start,
        };
    }

    // TODO: add backtrack

    pub fn next(self: *@This(), cursor: *Cursor) RgxNode {
        switch (self.repeatable.flavour) {
            .greedy => {
                outer: while (self.repeatable.range.max > self.count) {
                    while (true) {
                        var r = self.node.next(cursor);
                        _ = &r;
                        switch (r) {
                            .match => {
                                // TODO: register matches
                                self.count += 1;
                                self.node.literal.reset(cursor.i);
                                continue;
                            },
                            .failed => break :outer,
                            .group => @panic("not supported yet"),
                            else => continue,
                        }
                    }
                }

                if (!self.repeatable.range.in(self.count)) return .{ .failed = self.start };
                return .{
                    .match = .{
                        .start = self.start,
                        .end = cursor.i,
                    },
                };
            },
            .lazy => @panic("lazy not supported yet"),
        }
        unreachable;
    }
};

pub const Cursor = struct {
    data: []const u8,
    i: usize = 0,

    pub fn setCursors(self: *@This(), i: usize) void {
        assert(i <= self.data.len);
        self.i = i;
    }

    pub inline fn peek(self: *const @This()) u8 {
        assert(self.i < self.data.len);
        return self.data[self.i];
    }

    pub inline fn peekN(self: *const @This(), len: usize) []const u8 {
        assert(self.i + len <= self.data.len);
        return self.data[self.i .. self.i + len];
    }

    pub inline fn consume(self: *@This()) void {
        self.i += 1;
    }

    pub inline fn consumeN(self: *@This(), len: usize) void {
        self.i += len;
    }

    pub inline fn finished(self: *const @This()) bool {
        return self.i == self.data.len;
    }

    pub inline fn reminder(self: *const @This()) usize {
        return self.data.len - self.i;
    }

    pub inline fn reminderFrom(self: *const @This(), i: usize) usize {
        assert(self.data.len >= i);
        return self.data.len - i;
    }

    pub inline fn sliceFrom(self: *const @This(), start: usize) []const u8 {
        assert(start < self.i);
        return self.data[start..self.i];
    }

    pub inline fn slice(self: *const @This(), start: usize, end: usize) []const u8 {
        assert(end > start);
        assert(end <= self.data.len);
        return self.data[start..end];
    }
};

pub const LiteralRgxNode = struct {
    target: []const u8,
    start: usize = 0,

    pub fn init(target: []const u8, start: usize) @This() {
        return .{
            .target = target,
            .start = start,
        };
    }

    pub fn next(self: *@This(), cursor: *Cursor) RgxNode {
        // Short circuit
        if (self.target.len > cursor.reminderFrom(self.start)) return .{
            .failed = self.start,
        };

        for (self.target, cursor.peekN(self.target.len)) |c, tc| {
            if (c != tc) return .{
                .failed = self.start,
            };
        }

        cursor.consumeN(self.target.len);
        return .{
            .match = .{
                .start = self.start,
                .end = cursor.i,
            },
        };
    }

    pub fn reset(self: *@This(), start: usize) void {
        self.start = start;
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
