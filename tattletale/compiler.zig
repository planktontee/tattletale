const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Scanner = @import("compiler/scanner.zig");

fn SLNode(T: type) type {
    return struct {
        data: T,
        next: ?*@This(),
    };
}

const HeadAndTailLinkedList = struct {
    first: ?*SLNode(*const RgxNode) = null,
    end: ?*SLNode(*const RgxNode) = null,
    size: usize = 0,

    pub fn prepend(list: *HeadAndTailLinkedList, newNode: *SLNode(*const RgxNode)) void {
        list.size += 1;
        newNode.next = list.first;
        list.first = newNode;
        if (list.end == null) list.end = newNode;
    }

    pub fn append(list: *HeadAndTailLinkedList, newNode: *SLNode(*const RgxNode)) void {
        list.size += 1;
        if (list.end) |last| {
            last.next = newNode;
        }
        list.end = newNode;
        if (list.first == null) list.first = newNode;
    }

    pub fn free(list: *HeadAndTailLinkedList, allocator: Allocator) void {
        while (list.first) |first| {
            list.first = first.next;
            allocator.destroy(first);
        }
        list.first = null;
        list.end = null;
    }

    pub fn pop(list: *HeadAndTailLinkedList) ?*SLNode(*const RgxNode) {
        const optTmp = list.first;
        if (optTmp) |tmp| {
            list.first = tmp.next;
            if (list.first == null) {
                list.end = null;
            }
        }
        return optTmp;
    }
};

const RgxNode = struct {
    token: Scanner.Token,
    previous: ?*const RgxNode = null,
    next: HeadAndTailLinkedList = .{},

    pub inline fn new(self: *RgxNode, token: Scanner.Token) void {
        self.* = .{
            .token = token,
        };
    }

    pub fn format(self: *const RgxNode, w: *Writer) Writer.Error!void {
        try w.print("self {x}", .{@intFromPtr(self)});
        if (self.previous) |prev| {
            try w.print(", prev {x}", .{@intFromPtr(prev)});
        }
        try w.writeAll(", token ");
        try self.token.format(w);

        if (self.next.size > 0) {
            try w.print(", next [{d}]\n", .{self.next.size});
            var optNode: ?*SLNode(*const RgxNode) = self.next.first;
            while (optNode) |node| {
                try w.print("     {x}", .{@intFromPtr(node.data)});
                optNode = node.next;
                if (optNode != null) {
                    try w.writeAll(",\n");
                }
            }
        }
    }

    pub fn deinit(self: *const RgxNode, allocator: Allocator) void {
        var a = self.next;
        a.free(allocator);
    }
};

root: *const RgxNode,
size: usize,

pub fn compileWithDebug(self: *Compiler, allocator: Allocator, pattern: []const u8) !void {
    var scanner: Scanner = undefined;
    var diagnostics: Scanner.Diagnostics = undefined;
    scanner.initWithDiag(allocator, &diagnostics, pattern);

    var size: usize = 0;
    var optPrevNode: ?*RgxNode = null;
    while (true) {
        const token = try scanner.next();
        var node = try allocator.create(RgxNode);
        node.new(token);

        if (optPrevNode) |prevNode| {
            const slNode = try allocator.create(SLNode(*const RgxNode));
            slNode.* = .{
                .data = node,
                .next = null,
            };
            prevNode.next.append(slNode);
            node.previous = prevNode;
        }

        if (size == 0) {
            self.root = node;
        }

        size += 1;
        optPrevNode = node;

        if (token == .done) break;
    }

    self.size = size;

    return;
}

pub fn visitNodes(self: *Compiler, allocator: Allocator, visitor: Visitor) !void {
    var map = std.AutoHashMapUnmanaged(*const RgxNode, void).empty;
    try map.ensureTotalCapacity(allocator, @intCast(self.size));
    defer map.deinit(allocator);

    var queue: HeadAndTailLinkedList = .{};

    var currOpt: ?*const RgxNode = self.root;
    while (currOpt) |curr| {
        map.putAssumeCapacity(curr, {});
        var optNext = curr.next.first;
        while (optNext) |next| {
            if (map.contains(next.data)) continue;

            const reminderNode = try allocator.create(SLNode(*const RgxNode));

            reminderNode.* = .{
                .data = next.data,
                .next = null,
            };

            queue.append(reminderNode);

            optNext = next.next;
        }

        if (queue.pop()) |next| {
            currOpt = next.data;
            allocator.destroy(next);
        } else {
            currOpt = null;
        }

        visitor.visit(curr);
    }
}

const Compiler = @This();

test "comp" {
    const t = std.testing;
    // var arena = std.heap.ArenaAllocator.init(t.allocator);
    // defer arena.deinit();
    // const allocator = arena.allocator();

    var compiler: Compiler = undefined;
    try compiler.compileWithDebug(t.allocator, "abcde{1,10}?");

    std.debug.print("Size - {x},{x},{x},{x},{x}\n", .{
        @sizeOf(usize),
        @sizeOf(*const RgxNode),
        @sizeOf(HeadAndTailLinkedList),
        @sizeOf(RgxNode),
        @sizeOf(Scanner.Token),
    });

    const visitor: Visitor = .{ .allocator = t.allocator };

    try compiler.visitNodes(t.allocator, visitor);
}

const Visitor = struct {
    allocator: Allocator,

    pub fn visit(self: *const @This(), node: *const RgxNode) void {
        std.debug.print("{f}\n", .{node});
        node.deinit(self.allocator);
        self.allocator.destroy(node);
    }
};

comptime {
    _ = @import("compiler/scanner.zig");
}
