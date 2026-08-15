const std = @import("std");

const Buffer = @This();

lines: std.ArrayList(std.ArrayList(u8)),
cursor_row: usize = 0,
cursor_col: usize = 0,
top_line: usize = 0,
/// Horizontal scroll offset in display columns, for truncated
/// (soft-wrap-off) lines: how far the view has scrolled right so the
/// cursor stays on screen at the end of a wide line. Soft-wrapped
/// lines never scroll horizontally, so this stays 0.
hscroll: usize = 0,
filename: ?[]const u8 = null,
/// How the file's line endings are stored, detected when it is loaded:
/// a CRLF (Windows / DOS) file keeps its \r\n line breaks on save, so
/// editing one never silently converts the whole file to LF and dirties
/// every line for git. New buffers default to LF.
eol: EolMode = .lf,
/// Name shown in the modeline for buffers with no real file (e.g. the
/// home screen), since there's nothing to visit.
display_name: ?[]const u8 = null,
dirty: bool = false,
mark: ?Pos = null,
    undo_stack: std.ArrayList(Snapshot) = .empty,
    /// The redo stack: the states each undo discards, restored by redo
    /// (C-g C-/ or M-/). A new edit clears it, like Emacs abandoning the
    /// redo branch once you type after undoing.
    redo_stack: std.ArrayList(Snapshot) = .empty,
/// Kind of the most recent edit, so a run of the same kind (typing, or
/// backspacing) coalesces into a single undo step instead of one per key.
undo_group: UndoKind = .none,
    /// Next position for C-l (recenter-top-bottom): 0 = middle, 1 = top,
    /// 2 = bottom.
    recenter_pos: u8 = 0,
    /// M-z toggles soft wrap: when on (the default), long lines wrap at
    /// the window edge and movement steps visual lines (Emacs
    /// visual-line-mode); when off they truncate and movement steps
    /// logical lines (Emacs toggle-truncate-lines).
    soft_wrap: bool = true,
    /// C-z e toggles whitespace markers (Emacs whitespace-mode): every
    /// space shows as a ·, every tab as a », and every line break as a $
    /// at the end of the line. Per-buffer, like soft wrap.
    show_whitespace: bool = false,
    /// C-z n toggles the line-number gutter (Emacs
    /// display-line-numbers-mode): each line's number, right-aligned in
    /// a column ahead of the text. Per-buffer, like soft wrap.
    show_line_numbers: bool = false,
    /// C-x l toggles scroll lock (Emacs scroll-lock-mode, the same
    /// binding): the cursor stays on its locked screen row while the
    /// text scrolls under it, up to the ends of the buffer.
    scroll_lock: bool = false,
    /// The screen row the cursor is locked to while scroll_lock is on.
    scroll_row: usize = 0,
    /// Generation counter bumped whenever the line array or any line's
    /// contents change, so the wrap-height cache (main.zig) knows to
    /// rebuild. Plain u64 — no vaxis dependency.
    lines_gen: u64 = 0,
    /// Cached prefix sum of per-line visual (wrapped) heights, so the
    /// scroll-lock viewport search is O(log n) instead of O(n log n) on
    /// large buffers. wrap_prefix[i] = total visual lines in lines[0..i];
    /// wrap_prefix.len == lines.len + 1 (wrap_prefix[0] = 0). Rebuilt by
    /// main.zig's wrapPrefixSum when lines_gen / width / soft_wrap / the
    /// gwidth method tag change. Plain types only — the method is stored
    /// as a u8 tag (@intFromEnum) so the data model stays free of any
    /// vaxis dependency, the same discipline the rest of Buffer follows.
    wrap_prefix: std.ArrayList(usize) = .empty,
    wrap_cache_width: usize = 0,
    wrap_cache_soft_wrap: bool = false,
    wrap_cache_method: u8 = 0,
    wrap_cache_gen: u64 = 0,

pub const Pos = struct { row: usize, col: usize };
pub const Region = struct { start: Pos, end: Pos };
const UndoKind = enum { none, typing, newline, backspace, delete_fwd, kill, yank, replace };

/// The file's line-ending style (see Buffer.eol).
pub const EolMode = enum { lf, crlf };

const Snapshot = struct {
    lines: std.ArrayList(std.ArrayList(u8)),
    cursor_row: usize,
    cursor_col: usize,
    mark: ?Pos,
    /// The dirty flag at the moment the snapshot was taken, so undoing
    /// back to the saved state clears [modified] (and undoing past an
    /// edit restores it).
    dirty: bool,

    fn deinit(self: *Snapshot, gpa: std.mem.Allocator) void {
        for (self.lines.items) |*line| line.deinit(gpa);
        self.lines.deinit(gpa);
    }
};

pub fn initEmpty() Buffer {
    return .{ .lines = .empty };
}

/// Build a buffer from static text, splitting on newlines. The text is
/// copied, so the caller may free its source afterwards. Used for the home
/// screen, which is a real buffer with no backing file.
pub fn fromText(gpa: std.mem.Allocator, text: []const u8) !Buffer {
    var buf = Buffer.initEmpty();
    errdefer buf.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line_slice| {
        var line: std.ArrayList(u8) = .empty;
        try line.appendSlice(gpa, line_slice);
        try buf.lines.append(gpa, line);
    }
    if (buf.lines.items.len == 0) try buf.lines.append(gpa, .empty);
    return buf;
}

