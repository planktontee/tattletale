pub const Scanner = @import("tattletale/compiler/scanner.zig");
pub const Diagnostics = Scanner.Diagnostics;
pub const Token = Scanner.RgxToken;
pub const Quantifier = Scanner.Quantifier;
pub const Range = @import("tattletale/compiler/range.zig");
pub const Literal = @import("tattletale/compiler/literal.zig");
pub const Compiler = @import("tattletale/compiler.zig");
pub const Matcher = @import("tattletale/matcher.zig");

const std = @import("std");

const Returns = enum(u8) {
    ok = 0,
    matchFailed = 1,
    stdinReadFailure = 2,
    stderrWriteFailure = 3,
    stdoutWriteFailure = 4,
    failedInit = 5,
    failedDiagReport = 6,
    cantStatStdin = 7,
    failedCompilation = 8,
    outOfMem = 9,
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

    // var stdinBuff: [4096]u8 = undefined;
    // const stdin = std.fs.File.stdin();
    // var stdinR = stdin.readerStreaming(&stdinBuff);
    // const inR = &stdinR.interface;
    // defer stdin.close();

    var inFixedR = std.Io.Reader.fixed("(a{1,3}?())+ab\naaaaab");
    const inR = &inFixedR;
    const isTTY = false;

    // const stdinStat = stdin.stat() catch return .cantStatStdin;
    // const isTTY = switch (stdinStat.kind) {
    //     .character_device => true,
    //     else => false,
    // };

    var scrapBuff: [1 << 20 << 3]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scrapBuff);
    const scrapAlloc = fba.allocator();

    const hasDiagnostics = true;
    var compiler: Compiler.Compiler(hasDiagnostics) = .init;

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
        const trimmedLine = std.mem.trimEnd(u8, rawline, " \t\n");

        const pattern = scrapAlloc.alloc(u8, trimmedLine.len) catch return .outOfMem;
        @memcpy(pattern, trimmedLine);
        inR.toss(rawline.len);

        outW.print("\x1b[1;33mRaw | {s}\n\x1b[0m", .{pattern}) catch return .stdoutWriteFailure;
        outW.flush() catch return .stdoutWriteFailure;

        var matcher: Matcher.Matcher(hasDiagnostics) = undefined;
        matcher.init(scrapAlloc);
        compiler.compile(scrapAlloc, pattern, &matcher) catch |e| {
            if (hasDiagnostics and compiler.scannerDiagnostics.message != null) {
                errW.print("\x1b[1;31m{s}\x1b[0m\n", .{compiler.scannerDiagnostics.message.?}) catch return .stderrWriteFailure;
                errW.flush() catch return .stderrWriteFailure;
            } else {
                errW.print(
                    "\x1b[1;31mCompilation failed with: {s}\x1b[0m\n",
                    .{@errorName(e)},
                ) catch return .stderrWriteFailure;
                errW.flush() catch return .stderrWriteFailure;
            }
            continue :loop;
        };

        if (hasDiagnostics) {
            outW.writeAll("\x1b[0;35mTokens |\n") catch return .stdoutWriteFailure;
            for (compiler.tokens, 0..) |*token, i| {
                outW.print("       | {d}] {f}\n", .{ i, token.* }) catch return .stdoutWriteFailure;
            }
            outW.writeAll("\x1b[0m") catch return .stdoutWriteFailure;
            outW.flush() catch return .stdoutWriteFailure;
        }

        if (hasDiagnostics) outW.print("{f}", .{matcher}) catch return .stdoutWriteFailure;

        if (isTTY) {
            outW.writeAll("string> ") catch return .stdoutWriteFailure;
            outW.flush() catch return .stdoutWriteFailure;
        }

        const rawInput = inR.peekDelimiterInclusive('\n') catch |e| switch (e) {
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
        const trimmedInput = std.mem.trimEnd(u8, rawInput, " \t\n");

        const input = scrapAlloc.alloc(u8, trimmedInput.len) catch return .outOfMem;
        @memcpy(input, trimmedInput);
        inR.toss(rawInput.len);

        outW.print("\x1b[1;36mInput | {s}\n\x1b[0m", .{input}) catch return .stdoutWriteFailure;
        outW.flush() catch return .stdoutWriteFailure;

        matcher.match(input) catch |e| switch (e) {
            Matcher.MatchError.MatchFailed => {
                matcher.printDiagnosis(outW, input) catch return .stdoutWriteFailure;
                outW.writeAll("\x1b[1;31mMatch failed!\n\x1b[0m") catch return .stdoutWriteFailure;
                return .matchFailed;
            },
            else => {
                matcher.printDiagnosis(outW, input) catch return .stdoutWriteFailure;
                outW.print("\x1b[1;31mMatch execution error: {s}\n\x1b[0m", .{@errorName(e)}) catch return .stdoutWriteFailure;
                return .matchFailed;
            },
        };
        matcher.printDiagnosis(outW, input) catch return .stdoutWriteFailure;
        outW.writeAll("\x1b[1;32mMatch succeeded!\n\x1b[0m") catch return .stdoutWriteFailure;
        outW.flush() catch return .stdoutWriteFailure;
    }

    return .ok;
}
