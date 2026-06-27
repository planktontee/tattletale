pub const Scanner = @import("tattletale/compiler/scanner.zig");
pub const Diagnostics = Scanner.Diagnostics;
pub const Token = Scanner.RgxToken;
pub const Quantifier = Scanner.Quantifier;
pub const Range = @import("tattletale/compiler/range.zig");
pub const Literal = @import("tattletale/compiler/literal.zig");
pub const Compiler = @import("tattletale/compiler.zig");
pub const Matcher = @import("tattletale/matcher.zig");
pub const zcasp = @import("zcasp");
pub const positionals = zcasp.positionals;
pub const HelpData = zcasp.help.HelpData;
pub const spec = zcasp.spec;
pub const regent = @import("regent");

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

pub var io: std.Io = undefined;

pub const Args = struct {
    debug: bool = false,

    pub const Positionals = positionals.PositionalOf(.{
        .TupleType = struct {
            []const u8,
        },
        .ReminderType = void,
    });

    pub const Help: HelpData(@This()) = .{
        .usage = &.{"tattletale <regex>"},
        .description = "Thin cli to run regex on stdin.",
        .examples = &.{
            "echo 'a' | tattletale 'a'",
        },
        .positionalsDescription = .{
            .tuple = &.{
                "regex to be match stdin against.",
            },
        },
        .optionsDescription = &.{
            .{ .field = .debug, .description = "Enables diagnosis." },
        },
    };
};

const ArgsResponse = spec.SpecResponseWithConfig(Args, zcasp.help.HelpConf{
    .simpleTypes = true,
    .headerDelimiter = "",
}, true);

pub fn main(init: std.process.Init.Minimal) @typeInfo(Returns).@"enum".tag_type {
    var buff: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buff);
    const scrapAlloc = fba.allocator();

    var argsRes: ArgsResponse = .init(scrapAlloc);
    defer argsRes.deinit();

    if (argsRes.parseArgs(init.args)) |parseError| {
        std.debug.print("Last opt <{?s}>, Last token <{?s}>. ", .{ parseError.lastOpt, parseError.lastToken });
        std.debug.print("{s}\n", .{parseError.message orelse unreachable});
        return 1;
    }

    var sTh = std.Io.Threaded.init_single_threaded;
    io = sTh.io();

    return if (argsRes.options.debug)
        @intFromEnum(innerMain(true, &argsRes))
    else
        @intFromEnum(innerMain(false, &argsRes));
}

pub fn innerMain(comptime hasDiagnostics: bool, argsRes: *const ArgsResponse) Returns {
    var scrapBuff: [regent.units.ByteUnit.mb * 6]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scrapBuff);
    const scrapAlloc = fba.allocator();

    const stderrBuff: []u8 = scrapAlloc.alignedAlloc(u8, .fromByteUnits(4096), regent.units.ByteUnit.mb) catch return .outOfMem;
    defer scrapAlloc.free(stderrBuff);

    const stderr = std.Io.File.stderr();
    var stderrW = stderr.writerStreaming(io, stderrBuff);
    const errW = &stderrW.interface;
    defer {
        errW.flush() catch {};
        stderr.close(io);
    }

    const stdoutBuff: []u8 = scrapAlloc.alignedAlloc(u8, .fromByteUnits(4096), regent.units.ByteUnit.mb) catch return .outOfMem;
    defer scrapAlloc.free(stdoutBuff);

    const stdout = std.Io.File.stdout();
    var stdoutW = stdout.writerStreaming(io, stdoutBuff);
    const outW = &stdoutW.interface;
    defer {
        outW.flush() catch {};
        stdout.close(io);
    }

    var stdinBuff: [4096]u8 = undefined;
    const stdin = std.Io.File.stdin();
    var stdinR = stdin.readerStreaming(io, &stdinBuff);
    const inR = &stdinR.interface;
    defer stdin.close(io);

    var compiler: Compiler.Compiler(hasDiagnostics) = .init;
    const pattern = argsRes.positionals.tuple.@"0";
    if (hasDiagnostics) {
        outW.print("\x1b[1;33mRaw | {s}\n\x1b[0m", .{pattern}) catch return .stdoutWriteFailure;
        outW.flush() catch return .stdoutWriteFailure;
    }

    var arena = std.heap.ArenaAllocator.init(scrapAlloc);
    defer arena.deinit();
    const arenaAlloc = arena.allocator();

    loop: while (true) {
        defer _ = arena.reset(.free_all);

        var matcher: Matcher.Matcher(hasDiagnostics) = undefined;

        matcher.init(arenaAlloc);
        compiler.compile(arenaAlloc, pattern, &matcher) catch |e| {
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

        var input = inR.takeDelimiterInclusive('\n') catch |e| switch (e) {
            std.Io.Reader.DelimiterError.EndOfStream => r: {
                if (inR.bufferedLen() == 0) break :loop;
                const slice = inR.buffered();
                inR.toss(slice.len);
                break :r slice;
            },
            else => {
                errW.print("Failed to read stdin with: {s}\n", .{@errorName(e)}) catch
                    return .stderrWriteFailure;
                return .stdinReadFailure;
            },
        };
        if (input.len == 0) break :loop;

        if (input[input.len - 1] == '\n')
            input = input[0 .. input.len - 1];

        if (hasDiagnostics) {
            outW.print("\x1b[1;36mInput | {s}\n\x1b[0m", .{input}) catch return .stdoutWriteFailure;
            outW.flush() catch return .stdoutWriteFailure;
        }

        var matched = true;
        matcher.match(input) catch |e| switch (e) {
            Matcher.MatchError.MatchFailed => {
                @branchHint(.unpredictable);
                if (hasDiagnostics) {
                    matcher.printDiagnosis(outW, input) catch return .stdoutWriteFailure;
                    outW.writeAll("\x1b[1;31mMatch failed!\n\x1b[0m") catch return .stdoutWriteFailure;
                }
                matched = false;
            },
            else => {
                @branchHint(.unlikely);
                matcher.printDiagnosis(outW, input) catch return .stdoutWriteFailure;
                outW.print("\x1b[1;31mMatch execution error: {s}\n\x1b[0m", .{@errorName(e)}) catch return .stdoutWriteFailure;
                matched = false;
            },
        };
        matcher.printDiagnosis(outW, input) catch return .stdoutWriteFailure;
        if (!hasDiagnostics and matched) {
            defer outW.writeAll("\x1b[0m") catch {};

            var i: usize = 1;
            var cursor: usize = 0;
            while (i < matcher.groupCount) : (i += 1) {
                const idx: usize = i * 2;
                const start = matcher.groups[idx];
                const end = matcher.groups[idx + 1];

                outW.writeAll(input[cursor..start]) catch return .stdoutWriteFailure;
                outW.print("\x1b[0;{d}m", .{i % 4 + 33}) catch return .stdoutWriteFailure;
                outW.writeAll(input[start..end]) catch return .stdoutWriteFailure;
                outW.writeAll("\x1b[0m") catch {};

                cursor = end;
            }
            if (cursor < input.len)
                outW.writeAll(input[cursor..input.len]) catch return .stdoutWriteFailure;
            outW.writeByte('\n') catch return .stdoutWriteFailure;
        }
        outW.flush() catch return .stdoutWriteFailure;
    }

    return .ok;
}