pub fn deinit(self: *Buffer, gpa: std.mem.Allocator) void {
    for (self.lines.items) |*line| line.deinit(gpa);
    self.lines.deinit(gpa);
    for (self.undo_stack.items) |*snap| snap.deinit(gpa);
    self.undo_stack.deinit(gpa);
    for (self.redo_stack.items) |*snap| snap.deinit(gpa);
    self.redo_stack.deinit(gpa);
    self.wrap_prefix.deinit(gpa);
    if (self.filename) |f| gpa.free(f);
    if (self.display_name) |d| gpa.free(d);
}

/// Load a file from disk into a fresh buffer. If the file does not exist yet,
/// starts with a single empty line (like Emacs visiting a new file).
pub fn loadFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Buffer {
    var buf = Buffer.initEmpty();
    buf.filename = try gpa.dupe(u8, path);
    errdefer buf.deinit(gpa);

    const dir = std.Io.Dir.cwd();
    const contents = dir.readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => {
            try buf.lines.append(gpa, .empty);
            return buf;
        },
        else => return err,
    };
    defer gpa.free(contents);

    // A file whose raw text contains \r\n is CRLF: save it back with
    // \r\n line breaks (a lone \r elsewhere is left alone).
    buf.eol = if (std.mem.indexOf(u8, contents, "\r\n") != null) .crlf else .lf;

    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line_slice| {
        var line: std.ArrayList(u8) = .empty;
        // CRLF files keep a trailing \r on every line; drop it so the
        // line renders as text instead of a carriage-return control cell.
        const lf = if (line_slice.len > 0 and line_slice[line_slice.len - 1] == '\r')
            line_slice[0 .. line_slice.len - 1]
        else
            line_slice;
        try line.appendSlice(gpa, lf);
        try buf.lines.append(gpa, line);
    }
    if (buf.lines.items.len == 0) try buf.lines.append(gpa, .empty);
    return buf;
}

/// C-x g: discard the in-memory state and reload the file from disk,
/// exactly as if the buffer had just been visited. A file that has since
/// disappeared reverts to a single empty line, like visiting a new file.
pub fn reread(self: *Buffer, gpa: std.mem.Allocator, io: std.Io) !void {
    const path = self.filename orelse return error.NoFilename;
    const fresh = try loadFile(gpa, io, path);
    for (self.lines.items) |*line| line.deinit(gpa);
    self.lines.deinit(gpa);
    if (self.filename) |f| gpa.free(f);
    for (self.undo_stack.items) |*snap| snap.deinit(gpa);
    self.undo_stack.deinit(gpa);
    for (self.redo_stack.items) |*snap| snap.deinit(gpa);
    self.redo_stack.deinit(gpa);
    self.wrap_prefix.deinit(gpa);
    self.* = fresh;
}

pub fn save(self: *Buffer, gpa: std.mem.Allocator, io: std.Io) !void {
    var path = self.filename orelse return error.NoFilename;
    // A symlinked file saves through the link: the temp-file rename below
    // would otherwise replace the link itself with a plain file,
    // silently breaking it.
    var link_target: ?[]u8 = null;
    defer if (link_target) |t| gpa.free(t);
    {
        var buf: [4096]u8 = undefined;
        if (std.Io.Dir.cwd().readLink(io, path, &buf)) |n| {
            link_target = try gpa.dupe(u8, buf[0..n]);
            path = link_target.?;
        } else |_| {}
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    // A CRLF file is written with its original \r\n breaks, so saving
    // never silently rewrites a Windows / DOS file in LF (see eol).
    const br = if (self.eol == .crlf) "\r\n" else "\n";
    for (self.lines.items, 0..) |line, i| {
        try out.appendSlice(gpa, line.items);
        if (i != self.lines.items.len - 1) try out.appendSlice(gpa, br);
    }
    // Save atomically: the text goes to a temp file beside the target —
    // the same filesystem, so the final rename replaces it atomically on
    // both POSIX and Windows — and the temp is then renamed over the
    // original. A crash or power cut mid-write can no longer truncate the
    // real file: it is always either the old content or the new, never a
    // torn write. The temp inherits the original's permissions (a 0755
    // script must not come back 0644) and is synced, so a power cut after
    // the rename cannot leave the target pointing at unsynced data.
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.james-tmp", .{path});
    defer gpa.free(tmp_path);
    const f = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true });
    errdefer {
        f.close(io);
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    }
    try f.writeStreamingAll(io, out.items);
    if (std.Io.Dir.cwd().statFile(io, path, .{})) |st| {
        f.setPermissions(io, st.permissions) catch {};
    } else |_| {}
    f.sync(io) catch {};
    // The handle must be closed before the rename: on Windows an open
    // handle would block replacing the target.
    f.close(io);
    std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io) catch |err| {
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        return err;
    };
    self.dirty = false;
}

fn cloneLines(self: Buffer, gpa: std.mem.Allocator) !std.ArrayList(std.ArrayList(u8)) {
    var out: std.ArrayList(std.ArrayList(u8)) = .empty;
    errdefer {
        for (out.items) |*l| l.deinit(gpa);
        out.deinit(gpa);
    }
    for (self.lines.items) |line| {
        var copy: std.ArrayList(u8) = .empty;
        errdefer copy.deinit(gpa);
        try copy.appendSlice(gpa, line.items);
        try out.append(gpa, copy);
    }
    return out;
}

/// Push the current state onto the undo stack, unless we're continuing a run
/// of the same kind of edit (so a burst of typing undoes as one step).
fn recordUndo(self: *Buffer, gpa: std.mem.Allocator, kind: UndoKind) !void {
    if (kind == self.undo_group and self.undo_stack.items.len > 0) return;
    // A new edit abandons the redo branch, like Emacs.
    for (self.redo_stack.items) |*snap| snap.deinit(gpa);
    self.redo_stack.clearRetainingCapacity();
    try self.undo_stack.append(gpa, .{
        .lines = try self.cloneLines(gpa),
        .cursor_row = self.cursor_row,
        .cursor_col = self.cursor_col,
        .mark = self.mark,
        .dirty = self.dirty,
    });
    self.undo_group = kind;
}

