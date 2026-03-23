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

pub fn Matcher(comptime diagnostics: bool) type {
    return struct {
        instructions: []Instruction = undefined,
        allocator: Allocator = undefined,
        backtrackVisitor: std.AutoHashMap(State, void) = undefined,
        stack: std.ArrayList(State) = undefined,
        groupState: []State = undefined,
        groups: []usize = undefined,
        groupCount: usize = undefined,
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
                .greedy => return true,
                .lazy => {
                    const range = repeatLiteralInst.quantifier.range;
                    const literal = repeatLiteralInst.literal;

                    // Cant match anymore
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
