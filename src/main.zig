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

    const stdin = io.getStdIn();
    const stdout = io.getStdOut();
    const stderr = io.getStdErr();

    const global_cache_path = (try folders.getPath(gpa, .cache)) orelse
        return error.MissingGlobalCache;
    defer gpa.free(global_cache_path);

    const cache_path = try fs.path.join(gpa, &.{
        global_cache_path,
        "cache",
    });
    defer gpa.free(cache_path);

    var cache_dir = try std.fs.cwd().makeOpenPath(cache_path, .{});
    defer cache_dir.close();

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
    if (updateOutput(gpa, stdout, stderr, cache_dir, cache_path, &digest, args.args.output)) |_| {
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

    try updateCache(output_stdout, output_stderr, cache_dir, &digest, args.args.output);
    try updateOutput(gpa, stdout, stderr, cache_dir, cache_path, &digest, args.args.output);

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
        const content = process.getEnvVarOwned(allocator, env) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => "",
            else => |e| return e,
        };
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

    return std.fmt.bytesToHex(bin_digest, .lower);
}

fn updateOutput(
    allocator: mem.Allocator,
    stdout: std.fs.File,
    stderr: std.fs.File,
    cache_dir: std.fs.Dir,
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

    const stdout_name = try fmt.bufPrint(&buf, "{s}-stdout", .{digest});
    const stdout_file = try cache_dir.openFile(stdout_name, .{});
    defer stdout_file.close();
    try stdout.writeFileAll(stdout_file, .{});

    const stderr_name = try fmt.bufPrint(&buf, "{s}-stderr", .{digest});
    if (cache_dir.openFile(stderr_name, .{})) |stderr_file| {
        defer stderr_file.close();
        try stderr.writeFileAll(stderr_file, .{});
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }
}

fn updateCache(
    stdout: []const u8,
    stderr: []const u8,
    cache_dir: std.fs.Dir,
    digest: []const u8,
    outputs: []const []const u8,
) !void {
    var buf: [std.fs.max_name_bytes]u8 = undefined;
    const cwd = fs.cwd();

    const stdout_name = try fmt.bufPrint(&buf, "{s}-stdout", .{digest});
    try cache_dir.writeFile(.{ .sub_path = stdout_name, .data = stdout });

    if (stderr.len != 0) {
        const stderr_name = try fmt.bufPrint(&buf, "{s}-stderr", .{digest});
        try cache_dir.writeFile(.{ .sub_path = stderr_name, .data = stderr });
    }

    for (outputs, 0..) |output, i| {
        const cache_name = fmt.bufPrint(&buf, "{s}-{}", .{ digest, i }) catch unreachable;
        fs.rename(cwd, output, cache_dir, cache_name) catch |err| switch (err) {
            error.RenameAcrossMountPoints => try cwd.copyFile(output, cache_dir, cache_name, .{}),
            else => |e| return e,
        };
    }
}