/// Bump the generation counter — call on every lines mutation so the
/// wrap-height cache (main.zig) rebuilds.
fn bumpGen(self: *Buffer) void {
    self.lines_gen +%= 1;
}

/// Clone the current state onto `stack` — the counterpart of an undo or
/// redo step. Best effort: if the clone or the append fails, the step
/// simply has no counterpart (undo still works; that step just isn't
/// redoable — or vice versa).
fn pushState(self: *Buffer, gpa: std.mem.Allocator, stack: *std.ArrayList(Snapshot)) void {
    const lines = self.cloneLines(gpa) catch return;
    errdefer {
        for (lines.items) |*l| l.deinit(gpa);
        lines.deinit(gpa);
    }
    stack.append(gpa, .{
        .lines = lines,
        .cursor_row = self.cursor_row,
        .cursor_col = self.cursor_col,
        .mark = self.mark,
        .dirty = self.dirty,
    }) catch return;
}

/// C-x u / C-/: restore the state from before the last undo group. The
/// state being undone is pushed onto the redo stack, so redo (C-g C-/
/// or M-/) brings it back.
pub fn undo(self: *Buffer, gpa: std.mem.Allocator) void {
    const snap = self.undo_stack.pop() orelse return;
    // The state being undone becomes the redo's target.
    self.pushState(gpa, &self.redo_stack);
    for (self.lines.items) |*line| line.deinit(gpa);
    self.lines.deinit(gpa);
    self.lines = snap.lines;
    self.bumpGen();
    self.cursor_row = snap.cursor_row;
    self.cursor_col = snap.cursor_col;
    self.mark = snap.mark;
    self.undo_group = .none;
    self.dirty = snap.dirty;
}

/// M-/ / C-g C-/: redo — restore the state the last undo discarded, and
/// push the current state back onto the undo stack, so the redo is
/// itself undoable.
pub fn redo(self: *Buffer, gpa: std.mem.Allocator) void {
    const snap = self.redo_stack.pop() orelse return;
    // The state being redone away becomes undoable again.
    self.pushState(gpa, &self.undo_stack);
    for (self.lines.items) |*line| line.deinit(gpa);
    self.lines.deinit(gpa);
    self.lines = snap.lines;
    self.bumpGen();
    self.cursor_row = snap.cursor_row;
    self.cursor_col = snap.cursor_col;
    self.mark = snap.mark;
    self.undo_group = .none;
    self.dirty = snap.dirty;
}

fn insertSliceRaw(self: *Buffer, gpa: std.mem.Allocator, text: []const u8) !void {
    self.bumpGen();
    try self.lines.items[self.cursor_row].insertSlice(gpa, self.cursor_col, text);
    self.cursor_col += text.len;
    self.dirty = true;
}

/// Insert `text` at point, splitting on line breaks so a multi-line
/// paste (clipboard reads, bracketed paste) keeps its line structure
/// instead of embedding the break bytes inside one logical line — a line
/// with embedded \r\n renders its \r as a control cell, and the terminal
/// treats the carriage return as "back to column 0", gluing the text
/// together. CRLF and bare CR line endings normalize to LF, like Emacs's
/// yank. A trailing break doesn't leave an empty tail line.
fn insertTextRaw(self: *Buffer, gpa: std.mem.Allocator, text: []const u8) !void {
    var seg_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '\n' or c == '\r') {
            try self.insertSliceRaw(gpa, text[seg_start..i]);
            try self.insertNewlineRaw(gpa);
            i += 1;
            if (c == '\r' and i < text.len and text[i] == '\n') i += 1;
            seg_start = i;
        } else {
            i += 1;
        }
    }
    if (seg_start < text.len) try self.insertSliceRaw(gpa, text[seg_start..]);
}

pub fn insertSlice(self: *Buffer, gpa: std.mem.Allocator, text: []const u8) !void {
    try self.recordUndo(gpa, .typing);
    try self.insertTextRaw(gpa, text);
}

fn insertNewlineRaw(self: *Buffer, gpa: std.mem.Allocator) !void {
    self.bumpGen();
    const current = &self.lines.items[self.cursor_row];
    const rest = try gpa.dupe(u8, current.items[self.cursor_col..]);
    defer gpa.free(rest);
    current.shrinkRetainingCapacity(self.cursor_col);

    var new_line: std.ArrayList(u8) = .empty;
    try new_line.appendSlice(gpa, rest);
    try self.lines.insert(gpa, self.cursor_row + 1, new_line);

    self.cursor_row += 1;
    self.cursor_col = 0;
    self.dirty = true;
}

pub fn insertNewline(self: *Buffer, gpa: std.mem.Allocator) !void {
    try self.recordUndo(gpa, .newline);
    try self.insertNewlineRaw(gpa);
}

pub fn deleteBackward(self: *Buffer, gpa: std.mem.Allocator) !void {
    if (self.cursor_col == 0 and self.cursor_row == 0) return;
    self.bumpGen();
    try self.recordUndo(gpa, .backspace);
    if (self.cursor_col > 0) {
        _ = self.lines.items[self.cursor_row].orderedRemove(self.cursor_col - 1);
        self.cursor_col -= 1;
        self.dirty = true;
    } else if (self.cursor_row > 0) {
        const cur = self.lines.items[self.cursor_row];
        var prev = &self.lines.items[self.cursor_row - 1];
        const prev_len = prev.items.len;
        prev.appendSlice(gpa, cur.items) catch return;
        var removed = self.lines.orderedRemove(self.cursor_row);
        removed.deinit(gpa);
        self.cursor_row -= 1;
        self.cursor_col = prev_len;
        self.dirty = true;
    }
}

