const std = @import("std");

// make-lnk — generate a Windows shortcut (.lnk) with a relative target
// path and a PropertyStoreDataBlock that stamps the same AppUserModelID
// the james binary sets via SetCurrentProcessExplicitAppUserModelID, so
// Windows groups the running button with the pinned shortcut (Super+N
// activates it) instead of spawning a separate cmd.exe button.
//
// Runs on the build host (Linux/macOS) at build time — the .lnk is a
// pure binary file (MS-SHLLINK format), so no Windows, no PowerShell, no
// COM, no access-denied from read-only VM shared folders. Just copy
// james.exe and james.lnk to the same directory on Windows, pin the
// .lnk, and launch.
//
//   zig run tools/make-lnk.zig -- james.lnk [target=james.exe] [icon=target] [appid=JamesDyer.James]

// GUIDs are stored as: Data1(u32 LE) + Data2(u16 LE) + Data3(u16 LE) + Data4(8 bytes as-is).
const CLSID_SHELL_LINK = [_]u8{
    0x01, 0x14, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46,
};

// PKEY_AppUserModel_ID = {9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}, pid 5.
const FMTID_APPUSERMODEL_ID = [_]u8{
    0x55, 0x28, 0x4C, 0x9F, 0x79, 0x9F, 0x39, 0x4B,
    0xA8, 0xD0, 0xE1, 0xD4, 0x2D, 0xE1, 0xD5, 0xF3,
};

// LinkFlags bits (MS-SHLLINK §2.1.1).
const HAS_LINK_INFO: u32 = 0x00000002;
const HAS_RELATIVE_PATH: u32 = 0x00000008;
const HAS_WORKING_DIR: u32 = 0x00000010;
const HAS_ICON_LOCATION: u32 = 0x00000040;
const UNICODE: u32 = 0x00000080;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();
    _ = args_it.next();

    const out_path = args_it.next() orelse {
        std.debug.print("Usage: make-lnk <output.lnk> [target=james.exe] [icon=target] [appid=JamesDyer.James]\n", .{});
        std.process.exit(1);
    };
    const target = args_it.next() orelse "james.exe";
    const icon = args_it.next() orelse target;
    const appid = args_it.next() orelse "JamesDyer.James";

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    try writeShellLink(&buf, gpa, target, icon, appid);

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = buf.items }) catch |err| {
        std.debug.print("Error writing {s}: {}\n", .{ out_path, err });
        std.process.exit(1);
    };

    std.debug.print("Wrote {s} ({d} bytes) — target: {s}, icon: {s}, AppID: {s}\n", .{
        out_path, buf.items.len, target, icon, appid,
    });
}

fn writeU16(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, val: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, val, .little);
    try buf.appendSlice(gpa, &bytes);
}

fn writeU32(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, val: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, val, .little);
    try buf.appendSlice(gpa, &bytes);
}

fn writeU64(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, val: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, val, .little);
    try buf.appendSlice(gpa, &bytes);
}

fn writeGuid(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, guid: [16]u8) !void {
    try buf.appendSlice(gpa, &guid);
}

fn writeAnsiString(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8) !void {
    try buf.appendSlice(gpa, text);
    try buf.append(gpa, 0);
}

fn writeUtf16String(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8) !void {
    var temp: std.ArrayList(u16) = .empty;
    defer temp.deinit(gpa);
    try temp.ensureTotalCapacity(gpa, text.len);
    const n = std.unicode.utf8ToUtf16Le(temp.unusedCapacitySlice(), text) catch return error.InvalidUtf8;
    temp.items.len = n;

    try writeU16(buf, gpa, @intCast(n));
    for (temp.items) |c| try writeU16(buf, gpa, c);
    try writeU16(buf, gpa, 0);
}

