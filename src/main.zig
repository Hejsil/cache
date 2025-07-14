const spaghet = @import("spaghet");
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

const usage =
    \\Usage: cache [options]
    \\
    \\Options:
    \\-h, --help
    \\      Output this help message and exit.
    \\
    \\    --stdin
    \\      The output of the command depends on stdin. If it changes, the cache is invalidated.
    \\
    \\    --ignore-stdout
    \\      The output from stdout will not be cached.
    \\
    \\    --ignore-stderr
    \\      The output from stderr will not be cached.
    \\
    \\-e, --env <env>...
    \\      The output of the command depends on this environment variable. If it changes, the
    \\      cache is invalidated.
    \\
    \\-f, --file <file>...
    \\      The output of the command depends on this file. If it changes, the cache is
    \\      invalidated.
    \\
    \\-s, --string <string>...
    \\      The output of the command depends on this string. If it changes, the cache is
    \\      invalidated.
    \\
    \\-o, --output <file>...
    \\      The files that command outputs to.
    \\
    \\<command>...
    \\
;

const Args = struct {
    stdin: bool = false,
    ignore_stdout: bool = false,
    ignore_stderr: bool = false,
    envs: std.ArrayListUnmanaged([]const u8) = .{},
    files: std.ArrayListUnmanaged([]const u8) = .{},
    strings: std.ArrayListUnmanaged([]const u8) = .{},
    outputs: std.ArrayListUnmanaged([]const u8) = .{},
    command: std.ArrayListUnmanaged([]const u8) = .{},
};

pub fn main() !void {
    var gpa_state = heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_state.allocator();
    defer _ = gpa_state.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    const arena = arena_state.allocator();
    defer arena_state.deinit();

    const stdin = io.getStdIn();
    const stdout = io.getStdOut();
    const stderr = io.getStdErr();

    const global_cache_path = (try folders.getPath(arena, .cache)) orelse return error.MissingGlobalCache;
    const cache_path = try fs.path.join(arena, &.{ global_cache_path, "cache" });

    var cache_dir = try std.fs.cwd().makeOpenPath(cache_path, .{});
    defer cache_dir.close();

    var arg_parser = try spaghet.Args.initArgs(arena);
    var args = Args{};
    while (arg_parser.next()) {
        if (arg_parser.flag(&.{ "-h", "--help" }))
            return stdout.writeAll(usage);
        if (arg_parser.flag(&.{"--stdin"}))
            args.stdin = true;
        if (arg_parser.flag(&.{"--ignore-stdout"}))
            args.ignore_stdout = true;
        if (arg_parser.flag(&.{"--ignore-stderr"}))
            args.ignore_stderr = true;
        if (arg_parser.option(&.{ "-e", "--env" })) |v|
            try args.envs.append(arena, v);
        if (arg_parser.option(&.{ "-f", "--file" })) |v|
            try args.files.append(arena, v);
        if (arg_parser.option(&.{ "-s", "--string" })) |v|
            try args.strings.append(arena, v);
        if (arg_parser.option(&.{ "-o", "--output" })) |v|
            try args.outputs.append(arena, v);
        if (arg_parser.positional()) |v|
            try args.command.append(arena, v);
    }

    const stdin_content = if (args.stdin)
        try stdin.readToEndAlloc(gpa, math.maxInt(usize))
    else
        "";
    defer gpa.free(stdin_content);

    const digest = try digestFromArgs(gpa, stdin_content, args);
    if (updateOutput(gpa, stdout, stderr, cache_dir, cache_path, &digest, args.outputs.items)) |_| {
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
        .argv = args.command.items,
        .max_output_bytes = math.maxInt(usize),
    });
    defer gpa.free(output.stdout);
    defer gpa.free(output.stderr);

    const output_stdout = if (!args.ignore_stdout) output.stdout else "";
    const output_stderr = if (!args.ignore_stderr) output.stderr else "";

    try updateCache(output_stdout, output_stderr, cache_dir, &digest, args.outputs.items);
    try updateOutput(gpa, stdout, stderr, cache_dir, cache_path, &digest, args.outputs.items);

    // Print out stdout and stderr when ignore but didn't have a cache hit. This allows for better
    // debugging if the command fails.
    if (!args.ignore_stdout)
        try stdout.writeAll(output.stdout);
    if (!args.ignore_stderr)
        try stderr.writeAll(output.stderr);
}

const BinDigest = [bin_digest_len]u8;
const bin_digest_len = 16;
const Hasher = crypto.auth.siphash.SipHash128(1, 3);
const hex_digest_len = bin_digest_len * 2;

fn digestFromArgs(
    allocator: mem.Allocator,
    stdin: []const u8,
    args: Args,
) ![hex_digest_len]u8 {
    const cwd = fs.cwd();
    var hasher = Hasher.init(&[_]u8{0} ** Hasher.key_length);
    hasher.update(stdin);

    for (args.command.items) |command_arg|
        hasher.update(command_arg);
    for (args.strings.items) |string|
        hasher.update(string);
    for (args.envs.items) |env| {
        const content = process.getEnvVarOwned(allocator, env) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => "",
            else => |e| return e,
        };
        defer allocator.free(content);
        hasher.update(env);
        hasher.update(content);
    }
    for (args.files.items) |filepath| {
        const realpath = try cwd.realpathAlloc(allocator, filepath);
        defer allocator.free(realpath);

        const file = try cwd.openFile(realpath, .{});
        const metadata = try file.metadata();
        defer file.close();
        hasher.update(realpath);
        hasher.update(&mem.toBytes(metadata.size()));
        hasher.update(&mem.toBytes(metadata.modified()));
    }

    if (args.ignore_stdout)
        hasher.update("ignore-stdout");
    if (args.ignore_stderr)
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
        const cache_name = try fmt.bufPrint(&buf, "{s}-{}", .{ digest, i });
        fs.rename(cwd, output, cache_dir, cache_name) catch |err| switch (err) {
            error.RenameAcrossMountPoints => try cwd.copyFile(output, cache_dir, cache_name, .{}),
            else => |e| return e,
        };
    }
}
