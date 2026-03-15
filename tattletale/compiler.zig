const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Scanner = @import("compiler/scanner.zig");
const RgxToken = Scanner.RgxToken;
const Quantifier = Scanner.Quantifier;
const Range = @import("compiler/range.zig");
const Matcher = @import("matcher.zig").Matcher;

pub const GroupInstruction = struct {
    n: u16,
    start: usize,
    end: usize,

    pub fn format(
        self: *const @This(),
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try w.print("{d} ins[{d}..{d}]", .{ self.n, self.start, self.end });
    }
};

pub const RepeatGroupInstruction = struct {
    n: u16,
    start: usize,
    end: usize,
    quantifier: *const Quantifier,

    pub fn format(
        self: *const @This(),
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try w.print("{d} ins[{d}..{d}] {f}", .{ self.n, self.start, self.end, self.quantifier.* });
    }
};

pub const RepeatLiteralInstruction = struct {
    literal: []const u8,
    quantifier: *const Quantifier,

    pub fn format(
        self: *const @This(),
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try w.print("'{s}' {f}", .{ self.literal, self.quantifier.* });
    }
};

pub const Instruction = union(enum) {
    literal: []const u8,
    group: *GroupInstruction,

    repeatLiteral: *RepeatLiteralInstruction,
    repeatGroup: *RepeatGroupInstruction,
    groupEnd: *Instruction,

    pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
        try w.print(".{s} ", .{@tagName(self.*)});
        try switch (self.*) {
            .literal => |value| w.print("'{s}'", .{value}),
            .groupEnd => {},
            inline else => |value| w.print("{f}", .{value}),
        };
    }
};

pub fn Compiler(comptime withDiagnostics: bool) type {
    return struct {
        scannerDiagnostics: if (withDiagnostics) Scanner.Diagnostics else void = undefined,
        tokens: []const RgxToken = undefined,

        pub const init: @This() = .{};

        pub const Error = Scanner.Error || Allocator.Error;

        pub fn compile(
            self: *@This(),
            allocator: Allocator,
            pattern: []const u8,
            matcher: *Matcher(withDiagnostics),
        ) Error!void {
            var scanner: Scanner.Scanner(withDiagnostics) = undefined;
            try scanner.init(
                allocator,
                pattern,
                if (withDiagnostics) &self.scannerDiagnostics else {},
            );
            self.tokens = try scanner.collectWithReport();

            var instructions = try std.ArrayListUnmanaged(Instruction).initCapacity(allocator, self.tokens.len);
            // len / 2 is arbitrary here
            var groupFrames = try std.ArrayListUnmanaged(usize).initCapacity(allocator, self.tokens.len / 2);

            var i: usize = 0;
            matcher.groupCount = scanner.groupCount;

            while (i < self.tokens.len) : (i += 1) {
                switch (self.tokens[i]) {
                    .group => |n| {
                        const groupInst = try allocator.create(GroupInstruction);
                        groupInst.* = .{
                            .n = n,
                            .start = undefined,
                            .end = undefined,
                        };

                        instructions.appendAssumeCapacity(.{ .group = groupInst });
                        try groupFrames.append(allocator, instructions.items.len - 1);
                    },
                    .groupEnd => {
                        const targetGroupIdx = groupFrames.pop().?;
                        const targetGroupInst: *Instruction = @ptrCast(instructions.items.ptr + targetGroupIdx);
                        const lastInst: *Instruction = @ptrCast(instructions.items.ptr + instructions.items.len - 1);

                        groupEndLoop: switch (lastInst.*) {
                            .groupEnd => |groupInst| continue :groupEndLoop groupInst.*,
                            .literal,
                            .repeatLiteral,
                            => {
                                switch (targetGroupInst.*) {
                                    .literal, .repeatLiteral, .groupEnd => unreachable,
                                    inline else => |targetGroup| {
                                        targetGroup.start = targetGroupIdx + 1;
                                        targetGroup.end = instructions.items.len;
                                    },
                                }
                            },
                            inline else => |lastInstGroup| {
                                switch (targetGroupInst.*) {
                                    .literal,
                                    .repeatLiteral,
                                    .groupEnd,
                                    => unreachable,
                                    inline else => |targetGroup| {
                                        if (lastInstGroup.n == targetGroup.n) {
                                            targetGroup.start = targetGroupIdx;
                                            targetGroup.end = targetGroupIdx + 1;
                                        } else {
                                            targetGroup.start = targetGroupIdx + 1;
                                            targetGroup.end = instructions.items.len;
                                        }
                                    },
                                }
                            },
                        }

                        instructions.appendAssumeCapacity(.{ .groupEnd = targetGroupInst });
                    },
                    .literal => |value| {
                        instructions.appendAssumeCapacity(.{ .literal = value });
                    },
                    .quantifier => |quantifier| {
                        const lastInst: *Instruction = @ptrCast(instructions.items.ptr + instructions.items.len - 1);
                        switch (lastInst.*) {
                            .groupEnd => |groupInstTagged| {
                                const groupInst = groupInstTagged.group;

                                const repeatGroupInstruction = try allocator.create(RepeatGroupInstruction);
                                repeatGroupInstruction.* = .{
                                    .n = groupInst.n,
                                    .start = groupInst.start,
                                    .end = groupInst.end,
                                    .quantifier = quantifier,
                                };

                                groupInstTagged.* = .{ .repeatGroup = repeatGroupInstruction };
                            },
                            .literal => |literalIns| {
                                const repeatLiteral = try allocator.create(RepeatLiteralInstruction);
                                repeatLiteral.* = .{
                                    .literal = literalIns,
                                    .quantifier = quantifier,
                                };
                                lastInst.* = .{ .repeatLiteral = repeatLiteral };
                            },
                            .group,
                            .repeatGroup,
                            .repeatLiteral,
                            => unreachable,
                        }
                    },
                }
            }

            // TODO: cleanup tokens

            assert(groupFrames.items.len == 0);
            groupFrames.deinit(allocator);
            matcher.instructions = instructions.items;
        }
    };
}
