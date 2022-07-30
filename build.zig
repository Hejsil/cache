const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    b.setPreferredReleaseMode(.ReleaseFast);
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("cache", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addPackagePath("clap", "lib/zig-clap/clap.zig");
    exe.addPackagePath("folders", "lib/known-folders/known-folders.zig");
    exe.install();
}
