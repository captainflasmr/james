const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

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
