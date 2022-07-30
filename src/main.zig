const clap = @import("clap");
const folders = @import("folders");
const std = @import("std");

const crypto = std.crypto;
const fmt = std.fmt;
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const math = std.math;
const mem = std.mem;
const process = std.process;

const params = clap.parseParamsComptime(
    \\-e, --env <env>...
    \\    The output of the command depends on this environment variable. If it
    \\    changes, the cache is invalidated.
    \\
    \\-f, --file <file>...
    \\    The output of the command depends on this file. If it changes, the cache is
    \\    invalidated.
    \\
    \\-s, --string <string>...
    \\    The output of the command depends on this string. If it changes, the cache
    \\    is invalidated.
    \\
    \\-o, --output <file>...
    \\    The files that command outputs to.
    \\
    \\<command>...
    \\
);

const parsers = .{
    .command = clap.parsers.string,
    .env = clap.parsers.string,
    .file = clap.parsers.string,
    .string = clap.parsers.string,
};

pub fn main() anyerror!void {
    var gba_state = heap.GeneralPurposeAllocator(.{}){};
    const gba = gba_state.allocator();
    defer _ = gba_state.deinit();

    const global_cache_path = (try folders.getPath(gba, .cache)) orelse
        return error.MissingGlobalCache;
    defer gba.free(global_cache_path);

    const cache_path = try fs.path.join(gba, &.{
        global_cache_path,
        "cache",
    });
    defer gba.free(cache_path);

    const stdin = io.getStdIn();
    const stdout = io.getStdErr().writer();
    const stderr = io.getStdErr().writer();

    var diag = clap.Diagnostic{};
    const args = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
    }) catch |err| {
        diag.report(stderr, err) catch {};
        return err;
    };

    const stdin_content = if (!stdin.isTty())
        try stdin.readToEndAlloc(gba, math.maxInt(usize))
    else
        "";
    defer gba.free(stdin_content);

    const digest = try digestFromArgs(gba, stdin_content, args);
    if (updateOutput(gba, stdout, stderr, cache_path, &digest, args.args.output)) |_| {
        // Cache hit, just return
        return;
    } else |err| switch (err) {
        error.FileNotFound => {
            // Cache miss, execute command below
        },
        else => |err2| return err2,
    }

    const output = try std.ChildProcess.exec(.{
        .allocator = gba,
        .argv = args.positionals,
        .max_output_bytes = math.maxInt(usize),
    });
    defer gba.free(output.stdout);
    defer gba.free(output.stderr);

    try updateCache(gba, output.stdout, output.stderr, cache_path, &digest, args.args.output);
    try updateOutput(gba, stdout, stderr, cache_path, &digest, args.args.output);
}

const BinDigest = [bin_digest_len]u8;
const bin_digest_len = 16;
const Hasher = crypto.auth.siphash.SipHash128(1, 3);
const hex_digest_len = bin_digest_len * 2;

fn digestFromArgs(
    allocator: mem.Allocator,
    stdin: []const u8,
    args: anytype,
) ![hex_digest_len]u8 {
    const cwd = fs.cwd();
    var hasher = Hasher.init(&[_]u8{0} ** Hasher.key_length);
    hasher.update(stdin);

    for (args.positionals) |command_arg|
        hasher.update(command_arg);
    for (args.args.string) |string|
        hasher.update(string);
    for (args.args.env) |env| {
        const content = process.getEnvVarOwned(allocator, env) catch "";
        defer allocator.free(content);
        hasher.update(env);
        hasher.update(content);
    }
    for (args.args.file) |filepath| {
        const realpath = try cwd.realpathAlloc(allocator, filepath);
        defer allocator.free(realpath);

        const file = try cwd.openFile(realpath, .{});
        const metadata = try file.metadata();
        defer file.close();
        hasher.update(realpath);
        hasher.update(&mem.toBytes(metadata.size()));
        hasher.update(&mem.toBytes(metadata.modified()));
    }

    var bin_digest: BinDigest = undefined;
    hasher.final(&bin_digest);

    var res: [hex_digest_len]u8 = undefined;
    _ = std.fmt.bufPrint(
        &res,
        "{s}",
        .{std.fmt.fmtSliceHexLower(&bin_digest)},
    ) catch unreachable;
    return res;
}

fn updateOutput(
    allocator: mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    cache_path: []const u8,
    digest: []const u8,
    outputs: []const []const u8,
) !void {
    var buf: [1024]u8 = undefined;
    const cwd = fs.cwd();
    const stdout_path = try fs.path.join(allocator, &.{
        cache_path,
        fmt.bufPrint(&buf, "{s}-stdout", .{digest}) catch unreachable,
    });
    defer allocator.free(stdout_path);
    const stderr_path = try fs.path.join(allocator, &.{
        cache_path,
        fmt.bufPrint(&buf, "{s}-stderr", .{digest}) catch unreachable,
    });
    defer allocator.free(stderr_path);

    const stdout_file = try cwd.openFile(stdout_path, .{});
    const stderr_file = try cwd.openFile(stderr_path, .{});

    for (outputs) |output, i| {
        const path = try fs.path.join(allocator, &.{
            cache_path,
            fmt.bufPrint(&buf, "{s}-{}", .{ digest, i }) catch unreachable,
        });
        defer allocator.free(path);

        cwd.deleteFile(output) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
        try cwd.symLink(path, output, .{});
    }

    var fifo = std.fifo.LinearFifo(u8, .{ .Static = mem.page_size }).init();
    try fifo.pump(stdout_file.reader(), stdout);
    try fifo.pump(stderr_file.reader(), stderr);
}

fn updateCache(
    allocator: mem.Allocator,
    stdout: []const u8,
    stderr: []const u8,
    cache_path: []const u8,
    digest: []const u8,
    outputs: []const []const u8,
) !void {
    var buf: [1024]u8 = undefined;
    const cwd = fs.cwd();
    const stdout_path = try fs.path.join(allocator, &.{
        cache_path,
        fmt.bufPrint(&buf, "{s}-stdout", .{digest}) catch unreachable,
    });
    defer allocator.free(stdout_path);
    const stderr_path = try fs.path.join(allocator, &.{
        cache_path,
        fmt.bufPrint(&buf, "{s}-stderr", .{digest}) catch unreachable,
    });
    defer allocator.free(stderr_path);

    try cwd.writeFile(stdout_path, stdout);
    try cwd.writeFile(stderr_path, stderr);

    const cache_dir = try cwd.openDir(cache_path, .{});
    for (outputs) |output, i| {
        const cache_name = fmt.bufPrint(&buf, "{s}-{}", .{ digest, i }) catch unreachable;
        try fs.rename(cwd, output, cache_dir, cache_name);
    }
}
