const custom = @import("src/custom.zig");
const std = @import("std");

comptime {
    if (custom.bot_name.len == 0)
        @compileError("custom.bot_name cannot be empty!");
}

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    b.setPreferredReleaseMode(.ReleaseSafe);
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable(custom.bot_name, "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);

    if (exe.build_mode != .Debug) {
        exe.strip = true;
        exe.pie = true;
    }

    exe.linkLibC();
    exe.linkSystemLibrary("curl");

    exe.install();
}
