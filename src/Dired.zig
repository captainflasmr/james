const std = @import("std");
const builtin = @import("builtin");

const Dired = @This();

/// Directory currently being browsed. May be relative (to the process's
/// actual working directory) or absolute — both work fine as arguments to
/// Dir.cwd().openDir, which is all this ever calls.
path: std.ArrayList(u8) = .empty,
entries: std.ArrayList(Entry) = .empty,
selected: usize = 0,
top: usize = 0,

pub const Entry = struct {
    name: []u8,
    is_dir: bool,
    is_link: bool = false,
    /// The ls -al style prefix: permissions, size, modification time and a
    /// trailing space, e.g. "drwxr-xr-x  1234 2026-08-02 14:30 ". Computed
    /// and heap-allocated once at load time, so rendering can print it
    /// directly (vaxis stores grapheme slices, not copies — no scratch
    /// buffers at render time).
    meta: []u8 = &.{},
};

pub const Choice = union(enum) {
    /// The selected entry is a directory; the caller should open (or switch
    /// to) a dired buffer for this path. Caller must free.
    open_dir: []u8,
    open_file: []u8, // caller must free
    none,
};

pub fn deinit(self: *Dired, gpa: std.mem.Allocator) void {
    self.freeEntries(gpa);
    self.entries.deinit(gpa);
    self.path.deinit(gpa);
}

fn freeEntries(self: *Dired, gpa: std.mem.Allocator) void {
    for (self.entries.items) |e| {
        gpa.free(e.name);
        gpa.free(e.meta);
    }
    self.entries.clearRetainingCapacity();
}

/// Directory that should contain `filename`, for picking a sensible place
/// to start browsing. "." (the process's actual working directory) if
/// `filename` has no directory component of its own.
pub fn startingDir(gpa: std.mem.Allocator, filename: []const u8) ![]u8 {
    if (std.fs.path.dirname(filename)) |d| return gpa.dupe(u8, d);
    return gpa.dupe(u8, ".");
}

/// The directory "above" `current`, for the ".." entry. Doesn't require
/// resolving to a canonical absolute path: once a plain `dirname` can't go
/// any further up a relative path, further "up" requests just accumulate
/// literal ".." components instead, which the OS resolves fine. Returns
/// null only when `current` is an absolute path already at the filesystem
/// root, where there is truly nowhere further to go.
fn parentOf(gpa: std.mem.Allocator, current: []const u8) !?[]u8 {
    if (std.mem.eql(u8, current, ".")) return try gpa.dupe(u8, "..");
    if (std.mem.eql(u8, std.fs.path.basename(current), "..")) {
        return try std.fs.path.join(gpa, &.{ current, ".." });
    }
    if (std.fs.path.dirname(current)) |d| return try gpa.dupe(u8, d);
    if (std.fs.path.isAbsolute(current)) return null;
    return try gpa.dupe(u8, ".");
}

/// Point the browser at `new_path` (which the caller may free afterwards —
/// this copies it) and (re)load its listing.
pub fn open(self: *Dired, gpa: std.mem.Allocator, io: std.Io, new_path: []const u8) !void {
    self.path.clearRetainingCapacity();
    try self.path.appendSlice(gpa, new_path);
    try self.reload(gpa, io);
}

/// Re-read the directory listing, keeping the selection where it was.
/// Used after copy / delete change the directory contents.
pub fn refresh(self: *Dired, gpa: std.mem.Allocator, io: std.Io) !void {
    const prev_selected = self.selected;
    try self.reload(gpa, io);
    self.selected = @min(prev_selected, self.entries.items.len -| 1);
}

fn reload(self: *Dired, gpa: std.mem.Allocator, io: std.Io) !void {
    self.freeEntries(gpa);
    self.selected = 0;
    self.top = 0;

    var dir = try std.Io.Dir.cwd().openDir(io, self.path.items, .{ .iterate = true });
    defer dir.close(io);

    if (try parentOf(gpa, self.path.items)) |parent| {
        gpa.free(parent);
        try self.entries.append(gpa, try makeEntry(gpa, io, dir, "..", .directory));
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .directory, .file, .sym_link => {},
            else => continue,
        }
        try self.entries.append(gpa, try makeEntry(gpa, io, dir, entry.name, entry.kind));
    }

    std.mem.sort(Entry, self.entries.items, {}, lessThan);
}

/// Build one entry: the name plus an ls -al style metadata prefix. A file
/// that can't be stat'd (e.g. a broken symlink) keeps the entry with a
/// zeroed metadata line rather than vanishing, like real dired.
fn makeEntry(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
    kind: std.Io.File.Kind,
) !Entry {
    var e: Entry = .{
        .name = try gpa.dupe(u8, name),
        .is_dir = kind == .directory,
        .is_link = kind == .sym_link,
    };
    errdefer gpa.free(e.name);
    errdefer gpa.free(e.meta);

    const stat = dir.statFile(io, name, .{ .follow_symlinks = false }) catch {
        // Stat failed: zeroed metadata, keeping column alignment.
        e.meta = try std.fmt.allocPrint(gpa, "----------  {d:>8}  1970-01-01 00:00:00 ", .{@as(u64, 0)});
        return e;
    };
    e.meta = try formatMeta(gpa, e, stat);
    return e;
}

