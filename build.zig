const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const exe = b.addExecutable(.{
        .name = "cache",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addAnonymousModule("clap", .{
        .source_file = .{ .path = "lib/zig-clap/clap.zig" },
    });
    exe.addAnonymousModule("folders", .{
        .source_file = .{ .path = "lib/known-folders/known-folders.zig" },
    });
    exe.install();
}
