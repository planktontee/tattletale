const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Scanner = @import("compiler/scanner.zig");
const RgxToken = Scanner.RgxToken;
const Quantifier = Scanner.Quantifier;

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

pub const RepeatLiteral = struct {
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

    repeatLiteral: *RepeatLiteral,
    repeatGroup: *RepeatGroupInstruction,

    pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
        try switch (self.*) {
            .literal => |value| w.print("'{s}'", .{value}),
            inline else => |value| w.print("{f}", .{value}),
        };
    }
};

instructions: []Instruction = undefined,
allocator: Allocator = undefined,
stack: std.ArrayList(State) = undefined,

const GroupFrame = struct {
    n: u16,
    instructionIdxStart: usize,
};

pub fn compile(self: *@This(), tokens: []*const RgxToken) !void {
    var instructions = try std.ArrayList(Instruction).initCapacity(self.allocator, 10);
    var groupFrames = try std.ArrayList(usize).initCapacity(self.allocator, 10);

    var i: usize = 0;
    var lastInstruction: ?*Instruction = null;

    while (i < tokens.len) : (i += 1) {
        switch (tokens[i].*) {
            .group => |n| {
                const groupInst = try self.allocator.create(GroupInstruction);
                groupInst.* = .{
                    .n = n,
                    .start = undefined,
                    .end = undefined,
                };

                try instructions.append(self.allocator, .{ .group = groupInst });
                try groupFrames.append(self.allocator, instructions.items.len - 1);
                lastInstruction = &instructions.items[instructions.items.len - 1];
            },
            .groupEnd => {
                const targetGroupIdx = groupFrames.pop().?;
                const targetGroupInst: *Instruction = @ptrCast(instructions.items.ptr + targetGroupIdx);
                const lastInst: *Instruction = @ptrCast(instructions.items.ptr + instructions.items.len - 1);

                switch (lastInst.*) {
                    .literal,
                    .repeatLiteral,
                    => {
                        switch (targetGroupInst.*) {
                            .literal,
                            .repeatLiteral,
                            => unreachable,
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

                lastInstruction = targetGroupInst;
            },
            .literal => |value| {
                try instructions.append(self.allocator, .{ .literal = value });
                lastInstruction = &instructions.items[instructions.items.len - 1];
            },
            .quantifier => |quantifier| {
                switch (lastInstruction.?.*) {
                    .group => |groupIns| {
                        const repeatGroupInstruction = try self.allocator.create(RepeatGroupInstruction);
                        repeatGroupInstruction.* = .{
                            .n = groupIns.n,
                            .start = groupIns.start,
                            .end = groupIns.end,
                            .quantifier = quantifier,
                        };
                        lastInstruction.?.* = .{
                            .repeatGroup = repeatGroupInstruction,
                        };
                    },
                    .literal => |literalIns| {
                        const repeatLiteral = try self.allocator.create(RepeatLiteral);
                        repeatLiteral.* = .{
                            .literal = literalIns,
                            .quantifier = quantifier,
                        };
                        lastInstruction.?.* = .{
                            .repeatLiteral = repeatLiteral,
                        };
                    },
                    .repeatGroup,
                    .repeatLiteral,
                    => unreachable,
                }
            },
        }
    }

    assert(groupFrames.items.len == 0);
    self.instructions = try instructions.toOwnedSlice(self.allocator);
}

const State = struct {
    pc: usize,
    cursor: usize,
    matchCount: usize,
};

const MatchState = enum {
    // Matching
    matching,
    backtracking,

    // Decision
    queryStack,

    // Conclusive
    failed,
    succeeded,
};

pub const MatchError = error{
    MatchFailed,
    TBA,
} || std.mem.Allocator.Error;

pub fn match(
    self: *@This(),
    text: []const u8,
) MatchError!void {
    self.stack = try .initCapacity(self.allocator, 10);

    var state: State = .{
        .pc = 0,
        .cursor = 0,
        .matchCount = 0,
    };

    stateLoop: switch (@as(MatchState, .matching)) {
        .matching,
        => {
            if (state.pc >= self.instructions.len)
                continue :stateLoop .succeeded;

            switch (self.instructions[state.pc]) {
                .group,
                => |groupInst| {
                    // TODO: save match
                    if (groupInst.n != 0) return MatchError.TBA;

                    state.pc += 1;
                    continue :stateLoop .matching;
                },
                .literal,
                => |literal| {
                    if (self.matchLiteral(text[state.cursor..], literal)) {
                        state.cursor += literal.len;
                        state.pc += 1;
                        continue :stateLoop .matching;
                    } else continue :stateLoop .queryStack;
                    unreachable;
                },
                .repeatGroup,
                => {
                    // Save only the last picked
                    return MatchError.TBA;
                },
                .repeatLiteral,
                => |repeatLiteral| {
                    state.matchCount = 0;
                    const range = repeatLiteral.quantifier.range;
                    const literal = repeatLiteral.literal;

                    switch (repeatLiteral.quantifier.flavour) {
                        .greedy,
                        => {
                            greedyLoop: while (state.matchCount < range.max) : (state.matchCount += 1) {
                                if (self.matchLiteral(text[state.cursor..], literal)) {
                                    state.cursor += literal.len;

                                    // Only add to stack retriable states
                                    // matchCount is one behind
                                    if (state.matchCount + 1 >= range.min)
                                        try self.stack.append(self.allocator, .{
                                            .cursor = state.cursor,
                                            .pc = state.pc,
                                            .matchCount = state.matchCount + 1,
                                        });

                                    continue :greedyLoop;
                                } else {
                                    if (state.matchCount >= range.min) {
                                        state.pc += 1;
                                        state.matchCount = 0;
                                        continue :stateLoop .matching;
                                    }

                                    // Should not populate stack if < min
                                    if (self.stack.getLastOrNull()) |last|
                                        assert(last.pc != state.pc);

                                    state.matchCount = 0;
                                    continue :stateLoop .queryStack;
                                }
                            }

                            if (state.matchCount == range.max) {
                                state.pc += 1;
                                state.matchCount = 0;
                                continue :stateLoop .matching;
                            }

                            unreachable;
                        },
                        .lazy,
                        => {
                            lazyLoop: while (state.matchCount < range.min) : (state.matchCount += 1) {
                                if (self.matchLiteral(text[state.cursor..], literal)) {
                                    state.cursor += literal.len;
                                    continue :lazyLoop;
                                } else {
                                    state.matchCount = 0;
                                    continue :stateLoop .queryStack;
                                }
                            }

                            try self.stack.append(self.allocator, state);
                            state.pc += 1;
                            state.matchCount = 0;
                            continue :stateLoop .matching;
                        },
                    }
                },
            }
        },
        // Merge with backtracking
        .queryStack,
        => {
            if (self.stack.pop()) |prevState| {
                state = prevState;
                continue :stateLoop .backtracking;
            } else continue :stateLoop .failed;
        },
        .backtracking,
        => {
            switch (self.instructions[state.pc]) {
                .literal,
                => unreachable,
                .group,
                .repeatGroup,
                => return MatchError.TBA,
                .repeatLiteral => |repeatLiteral| {
                    switch (repeatLiteral.quantifier.flavour) {
                        .greedy,
                        => {
                            // Forwards to next token, all valid matches are stacked
                            state.pc += 1;
                            continue :stateLoop .matching;
                        },
                        .lazy,
                        => {
                            // Try a new match lazily based on backtracking
                            const range = repeatLiteral.quantifier.range;
                            const literal = repeatLiteral.literal;

                            if (state.matchCount >= range.max) {
                                state.matchCount = 0;
                                continue :stateLoop .queryStack;
                            }

                            if (self.matchLiteral(text[state.cursor..], literal)) {
                                state.cursor += literal.len;
                                state.matchCount += 1;
                                try self.stack.append(self.allocator, state);

                                state.pc += 1;
                                state.matchCount = 0;
                                continue :stateLoop .matching;
                            } else {
                                state.matchCount = 0;
                                continue :stateLoop .queryStack;
                            }

                            unreachable;
                        },
                    }
                },
            }
        },
        .failed,
        => return MatchError.MatchFailed,
        .succeeded,
        => return,
    }
    unreachable;
}

fn matchLiteral(_: *const @This(), text: []const u8, literal: []const u8) bool {
    if (literal.len > text.len)
        return false;

    if (std.mem.eql(u8, literal, text[0..literal.len]))
        return true;

    return false;
}

pub fn format(
    self: *const @This(),
    w: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try w.writeAll("Instructions |\n");

    for (0.., self.instructions) |i, *instruction| {
        try w.print("             | {d}] {s} {f}\n", .{ i, @tagName(instruction.*), instruction.* });
    }
}
