const std = @import("std");
const builtin = @import("builtin");

const Dired = @This();

/// Directory currently being browsed. May be relative (to the process's
/// actual working directory) or absolute — both work fine as arguments to
/// Dir.cwd().openDir, which is all this ever calls.
path: std.ArrayList(u8) = .empty,
/// The full directory path, for display (the dired header line and the
/// modeline): `path` made absolute, with "." and ".." components
/// resolved. Filesystem operations keep using the raw `path`.
display_path: std.ArrayList(u8) = .empty,
entries: std.ArrayList(Entry) = .empty,
selected: usize = 0,
top: usize = 0,
/// Next position for C-l (recenter-top-bottom): 0 = middle, 1 = top,
/// 2 = bottom.
recenter_pos: u8 = 0,
/// How the listing is ordered — the digit keys 3-6 in dired, mirroring
/// the ls flags S / t / (default) / X.
sort_mode: SortMode = .name,
/// ( toggles dired-hide-details-mode: hide the metadata prefix
/// (permissions, size, date) so only the names remain, like Emacs.
hide_details: bool = false,

pub const SortMode = enum { name, size, date, extension };

pub const Entry = struct {
    name: []u8,
    is_dir: bool,
    is_link: bool = false,
    /// Set by m in dired (Emacs dired-mark): marked entries are the
    /// operands of C (copy) and R (rename), shown with a * in column 0.
    /// Rebuilt entries from a refresh are unmarked.
    marked: bool = false,
    /// The raw sort keys, captured from the stat so sorting by size or
    /// date doesn't have to parse the formatted meta string back out.
    size: u64 = 0,
    mtime: i64 = 0,
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
    self.display_path.deinit(gpa);
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
    // The absolute display path (best effort: keep the raw path if the
    // working directory can't be read).
    self.display_path.clearRetainingCapacity();
    const abs = absPathOf(gpa, io, new_path) catch null;
    if (abs) |a| {
        defer gpa.free(a);
        self.display_path.appendSlice(gpa, a) catch {};
    }
    if (self.display_path.items.len == 0) self.display_path.appendSlice(gpa, new_path) catch {};
    try self.reload(gpa, io);
}

/// `path` made absolute against the process's working directory, with "."
/// and ".." components normalized out lexically (no filesystem access, so
/// symlinks are not resolved) — the dired twin of Emacs's
/// expand-file-name, for display only. Caller must free.
pub fn absPathOf(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(gpa, &.{path});
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    return std.fs.path.resolve(gpa, &.{ cwd, path });
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

    if (comptime builtin.os.tag == .windows) {
        // The Windows iterator's records already carry the size, the
        // modification time and the attributes — but std discards them,
        // so a per-entry stat would open a handle for every file (a
        // CreateFileW per entry, which makes large listings noticeably
        // slow). Enumerate with the Win32 Find* API instead.
        try self.loadWindowsEntries(gpa, io, dir);
    } else {
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
    }

    std.mem.sort(Entry, self.entries.items, self.sort_mode, lessThan);
}

const win = std.os.windows;

/// The Win32 directory-enumeration record, mirroring WIN32_FIND_DATAW.
const Win32FindData = extern struct {
    dwFileAttributes: win.DWORD,
    ftCreationTime: win.FILETIME,
    ftLastAccessTime: win.FILETIME,
    ftLastWriteTime: win.FILETIME,
    nFileSizeHigh: win.DWORD,
    nFileSizeLow: win.DWORD,
    dwReserved0: win.DWORD,
    dwReserved1: win.DWORD,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};

extern "kernel32" fn FindFirstFileW(lpFileName: [*:0]const u16, lpFindFileData: *Win32FindData) callconv(.winapi) win.HANDLE;
extern "kernel32" fn FindNextFileW(hFindFile: win.HANDLE, lpFindFileData: *Win32FindData) callconv(.winapi) win.BOOL;
extern "kernel32" fn FindClose(hFindFile: win.HANDLE) callconv(.winapi) win.BOOL;

/// A FILETIME (100ns ticks since 1601-01-01) as Unix nanoseconds.
fn filetimeNanos(ft: win.FILETIME) i64 {
    const raw: u64 = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
    return (@as(i64, @intCast(raw)) - 116444736000000000) * 100;
}

/// Windows listing: the ".." entry like reload, then the Find* sweep —
/// each record's size, mtime and attributes build the entry directly,
/// no per-file handle opens.
fn loadWindowsEntries(self: *Dired, gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
    if (try parentOf(gpa, self.path.items)) |parent| {
        gpa.free(parent);
        try self.entries.append(gpa, try makeEntry(gpa, io, dir, "..", .directory));
    }

    var wild: std.ArrayList(u16) = .empty;
    defer wild.deinit(gpa);
    // utf8ToUtf16LeAllocZ returns a [:0] slice whose .len does not count
    // the sentinel null — the whole string (including its final character)
    // is wide[0..wide.len], and the terminator lives at wide[wide.len].
    const wide = std.unicode.utf8ToUtf16LeAllocZ(gpa, self.path.items) catch return;
    defer gpa.free(wide);
    try wild.appendSlice(gpa, wide);
    try wild.appendSlice(gpa, &[_]u16{ '\\', '*' });
    try wild.append(gpa, 0);

    var data: Win32FindData = undefined;
    const wild_z: [:0]const u16 = wild.items[0 .. wild.items.len - 1 :0];
    const h = FindFirstFileW(wild_z.ptr, &data);
    if (h == win.INVALID_HANDLE_VALUE) return;
    defer _ = FindClose(h);
    while (true) {
        const e = try makeEntryFromFindData(gpa, &data);
        // The sweep yields "." and ".." too; the ".." entry is already
        // appended above, and dired never lists the directory itself, so
        // drop both like the POSIX iterator path does.
        if (!std.mem.eql(u8, e.name, ".") and !std.mem.eql(u8, e.name, "..")) {
            try self.entries.append(gpa, e);
        } else {
            gpa.free(e.name);
            gpa.free(e.meta);
        }
        if (FindNextFileW(h, &data) == .FALSE) return;
    }
}

