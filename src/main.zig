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
    \\-h, --help
    \\    Output this help message and exit.
    \\
    \\    --stdin
    \\    The output of the command depends on stdin. If it changes, the cache is invalidated.
    \\
    \\    --ignore-stdout
    \\    The output from stdout will not be cached.
    \\
    \\    --ignore-stderr
    \\    The output from stderr will not be cached.
    \\
    \\-e, --env <env>...
    \\    The output of the command depends on this environment variable. If it changes, the cache
    \\    is invalidated.
    \\
    \\-f, --file <file>...
    \\    The output of the command depends on this file. If it changes, the cache is invalidated.
    \\
    \\-s, --string <string>...
    \\    The output of the command depends on this string. If it changes, the cache is
    \\    invalidated.
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

pub fn main() !void {
    var gpa_state = heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_state.allocator();
    defer _ = gpa_state.deinit();

    const global_cache_path = (try folders.getPath(gpa, .cache)) orelse
        return error.MissingGlobalCache;
    defer gpa.free(global_cache_path);

    const cache_path = try fs.path.join(gpa, &.{
        global_cache_path,
        "cache",
    });
    defer gpa.free(cache_path);
    try fs.cwd().makePath(cache_path);

    const stdin = io.getStdIn();
    const stdout = io.getStdOut();
    const stderr = io.getStdErr();

    var diag = clap.Diagnostic{};
    const args = clap.parse(clap.Help, &params, parsers, .{
        .allocator = gpa,
        .diagnostic = &diag,
    }) catch |err| {
        diag.report(stderr.writer(), err) catch {};
        return err;
    };
    defer args.deinit();

    if (args.args.help != 0) {
        try stdout.writeAll("Usage: cache ");
        try clap.usage(stdout.writer(), clap.Help, &params);
        try stdout.writeAll("\n\nOptions:\n");
        return clap.help(stdout.writer(), clap.Help, &params, .{});
    }

    const stdin_content = if (args.args.stdin != 0)
        try stdin.readToEndAlloc(gpa, math.maxInt(usize))
    else
        "";
    defer gpa.free(stdin_content);

    const digest = try digestFromArgs(gpa, stdin_content, args);
    if (updateOutput(gpa, stdout, stderr, cache_path, &digest, args.args.output)) |_| {
        // Cache hit, just return
        return;
    } else |err| switch (err) {
        error.FileNotFound => {
            // Cache miss, execute command below
        },
        else => |err2| return err2,
    }

    const output = try std.process.Child.run(.{
        .allocator = gpa,
        .argv = args.positionals,
        .max_output_bytes = math.maxInt(usize),
    });
    defer gpa.free(output.stdout);
    defer gpa.free(output.stderr);

    const output_stdout = if (args.args.@"ignore-stdout" == 0) output.stdout else "";
    const output_stderr = if (args.args.@"ignore-stderr" == 0) output.stderr else "";

    try updateCache(gpa, output_stdout, output_stderr, cache_path, &digest, args.args.output);
    try updateOutput(gpa, stdout, stderr, cache_path, &digest, args.args.output);

    // Print out stdout and stderr when ignore but didn't have a cache hit. This allows for better
    // debugging if the command fails.
    if (args.args.@"ignore-stdout" != 0)
        try stdout.writeAll(output.stdout);
    if (args.args.@"ignore-stderr" != 0)
        try stderr.writeAll(output.stderr);
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

    if (args.args.@"ignore-stdout" != 0)
        hasher.update("ignore-stdout");
    if (args.args.@"ignore-stderr" != 0)
        hasher.update("ignore-stderr");

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
    stdout: std.fs.File,
    stderr: std.fs.File,
    cache_path: []const u8,
    digest: []const u8,
    outputs: []const []const u8,
) !void {
    var buf: [std.fs.max_name_bytes]u8 = undefined;

    const cwd = fs.cwd();
    for (outputs, 0..) |output, i| {
        const path = try fs.path.join(allocator, &.{
            cache_path,
            try fmt.bufPrint(&buf, "{s}-{}", .{ digest, i }),
        });
        defer allocator.free(path);

        cwd.deleteFile(output) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
        try cwd.symLink(path, output, .{});
    }

    const stdout_path = try fs.path.join(allocator, &.{
        cache_path,
        try fmt.bufPrint(&buf, "{s}-stdout", .{digest}),
    });
    defer allocator.free(stdout_path);

    const stdout_file = try cwd.openFile(stdout_path, .{});
    defer stdout_file.close();
    try stdout.writeFileAll(stdout_file, .{});

    const stderr_path = try fs.path.join(allocator, &.{
        cache_path,
        try fmt.bufPrint(&buf, "{s}-stderr", .{digest}),
    });
    defer allocator.free(stderr_path);

    const stderr_file = try cwd.openFile(stderr_path, .{});
    defer stderr_file.close();
    try stderr.writeFileAll(stderr_file, .{});
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

    try cwd.writeFile(.{ .sub_path = stdout_path, .data = stdout });
    try cwd.writeFile(.{ .sub_path = stderr_path, .data = stderr });

    const cache_dir = try cwd.openDir(cache_path, .{});
    for (outputs, 0..) |output, i| {
        const cache_name = fmt.bufPrint(&buf, "{s}-{}", .{ digest, i }) catch unreachable;
        fs.rename(cwd, output, cache_dir, cache_name) catch |err| switch (err) {
            error.RenameAcrossMountPoints => try cwd.copyFile(output, cache_dir, cache_name, .{}),
            else => |e| return e,
        };
    }
}
