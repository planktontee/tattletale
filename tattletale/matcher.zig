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

    pub fn jumpInstructionTo(self: *@This(), idx: usize) void {
        self.pc = idx;
    }

    pub fn nextInstruction(self: *@This()) void {
        self.pc += 1;
    }

    pub fn resetAndNextInstruction(self: *@This()) void {
        self.nextInstruction();
        self.restartMatchCount();
        self.resetStart();
    }

    pub fn restartMatchCount(self: *@This()) void {
        self.matchCount = 0;
    }

    pub fn moveCursorBy(self: *@This(), count: usize) void {
        self.cursor += count;
    }

    pub fn moveCursorTo(self: *@This(), idx: usize) void {
        self.cursor = idx;
    }

    pub fn resetStart(self: *@This()) void {
        self.start = self.cursor;
    }

    pub fn countMatch(self: *@This()) void {
        self.matchCount += 1;
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

    pub fn match(self: *@This()) void {
        self.* = .matching;
    }

    pub fn succeed(self: *@This()) void {
        self.* = .succeeded;
    }

    pub fn backtrack(self: *@This()) void {
        self.* = .backtracking;
    }

    pub fn fail(self: *@This()) void {
        self.* = .failed;
    }

    pub fn isMatching(self: *const @This()) bool {
        return self.* == .matching;
    }

    pub fn isNotMatching(self: *const @This()) bool {
        return !self.isMatching();
    }
};

pub const MatchError = error{
    MatchFailed,
    TBA,
} ||
    std.mem.Allocator.Error;

pub const EMPTY_MATCH: usize = std.math.maxInt(usize);

const RepeatableGroupState = enum {
    @"continue",
    finished,
};

