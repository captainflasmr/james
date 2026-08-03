const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // Cross-compiling without an explicit -p installs over the native
    // binary in zig-out/bin (a Windows PE or macOS Mach-O that the host
    // then can't run). This bit three times in a row, so refuse.
    const is_native = target.result.cpu.arch == builtin.cpu.arch and
        target.result.os.tag == builtin.os.tag;
    if (!is_native and std.mem.endsWith(u8, b.install_prefix, "zig-out")) {
        std.debug.print("cross-compiling for {s}-{s}: pass -p <prefix> (e.g. -p zig-out/{s}) so zig-out/bin keeps the native binary — or use ./build.sh\n", .{ @tagName(target.result.os.tag), @tagName(target.result.cpu.arch), @tagName(target.result.os.tag) });
        std.process.exit(1);
    }

    // Default builds are ReleaseSmall and stripped: james is meant to be
    // run, not debugged, so the plain `zig build` should hand back the
    // smallest practical binary. Debugging builds are still one flag
    // away: `zig build -Doptimize=Debug -Dstrip=false`.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .ReleaseSmall;
    const strip = b.option(bool, "strip", "Omit debug information") orelse true;

    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "james",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis.module("vaxis") },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the editor");
    run_step.dependOn(&run_cmd.step);
}