pub fn deleteForward(self: *Buffer, gpa: std.mem.Allocator) !void {
    const at_end_of_buffer = self.cursor_row + 1 >= self.lines.items.len and
        self.cursor_col >= self.lines.items[self.cursor_row].items.len;
    if (at_end_of_buffer) return;
    self.bumpGen();
    try self.recordUndo(gpa, .delete_fwd);
    const line = &self.lines.items[self.cursor_row];
    if (self.cursor_col < line.items.len) {
        _ = line.orderedRemove(self.cursor_col);
        self.dirty = true;
    } else if (self.cursor_row + 1 < self.lines.items.len) {
        const next = self.lines.items[self.cursor_row + 1];
        line.appendSlice(gpa, next.items) catch return;
        var removed = self.lines.orderedRemove(self.cursor_row + 1);
        removed.deinit(gpa);
        self.dirty = true;
    }
}

pub fn setMark(self: *Buffer) void {
    self.mark = .{ .row = self.cursor_row, .col = self.cursor_col };
}

/// M-h: mark the whole paragraph around the cursor (Emacs mark-paragraph)
/// — the run of non-blank lines bounded by blank lines. The mark lands at
/// the paragraph's start and the cursor at its end, so the region is the
/// paragraph (the same shape as C-x h for the whole buffer). On a blank
/// line the following paragraph is marked, falling back to the previous.
pub fn markParagraph(self: *Buffer) void {
    const n = self.lines.items.len;
    if (n == 0) return;
    const is_blank = struct {
        fn f(line: []const u8) bool {
            for (line) |c| if (!std.ascii.isWhitespace(c)) return false;
            return true;
        }
    }.f;
    var row = self.cursor_row;
    if (is_blank(self.lines.items[row].items)) {
        row += 1;
        while (row < n and is_blank(self.lines.items[row].items)) row += 1;
        if (row >= n) {
            row = self.cursor_row;
            while (row > 0 and is_blank(self.lines.items[row].items)) row -= 1;
        }
    }
    var start = row;
    while (start > 0 and !is_blank(self.lines.items[start - 1].items)) start -= 1;
    var end = row;
    while (end + 1 < n and !is_blank(self.lines.items[end + 1].items)) end += 1;
    self.mark = .{ .row = start, .col = 0 };
    self.cursor_row = end;
    self.cursor_col = self.lines.items[end].items.len;
}

/// Start a new undo group, so the next edit records a fresh undo step
/// instead of joining the previous run (recordUndo coalesces same-kind
/// edits). Query-replace calls this once per session, so the whole
/// replace — however many y's — undoes as one step, like Emacs.
pub fn undoBoundary(self: *Buffer) void {
    self.undo_group = .none;
}

/// M-% query-replace, one match: replace the `len` bytes starting at `at`
/// (a match of the query, which never crosses a line boundary) with
/// `with`, which may span lines. Returns where the replacement ends, so
/// the next search starts past the fresh text — replacing "a" with "aa"
/// mustn't re-match what was just inserted. The cursor lands there too.
/// Every replacement of a session is one undo step (see undoBoundary).
pub fn replaceAt(self: *Buffer, gpa: std.mem.Allocator, at: Pos, len: usize, with: []const u8) !Pos {
    try self.recordUndo(gpa, .replace);
    self.bumpGen();
    self.cursor_row = at.row;
    self.cursor_col = at.col;
    const line = &self.lines.items[at.row];
    const del = @min(len, line.items.len -| at.col);
    if (del > 0) {
        line.replaceRange(gpa, at.col, del, &.{}) catch |e| return e;
        self.dirty = true;
    }
    try self.insertTextRaw(gpa, with);
    return .{ .row = self.cursor_row, .col = self.cursor_col };
}

/// Region bounds in document order (start <= end). Null if no mark is set.
/// Note: mark is a plain (row, col) snapshot, not a self-adjusting marker, so
/// it can go stale if you edit the buffer between setting it and using it.
pub fn orderedRegion(self: Buffer) ?Region {
    const m = self.mark orelse return null;
    const p = Pos{ .row = self.cursor_row, .col = self.cursor_col };
    if (m.row < p.row or (m.row == p.row and m.col <= p.col)) return .{ .start = m, .end = p };
    return .{ .start = p, .end = m };
}

/// Copy of the text between start and end (lines joined with '\n'). Caller owns the result.
fn extractRange(self: *Buffer, gpa: std.mem.Allocator, start: Pos, end: Pos) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (start.row == end.row) {
        try out.appendSlice(gpa, self.lines.items[start.row].items[start.col..end.col]);
        return out.toOwnedSlice(gpa);
    }
    try out.appendSlice(gpa, self.lines.items[start.row].items[start.col..]);
    var r = start.row + 1;
    while (r < end.row) : (r += 1) {
        try out.append(gpa, '\n');
        try out.appendSlice(gpa, self.lines.items[r].items);
    }
    try out.append(gpa, '\n');
    try out.appendSlice(gpa, self.lines.items[end.row].items[0..end.col]);
    return out.toOwnedSlice(gpa);
}

