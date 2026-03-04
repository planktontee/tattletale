pub const Scanner = @import("tattletale/compiler/scanner.zig");
pub const Diagnostics = Scanner.Diagnostics;
pub const Token = Scanner.RgxToken;
pub const Quantifier = Scanner.Quantifier;
pub const Range = @import("tattletale/compiler/range.zig");
pub const Literal = @import("tattletale/compiler/literal.zig");
pub const Compiler = @import("tattletale/compiler.zig");
pub const RgxNode = Compiler.RgxNode;
pub const Visitor = Compiler.Visitor;
pub const LinkedList = Compiler.LinkedList;
pub const LiteralRgxNode = Compiler.LiteralRgxNode;
pub const QuantifierRgxNode = Compiler.QuantifierRgxNode;
pub const Cursor = Compiler.Cursor;

const std = @import("std");

const Returns = enum(u8) {
    ok = 0,
    stdinReadFailure = 1,
    stderrWriteFailure = 2,
    stdoutWriteFailure = 3,
    failedInit = 4,
    failedDiagReport = 5,
    cantStatStdin = 6,
};

pub fn main() @typeInfo(Returns).@"enum".tag_type {
    return @intFromEnum(innerMain());
}

pub fn innerMain() Returns {
    var stderrBuff: [1024]u8 = undefined;
    const stderr = std.fs.File.stderr();
    var stderrW = stderr.writer(&stderrBuff);
    const errW = &stderrW.interface;
    defer {
        errW.flush() catch {};
        stderr.close();
    }

    var stdoutBuff: [1024]u8 = undefined;
    const stdout = std.fs.File.stdout();
    var stdoutW = stdout.writer(&stdoutBuff);
    const outW = &stdoutW.interface;
    defer {
        outW.flush() catch {};
        stdout.close();
    }

    var stdinBuff: [4096]u8 = undefined;
    const stdin = std.fs.File.stdin();
    var stdinR = stdin.readerStreaming(&stdinBuff);
    const inR = &stdinR.interface;
    defer stdin.close();

    const stdinStat = stdin.stat() catch return .cantStatStdin;
    const isTTY = switch (stdinStat.kind) {
        .character_device => true,
        else => false,
    };

    var scrapBuff: [1 << 20 << 3]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scrapBuff);
    const scrapAlloc = fba.allocator();

    var scanner: Scanner = undefined;
    var diag: Diagnostics = undefined;

    loop: while (true) {
        if (isTTY) {
            outW.writeAll("$ ") catch return .stdoutWriteFailure;
            outW.flush() catch return .stdoutWriteFailure;
        }

        const rawline = inR.peekDelimiterInclusive('\n') catch |e| switch (e) {
            std.Io.Reader.DelimiterError.EndOfStream => rv: {
                if (inR.bufferedLen() > 0)
                    break :rv inR.buffered()
                else
                    break :loop;
            },
            else => {
                errW.print("Failed to read stdin with: {s}\n", .{@errorName(e)}) catch
                    return .stderrWriteFailure;
                return .stdinReadFailure;
            },
        };
        // TODO: stop trimming on non-tty, handle line break properly
        const line = std.mem.trimEnd(u8, rawline, " \t\n");

        outW.writeAll("\x1b[1;32m") catch return .stdoutWriteFailure;
        outW.writeAll("raw] ") catch return .stdoutWriteFailure;
        outW.writeAll(line) catch return .stdoutWriteFailure;
        outW.writeByte('\n') catch return .stdoutWriteFailure;
        outW.writeAll("\x1b[0m") catch return .stdoutWriteFailure;
        outW.flush() catch return .stdoutWriteFailure;
        inR.toss(rawline.len);

        scanner.initWithDiag(scrapAlloc, &diag, line) catch return .failedInit;
        const tokens = scanner.collectWithReport() catch {
            errW.writeAll("\x1b[1;31m") catch return .stderrWriteFailure;
            errW.writeAll(diag.message.?) catch return .stderrWriteFailure;
            errW.writeAll("\n\x1b[0m") catch return .stderrWriteFailure;
            errW.flush() catch return .stderrWriteFailure;
            continue :loop;
        };

        outW.writeAll("\x1b[0;35m") catch return .stdoutWriteFailure;
        for (tokens, 0..) |token, i| {
            outW.print("tk]{d}] {f}\n", .{ i, token.* }) catch return .stdoutWriteFailure;
        }
        outW.writeAll("\x1b[0m") catch return .stdoutWriteFailure;
        outW.flush() catch return .stdoutWriteFailure;

        // TODO: deinit
    }

    return .ok;
}