/// "drwxr-xr-x  1234 2026-08-02 14:30 " for a POSIX stat; on Windows the
/// permission bits don't exist, so the nine permission characters become
/// "r/w" for writability and "-" elsewhere.
fn formatMeta(gpa: std.mem.Allocator, e: Entry, stat: std.Io.File.Stat) ![]u8 {
    var perms_buf: [10]u8 = undefined;
    permString(&perms_buf, e, stat.permissions);
    var date_buf: [19]u8 = undefined;
    dateString(&date_buf, stat.mtime);
    return std.fmt.allocPrint(gpa, "{s} {d:>8} {s} ", .{ perms_buf, stat.size, date_buf });
}

fn permString(buf: *[10]u8, e: Entry, perms: std.Io.File.Permissions) void {
    buf[0] = if (e.is_dir) 'd' else if (e.is_link) 'l' else '-';
    if (comptime builtin.os.tag == .windows) {
        // Windows has no rwx bits; FILE_ATTRIBUTE_READONLY is 0x1. (The
        // std helper is unusable here — it doesn't compile for Windows in
        // this Zig version.)
        const attrs: u32 = @intFromEnum(perms);
        buf[1] = 'r';
        buf[2] = if (attrs & 1 != 0) '-' else 'w';
        for (buf[3..10]) |*c| c.* = '-';
    } else {
        const mode = perms.toMode();
        var i: usize = 1;
        // setuid / setgid / sticky sit three octal places above the
        // class's read bit, so the shift differs per class (3, 5, 7 bits).
        for ([_]u16{ 0o400, 0o040, 0o004 }, [3]u4{ 3, 5, 7 }) |rbit, sshift| {
            buf[i] = if (mode & rbit != 0) 'r' else '-';
            i += 1;
            buf[i] = if (mode & (rbit >> 1) != 0) 'w' else '-';
            i += 1;
            const xbit = rbit >> 2;
            const sbit = rbit << sshift;
            buf[i] = if (mode & xbit != 0)
                (if (mode & sbit != 0) 's' else 'x')
            else
                (if (mode & sbit != 0) 'S' else '-');
            i += 1;
        }
    }
}

fn dateString(buf: *[19]u8, mtime: std.Io.Timestamp) void {
    const secs_i: i64 = @intCast(@divTrunc(mtime.nanoseconds, 1_000_000_000));
    const secs: u64 = @intCast(@max(secs_i, 0));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = es.getEpochDay();
    const ds = es.getDaySeconds();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    _ = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch {};
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    if (std.mem.eql(u8, a.name, "..")) return true;
    if (std.mem.eql(u8, b.name, "..")) return false;
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

pub fn moveUp(self: *Dired) void {
    if (self.selected > 0) self.selected -= 1;
}

pub fn moveDown(self: *Dired) void {
    if (self.selected + 1 < self.entries.items.len) self.selected += 1;
}

pub fn scrollToSelected(self: *Dired, height: usize) void {
    if (height == 0) return;
    if (self.selected < self.top) {
        self.top = self.selected;
    } else if (self.selected >= self.top + height) {
        self.top = self.selected - height + 1;
    }
}

/// The directory "above" `current` (owned by the caller), for the "^" /
/// M-e shortcut — the Emacs equivalent of dired-up-directory. Returns null
/// only when `current` is an absolute path already at the filesystem root.
pub fn upPath(self: *Dired, gpa: std.mem.Allocator) !?[]u8 {
    return parentOf(gpa, self.path.items);
}

/// Act on the selected entry: report a directory for the caller to open as
/// its own dired buffer, or a file to be opened. Never mutates the listing
/// itself — the caller decides what to do with the path, so dired behaves
/// like a buffer rather than a one-shot picker.
pub fn choose(self: *Dired, gpa: std.mem.Allocator) !Choice {
    if (self.entries.items.len == 0) return .none;
    const entry = self.entries.items[self.selected];

    var target: std.ArrayList(u8) = .empty;
    defer target.deinit(gpa);

    if (std.mem.eql(u8, entry.name, "..")) {
        const parent = try parentOf(gpa, self.path.items) orelse return .none;
        defer gpa.free(parent);
        try target.appendSlice(gpa, parent);
    } else {
        const full = try std.fs.path.join(gpa, &.{ self.path.items, entry.name });
        defer gpa.free(full);
        try target.appendSlice(gpa, full);
    }

    if (entry.is_dir) return .{ .open_dir = try target.toOwnedSlice(gpa) };
    return .{ .open_file = try target.toOwnedSlice(gpa) };
}