/// Remove the text between start and end, merging what's left into one line.
fn deleteRange(self: *Buffer, gpa: std.mem.Allocator, start: Pos, end: Pos) !void {
    self.bumpGen();
    if (start.row == end.row) {
        try self.lines.items[start.row].replaceRange(gpa, start.col, end.col - start.col, &.{});
        return;
    }
    const tail = try gpa.dupe(u8, self.lines.items[end.row].items[end.col..]);
    defer gpa.free(tail);
    self.lines.items[start.row].shrinkRetainingCapacity(start.col);
    try self.lines.items[start.row].appendSlice(gpa, tail);

    var r = end.row;
    while (r > start.row) : (r -= 1) {
        var removed = self.lines.orderedRemove(r);
        removed.deinit(gpa);
    }
}

fn rememberKill(gpa: std.mem.Allocator, kill_ring: *KillRing, text: []const u8, append: bool) !void {
    try kill_ring.remember(gpa, text, append);
}

/// A real Emacs-style kill ring: a list of heap-allocated kill texts with
/// a head index pointing at the most recent. Consecutive kills append to
/// the head entry, joined by a newline — killing "foo" then "bar" yanks as
/// "foo\nbar", not the "foobar" a flat buffer would produce. The ring is
/// bounded (oldest entries fall off), and M-y cycles back through it.
pub const KillRing = struct {
    entries: std.ArrayList([]u8) = .empty,
    /// Index of the most recent kill.
    head: usize = 0,

    const max_kills = 60;

    pub fn deinit(self: *KillRing, gpa: std.mem.Allocator) void {
        for (self.entries.items) |e| gpa.free(e);
        self.entries.deinit(gpa);
    }

    pub fn count(self: *const KillRing) usize {
        return self.entries.items.len;
    }

    /// The most recent kill, or null when the ring is empty.
    pub fn current(self: *const KillRing) ?[]const u8 {
        if (self.entries.items.len == 0) return null;
        return self.entries.items[self.head];
    }

    /// The entry at ring index `idx`.
    pub fn at(self: *const KillRing, idx: usize) []const u8 {
        return self.entries.items[idx];
    }

    /// The ring index `steps` before `from` (1 = the previous kill),
    /// wrapping around the ring.
    pub fn beforeIdx(self: *const KillRing, from: usize, steps: usize) usize {
        const n = self.entries.items.len;
        return (from + n - (steps % n)) % n;
    }

    /// Remember a kill: start a fresh head entry, or append `text` to the
    /// head for a consecutive kill (newline-joined when the head doesn't
    /// already end in one).
    pub fn remember(self: *KillRing, gpa: std.mem.Allocator, text: []const u8, append: bool) !void {
        if (append and self.entries.items.len > 0) {
            const head_entry = &self.entries.items[self.head];
            // Join with a newline only when neither side has one: killing
            // "abc" then "def" joins as "abc\ndef", while killing "aaa"
            // then the line's own "\n" stays "aaa\n" — no doubled newline.
            const head_ends_nl = head_entry.*.len > 0 and head_entry.*[head_entry.*.len - 1] == '\n';
            const text_starts_nl = text.len > 0 and text[0] == '\n';
            const needs_sep = !head_ends_nl and !text_starts_nl;
            const joined = try std.mem.concat(gpa, u8, &.{
                head_entry.*,
                if (needs_sep) "\n" else "",
                text,
            });
            gpa.free(head_entry.*);
            head_entry.* = joined;
        } else {
            const copy = try gpa.dupe(u8, text);
            if (self.entries.items.len < max_kills) {
                try self.entries.append(gpa, copy);
                self.head = self.entries.items.len - 1;
            } else {
                // Ring full: overwrite the oldest entry.
                self.head = (self.head + 1) % self.entries.items.len;
                gpa.free(self.entries.items[self.head]);
                self.entries.items[self.head] = copy;
            }
        }
    }
};

/// C-k: kill to end of line, or kill the newline itself when already at end of line.
pub fn killLine(self: *Buffer, gpa: std.mem.Allocator, kill_ring: *KillRing, append: bool) !void {
    const row = self.cursor_row;
    const col = self.cursor_col;
    const nothing_to_kill = col >= self.lines.items[row].items.len and row + 1 >= self.lines.items.len;
    if (nothing_to_kill) return;
    self.bumpGen();
    try self.recordUndo(gpa, .kill);

    if (col < self.lines.items[row].items.len) {
        const owned = try gpa.dupe(u8, self.lines.items[row].items[col..]);
        defer gpa.free(owned);
        self.lines.items[row].shrinkRetainingCapacity(col);
        try rememberKill(gpa, kill_ring, owned, append);
    } else {
        try self.lines.items[row].appendSlice(gpa, self.lines.items[row + 1].items);
        var removed = self.lines.orderedRemove(row + 1);
        removed.deinit(gpa);
        try rememberKill(gpa, kill_ring, "\n", append);
    }
    self.dirty = true;
}

/// C-w: kill the region between point and mark.
pub fn killRegion(self: *Buffer, gpa: std.mem.Allocator, kill_ring: *KillRing, append: bool) !void {
    const region = self.orderedRegion() orelse return;
    try self.recordUndo(gpa, .kill);
    const text = try self.extractRange(gpa, region.start, region.end);
    defer gpa.free(text);
    try self.deleteRange(gpa, region.start, region.end);
    self.cursor_row = region.start.row;
    self.cursor_col = region.start.col;
    self.mark = null;
    try rememberKill(gpa, kill_ring, text, append);
    self.dirty = true;
}

