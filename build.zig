const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const exe = b.addExecutable(.{
        .name = "cache",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addAnonymousImport("clap", .{
        .root_source_file = b.path("lib/zig-clap/clap.zig"),
    });
    exe.root_module.addAnonymousImport("folders", .{
        .root_source_file = b.path("lib/known-folders/known-folders.zig"),
    });

    b.installArtifact(exe);
}
