const std = @import("std");

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
    for (self.entries.items) |e| gpa.free(e.name);
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

fn reload(self: *Dired, gpa: std.mem.Allocator, io: std.Io) !void {
    self.freeEntries(gpa);
    self.selected = 0;
    self.top = 0;

    var dir = try std.Io.Dir.cwd().openDir(io, self.path.items, .{ .iterate = true });
    defer dir.close(io);

    if (try parentOf(gpa, self.path.items)) |parent| {
        gpa.free(parent);
        try self.entries.append(gpa, .{ .name = try gpa.dupe(u8, ".."), .is_dir = true });
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .directory, .file, .sym_link => {},
            else => continue,
        }
        try self.entries.append(gpa, .{
            .name = try gpa.dupe(u8, entry.name),
            .is_dir = entry.kind == .directory,
        });
    }

    std.mem.sort(Entry, self.entries.items, {}, lessThan);
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