/// M-d: kill one word forward (Emacs kill-word). Kills from point to the
/// end of the word run forward — moveWordForward skips any leading non-word
/// chars then the word, so this kills "foo" from "foo| bar" and " bar"
/// from "foo |bar" (the leading space goes with the word, like Emacs). The
/// killed text heads the kill ring (so C-y gets it back); the mark is left
/// untouched (a stale mark after a kill is the same caveat as C-x C-k). At
/// end of buffer there's nothing to kill, so it's a no-op.
pub fn killWord(self: *Buffer, gpa: std.mem.Allocator, kill_ring: *KillRing, append: bool) !void {
    const start = Pos{ .row = self.cursor_row, .col = self.cursor_col };
    self.moveWordForward();
    const end = Pos{ .row = self.cursor_row, .col = self.cursor_col };
    if (start.row == end.row and start.col == end.col) return; // nothing to kill
    try self.recordUndo(gpa, .kill);
    const text = try self.extractRange(gpa, start, end);
    defer gpa.free(text);
    try self.deleteRange(gpa, start, end);
    self.cursor_row = start.row;
    self.cursor_col = start.col;
    try rememberKill(gpa, kill_ring, text, append);
    self.dirty = true;
}

/// M-Backspace: kill one word backward (Emacs backward-kill-word). Kills
/// from point back to the start of the word run — moveWordBackward skips
/// any trailing non-word chars then the word, so this kills "foo" from
/// "foo |bar" (the trailing space goes with the word, like Emacs) and
/// "bar" from "foo bar|". The killed text heads the kill ring (so C-y gets
/// it back); the mark is left untouched (same caveat as M-d). At beginning
/// of buffer there's nothing to kill, so it's a no-op.
pub fn killWordBackward(self: *Buffer, gpa: std.mem.Allocator, kill_ring: *KillRing, append: bool) !void {
    const end = Pos{ .row = self.cursor_row, .col = self.cursor_col };
    self.moveWordBackward();
    const start = Pos{ .row = self.cursor_row, .col = self.cursor_col };
    if (start.row == end.row and start.col == end.col) return; // nothing to kill
    try self.recordUndo(gpa, .kill);
    const text = try self.extractRange(gpa, start, end);
    defer gpa.free(text);
    try self.deleteRange(gpa, start, end);
    self.cursor_row = start.row;
    self.cursor_col = start.col;
    try rememberKill(gpa, kill_ring, text, append);
    self.dirty = true;
}

/// M-w: copy the region between point and mark without deleting it.
pub fn copyRegion(self: *Buffer, gpa: std.mem.Allocator, kill_ring: *KillRing, append: bool) !void {
    const region = self.orderedRegion() orelse return;
    const text = try self.extractRange(gpa, region.start, region.end);
    defer gpa.free(text);
    try rememberKill(gpa, kill_ring, text, append);
}

/// M-w with no mark: copy the current line (the whole logical line under
/// point) to the kill ring, without deleting it. Like copyRegion, this
/// doesn't touch the buffer or the mark. The line's trailing newline is
/// included — the last line of the buffer has none — so pasting the line
/// restores the line break, like Emacs's line copy.
pub fn copyLine(self: *Buffer, gpa: std.mem.Allocator, kill_ring: *KillRing, append: bool) !void {
    const line = self.lines.items[self.cursor_row].items;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, line);
    // The line break belongs to the line: a paste of a mid-buffer line
    // reproduces the break, instead of gluing the line to whatever
    // follows it at the paste point.
    if (self.cursor_row + 1 < self.lines.items.len) try out.append(gpa, '\n');
    try rememberKill(gpa, kill_ring, out.items, append);
}

/// C-c b: copy the whole buffer to the kill ring, leaving point where it
/// is (and no mark set).
pub fn copyWholeBuffer(self: *Buffer, gpa: std.mem.Allocator, kill_ring: *KillRing) !void {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (self.lines.items, 0..) |line, i| {
        try out.appendSlice(gpa, line.items);
        if (i != self.lines.items.len - 1) try out.append(gpa, '\n');
    }
    try rememberKill(gpa, kill_ring, out.items, false);
}

fn yankRaw(self: *Buffer, gpa: std.mem.Allocator, text: []const u8) !void {
    // The kill ring holds raw text (a Windows clipboard read keeps its
    // CRLF), so yank through the same split/normalize path as a paste.
    try self.insertTextRaw(gpa, text);
}

/// C-y: insert kill text at point (the head of the kill ring).
pub fn yank(self: *Buffer, gpa: std.mem.Allocator, text: []const u8) !void {
    try self.recordUndo(gpa, .yank);
    try self.yankRaw(gpa, text);
}

/// M-y (yank-pop): replace the text yanked between `start` and `end` with
/// `text`, all inside the original yank's undo step. The cursor ends at
/// the end of the replacement, ready for the next pop.
pub fn yankPop(self: *Buffer, gpa: std.mem.Allocator, text: []const u8, start: Pos, end: Pos) !void {
    try self.deleteRange(gpa, start, end);
    self.cursor_row = start.row;
    self.cursor_col = start.col;
    try self.yankRaw(gpa, text);
}

/// C-;: comment (or uncomment) the current line by prefixing it with the
/// comment marker guessed from the file's extension. Point doesn't move.
pub fn toggleComment(self: *Buffer, gpa: std.mem.Allocator) !void {
    try self.recordUndo(gpa, .typing);
    self.bumpGen();
    const row = self.cursor_row;
    const line = &self.lines.items[row];
    const prefix = self.commentPrefix();
    if (line.items.len >= prefix.len and std.mem.eql(u8, line.items[0..prefix.len], prefix)) {
        line.replaceRange(gpa, 0, prefix.len, &.{}) catch {};
        self.dirty = true;
    } else {
        line.insertSlice(gpa, 0, prefix) catch {};
        self.dirty = true;
    }
}