fn makeEntryFromFindData(gpa: std.mem.Allocator, data: *const Win32FindData) !Entry {
    const name_len = std.mem.indexOfScalar(u16, &data.cFileName, 0) orelse data.cFileName.len;
    const name = std.unicode.utf16LeToUtf8Alloc(gpa, data.cFileName[0..name_len]) catch return error.OutOfMemory;
    const attrs: win.FILE.ATTRIBUTE = @bitCast(data.dwFileAttributes);
    var e: Entry = .{
        .name = name,
        .is_dir = attrs.DIRECTORY,
        .is_link = attrs.REPARSE_POINT,
        .size = (@as(u64, data.nFileSizeHigh) << 32) | data.nFileSizeLow,
        .mtime = filetimeNanos(data.ftLastWriteTime),
    };
    errdefer gpa.free(e.name);
    errdefer gpa.free(e.meta);
    e.meta = try formatMeta(gpa, e, @enumFromInt(data.dwFileAttributes), e.size, .{ .nanoseconds = e.mtime });
    return e;
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
    e.size = stat.size;
    e.mtime = @intCast(stat.mtime.nanoseconds);
    e.meta = try formatMeta(gpa, e, stat.permissions, stat.size, stat.mtime);
    return e;
}

/// "drwxr-xr-x  1234 2026-08-02 14:30 " for a POSIX stat; on Windows the
/// permission bits don't exist, so the nine permission characters become
/// "r/w" for writability and "-" elsewhere.
fn formatMeta(gpa: std.mem.Allocator, e: Entry, perms: std.Io.File.Permissions, size: u64, mtime: std.Io.Timestamp) ![]u8 {
    var perms_buf: [10]u8 = undefined;
    permString(&perms_buf, e, perms);
    var date_buf: [19]u8 = undefined;
    dateString(&date_buf, mtime);
    return std.fmt.allocPrint(gpa, "{s} {d:>8} {s} ", .{ perms_buf, size, date_buf });
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

/// The part of a file name after the last dot, for sorting by extension
/// like `ls -X`. Hidden files such as ".gitignore" are all extension, not
/// extension-less.
fn extensionOf(name: []const u8) []const u8 {
    const base = std.fs.path.basename(name);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "";
    if (dot == 0) return "";
    return base[dot + 1 ..];
}

/// Order the listing by `mode`, keeping ".." pinned first. Size sorts
/// largest first (`ls -S`), date newest first (`ls -t`); ties fall back
/// to the name.
fn lessThan(mode: SortMode, a: Entry, b: Entry) bool {
    if (std.mem.eql(u8, a.name, "..")) return true;
    if (std.mem.eql(u8, b.name, "..")) return false;
    switch (mode) {
        .name => return std.ascii.lessThanIgnoreCase(a.name, b.name),
        .size => {
            if (a.size != b.size) return a.size > b.size;
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        },
        .date => {
            if (a.mtime != b.mtime) return a.mtime > b.mtime;
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        },
        .extension => {
            const ae = extensionOf(a.name);
            const be = extensionOf(b.name);
            if (!std.mem.eql(u8, ae, be)) return std.ascii.lessThanIgnoreCase(ae, be);
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        },
    }
}

/// Re-order the listing by `mode` (the digit keys 3-6, mirroring the ls
/// flags S / t / default / X), keeping ".." pinned first. The selection
/// moves to the first real entry, like the dired sort advice in the
/// author's Emacs config.
pub fn sortBy(self: *Dired, mode: SortMode) void {
    self.sort_mode = mode;
    std.mem.sort(Entry, self.entries.items, mode, lessThan);
    self.selected = 0;
    if (self.entries.items.len > 0 and std.mem.eql(u8, self.entries.items[0].name, "..")) self.selected = 1;
    self.top = 0;
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

/// C-l: recenter the listing on the selected entry, cycling through the
/// middle, top, and bottom of the window like Emacs's
/// recenter-top-bottom (the dired twin of Buffer.recenterTopBottom).
/// `cycling` is true when the previous key was also C-l; otherwise the
/// listing recenters to the middle.
pub fn recenterTopBottom(self: *Dired, height: usize, cycling: bool) void {
    if (height == 0) return;
    const pos: u8 = if (cycling) (self.recenter_pos + 1) % 3 else 0;
    self.recenter_pos = pos;
    switch (pos) {
        0 => self.top = self.selected -| (height / 2),   // middle
        1 => self.top = self.selected,                   // top
        else => self.top = self.selected -| (height - 1), // bottom
    }
    const max_top = self.entries.items.len -| height;
    self.top = @min(self.top, max_top);
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
