// const std = @import("std");
// const Allocator = std.mem.Allocator;
// const Writer = std.Io.Writer;
// const Scanner = @import("compiler/scanner.zig");
// const Literal = @import("compiler/literal.zig");
// const Quantifier = Scanner.Quantifier;
// const Token = Scanner.RgxToken;
// const assert = std.debug.assert;
//
// pub fn LLNode(T: type) type {
//     return struct {
//         data: T,
//         next: ?*@This(),
//     };
// }
//
// pub fn LinkedList(T: type) type {
//     return struct {
//         first: ?*LLNode(T) = null,
//         end: ?*LLNode(T) = null,
//         size: usize = 0,
//
//         pub fn prepend(list: *@This(), allocator: Allocator) !void {
//             const newNode = try allocator.create(LLNode(T));
//             newNode.next = list.first;
//             list.first = newNode;
//             list.size += 1;
//         }
//
//         pub fn pop(list: *@This(), allocator: Allocator) ?T {
//             if (list.first == null) return null;
//             const node = list.last.?;
//             defer allocator.destroy(node);
//
//             list.last = node.next;
//             return node.data;
//         }
//     };
// }
//
// pub const State = union(enum) {
//     finished: usize,
//     partial: usize,
//     failed,
// };
//
// pub const RgxNodeEnum = @typeInfo(RgxNode).@"union".tag_type.?;
//
// pub const RgxNode = union(enum) {
//     group,
//     literal: *LiteralRgxNode,
//     quantifier: *QuantifierRgxNode,
//
//     pub fn next(self: *@This(), cursor: *Cursor) State {
//         switch (self.*) {
//             .literal,
//             => |lit| return lit.next(cursor),
//             // TODO: register to potentitial backtrack
//             .quantifier,
//             => |reap| return reap.next(cursor),
//             .group,
//             => assert(false),
//         }
//         unreachable;
//     }
// };
//
// pub const SavedState = struct {
//     i: usize,
//     start: usize,
//     end: usize,
// };

// pub const Match = struct {
//     nodes: []*RgxNode,
//     allocator: Allocator,
//
//     state: std.AutoHashMapUnmanaged(
//         *RgxNode,
//         *std.ArrayListUnmanaged(*const SavedState),
//     ),
//
//     pub const _State = enum {
//         init,
//         matching,
//         done,
//     };
//
//     pub fn init(allocator: Allocator, nodes: []*RgxNode) @This() {
//         return .{
//             .allocator = allocator,
//             .state = .empty,
//             .nodes = nodes,
//         };
//     }
//
//     // NOTE:
//     // Sketch:
//     // - move forward by nodes
//     // - group0 matches entire list
//     // - match sequentially the nodes
//     // - on failure, ask all matched nodes if they can rollback
//     // - every node that can't be rolled back, needs resetting
//     // - nodes that can be rolled back, need an internal cache state to roll back to
//     // - rollback needs to also rollback cursor
//     // - if all nodes are resetted, we restore cursor and +1 and try again
//     //
//     // TODO:
//     // Stricter state handling
//     // - failures will require resets on handlers
//     // - failures dont move cursor
//     // - partials are not exposes, are used as:wq internal states
//     //
//     // TODO:
//     //
//
//     pub fn next(self: *@This(), cursor: *Cursor) State {
//         var i: usize = 0;
//         var state: _State = .init;
//         var start: usize = 0;
//         while (true) {
//             if (cursor.finished()) {
//                 if (state != .done) {
//                     // TODO: backtrack
//                     assert(false);
//                 } else {
//                     const last = self.state.get(self.nodes[self.nodes.len - 1]).?;
//                     return .{ .finished = last.getLast().end };
//                 }
//             }
//
//             const node = self.nodes[i];
//             const result = node.next(cursor);
//             switch (result) {
//                 .finished => i += 1,
//                 .partial => |end| {
//                     switch (node.*) {
//                         .quantifier => |rp| {
//                             const list = if (self.state.get(node)) |list| list else rv: {
//                                 const list = try self.allocator.create(std.ArrayListUnmanaged(*const SavedState));
//                                 list.* = .empty;
//                                 break :rv list;
//                             };
//                             const ss = try self.allocator.create(SavedState);
//                             ss.* = .{
//                                 .i = rp.count,
//                                 .start = start,
//                                 .end = end,
//                             };
//                             try list.append(self.allocator, ss);
//                             start = end;
//                         },
//                         .group, .literal => assert(false),
//                     }
//                 },
//                 .failed => {
//                     switch (state) {
//                         .init => cursor.consume(),
//                         .matching => {
//                             // TODO: backtrack
//                             assert(false);
//                         },
//                     }
//                 },
//             }
//         }
//     }
// };

