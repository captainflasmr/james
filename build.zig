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
    // The native Win32 clipboard API (the console's OSC 52 support is
    // spotty), used only on Windows.
    if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("user32", .{});
    }

    // The welcome screen's version line: the newest CHANGELOG.org entry
    // (version, date, and the change line under the heading), parsed once
    // at build time and baked into the binary — so it shows however james
    // is launched (the .desktop launcher starts it from $HOME, where
    // CHANGELOG.org isn't).
    const release = latestRelease(b);
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", release.version);
    build_options.addOption([]const u8, "date", release.date);
    build_options.addOption([]const u8, "built", buildTime(b));
    build_options.addOption([]const u8, "theme", release.theme);
    exe.root_module.addOptions("build_options", build_options);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the editor");
    run_step.dependOn(&run_cmd.step);
}

const ReleaseInfo = struct { version: []const u8, date: []const u8, theme: []const u8 };

/// The newest entry of CHANGELOG.org — version number, release date, and
/// the theme line under the heading — for the welcome screen. Parsed once
/// at build time and baked into the binary, so it shows however james is
/// launched (a .desktop launcher starts it from $HOME, where the
/// changelog isn't). Empty strings when the changelog can't be read or
/// parsed.
fn latestRelease(b: *std.Build) ReleaseInfo {
    const empty: ReleaseInfo = .{ .version = "", .date = "", .theme = "" };
    const io = std.Io.Threaded.global_single_threaded.io();
    const src = std.Io.Dir.cwd().readFileAlloc(io, "CHANGELOG.org", b.allocator, .limited(1 << 20)) catch return empty;
    defer b.allocator.free(src);

    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "** ")) continue;
        // The heading is "** 0.21.0 — <2026-08-05>"; the version sits
        // before the "<date>", and the theme is the first non-blank line
        // under the heading.
        const rest = std.mem.trim(u8, line["** ".len..], " ");
        const lt = std.mem.indexOfScalar(u8, rest, '<') orelse continue;
        const gt = std.mem.indexOfScalarPos(u8, rest, lt + 1, '>') orelse continue;
        const raw_version = std.mem.trim(u8, rest[0..lt], " ");
        // The em-dash before "<date>" belongs to the heading, not the
        // version number: "0.38.0 — <2026-08-06>" names the release 0.38.0.
        const version = if (std.mem.endsWith(u8, raw_version, " —"))
            raw_version[0 .. raw_version.len - " —".len]
        else
            raw_version;
        const date = rest[lt + 1 .. gt];
        if (version.len == 0 or date.len == 0) continue;
        while (lines.next()) |theme_line| {
            const theme = std.mem.trim(u8, theme_line, " \t");
            if (theme.len == 0) continue;
            // Strip the org =...= markup the changelog uses for keys.
            var plain: std.ArrayList(u8) = .empty;
            defer plain.deinit(b.allocator);
            for (theme) |c| {
                if (c != '=') plain.append(b.allocator, c) catch return empty;
            }
            return .{
                .version = b.allocator.dupe(u8, version) catch return empty,
                .date = b.allocator.dupe(u8, date) catch return empty,
                .theme = plain.toOwnedSlice(b.allocator) catch return empty,
            };
        }
        return empty;
    }
    return empty;
}

/// The build moment's clock time, "HH:MM" (UTC, like every timestamp
/// james shows) — the welcome screen's version line pairs it with the
/// release date from CHANGELOG.org, so a rebuild of the same version is
/// visible at a glance. Empty on failure.
fn buildTime(b: *std.Build) []const u8 {
    var buf: [8]u8 = undefined;
    const io = std.Io.Threaded.global_single_threaded.io();
    const secs: u64 = @intCast(@max(@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s), 0));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const ds = es.getDaySeconds();
    const s = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}", .{ ds.getHoursIntoDay(), ds.getMinutesIntoHour() }) catch return "";
    return b.allocator.dupe(u8, s) catch return "";
}