/// The comment marker for the buffer's file, guessed from the extension;
/// defaults to =// = since most source files use it.
fn commentPrefix(self: *const Buffer) []const u8 {
    const name = self.filename orelse return "// ";
    const hash: []const []const u8 = &.{ ".py", ".sh", ".rb", ".pl", ".yml", ".yaml", ".toml", ".ini", ".cfg", ".org" };
    for (hash) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return "# ";
    }
    return "// ";
}

fn clampCol(self: *Buffer) void {
    const len = self.lines.items[self.cursor_row].items.len;
    if (self.cursor_col > len) self.cursor_col = len;
}

pub fn moveLeft(self: *Buffer) void {
    if (self.cursor_col > 0) {
        self.cursor_col -= 1;
    } else if (self.cursor_row > 0) {
        self.cursor_row -= 1;
        self.cursor_col = self.lines.items[self.cursor_row].items.len;
    }
}

pub fn moveRight(self: *Buffer) void {
    const len = self.lines.items[self.cursor_row].items.len;
    if (self.cursor_col < len) {
        self.cursor_col += 1;
    } else if (self.cursor_row + 1 < self.lines.items.len) {
        self.cursor_row += 1;
        self.cursor_col = 0;
    }
}

/// A word char for M-f / M-b (Emacs word syntax): a letter, digit, or
/// underscore. Everything else — whitespace, punctuation — is non-word,
/// and a run of non-word chars is skipped separately from a run of word
/// chars (so M-f from "foo.bar" lands on ".", then past "bar").
fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// M-f: move forward one word (Emacs forward-word). A "word" is a maximal
/// run of word chars (letters, digits, underscore); everything else
/// (whitespace, punctuation) is non-word. forward-word skips any leading
/// non-word chars, then the word, landing at the end of the word run. A
/// line break counts as non-word (like Emacs treating a newline as
/// whitespace), so the non-word skip crosses line boundaries — but a word
/// itself never spans a line break, so the word-skip stops at end of line.
pub fn moveWordForward(self: *Buffer) void {
    // Step 1: skip non-word chars forward, crossing line breaks.
    while (true) {
        const line = self.lines.items[self.cursor_row];
        if (self.cursor_col < line.items.len) {
            if (isWordChar(line.items[self.cursor_col])) break;
            self.cursor_col += 1;
        } else if (self.cursor_row + 1 < self.lines.items.len) {
            self.cursor_row += 1;
            self.cursor_col = 0;
        } else break;
    }
    // Step 2: skip word chars forward, stopping at a line break.
    while (true) {
        const line = self.lines.items[self.cursor_row];
        if (self.cursor_col < line.items.len) {
            if (!isWordChar(line.items[self.cursor_col])) break;
            self.cursor_col += 1;
        } else break;
    }
}

/// M-b: move backward one word (Emacs backward-word). Skips non-word chars
/// backward (crossing line breaks), then the word, landing at the start of
/// the word run. The word-skip stops at a line break, so a word never
/// spans one.
pub fn moveWordBackward(self: *Buffer) void {
    // Step 1: skip non-word chars backward, crossing line breaks.
    while (self.cursor_row > 0 or self.cursor_col > 0) {
        if (self.cursor_col > 0) {
            const line = self.lines.items[self.cursor_row];
            if (isWordChar(line.items[self.cursor_col - 1])) break;
            self.cursor_col -= 1;
        } else {
            self.cursor_row -= 1;
            self.cursor_col = self.lines.items[self.cursor_row].items.len;
        }
    }
    // Step 2: skip word chars backward, stopping at a line break.
    while (self.cursor_row > 0 or self.cursor_col > 0) {
        if (self.cursor_col > 0) {
            const line = self.lines.items[self.cursor_row];
            if (!isWordChar(line.items[self.cursor_col - 1])) break;
            self.cursor_col -= 1;
        } else break;
    }
}

pub fn moveUp(self: *Buffer) void {
    if (self.cursor_row > 0) {
        self.cursor_row -= 1;
        self.clampCol();
    }
}

pub fn moveDown(self: *Buffer) void {
    if (self.cursor_row + 1 < self.lines.items.len) {
        self.cursor_row += 1;
        self.clampCol();
    }
}

pub fn moveLineStart(self: *Buffer) void {
    self.cursor_col = 0;
}

pub fn moveLineEnd(self: *Buffer) void {
    self.cursor_col = self.lines.items[self.cursor_row].items.len;
}

/// M-<: jump to the very start of the buffer.
pub fn moveBufStart(self: *Buffer) void {
    self.cursor_row = 0;
    self.cursor_col = 0;
}

/// M->: jump to the very end of the buffer.
pub fn moveBufEnd(self: *Buffer) void {
    if (self.lines.items.len == 0) return;
    self.cursor_row = self.lines.items.len - 1;
    self.cursor_col = self.lines.items[self.cursor_row].items.len;
}

/// M-j / M-k: move the cursor `delta` lines (positive down, negative up),
/// clamped to the buffer.
pub fn moveLines(self: *Buffer, delta: isize) void {
    if (self.lines.items.len == 0) return;
    const target: isize = @as(isize, @intCast(self.cursor_row)) + delta;
    const last: isize = @intCast(self.lines.items.len - 1);
    self.cursor_row = @intCast(std.math.clamp(target, 0, last));
    self.clampCol();
}

/// Keep the cursor row within [top_line, top_line + height) by adjusting top_line.
pub fn scrollToCursor(self: *Buffer, height: usize) void {
    if (height == 0) return;
    if (self.cursor_row < self.top_line) {
        self.top_line = self.cursor_row;
    } else if (self.cursor_row >= self.top_line + height) {
        self.top_line = self.cursor_row - height + 1;
    }
}

