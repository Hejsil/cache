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
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_state.allocator();
    defer _ = gpa_state.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    const arena = arena_state.allocator();
    defer arena_state.deinit();

    var stdin_buf: [std.heap.page_size_min]u8 = undefined;
    var stdout_buf: [std.heap.page_size_min]u8 = undefined;
    var stderr_buf: [std.heap.page_size_min]u8 = undefined;
    var stdin = std.fs.File.stdin().reader(&stdin_buf);
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    var stderr = std.fs.File.stderr().writer(&stderr_buf);

    try mainFull(.{
        .arena = arena,
        .stdin = &stdin,
        .stdout = &stdout,
        .stderr = &stderr,
    });
    try stdout.end();
    try stderr.end();
}

const Io = struct {
    arena: std.mem.Allocator,
    stdout: *std.fs.File.Writer,
    stderr: *std.fs.File.Writer,
    stdin: *std.fs.File.Reader,
};

fn mainFull(io: Io) !void {
    const global_cache_path = (try folders.getPath(io.arena, .cache)) orelse return error.MissingGlobalCache;
    const cache_path = try std.fs.path.join(io.arena, &.{ global_cache_path, "cache" });

    var cache_dir = try std.fs.cwd().makeOpenPath(cache_path, .{});
    defer cache_dir.close();

    var arg_parser = try spaghet.Args.initArgs(io.arena);
    var args = Args{};
    while (arg_parser.next()) {
        if (arg_parser.flag(&.{ "-h", "--help" }))
            return io.stdout.interface.writeAll(usage);
        if (arg_parser.flag(&.{"--stdin"}))
            args.stdin = true;
        if (arg_parser.flag(&.{"--ignore-stdout"}))
            args.ignore_stdout = true;
        if (arg_parser.flag(&.{"--ignore-stderr"}))
            args.ignore_stderr = true;
        if (arg_parser.option(&.{ "-e", "--env" })) |v|
            try args.envs.append(io.arena, v);
        if (arg_parser.option(&.{ "-f", "--file" })) |v|
            try args.files.append(io.arena, v);
        if (arg_parser.option(&.{ "-s", "--string" })) |v|
            try args.strings.append(io.arena, v);
        if (arg_parser.option(&.{ "-o", "--output" })) |v|
            try args.outputs.append(io.arena, v);
        if (arg_parser.positional()) |v|
            try args.command.append(io.arena, v);
    }

    const stdin_content = if (args.stdin)
        try io.stdin.interface.allocRemaining(io.arena, .unlimited)
    else
        "";

    const digest = try digestFromArgs(io.arena, stdin_content, args);
    if (updateOutput(io, cache_dir, cache_path, &digest, args.outputs.items)) |_| {
        // Cache hit, just return
        return;
    } else |err| switch (err) {
        error.FileNotFound => {
            // Cache miss, execute command below
        },
        else => |err2| return err2,
    }

    const output = try std.process.Child.run(.{
        .allocator = io.arena,
        .argv = args.command.items,
        .max_output_bytes = std.math.maxInt(usize),
    });

    const output_stdout = if (!args.ignore_stdout) output.stdout else "";
    const output_stderr = if (!args.ignore_stderr) output.stderr else "";

    try updateCache(io, output_stdout, output_stderr, cache_dir, &digest, args.outputs.items);
    try updateOutput(io, cache_dir, cache_path, &digest, args.outputs.items);

    // Print out stdout and stderr when ignore but didn't have a cache hit. This allows for better
    // debugging if the command fails.
    if (!args.ignore_stdout)
        try io.stdout.interface.writeAll(output.stdout);
    if (!args.ignore_stderr)
        try io.stderr.interface.writeAll(output.stderr);
}

const BinDigest = [bin_digest_len]u8;
const bin_digest_len = 16;
const Hasher = std.crypto.auth.siphash.SipHash128(1, 3);
const hex_digest_len = bin_digest_len * 2;

fn digestFromArgs(arena: std.mem.Allocator, stdin: []const u8, args: Args) ![hex_digest_len]u8 {
    const cwd = std.fs.cwd();
    var hasher = Hasher.init(&[_]u8{0} ** Hasher.key_length);
    hasher.update(stdin);

    for (args.command.items) |command_arg|
        hasher.update(command_arg);
    for (args.strings.items) |string|
        hasher.update(string);
    for (args.envs.items) |env| {
        const content = std.process.getEnvVarOwned(arena, env) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => "",
            else => |e| return e,
        };
        hasher.update(env);
        hasher.update(content);
    }
    for (args.files.items) |filepath| {
        const realpath = try cwd.realpathAlloc(arena, filepath);
        const file = try cwd.openFile(realpath, .{});
        const stat = try file.stat();
        defer file.close();
        hasher.update(realpath);
        hasher.update(&std.mem.toBytes(stat.size));
        hasher.update(&std.mem.toBytes(stat.mtime));
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
    io: Io,
    cache_dir: std.fs.Dir,
    cache_path: []const u8,
    digest: []const u8,
    outputs: []const []const u8,
) !void {
    const cwd = std.fs.cwd();
    for (outputs, 0..) |output, i| {
        const file_name = try std.fmt.allocPrint(io.arena, "{s}-{}", .{ digest, i });
        const path = try std.fs.path.join(io.arena, &.{ cache_path, file_name });

        cwd.deleteFile(output) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
        try cwd.symLink(path, output, .{});
    }

    const stdout_name = try std.fmt.allocPrint(io.arena, "{s}-stdout", .{digest});
    const stderr_name = try std.fmt.allocPrint(io.arena, "{s}-stderr", .{digest});

    var stdout_file_buf: [std.heap.page_size_min]u8 = undefined;
    var stderr_file_buf: [std.heap.page_size_min]u8 = undefined;

    var stdout_file = (try cache_dir.openFile(stdout_name, .{})).reader(&stdout_file_buf);
    defer stdout_file.file.close();

    _ = try io.stdout.interface.sendFileAll(&stdout_file, .unlimited);

    var stderr_file = (cache_dir.openFile(stderr_name, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    }).reader(&stderr_file_buf);
    defer stderr_file.file.close();

    _ = try io.stderr.interface.sendFileAll(&stderr_file, .unlimited);
}

fn updateCache(
    io: Io,
    stdout: []const u8,
    stderr: []const u8,
    cache_dir: std.fs.Dir,
    digest: []const u8,
    outputs: []const []const u8,
) !void {
    const cwd = std.fs.cwd();

    const stdout_name = try std.fmt.allocPrint(io.arena, "{s}-stdout", .{digest});
    try cache_dir.writeFile(.{ .sub_path = stdout_name, .data = stdout });

    std.debug.print("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n", .{});
    if (stderr.len != 0) {
        std.debug.print("BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB\n", .{});
        const stderr_name = try std.fmt.allocPrint(io.arena, "{s}-stderr", .{digest});
        try cache_dir.writeFile(.{ .sub_path = stderr_name, .data = stderr });
    }

    for (outputs, 0..) |output, i| {
        const cache_name = try std.fmt.allocPrint(io.arena, "{s}-{}", .{ digest, i });
        std.fs.rename(cwd, output, cache_dir, cache_name) catch |err| switch (err) {
            error.RenameAcrossMountPoints => try cwd.copyFile(output, cache_dir, cache_name, .{}),
            else => |e| return e,
        };
    }
}

const spaghet = @import("spaghet");
const folders = @import("folders");
const std = @import("std");
