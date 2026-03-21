const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Compiler = @import("compiler.zig");
const Instruction = Compiler.Instruction;
const GroupInstruction = Compiler.GroupInstruction;
const RepeatGroupInstruction = Compiler.RepeatGroupInstruction;
const RepeatLiteralInstruction = Compiler.RepeatLiteralInstruction;

const State = struct {
    pc: usize,
    cursor: usize,
    start: usize,
    matchCount: usize,

    pub fn format(
        self: *const @This(),
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try w.print("pc {d} start {d} cursor {d} count {d}", .{ self.pc, self.start, self.cursor, self.matchCount });
    }
};

const EnrichedState = struct {
    matchState: MatchState,
    state: State,
};

const MatchState = enum {
    // Matching
    matching,
    backtracking,

    // Conclusive
    failed,
    succeeded,
};

pub const MatchError = error{
    MatchFailed,
    TBA,
} ||
    std.mem.Allocator.Error;

pub const EMPTY_MATCH: usize = std.math.maxInt(usize);

pub fn Matcher(comptime diagnostics: bool) type {
    return struct {
        instructions: []Instruction = undefined,
        allocator: Allocator = undefined,
        stackHash: std.AutoHashMap(State, void) = undefined,
        stack: std.ArrayList(State) = undefined,
        groupState: []State = undefined,
        groups: []usize = undefined,
        groupCount: usize = undefined,
        runStack: if (diagnostics) std.ArrayList(EnrichedState) else void = if (diagnostics) undefined else {},

        pub fn init(self: *@This(), allocator: Allocator) void {
            self.allocator = allocator;
        }

        pub fn match(
            self: *@This(),
            text: []const u8,
        ) anyerror!void {
            if (diagnostics) self.runStack = try .initCapacity(self.allocator, 1);

            self.stackHash = .init(self.allocator);
            self.stack = try .initCapacity(self.allocator, 10);
            self.groups = try self.allocator.alloc(usize, self.groupCount * 2);
            @memset(self.groups, EMPTY_MATCH);

            self.groupState = try self.allocator.alloc(State, self.groupCount);

            var state: State = .{
                .pc = 0,
                .start = 0,
                .cursor = 0,
                .matchCount = 0,
            };

            var matchState: MatchState = .matching;
            stateLoop: while (true) {
                if (diagnostics and
                    (matchState == .matching and state.pc < self.instructions.len or matchState != .matching))
                {
                    try self.runStack.append(self.allocator, .{
                        .matchState = matchState,
                        .state = state,
                    });
                }

                switch (matchState) {
                    .matching,
                    => {
                        if (state.pc >= self.instructions.len) {
                            matchState = .succeeded;
                            continue :stateLoop;
                        }

                        switch (self.instructions[state.pc]) {
                            .group,
                            => |groupInst| {
                                // We need to reload matchCount later
                                // We need to restore state.start over the matches as well
                                self.groupState[groupInst.n] = state;

                                state.pc += 1;
                                continue :stateLoop;
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

                                switch (groupInst.*) {
                                    .literal,
                                    .groupEnd,
                                    .repeatLiteral,
                                    => unreachable,
                                    inline else => |group| {
                                        const groupIdx: usize = group.n * 2;

                                        if (initialState.start > state.cursor) {
                                            const out = std.fs.File.stdout();
                                            const buff = try self.allocator.alloc(u8, 1 << 20);
                                            defer self.allocator.free(buff);
                                            var outFsW = out.writer(buff);
                                            const outW = &outFsW.interface;
                                            try self.printDiagnosis(outW, text);
                                            try outW.print("Curr: {f}\n", .{state});
                                            try outW.print("InG: {f}\n", .{initialState.*});
                                            try outW.flush();
                                            assert(false);
                                        }

                                        if (initialState.start != state.cursor) {
                                            self.groups[groupIdx] = initialState.start;
                                            self.groups[groupIdx + 1] = state.cursor;
                                        }
                                    },
                                }

                                switch (groupInst.*) {
                                    .literal,
                                    .repeatLiteral,
                                    .groupEnd,
                                    => unreachable,
                                    .group => {
                                        initialState.cursor = state.cursor;
                                        state.pc += 1;
                                        continue :stateLoop;
                                    },
                                    .repeatGroup => |repeatGroupInst| {
                                        const quantifier = repeatGroupInst.quantifier;
                                        switch (quantifier.flavour) {
                                            .lazy => return MatchError.TBA,
                                            .greedy => {
                                                initialState.matchCount += 1;
                                                const range = quantifier.range;

                                                if (initialState.matchCount == range.max) {
                                                    initialState.start = state.cursor;
                                                    initialState.cursor = state.cursor;
                                                    state.pc += 1;
                                                    continue :stateLoop;
                                                }

                                                if (initialState.matchCount >= range.min) {
                                                    try self.stackState(.{
                                                        .start = initialState.start,
                                                        .cursor = state.cursor,
                                                        .pc = initialState.pc,
                                                        .matchCount = initialState.matchCount,
                                                    });
                                                }

                                                // Move initial cursor to do the next match
                                                initialState.start = state.cursor;
                                                state.start = state.cursor;
                                                state.pc = initialState.pc + 1;
                                                continue :stateLoop;
                                            },
                                        }
                                    },
                                }
                                unreachable;
                            },
                            .literal,
                            => |literal| {
                                if (self.matchLiteral(text[state.cursor..], literal)) {
                                    state.cursor += literal.len;
                                    state.start = state.cursor;
                                    state.pc += 1;
                                    continue :stateLoop;
                                } else {
                                    matchState = .backtracking;
                                    continue :stateLoop;
                                }
                                unreachable;
                            },
                            .repeatGroup,
                            => |groupInst| {
                                state.matchCount = 0;
                                self.groupState[groupInst.n] = state;

                                if (groupInst.quantifier.range.min == 0) {
                                    try self.stackState(.{
                                        .pc = state.pc,
                                        .start = state.start,
                                        .cursor = state.cursor,
                                        .matchCount = state.matchCount,
                                    });
                                }

                                state.pc += 1;
                                continue :stateLoop;
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
                                                    try self.stackState(.{
                                                        .start = state.cursor,
                                                        .cursor = state.cursor,
                                                        .pc = state.pc,
                                                        .matchCount = state.matchCount + 1,
                                                    });

                                                continue :greedyLoop;
                                            } else {
                                                if (state.matchCount >= range.min) {
                                                    state.pc += 1;
                                                    state.start = state.cursor;
                                                    state.matchCount = 0;
                                                    continue :stateLoop;
                                                }

                                                // Should not populate stack if < min
                                                if (self.stack.getLastOrNull()) |last|
                                                    assert(last.pc != state.pc);

                                                matchState = .backtracking;
                                                continue :stateLoop;
                                            }
                                        }

                                        if (state.matchCount == range.max) {
                                            state.pc += 1;
                                            state.start = state.cursor;
                                            state.matchCount = 0;
                                            continue :stateLoop;
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
                                                matchState = .backtracking;
                                                continue :stateLoop;
                                            }
                                        }

                                        try self.stackState(state);
                                        state.pc += 1;
                                        state.start = state.cursor;
                                        state.matchCount = 0;
                                        continue :stateLoop;
                                    },
                                }
                            },
                        }
                    },
                    .backtracking,
                    => {
                        if (self.stack.pop()) |prevState| {
                            state = prevState;
                        } else {
                            matchState = .failed;
                            continue :stateLoop;
                        }

                        switch (self.instructions[state.pc]) {
                            .literal, .group, .groupEnd => unreachable,
                            .repeatGroup,
                            => |repeatGroupInst| {
                                switch (repeatGroupInst.quantifier.flavour) {
                                    .greedy,
                                    => {
                                        const initState: *State = @ptrCast(self.groupState.ptr + repeatGroupInst.n);

                                        initState.start = state.start;
                                        initState.cursor = state.cursor;
                                        initState.matchCount = state.matchCount;

                                        // Forwards to next token, all valid matches are stacked
                                        // restore last match
                                        const groupIdx = repeatGroupInst.n * 2;
                                        self.groups[groupIdx] = state.start;
                                        self.groups[groupIdx + 1] = state.cursor;

                                        state.pc = repeatGroupInst.end + 1;
                                        matchState = .matching;
                                        continue :stateLoop;
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
                                        matchState = .matching;
                                        continue :stateLoop;
                                    },
                                    .lazy,
                                    => {
                                        // Try a new match lazily based on backtracking
                                        const range = repeatLiteral.quantifier.range;
                                        const literal = repeatLiteral.literal;

                                        if (state.matchCount >= range.max) {
                                            matchState = .backtracking;
                                            continue :stateLoop;
                                        }

                                        if (self.matchLiteral(text[state.cursor..], literal)) {
                                            state.cursor += literal.len;
                                            state.matchCount += 1;
                                            try self.stackState(state);

                                            state.pc += 1;
                                            state.matchCount = 0;
                                            state.start = state.cursor;
                                            matchState = .matching;
                                            continue :stateLoop;
                                        } else {
                                            matchState = .backtracking;
                                            continue :stateLoop;
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

        pub fn stackState(self: *@This(), state: State) !void {
            if (!self.stackHash.contains(state)) {
                try self.stackHash.put(state, {});
                try self.stack.append(self.allocator, state);
            }
        }

        pub fn format(
            self: *const @This(),
            w: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try w.writeAll("Instructions |\n");

            for (0.., self.instructions) |i, *instruction| {
                try w.print("             | {d}] {f}\n", .{ i, instruction.* });
            }
        }

        pub fn printDiagnosis(
            self: *const @This(),
            w: *std.Io.Writer,
            text: []const u8,
        ) std.Io.Writer.Error!void {
            if (!diagnostics) return;

            try w.writeAll("\x1b[1;37m");
            for (self.runStack.items) |enrichedState| {
                if (enrichedState.state.cursor > 0) try w.writeAll(text[0..enrichedState.state.cursor]);
                try w.print("<{s}> | {d}] .{s}]", .{ text[enrichedState.state.cursor..], enrichedState.state.pc, @tagName(enrichedState.matchState) });
                if (enrichedState.state.pc < self.instructions.len and enrichedState.matchState != .backtracking)
                    try w.print(" {f}\n", .{self.instructions[enrichedState.state.pc]})
                else
                    try w.writeAll("\n");
            }

            for (0..self.groupCount) |i| {
                const groupIdx: usize = i * 2;
                const start = self.groups[groupIdx];
                const end = self.groups[groupIdx + 1];

                if (start == EMPTY_MATCH and end == EMPTY_MATCH) {
                    try w.print("Group {d}] <empty match>\n", .{i});
                } else if (start != EMPTY_MATCH and end == EMPTY_MATCH) {
                    try w.print("Group {d}] <partial state [{d}, EMPTY]>\n", .{ i, start });
                } else if (start == EMPTY_MATCH and end != EMPTY_MATCH) {
                    try w.print("Group {d}] <partial state [EMPTY, {d}]>\n", .{ i, end });
                } else if (start < end) {
                    const piece = text[start..end];
                    try w.print("Group {d}] {s} [{d}, {d}]\n", .{ i, piece, start, end });
                } else {
                    try w.print("Group {d}] Bad state [{d}, {d}]\n", .{ i, start, end });
                }
            }
            try w.writeAll("\x1b[0m");

            for (self.stack.items, 0..) |item, i| {
                try w.print("Backtrack {d}] {f}\n", .{ i, item });
            }
        }
    };
}