// pub const QuantifierRgxNode = struct {
//     count: usize = 0,
//     quantifier: *const Quantifier,
//     node: RgxNode,
//
//     pub fn init(quantifier: *const Quantifier, node: RgxNode) @This() {
//         return .{
//             .count = 0,
//             .quantifier = quantifier,
//             .node = node,
//         };
//     }
//
//     // TODO: add backtrack
//
//     // TODO: internalize state
//     pub fn next(self: *@This(), cursor: *Cursor) State {
//         switch (self.quantifier.flavour) {
//             .greedy => {
//                 const range = self.quantifier.range;
//                 assert(self.count < range.max);
//
//                 const start = cursor.i;
//                 switch (self.node.next(cursor)) {
//                     .finished => |end| {
//                         self.count += 1;
//                         if (self.count == range.max) {
//                             return .{ .finished = end };
//                         }
//                         return .{ .partial = end };
//                     },
//                     .failed => {
//                         assert(start == cursor.i);
//                         if (range.in(self.count)) return .{
//                             .finished = cursor.i,
//                         };
//                         return .failed;
//                     },
//                     .partial => assert(false),
//                 }
//             },
//             .lazy => @panic("lazy not supported yet"),
//         }
//         unreachable;
//     }
// };
//
// pub const LiteralRgxNode = struct {
//     target: []const u8,
//
//     pub fn init(target: []const u8) @This() {
//         return .{
//             .target = target,
//         };
//     }
//
//     pub fn next(self: *@This(), cursor: *Cursor) State {
//         // Short circuit
//         if (self.target.len > cursor.reminder()) return .failed;
//
//         for (self.target, cursor.peekN(self.target.len)) |c, tc| {
//             if (c != tc) return .failed;
//         }
//
//         cursor.consumeN(self.target.len);
//         return .{ .finished = cursor.i };
//     }
// };
//
// pub const Cursor = struct {
//     data: []const u8,
//     i: usize = 0,
//
//     pub fn setCursors(self: *@This(), i: usize) void {
//         assert(i <= self.data.len);
//         self.i = i;
//     }
//
//     pub inline fn peek(self: *const @This()) u8 {
//         assert(self.i < self.data.len);
//         return self.data[self.i];
//     }
//
//     pub inline fn peekN(self: *const @This(), len: usize) []const u8 {
//         assert(self.i + len <= self.data.len);
//         return self.data[self.i .. self.i + len];
//     }
//
//     pub inline fn consume(self: *@This()) void {
//         self.i += 1;
//     }
//
//     pub inline fn consumeN(self: *@This(), len: usize) void {
//         self.i += len;
//     }
//
//     pub inline fn finished(self: *const @This()) bool {
//         return self.i == self.data.len;
//     }
//
//     pub inline fn reminder(self: *const @This()) usize {
//         return self.data.len - self.i;
//     }
//
//     pub inline fn reminderFrom(self: *const @This(), i: usize) usize {
//         assert(self.data.len >= i);
//         return self.data.len - i;
//     }
//
//     pub inline fn sliceFrom(self: *const @This(), start: usize) []const u8 {
//         assert(start < self.i);
//         return self.data[start..self.i];
//     }
//
//     pub inline fn slice(self: *const @This(), start: usize, end: usize) []const u8 {
//         assert(end > start);
//         assert(end <= self.data.len);
//         return self.data[start..end];
//     }
// };
//
// pub fn compileWithDebug(_: *Compiler, allocator: Allocator, pattern: []const u8) !RgxNode {
//     var scanner: Scanner = undefined;
//     var diagnostics: Scanner.Diagnostics = undefined;
//     try scanner.initWithDiag(allocator, &diagnostics, pattern);
//
//     const root = try scanner.collectWithReport();
//     var nodeOpt: ?*const Scanner.RgxToken = root;
//     while (nodeOpt) |node| {
//         switch (node.*) {
//             .group,
//             .quantifier,
//             => {},
//             .literal,
//             => {},
//         }
//         nodeOpt = null;
//     }
//
//     return;
// }
//
// const Compiler = @This();
