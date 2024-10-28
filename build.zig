const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const strip = b.option(bool, "strip", "Omit debug symbols") orelse false;

    const clap = b.dependency("clap", .{});
    const known_folders = b.dependency("known-folders", .{});

    const exe = b.addExecutable(.{
        .name = "cache",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    exe.root_module.addImport("clap", clap.module("clap"));
    exe.root_module.addImport("folders", known_folders.module("known-folders"));

    b.installArtifact(exe);
}