pub fn Matcher(comptime diagnostics: bool) type {
    return struct {
        allocator: Allocator = undefined,
        instructions: []Instruction = undefined,
        groupCount: usize = undefined,
        // Hashset to avoid revisinting states during backtrack
        backtrackVisitor: std.AutoHashMap(State, void) = undefined,
        // Backtrack stack
        stack: std.ArrayList(State) = undefined,
        // Shadow state for groups, treated completely iteratively
        groupState: []State = undefined,
        // End group match
        groups: []usize = undefined,
        // Diagnostics stack, optional based on template
        runStack: if (diagnostics) std.ArrayList(EnrichedState) else void = if (diagnostics) undefined else {},

        pub fn init(self: *@This(), allocator: Allocator) void {
            self.allocator = allocator;
        }

        fn programFinished(self: *const @This(), state: State) bool {
            return state.pc >= self.instructions.len;
        }

        fn appendDiagnosticState(self: *@This(), matchState: MatchState, state: State) !void {
            if (diagnostics and
                (matchState.isMatching() and !self.programFinished(state) or matchState.isNotMatching()))
            {
                try self.runStack.append(self.allocator, .{
                    .matchState = matchState,
                    .state = state,
                });
            }
        }

        fn initMatch(self: *@This()) !void {
            if (diagnostics) self.runStack = try .initCapacity(self.allocator, 1);

            self.backtrackVisitor = .init(self.allocator);
            self.stack = try .initCapacity(self.allocator, 10);
            self.groups = try self.allocator.alloc(usize, self.groupCount * 2);
            @memset(self.groups, EMPTY_MATCH);

            self.groupState = try self.allocator.alloc(State, self.groupCount);
        }

        fn getInst(self: *const @This(), state: State) Instruction {
            return self.instructions[state.pc];
        }

        fn initGroupState(self: *@This(), groupInst: anytype, state: State) void {
            self.groupState[groupInst.n] = state;
        }

        fn stackState(self: *@This(), state: State) !void {
            if (!self.backtrackVisitor.contains(state)) {
                try self.backtrackVisitor.put(state, {});
                try self.stack.append(self.allocator, state);
            }
        }

        fn backtrackState(self: *@This(), state: *State) bool {
            if (self.stack.pop()) |prevState| {
                state.* = prevState;
            } else {
                return false;
            }
            return true;
        }

        fn matchLiteral(_: *const @This(), state: State, baseText: []const u8, literal: []const u8) bool {
            const text = baseText[state.cursor..];

            if (literal.len > text.len)
                return false;

            return std.mem.eql(u8, literal, text[0..literal.len]);
        }

        fn matchRepeatableLiteral(
            self: *@This(),
            repeatLiteralInst: *RepeatLiteralInstruction,
            state: *State,
            text: []const u8,
        ) !bool {
            state.restartMatchCount();
            state.resetStart();
            return switch (repeatLiteralInst.quantifier.flavour) {
                .greedy => try self.matchGreedyLiteral(repeatLiteralInst, state, text),
                .lazy => try self.matchLazyLiteral(repeatLiteralInst, state, text),
            };
        }

        fn matchGreedyLiteral(
            self: *@This(),
            repeatLiteralInst: *RepeatLiteralInstruction,
            state: *State,
            text: []const u8,
        ) !bool {
            const range = repeatLiteralInst.quantifier.range;
            const literal = repeatLiteralInst.literal;

            while (state.matchCount < range.max) {
                if (self.matchLiteral(state.*, text, literal)) {
                    state.moveCursorBy(literal.len);
                    state.countMatch();

                    // Only add to stack retriable states
                    if (state.matchCount >= range.min) try self.stackState(state.*);
                } else {
                    // Even on failures so long we reached the minimal, this is a success
                    if (state.matchCount >= range.min)
                        return true;

                    // Should not populate stack if < min
                    if (self.stack.getLastOrNull()) |last|
                        assert(last.pc != state.pc);

                    return false;
                }
            }

            return true;
        }

        fn matchLazyLiteral(
            self: *@This(),
            repeatLiteralInst: *RepeatLiteralInstruction,
            state: *State,
            text: []const u8,
        ) !bool {
            const range = repeatLiteralInst.quantifier.range;
            const literal = repeatLiteralInst.literal;
            while (state.matchCount < range.min) : (state.countMatch()) {
                if (self.matchLiteral(state.*, text, literal)) {
                    state.moveCursorBy(literal.len);
                } else {
                    return false;
                }
            }

            try self.stackState(state.*);
            return true;
        }

        fn backtrackRepeatableLiteral(
            self: *@This(),
            repeatLiteralInst: *RepeatLiteralInstruction,
            state: *State,
            text: []const u8,
        ) !bool {
            switch (repeatLiteralInst.quantifier.flavour) {
                // No-op since greedy fills backtrack during match
                .greedy => return true,
                // Fills next match during backtrack
                .lazy => {
                    const range = repeatLiteralInst.quantifier.range;
                    const literal = repeatLiteralInst.literal;

                    // Cant match anymore, so state cant be changed
                    if (state.matchCount >= range.max)
                        return false;

                    if (self.matchLiteral(state.*, text, literal)) {
                        state.moveCursorBy(literal.len);
                        state.countMatch();
                        try self.stackState(state.*);
                        return true;
                    }
                    return false;
                },
            }
            unreachable;
        }

        fn getGroupState(self: *const @This(), groupInst: anytype) *State {
            return @ptrCast(self.groupState.ptr + groupInst.n);
        }

        fn getGroupStateFromInstPtr(self: *const @This(), inst: *Instruction) *State {
            return switch (inst.*) {
                // Cannot retrieve group state from these instructions
                .literal,
                .repeatLiteral,
                .groupEnd,
                => unreachable,
                .repeatGroup => |groupInst| self.getGroupState(groupInst),
                .group => |groupInst| self.getGroupState(groupInst),
            };
        }

        fn groupIdx(_: *const @This(), groupInst: anytype) usize {
            return groupInst.n * 2;
        }

        fn groupIdxFromInstPtr(self: *const @This(), inst: *Instruction) usize {
            return switch (inst.*) {
                .literal,
                .groupEnd,
                .repeatLiteral,
                => unreachable,
                .repeatGroup => |groupInst| self.groupIdx(groupInst),
                .group => |groupInst| self.groupIdx(groupInst),
            };
        }

        fn saveGroupMatch(
            self: *@This(),
            inst: *Instruction,
            groupState: *State,
            state: State,
        ) void {
            const idx: usize = self.groupIdxFromInstPtr(inst);

            assert(groupState.start <= state.cursor);
            if (groupState.start != state.cursor) {
                self.groups[idx] = groupState.start;
                self.groups[idx + 1] = state.cursor;
            }
        }

        fn setGroupMatch(
            self: *@This(),
            groupInst: anytype,
            state: State,
        ) void {
            const idx: usize = self.groupIdx(groupInst);

            assert(state.start <= state.cursor);
            self.groups[idx] = state.start;
            self.groups[idx + 1] = state.cursor;
        }

        fn finishRepeatableGroup(
            self: *@This(),
            inst: *RepeatGroupInstruction,
            groupState: *State,
            state: *State,
        ) !RepeatableGroupState {
            const quantifier = inst.quantifier;
            switch (quantifier.flavour) {
                .lazy => return MatchError.TBA,
                .greedy => {
                    groupState.countMatch();
                    const range = quantifier.range;

                    if (groupState.matchCount == range.max)
                        return .finished;

                    // This ensures we can restore the group match based on this state
                    // Range is [groupState.start, state.cursor)
                    // This also moves the backtrack state to actual group instruction, this
                    // is later used to identify it and then moved to groupEnd + 1
                    if (groupState.matchCount >= range.min) {
                        try self.stackState(.{
                            .start = groupState.start,
                            .cursor = state.cursor,
                            .pc = groupState.pc,
                            .matchCount = groupState.matchCount,
                        });
                    }

                    return .@"continue";
                },
            }
            unreachable;
        }

        pub fn match(
            self: *@This(),
            text: []const u8,
        ) anyerror!void {
            try self.initMatch();

            var state: State = .{
                .pc = 0,
                .start = 0,
                .cursor = 0,
                .matchCount = 0,
            };

            var matchState: MatchState = .matching;
            stateLoop: while (true) {
                try self.appendDiagnosticState(matchState, state);

                switch (matchState) {
                    .matching,
                    => {
                        if (self.programFinished(state)) {
                            matchState.succeed();
                            continue :stateLoop;
                        }

                        switch (self.getInst(state)) {
                            .group,
                            => |groupInst| {
                                state.restartMatchCount();
                                state.resetStart();
                                self.initGroupState(groupInst, state);
                                state.nextInstruction();
                                continue :stateLoop;
                            },
                            .repeatGroup,
                            => |groupInst| {
                                state.restartMatchCount();
                                state.resetStart();
                                self.initGroupState(groupInst, state);

                                // This is a backtrackable state if min is 0 because this group
                                // becomes optional
                                if (groupInst.quantifier.range.min == 0) try self.stackState(state);

                                state.nextInstruction();
                                continue :stateLoop;
                            },
                            .literal,
                            => |literal| {
                                if (self.matchLiteral(state, text, literal)) {
                                    state.moveCursorBy(literal.len);
                                    state.resetAndNextInstruction();
                                } else {
                                    matchState.backtrack();
                                }
                                continue :stateLoop;
                            },
                            .repeatLiteral,
                            => |repeatLiteral| {
                                if (try self.matchRepeatableLiteral(
                                    repeatLiteral,
                                    &state,
                                    text,
                                )) {
                                    state.resetAndNextInstruction();
                                } else {
                                    matchState.backtrack();
                                }
                                continue :stateLoop;
                            },
                            .groupEnd => |groupInst| {
                                var groupState: *State = self.getGroupStateFromInstPtr(groupInst);
                                self.saveGroupMatch(groupInst, groupState, state);

                                switch (groupInst.*) {
                                    // Those are all invalid states that should never happen
                                    // based on the compiler logic
                                    .literal,
                                    .repeatLiteral,
                                    .groupEnd,
                                    => unreachable,
                                    .group => {
                                        // Reset shadow state
                                        groupState.moveCursorTo(state.cursor);
                                        groupState.resetStart();
                                        // Move to next instruction with a fresh state
                                        state.resetAndNextInstruction();
                                    },
                                    .repeatGroup => |repeatGroupInst| {
                                        switch (try self.finishRepeatableGroup(
                                            repeatGroupInst,
                                            groupState,
                                            &state,
                                        )) {
                                            .@"continue",
                                            => {
                                                // In this case we loop pc back to group pc start + 1
                                                // which is essentially the first instruction after the group start
                                                // State will start fresh to do the next group match
                                                state.resetStart();
                                                state.jumpInstructionTo(groupState.pc + 1);
                                                // The shadow group state will be re-initialized to match state.cursor
                                                // The cursor for the shadow state in this case doesn't matter
                                                groupState.moveCursorTo(state.cursor);
                                                groupState.resetStart();
                                            },
                                            .finished,
                                            => {
                                                // Reset shadow state
                                                groupState.moveCursorTo(state.cursor);
                                                groupState.resetStart();
                                                // Move to the next instruction with a fresh state
                                                state.resetAndNextInstruction();
                                            },
                                        }
                                    },
                                }
                                continue :stateLoop;
                            },
                        }
                    },
                    .backtracking,
                    => {
                        if (!self.backtrackState(&state)) {
                            matchState.fail();
                            continue :stateLoop;
                        }

                        switch (self.getInst(state)) {
                            // Non-backtrackable states are states that do not produce
                            // meaningful results when executing again over a backtrack
                            // None of these are ever mean to be stacked
                            .literal, .group, .groupEnd => unreachable,
                            .repeatLiteral => |repeatLiteral| {
                                // .greedy is a no-op because all possible matches were already stacked
                                // .lazy may require further backtracking in case match fails
                                if (try self.backtrackRepeatableLiteral(
                                    repeatLiteral,
                                    &state,
                                    text,
                                )) {
                                    state.resetAndNextInstruction();
                                    matchState.match();
                                } else {
                                    matchState.backtrack();
                                }
                                continue :stateLoop;
                            },
                            .repeatGroup,
                            => |groupInst| {
                                switch (groupInst.quantifier.flavour) {
                                    .greedy,
                                    => {
                                        const groupState: *State = self.getGroupState(groupInst);

                                        // Shadow state start needs to be restore in case matches need to be
                                        // redone
                                        groupState.start = state.start;
                                        groupState.cursor = state.cursor;
                                        groupState.matchCount = state.matchCount;

                                        // Restores group match based on stacked state
                                        // States when saved by groupEnd will have the range as follow:
                                        // [groupState.start, state.cursor]
                                        self.setGroupMatch(groupInst, state);

                                        state.jumpInstructionTo(groupInst.end);
                                        state.resetAndNextInstruction();
                                        matchState.match();
                                        continue :stateLoop;
                                    },
                                    .lazy,
                                    => return MatchError.TBA,
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
                const idx: usize = i * 2;
                const start = self.groups[idx];
                const end = self.groups[idx + 1];

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
