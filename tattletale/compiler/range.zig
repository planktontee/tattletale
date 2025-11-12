const std = @import("std");
const Writer = std.Io.Writer;
const regent = @import("regent");
const Scanner = @import("scanner.zig");

min: usize,
max: usize,

const Range = @This();

pub const Unlimited = std.math.maxInt(usize);

pub const Error = error{
    SyntaxError,
    StartSmallerThanEnd,
} ||
    Scanner.ConsumeError ||
    std.fmt.ParseIntError;

const State = enum {
    init,

    initStartParse,
    startParse,

    seekComma,

    initEndParse,
    endParse,

    end,
};

pub const Any: *const Range = &.{
    .min = 0,
    .max = Unlimited,
};

pub const OneOrMore: *const Range = &.{
    .min = 1,
    .max = Unlimited,
};

pub const Optional: *const Range = &.{
    .min = 0,
    .max = 1,
};

pub fn in(self: *const Range, value: usize) bool {
    return value >= self.min and value <= self.max;
}

pub fn parseRange(self: *Range, scanner: *Scanner) Error!void {
    var digitsIdx: usize = undefined;

    stateLoop: switch (State.init) {
        .init => {
            try scanner.ensureByte();
            switch (scanner.peek()) {
                '{',
                => {
                    scanner.consume();
                    continue :stateLoop .initStartParse;
                },
                else => return Error.SyntaxError,
            }
        },
        .initStartParse => {
            try scanner.consumeWhite();
            switch (scanner.peek()) {
                '0',
                => {
                    scanner.consume();
                    self.min = 0;
                    try scanner.consumeWhite();
                    continue :stateLoop .seekComma;
                },
                '1'...'9',
                => {
                    digitsIdx = scanner.i;
                    scanner.consume();
                    continue :stateLoop .startParse;
                },
                ',' => {
                    self.min = 0;
                    try scanner.consumeWhite();
                    continue :stateLoop .seekComma;
                },
                else => return Error.SyntaxError,
            }
        },
        .startParse => {
            try scanner.consumeDigits();
            const digits = scanner.sliceFrom(digitsIdx);
            try scanner.consumeWhite();
            self.min = try std.fmt.parseInt(usize, digits, 10);
            continue :stateLoop .seekComma;
        },
        .seekComma => {
            switch (scanner.peek()) {
                ',',
                => {
                    scanner.consume();
                    continue :stateLoop .initEndParse;
                },
                '}',
                => {
                    self.max = self.min;
                    continue :stateLoop .end;
                },
                else => return Error.SyntaxError,
            }
        },
        .initEndParse => {
            try scanner.consumeWhite();
            switch (scanner.peek()) {
                '0',
                => {
                    scanner.consume();
                    self.max = 0;
                    try scanner.consumeWhite();
                    continue :stateLoop .end;
                },
                '1'...'9',
                => {
                    digitsIdx = scanner.i;
                    scanner.consume();
                    continue :stateLoop .endParse;
                },
                '}' => {
                    self.max = std.math.maxInt(usize);
                    try scanner.consumeWhite();
                    continue :stateLoop .end;
                },
                else => return Error.SyntaxError,
            }
        },
        .endParse => {
            try scanner.consumeDigits();
            const digits = scanner.sliceFrom(digitsIdx);
            try scanner.consumeWhite();
            self.max = try std.fmt.parseInt(usize, digits, 10);
            continue :stateLoop .end;
        },
        .end => {
            if (self.min > self.max) return Error.StartSmallerThanEnd;
            switch (scanner.peek()) {
                '}',
                => {
                    scanner.consume();
                    return;
                },
                else => return Error.SyntaxError,
            }
        },
    }
}

pub fn format(self: *const Range, w: *Writer) Writer.Error!void {
    const buffSize = comptime std.fmt.count("{d}", .{std.math.maxInt(usize)});
    var startIntBuff: [buffSize]u8 = undefined;
    var endIntBuff: [buffSize]u8 = undefined;

    const startLen = std.fmt.printInt(&startIntBuff, self.min, 10, .lower, .{});
    const endLen = std.fmt.printInt(&endIntBuff, self.max, 10, .lower, .{});

    try w.writeAll("{");
    try w.writeAll(startIntBuff[0..startLen]);
    try w.writeAll(",");
    try w.writeAll(endIntBuff[0..endLen]);
    try w.writeAll("}");
}
