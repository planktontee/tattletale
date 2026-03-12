const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Scanner = @import("compiler/scanner.zig");
const RgxToken = Scanner.RgxToken;
const Quantifier = Scanner.Quantifier;
const Range = @import("compiler/range.zig");

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
    groupEnd: *Instruction,

    pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
        try switch (self.*) {
            .literal => |value| w.print("'{s}'", .{value}),
            .groupEnd => {},
            inline else => |value| w.print("{f}", .{value}),
        };
    }
};

pub const GroupResult = struct {
    start: usize,
    end: usize,
};

instructions: []Instruction = undefined,
allocator: Allocator = undefined,
stack: std.ArrayList(State) = undefined,
groupState: []State = undefined,
groups: []usize = undefined,
groupCount: usize = undefined,

pub fn compile(self: *@This(), tokens: []*const RgxToken) !void {
    var instructions = try std.ArrayList(Instruction).initCapacity(self.allocator, 10);
    var groupFrames = try std.ArrayList(usize).initCapacity(self.allocator, 10);

    var i: usize = 0;
    self.groupCount = 0;

    while (i < tokens.len) : (i += 1) {
        switch (tokens[i].*) {
            .group => |n| {
                const groupInst = try self.allocator.create(GroupInstruction);
                groupInst.* = .{
                    .n = n,
                    .start = undefined,
                    .end = undefined,
                };

                self.groupCount += 1;
                try instructions.append(self.allocator, .{ .group = groupInst });
                try groupFrames.append(self.allocator, instructions.items.len - 1);
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

                try instructions.append(self.allocator, .{ .groupEnd = targetGroupInst });
            },
            .literal => |value| {
                try instructions.append(self.allocator, .{ .literal = value });
            },
            .quantifier => |quantifier| {
                const lastInst: *Instruction = @ptrCast(instructions.items.ptr + instructions.items.len - 1);
                switch (lastInst.*) {
                    .groupEnd => |groupInstTagged| {
                        const groupInst = groupInstTagged.group;

                        const repeatGroupInstruction = try self.allocator.create(RepeatGroupInstruction);
                        repeatGroupInstruction.* = .{
                            .n = groupInst.n,
                            .start = groupInst.start,
                            .end = groupInst.end,
                            .quantifier = quantifier,
                        };

                        groupInstTagged.* = .{ .repeatGroup = repeatGroupInstruction };
                    },
                    .literal => |literalIns| {
                        const repeatLiteral = try self.allocator.create(RepeatLiteral);
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

pub const EMPTY_MATCH: usize = std.math.maxInt(usize);

pub fn match(
    self: *@This(),
    text: []const u8,
) MatchError!void {
    self.stack = try .initCapacity(self.allocator, 10);
    self.groups = try self.allocator.alloc(usize, self.groupCount * 2);
    @memset(self.groups, EMPTY_MATCH);

    self.groupState = try self.allocator.alloc(State, self.groupCount);

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
                    self.groupState[groupInst.n] = state;

                    state.pc += 1;
                    continue :stateLoop .matching;
                },
                .groupEnd => |groupInst| {
                    const initialStateIdx = switch (groupInst.*) {
                        .literal,
                        .repeatLiteral,
                        .groupEnd,
                        => unreachable,
                        inline else => |groupInstInner| groupInstInner.n,
                    };

                    var initialState: *State = @ptrCast(self.groupState.ptr + initialStateIdx);

                    // TODO: refactor to method
                    const groupInstTagged = self.instructions[initialState.pc];
                    switch (groupInstTagged) {
                        .literal,
                        .groupEnd,
                        .repeatLiteral,
                        => unreachable,
                        inline else => |group| {
                            const groupIdx: usize = group.n * 2;
                            self.groups[groupIdx] = initialState.cursor;
                            self.groups[groupIdx + 1] = state.cursor;
                        },
                    }

                    switch (groupInst.*) {
                        .literal,
                        .repeatLiteral,
                        .groupEnd,
                        => unreachable,
                        .group => state.pc += 1,
                        .repeatGroup => |repeatGroupInst| {
                            const quantifier = repeatGroupInst.quantifier;
                            switch (quantifier.flavour) {
                                .lazy => return MatchError.TBA,
                                .greedy => {
                                    initialState.matchCount += 1;

                                    const range = quantifier.range;

                                    if (initialState.matchCount == range.max) {
                                        state.pc += 1;
                                        continue :stateLoop .matching;
                                    }

                                    if (initialState.matchCount >= range.min) {
                                        try self.stack.append(self.allocator, .{
                                            .cursor = state.cursor,
                                            .pc = initialState.pc,
                                            .matchCount = initialState.matchCount,
                                        });
                                    }

                                    state.pc = initialState.pc + 1;
                                },
                            }
                        },
                    }

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
                => |groupInst| {
                    state.matchCount = 0;
                    self.groupState[groupInst.n] = state;

                    if (groupInst.quantifier.range.min == 0) {
                        try self.stack.append(self.allocator, .{
                            .cursor = state.cursor,
                            .pc = state.pc,
                            .matchCount = state.matchCount,
                        });
                    }

                    state.pc += 1;
                    continue :stateLoop .matching;
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
                .literal, .group, .groupEnd => unreachable,
                .repeatGroup,
                => |repeatGroupInst| {
                    switch (repeatGroupInst.quantifier.flavour) {
                        .greedy,
                        => {
                            // Forwards to next token, all valid matches are stacked
                            state.pc = repeatGroupInst.end + 1;
                            continue :stateLoop .matching;
                        },
                        .lazy,
                        => return MatchError.TBA,
                    }
                },
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