fn writeShellLink(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, target: []const u8, icon: []const u8, appid: []const u8) !void {
    const flags: u32 = HAS_LINK_INFO | HAS_RELATIVE_PATH | HAS_WORKING_DIR | HAS_ICON_LOCATION | UNICODE;

    // §2.1 ShellLinkHeader (76 bytes).
    try writeU32(buf, gpa, 0x4C);
    try writeGuid(buf, gpa, CLSID_SHELL_LINK);
    try writeU32(buf, gpa, flags);
    try writeU32(buf, gpa, 0);
    try writeU64(buf, gpa, 0);
    try writeU64(buf, gpa, 0);
    try writeU64(buf, gpa, 0);
    try writeU32(buf, gpa, 0);
    try writeU32(buf, gpa, 0);
    try writeU32(buf, gpa, 1);
    try writeU16(buf, gpa, 0);
    try writeU16(buf, gpa, 0);
    try writeU32(buf, gpa, 0);
    try writeU32(buf, gpa, 0);

    // §2.3 LinkInfo. LocalBasePath holds the target path; RELATIVE_PATH
    // (in StringData below) is the same path relative to the .lnk's
    // directory, so Windows resolves it wherever the pair is copied.
    const header_size: u32 = 0x1C;
    const volume_id_offset: u32 = header_size;

    const local_base_path_offset: u32 = volume_id_offset + 17;
    const local_base_path_bytes: u32 = @intCast(target.len + 1);
    const common_path_suffix_offset: u32 = local_base_path_offset + local_base_path_bytes;

    const link_info_size: u32 = common_path_suffix_offset + 1;

    try writeU32(buf, gpa, link_info_size);
    try writeU32(buf, gpa, header_size);
    try writeU32(buf, gpa, 0x01);
    try writeU32(buf, gpa, volume_id_offset);
    try writeU32(buf, gpa, local_base_path_offset);
    try writeU32(buf, gpa, 0);
    try writeU32(buf, gpa, common_path_suffix_offset);

    // VolumeID (§2.3.1): DRIVE_FIXED, empty label.
    try writeU32(buf, gpa, 17);
    try writeU32(buf, gpa, 3);
    try writeU32(buf, gpa, 0);
    try writeU32(buf, gpa, 0x10);
    try buf.append(gpa, 0);

    try writeAnsiString(buf, gpa, target);
    try buf.append(gpa, 0);

    // §2.4 StringData — order is fixed by the flags: RELATIVE_PATH,
    // WORKING_DIR, ICON_LOCATION. Each is a u16 char-count + UTF-16LE
    // chars + a null terminator.
    try writeUtf16String(buf, gpa, target);
    try writeUtf16String(buf, gpa, "");
    try writeUtf16String(buf, gpa, icon);

    // §2.5 ExtraData: a PropertyStoreDataBlock (signature 0xA0000007)
    // containing one property — AppUserModel_ID — followed by a
    // 4-byte TerminalBlock.
    try writePropertyStore(buf, gpa, appid);

    try writeU32(buf, gpa, 4);
}

fn writePropertyStore(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, appid: []const u8) !void {
    // The PropertyStore is a self-contained blob; we build it in a
    // temp buffer to know its size before writing the block header.
    var store: std.ArrayList(u8) = .empty;
    defer store.deinit(gpa);

    // PropertyStoreHeader (§1.2 in MS-PROPSTORE).
    store.appendSlice(gpa, &[_]u8{ 0x53, 0x50 }) catch return error.OutOfMemory; // "PS"
    try writeU16(&store, gpa, 1);

    // FormatID[0]: the GUID + offset to the PropertySection.
    try writeGuid(&store, gpa, FMTID_APPUSERMODEL_ID);
    const section_offset: u32 = 4 + 20;
    try writeU32(&store, gpa, section_offset);

    // PropertySection: header (GUID + offset) + body (count + properties).
    try writeGuid(&store, gpa, FMTID_APPUSERMODEL_ID);
    try writeU32(&store, gpa, section_offset);

    try writeU32(&store, gpa, 1);

    // Property: PropertyID=5 (PID_APPUSERMODEL_ID), VT_LPWSTR.
    try writeU32(&store, gpa, 5);

    try writeU16(&store, gpa, 31); // VT_LPWSTR
    var padding: [6]u8 = .{ 0, 0, 0, 0, 0, 0 };
    try store.appendSlice(gpa, &padding);

    var appid16: std.ArrayList(u16) = .empty;
    defer appid16.deinit(gpa);
    try appid16.ensureTotalCapacity(gpa, appid.len);
    const n = std.unicode.utf8ToUtf16Le(appid16.unusedCapacitySlice(), appid) catch return error.InvalidUtf8;
    appid16.items.len = n;

    const string_bytes: u32 = @intCast((n + 1) * 2);
    try writeU32(&store, gpa, string_bytes);
    for (appid16.items) |c| try writeU16(&store, gpa, c);
    try writeU16(&store, gpa, 0);

    const block_size: u32 = @intCast(4 + 4 + store.items.len);
    try writeU32(buf, gpa, block_size);
    try writeU32(buf, gpa, 0xA0000007);
    try buf.appendSlice(gpa, store.items);
}
