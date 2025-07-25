const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const strip = b.option(bool, "strip", "Omit debug symbols") orelse false;

    const spaghet = b.dependency("spaghet", .{});
    const known_folders = b.dependency("known_folders", .{});

    const exe = b.addExecutable(.{
        .name = "cache",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    exe.root_module.addImport("spaghet", spaghet.module("spaghet"));
    exe.root_module.addImport("folders", known_folders.module("known-folders"));

    b.installArtifact(exe);
}
