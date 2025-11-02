const std = @import("std");
const Scanner = @import("scanner.zig");

min: usize,
max: usize,

const Range = @This();

pub const Error = error{
    SyntaxError,
    StartSmallerThanEnd,
} ||
    Scanner.ConsumeError ||
    std.fmt.ParseIntError;

const State = enum {
    init,

    startParse,
    seekComma,
    initEndParse,
    endParse,

    end,
};

pub fn parseRange(self: *Range, scanner: *Scanner) Error!void {
    var state: State = .init;
    var startI: usize = undefined;

    stateLoop: while (true) {
        switch (state) {
            .init => {
                try scanner.consumeWhite();
                switch (scanner.pattern[scanner.i]) {
                    '0',
                    => {
                        scanner.i += 1;
                        self.min = 0;
                        try scanner.consumeWhite();
                        state = .seekComma;
                        continue :stateLoop;
                    },
                    '1'...'9',
                    => {
                        startI = scanner.i;
                        scanner.i += 1;
                        state = .startParse;
                        continue :stateLoop;
                    },
                    ',' => {
                        scanner.i += 1;
                        self.min = 0;
                        try scanner.consumeWhite();
                        state = .seekComma;
                        continue :stateLoop;
                    },
                    else => return Error.SyntaxError,
                }
            },
            .startParse => {
                try scanner.consumeDigits();
                const endDigits = scanner.i;
                try scanner.consumeWhite();
                self.min = try std.fmt.parseInt(usize, scanner.pattern[startI..endDigits], 10);
                state = .seekComma;
                continue :stateLoop;
            },
            .seekComma => {
                switch (scanner.pattern[scanner.i]) {
                    ',',
                    => {
                        scanner.i += 1;
                        state = .initEndParse;
                        continue :stateLoop;
                    },
                    '}',
                    => {
                        self.max = self.min;
                        state = .end;
                    },
                    else => return Error.InvalidCharacter,
                }
            },
            .initEndParse => {
                try scanner.consumeWhite();
                switch (scanner.pattern[scanner.i]) {
                    '0',
                    => {
                        scanner.i += 1;
                        self.max = 0;
                        try scanner.consumeWhite();
                        state = .end;
                        continue :stateLoop;
                    },
                    '1'...'9',
                    => {
                        startI = scanner.i;
                        scanner.i += 1;
                        state = .endParse;
                        continue :stateLoop;
                    },
                    '}' => {
                        self.max = std.math.maxInt(usize);
                        state = .end;
                        try scanner.consumeWhite();
                        continue :stateLoop;
                    },
                    ',' => return Error.InvalidCharacter,
                    else => return Error.SyntaxError,
                }
            },
            .endParse => {
                try scanner.consumeDigits();
                const endDigits = scanner.i;
                try scanner.consumeWhite();
                self.max = try std.fmt.parseInt(usize, scanner.pattern[startI..endDigits], 10);
                state = .end;
                continue :stateLoop;
            },
            .end => {
                if (self.min > self.max) return Error.StartSmallerThanEnd;
                switch (scanner.pattern[scanner.i]) {
                    '}',
                    => {
                        scanner.i += 1;
                        return;
                    },
                    else => return Error.InvalidCharacter,
                }
            },
        }
    }
    unreachable;
}

fn testParse(allocator: std.mem.Allocator, diag: *Scanner.DiagnosticTracker, pattern: []const u8) !Range {
    var range: Range = undefined;
    var scanner: Scanner = undefined;
    scanner.initWithDiag(allocator, diag, pattern);
    range.parseRange(&scanner) catch |e| try scanner.report(e, "Failed parsing range");
    return range;
}

test "Parse ranges" {
    const t = std.testing;
    var diag: Scanner.DiagnosticTracker = undefined;
    defer diag.deinit();

    try t.expectEqual(
        @as(Range, .{ .min = 1, .max = 2 }),
        testParse(t.allocator, &diag, "1,2}") catch |e| try diag.printRaise(e),
    );
}
