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
pub fn parentOf(gpa: std.mem.Allocator, current: []const u8) !?[]u8 {
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
    self.selected = @min(prev_selected, self.entries.items.len);
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
/// to the name. The comparison is reflexive — an entry never sorts
/// before itself — which the sort's internal binary search relies on
/// (it compares elements against themselves while probing ranges).
fn lessThan(mode: SortMode, a: Entry, b: Entry) bool {
    const a_up = std.mem.eql(u8, a.name, "..");
    const b_up = std.mem.eql(u8, b.name, "..");
    if (a_up or b_up) {
        if (a_up == b_up) return false;
        return a_up;
    }
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

/// Move the selection down, onto the listing's trailing newline after
/// the last entry (the empty line an Emacs dired ends with — the
/// mirror buffer's final line), so the cursor can rest there like any
/// buffer's end.
pub fn moveDown(self: *Dired) void {
    if (self.selected < self.entries.items.len) self.selected += 1;
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
/// like a buffer rather than a one-shot picker. The listing's trailing
/// newline (the selection at == entries.len) is nothing to open.
pub fn choose(self: *Dired, gpa: std.mem.Allocator) !Choice {
    if (self.selected >= self.entries.items.len) return .none;
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

/// Mark every entry whose name matches `regexp` — Emacs
/// dired-mark-files-regexp, `% m` in dired — a small regexp over the bare
/// entry name. ".." is never marked, like the other marking keys. Returns
/// how many entries were marked.
pub fn markFilesRegexp(self: *Dired, regexp: []const u8) usize {
    var n: usize = 0;
    for (self.entries.items) |*e| {
        if (std.mem.eql(u8, e.name, "..")) continue;
        if (regexMatch(e.name, regexp)) {
            e.marked = true;
            n += 1;
        }
    }
    return n;
}

/// One parsed regexp atom: a single element of the pattern — a literal
/// character, ".", a character class, an anchor, or a group.
const Atom = struct {
    /// Pattern position just after the atom (before any quantifier).
    next: usize,
    kind: Kind,
    /// .literal: the character. .group: where the group's pattern starts
    /// (just after the opening paren).
    a: usize = 0,
    /// .group: where the group's pattern ends (at the closing paren).
    b: usize = 0,
    /// .class: the class body, between the brackets.
    text: []const u8 = &.{},
    /// .class: a negated class ([^...]).
    negate: bool = false,

    const Kind = enum { literal, any, class, start, end, group };
};

/// Match the small regexp `pat` against `s` anywhere in the string (the
/// dired twin of Emacs string-match-p): unanchored unless the pattern
/// starts with ^, which pins it to the beginning; $ pins the end. The
/// supported syntax is strict Emacs regexp: . (any char), [...] / [^...]
/// classes with ranges, the greedy * + ? quantifiers, \(...\) groups and
/// \| alternation (a bare ( ) | is a literal, so names containing them
/// are matchable), ^ $ anchors, and the escapes \d \D \w \W \s \S plus
/// any escaped literal. A simple backtracking match — no
/// backreferences.
fn regexMatch(s: []const u8, pat: []const u8) bool {
    const anchored = pat.len > 0 and pat[0] == '^';
    var i: usize = 0;
    while (i <= s.len) : (i += 1) {
        if (matchBranch(s, i, pat, 0, pat.len) != null) return true;
        if (anchored) break;
    }
    return false;
}

/// Match one branch of `pat[pi..end]` against `s[si..]` — a sequence of
/// atoms, possibly split by top-level Emacs-style "\|" alternation —
/// and return the position in `s` just after the match, or null on
/// failure. `end` is the end of the enclosing group's pattern (or the
/// whole pattern), so a branch never reads past its own closing paren.
/// Strict Emacs syntax: only the escaped "\|" alternates (a bare "|" is
/// a literal), and only "\(" / "\)" are group markers.
fn matchBranch(s: []const u8, si: usize, pat: []const u8, pi: usize, end: usize) ?usize {
    // Find the top-level alternation points. Nested groups and classes
    // are skipped; their own branch matching resolves the pipes inside.
    // The recorded positions are the `|` characters themselves, so the
    // alternative before a pipe is [start, pipe) and the next starts at
    // pipe + 1.
    var pipe: [16]usize = undefined;
    var npipes: usize = 0;
    var depth: usize = 0;
    var q = pi;
    while (q < end) {
        const c = pat[q];
        if (c == '\\') {
            if (q + 1 >= end) break;
            const e = pat[q + 1];
            if (e == '(') {
                depth += 1;
            } else if (e == ')') {
                depth -|= 1;
            } else if (e == '|') {
                // Only a depth-0 pipe splits this branch; one inside a
                // group belongs to the group's own branch matching.
                if (depth == 0) {
                    if (npipes < pipe.len) pipe[npipes] = q + 1;
                    npipes = @min(npipes + 1, pipe.len);
                }
            }
            q += 2;
        } else if (c == '[') {
            q = skipClass(pat, q, end) orelse break;
        } else {
            // A bare ( ) | is a literal in Emacs regexps.
            q += 1;
        }
    }
    // Try each alternative from the same position in `s`: the first that
    // matches, wins. A pipe recorded at position p (the `|` character
    // itself) ends its alternative at p - 1 — just before the escape —
    // and the next starts at p + 1.
    var start = pi;
    for (pipe[0..npipes]) |p| {
        if (matchSequence(s, si, pat, start, p - 1)) |m| return m;
        start = p + 1;
    }
    return matchSequence(s, si, pat, start, end);
}

/// Match the atom sequence `pat[pi..end]` against `s[si..]`, returning
/// the position just after the match, or null on failure. A quantifier
/// after an atom (* + ?) repeats it, trying the most repetitions first so
/// the match is greedy, then backtracking.
fn matchSequence(s: []const u8, si: usize, pat: []const u8, pi: usize, end: usize) ?usize {
    if (pi >= end) return si;
    const atom = parseAtom(pat, pi, end) orelse return null;
    if (atom.next >= end or (pat[atom.next] != '*' and pat[atom.next] != '+' and pat[atom.next] != '?')) {
        const pos = matchAtom(s, si, pat, atom) orelse return null;
        return matchSequence(s, pos, pat, atom.next, end);
    }
    const op = pat[atom.next];
    const after = atom.next + 1;
    const min: usize = if (op == '+') 1 else 0;
    const max: usize = if (op == '?') 1 else 0x7fff_ffff;
    // The positions reachable by repeating the atom, greedily — a name is
    // at most a few hundred bytes, so the fixed history is plenty.
    var poss: [256]usize = undefined;
    var np: usize = 0;
    var pos = si;
    while (np < max and np < poss.len) {
        const npos = matchAtom(s, pos, pat, atom) orelse break;
        if (npos == pos) {
            // A zero-width repetition (e.g. a group matching nothing):
            // take it once and stop, like the real engines.
            poss[np] = npos;
            np += 1;
            break;
        }
        poss[np] = npos;
        np += 1;
        pos = npos;
    }
    var count = np;
    while (count > 0) : (count -= 1) {
        if (matchSequence(s, poss[count - 1], pat, after, end)) |m| return m;
        if (count <= min) break;
    }
    if (min == 0) {
        if (matchSequence(s, si, pat, after, end)) |m| return m;
    }
    return null;
}

/// Parse the atom at `pat[pi]`: a literal character, ".", a character
/// class, an anchor, or a group. Returns the atom and the pattern
/// position just after it, or null when the pattern is malformed there
/// (an unterminated class or group, a dangling backslash).
fn parseAtom(pat: []const u8, pi: usize, end: usize) ?Atom {
    if (pi >= end) return null;
    const c = pat[pi];
    if (c == '\\') {
        if (pi + 1 >= end) return null;
        const e = pat[pi + 1];
        switch (e) {
            '(' => {
                const close = findGroupEnd(pat, pi + 2, end) orelse return null;
                // `close` is the closing paren's position; the group's
                // inner span ends just before it, so an escaped \) — the
                // only closing paren there is — is not part of the inner
                // pattern (the last alternative of a trailing \| would
                // otherwise have to match it as a literal).
                return .{ .next = close + 1, .kind = .group, .a = pi + 2, .b = close - 1 };
            },
            'd' => return .{ .next = pi + 2, .kind = .class, .text = "0-9" },
            'D' => return .{ .next = pi + 2, .kind = .class, .negate = true, .text = "0-9" },
            'w' => return .{ .next = pi + 2, .kind = .class, .text = "A-Za-z0-9_" },
            'W' => return .{ .next = pi + 2, .kind = .class, .negate = true, .text = "A-Za-z0-9_" },
            's' => return .{ .next = pi + 2, .kind = .class, .text = " \t\n\r\x0c\x0b" },
            'S' => return .{ .next = pi + 2, .kind = .class, .negate = true, .text = " \t\n\r\x0c\x0b" },
            // Any other escape is a literal of the escaped character
            // (\. \* \[ and friends, or a stray \| \ ) \]).
            else => return .{ .next = pi + 2, .kind = .literal, .a = e },
        }
    }
    switch (c) {
        '.' => return .{ .next = pi + 1, .kind = .any },
        '^' => return .{ .next = pi + 1, .kind = .start },
        '$' => return .{ .next = pi + 1, .kind = .end },
        '[' => {
            const close = skipClass(pat, pi, end) orelse return null;
            var body_start = pi + 1;
            var negate = false;
            if (body_start < close - 1 and (pat[body_start] == '^' or pat[body_start] == '!')) {
                negate = true;
                body_start += 1;
            }
            if (body_start >= close - 1) return null; // an empty class
            return .{ .next = close, .kind = .class, .text = pat[body_start .. close - 1], .negate = negate };
        },
        // A bare quantifier is a literal — there is nothing for it to
        // quantify. A bare ( or ) is a literal too, strict Emacs syntax:
        // groups are \(...\) and alternation is \|, so names containing
        // parentheses or pipes are matchable as-is.
        '*', '+', '?', '(', ')' => return .{ .next = pi + 1, .kind = .literal, .a = c },
        else => return .{ .next = pi + 1, .kind = .literal, .a = c },
    }
}

/// The position just after the closing "]" of the class starting at
/// `pat[pi]` == "[", or null when the class never closes.
fn skipClass(pat: []const u8, pi: usize, end: usize) ?usize {
    var q = pi + 1;
    if (q < end and (pat[q] == '^' or pat[q] == '!')) q += 1;
    while (q < end and pat[q] != ']') : (q += 1) {}
    if (q >= end) return null;
    return q + 1;
}

/// The position of the closing paren of the group whose pattern starts at
/// `pat[pi]` (just after the opening "\("): the scan tracks nested
/// Emacs-style \(...\) groups (classes skipped) and returns the closing
/// paren's position, or null when the group never closes. A bare ( or )
/// is a literal and never opens or closes a group.
fn findGroupEnd(pat: []const u8, pi: usize, end: usize) ?usize {
    var depth: usize = 1;
    var q = pi;
    while (q < end) {
        const c = pat[q];
        if (c == '\\') {
            if (q + 1 >= end) return null;
            if (pat[q + 1] == '(') {
                depth += 1;
            } else if (pat[q + 1] == ')') {
                depth -= 1;
                if (depth == 0) return q + 1;
            }
            q += 2;
        } else if (c == '[') {
            q = skipClass(pat, q, end) orelse return null;
        } else {
            q += 1;
        }
    }
    return null;
}

/// Match one atom against `s[si]`, returning the position just after it,
/// or null when the character doesn't fit. A group matches its whole
/// nested pattern via matchBranch.
fn matchAtom(s: []const u8, si: usize, pat: []const u8, atom: Atom) ?usize {
    switch (atom.kind) {
        .literal => return if (si < s.len and s[si] == atom.a) si + 1 else null,
        .any => return if (si < s.len) si + 1 else null,
        .start => return if (si == 0) si else null,
        .end => return if (si == s.len) si else null,
        .group => return matchBranch(s, si, pat, atom.a, atom.b),
        .class => {
            if (si >= s.len) return null;
            const ch = s[si];
            var in_class = false;
            var q: usize = 0;
            while (q < atom.text.len) {
                // A range is a-b; a dash anywhere else is a literal.
                if (q + 2 < atom.text.len and atom.text[q + 1] == '-') {
                    if (atom.text[q] <= ch and ch <= atom.text[q + 2]) in_class = true;
                    q += 3;
                } else {
                    if (atom.text[q] == ch) in_class = true;
                    q += 1;
                }
            }
            return if (in_class != atom.negate) si + 1 else null;
        },
    }
}

test "regexMatch" {
    // Literals and unanchored matching.
    try std.testing.expect(regexMatch("Makefile", "Make"));
    try std.testing.expect(regexMatch("Makefile", "file"));
    try std.testing.expect(!regexMatch("Makefile", "readme"));
    // Anchors.
    try std.testing.expect(regexMatch("Makefile", "^Make"));
    try std.testing.expect(!regexMatch("Makefile", "^file"));
    try std.testing.expect(regexMatch("Makefile", "file$"));
    try std.testing.expect(!regexMatch("Makefile", "Make$"));
    try std.testing.expect(regexMatch("Makefile", "^Makefile$"));
    // The any char and classes, with ranges and negation.
    try std.testing.expect(regexMatch("file.txt", "file.t.t"));
    try std.testing.expect(regexMatch("file.txt", "file.[tx]xt"));
    try std.testing.expect(!regexMatch("file.ax t", "file.[tx]xt"));
    try std.testing.expect(regexMatch("file1", "file[0-9]"));
    try std.testing.expect(!regexMatch("filex", "file[0-9]"));
    try std.testing.expect(regexMatch("filex", "file[^0-9]"));
    try std.testing.expect(!regexMatch("file1", "file[^0-9]"));
    try std.testing.expect(regexMatch("file-1", "file[-a]1"));
    // Quantifiers, greedy and backtracking.
    try std.testing.expect(regexMatch("foooo", "fo*"));
    try std.testing.expect(regexMatch("f", "fo*"));
    try std.testing.expect(regexMatch("foooo", "fo+"));
    try std.testing.expect(!regexMatch("f", "fo+"));
    try std.testing.expect(regexMatch("fo", "fo?"));
    try std.testing.expect(regexMatch("f", "fo?"));
    try std.testing.expect(!regexMatch("foo", "fo?$"));
    try std.testing.expect(regexMatch("ab", "a.*b"));
    try std.testing.expect(regexMatch("axb", "a.b"));
    try std.testing.expect(!regexMatch("ab", "a.b"));
    try std.testing.expect(regexMatch("config.log", ".*\\.log$"));
    try std.testing.expect(regexMatch("Makefile", "^Make*f"));
    // Alternation and groups: strict Emacs syntax — \(...\) and \| are
    // the group and alternation markers, a bare ( ) | is a literal.
    try std.testing.expect(regexMatch("file.txt", "md\\|txt"));
    try std.testing.expect(regexMatch("README.md", "md\\|txt"));
    try std.testing.expect(regexMatch("foo.txt", "\\(foo\\|bar\\).txt"));
    try std.testing.expect(regexMatch("bar.txt", "\\(foo\\|bar\\).txt"));
    try std.testing.expect(!regexMatch("baz.txt", "\\(foo\\|bar\\).txt"));
    try std.testing.expect(regexMatch("ababab", "\\(ab\\)+"));
    try std.testing.expect(!regexMatch("ababx", "^\\(ab\\)+$"));
    try std.testing.expect(regexMatch("aabb", "\\(a\\|b\\)*"));
    // Nested groups, and a group with alternation at the end of the
    // pattern — the escaped close must not leak into the last
    // alternative.
    try std.testing.expect(regexMatch("axby", "\\(a\\(x\\|y\\)b\\)"));
    try std.testing.expect(regexMatch("ayby", "\\(a\\(x\\|y\\)b\\)"));
    try std.testing.expect(!regexMatch("abz", "\\(a\\|b\\)$"));
    try std.testing.expect(regexMatch("b", "\\(a\\|b\\)$"));
    try std.testing.expect(regexMatch("photo-2026.jpg", "photo-[0-9][0-9][0-9][0-9]"));
    // A literal ( ) | in a name matches literally, like Emacs.
    try std.testing.expect(regexMatch("archive_(1).zip", "(1)"));
    try std.testing.expect(regexMatch("archive_(1).zip", "archive_(1)"));
    try std.testing.expect(!regexMatch("bar.txt", "(foo|bar).txt"));
    try std.testing.expect(regexMatch("md|txt", "md|txt"));
    try std.testing.expect(regexMatch("(foo|bar).txt", "(foo|bar).txt"));
    // Escapes.
    try std.testing.expect(regexMatch("file1", "file\\d"));
    try std.testing.expect(!regexMatch("filex", "file\\d"));
    try std.testing.expect(regexMatch("filex", "file\\D"));
    try std.testing.expect(regexMatch("a_b", "\\w\\w\\w"));
    try std.testing.expect(!regexMatch("a b", "\\w\\w\\w"));
    try std.testing.expect(regexMatch("a b", "\\S\\s\\S"));
    try std.testing.expect(regexMatch("file.txt", "file\\.txt"));
    try std.testing.expect(!regexMatch("filextxt", "file\\.txt"));
    // Empty and degenerate patterns.
    try std.testing.expect(regexMatch("anything", ""));
    try std.testing.expect(regexMatch("anything", ".*"));
    try std.testing.expect(regexMatch("", "^$"));
    try std.testing.expect(regexMatch("", ""));
    try std.testing.expect(regexMatch("file.txt", "file"));
}

test "markFilesRegexp" {
    var d: Dired = .{};
    const names = [_][]const u8{ "..", "a.txt", "b.md", "c.txt", "notes.txt.bak", "README" };
    for (names) |n| {
        try d.entries.append(std.testing.allocator, .{ .name = try std.testing.allocator.dupe(u8, n), .is_dir = false });
    }
    defer {
        for (d.entries.items) |e| {
            std.testing.allocator.free(e.name);
            if (e.meta.len > 0) std.testing.allocator.free(e.meta);
        }
        d.entries.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 3), d.markFilesRegexp("txt"));
    try std.testing.expect(d.entries.items[1].marked); // a.txt
    try std.testing.expect(d.entries.items[3].marked); // c.txt
    try std.testing.expect(d.entries.items[4].marked); // notes.txt.bak
    try std.testing.expect(!d.entries.items[0].marked); // ".." is never marked
    try std.testing.expect(!d.entries.items[2].marked); // b.md
    try std.testing.expect(!d.entries.items[5].marked); // README
    try std.testing.expectEqual(@as(usize, 1), d.markFilesRegexp("\\.md$"));
    try std.testing.expect(d.entries.items[2].marked);
}