/// C-l: recenter the window on the cursor line, cycling through the
/// middle, top, and bottom of the window like Emacs's
/// recenter-top-bottom. `cycling` is true when the previous key was also
/// C-l — the position then advances (middle → top → bottom → middle);
/// otherwise the line recenters to the middle. The last position is
/// remembered per buffer.
pub fn recenterTopBottom(self: *Buffer, height: usize, cycling: bool) void {
    if (height == 0) return;
    const pos: u8 = if (cycling) (self.recenter_pos + 1) % 3 else 0;
    self.recenter_pos = pos;
    switch (pos) {
        0 => self.top_line = self.cursor_row -| (height / 2),   // middle
        1 => self.top_line = self.cursor_row,                   // top
        else => self.top_line = self.cursor_row -| (height - 1), // bottom
    }
    // Keep the last lines of a long buffer on screen.
    const max_top = self.lines.items.len -| height;
    self.top_line = @min(self.top_line, max_top);
}

pub const SearchDirection = enum { forward, backward };

/// Case-insensitive backward search, mirroring std.ascii.findIgnoreCasePos
/// (std only ships the forward variant).
fn lastIndexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len or needle.len == 0) return null;
    var i = haystack.len - needle.len;
    while (true) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
        if (i == 0) break;
        i -= 1;
    }
    return null;
}

/// How many times `query` occurs in the buffer — case-insensitive (ASCII),
/// counting one match per line without crossing a line boundary, exactly
/// like findNext. The total for isearch's lazy count (Emacs
/// isearch-lazy-count).
pub fn matchCount(self: Buffer, query: []const u8) usize {
    var n: usize = 0;
    if (query.len == 0) return 0;
    for (self.lines.items) |line| {
        var col: usize = 0;
        while (std.ascii.findIgnoreCasePos(line.items, col, query)) |c| {
            n += 1;
            col = c + query.len;
        }
    }
    return n;
}

/// The 1-based position of `at` among the buffer's matches of `query`, in
/// buffer order (row, then column) — the "current" half of isearch's lazy
/// count. `at` must be a match start, as findNext returns.
pub fn matchIndex(self: Buffer, query: []const u8, at: Pos) usize {
    var n: usize = 0;
    if (query.len == 0) return 0;
    for (self.lines.items, 0..) |line, row| {
        if (row > at.row) break;
        var col: usize = 0;
        while (std.ascii.findIgnoreCasePos(line.items, col, query)) |c| {
            if (row == at.row and c >= at.col) return n + 1;
            n += 1;
            col = c + query.len;
        }
    }
    return n;
}

/// Find the next occurrence of `query` from `from`, wrapping around the
/// buffer if needed. Search never crosses a line boundary within a single
/// match. Returns the position of the start of the match.
///
/// Matching is always case-insensitive (ASCII), like the Jasspa "exact"
/// mode being off.
pub fn findNext(self: Buffer, query: []const u8, from: Pos, dir: SearchDirection) ?Pos {
    const n = self.lines.items.len;
    if (query.len == 0 or n == 0) return null;

    switch (dir) {
        .forward => {
            var row = from.row;
            var col_start: usize = from.col;
            var i: usize = 0;
            while (i <= n) : (i += 1) {
                const line = self.lines.items[row].items;
                if (col_start <= line.len) {
                    if (std.ascii.findIgnoreCasePos(line, col_start, query)) |c| {
                        return .{ .row = row, .col = c };
                    }
                }
                row = if (row + 1 == n) 0 else row + 1;
                col_start = 0;
            }
            return null;
        },
        .backward => {
            var row = from.row;
            var end_col: ?usize = from.col;
            var i: usize = 0;
            while (i <= n) : (i += 1) {
                const line = self.lines.items[row].items;
                const limit = @min(end_col orelse line.len, line.len);
                if (lastIndexOfIgnoreCase(line[0..limit], query)) |c| {
                    return .{ .row = row, .col = c };
                }
                row = if (row == 0) n - 1 else row - 1;
                end_col = null;
            }
            return null;
        },
    }
}

/// The next occurrence of `query` at or after `from`, searched to the end
/// of the buffer without wrapping — the query-replace walk's search: it
/// stops when the buffer has no more matches ahead, rather than asking
/// again about the ones it already covered the way isearch's wrap-around
/// does. Same matching as findNext.
pub fn findNextEnd(self: Buffer, query: []const u8, from: Pos) ?Pos {
    var row = from.row;
    var col_start: usize = from.col;
    while (row < self.lines.items.len) : (row += 1) {
        const line = self.lines.items[row].items;
        if (col_start <= line.len) {
            if (std.ascii.findIgnoreCasePos(line, col_start, query)) |c| {
                return .{ .row = row, .col = c };
            }
        }
        col_start = 0;
    }
    return null;
}

/// The previous occurrence of `query` at or before `from`, searched to the
/// start of the buffer without wrapping — the ^ (back) of the query-replace
/// walk, and the backward twin of findNextEnd. Same matching as findNext.
pub fn findPrevEnd(self: Buffer, query: []const u8, from: Pos) ?Pos {
    var row = from.row;
    var end_col: ?usize = from.col;
    while (true) {
        const line = self.lines.items[row].items;
        const limit = @min(end_col orelse line.len, line.len);
        if (lastIndexOfIgnoreCase(line[0..limit], query)) |c| {
            return .{ .row = row, .col = c };
        }
        if (row == 0) return null;
        row -= 1;
        end_col = null;
    }
}
