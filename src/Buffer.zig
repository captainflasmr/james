const std = @import("std");

const Buffer = @This();

lines: std.ArrayList(std.ArrayList(u8)),
cursor_row: usize = 0,
cursor_col: usize = 0,
top_line: usize = 0,
filename: ?[]const u8 = null,
dirty: bool = false,
mark: ?Pos = null,
undo_stack: std.ArrayList(Snapshot) = .empty,
/// Kind of the most recent edit, so a run of the same kind (typing, or
/// backspacing) coalesces into a single undo step instead of one per key.
undo_group: UndoKind = .none,

pub const Pos = struct { row: usize, col: usize };
pub const Region = struct { start: Pos, end: Pos };
const UndoKind = enum { none, typing, newline, backspace, delete_fwd, kill, yank };

const Snapshot = struct {
    lines: std.ArrayList(std.ArrayList(u8)),
    cursor_row: usize,
    cursor_col: usize,
    mark: ?Pos,

    fn deinit(self: *Snapshot, gpa: std.mem.Allocator) void {
        for (self.lines.items) |*line| line.deinit(gpa);
        self.lines.deinit(gpa);
    }
};

pub fn initEmpty() Buffer {
    return .{ .lines = .empty };
}

pub fn deinit(self: *Buffer, gpa: std.mem.Allocator) void {
    for (self.lines.items) |*line| line.deinit(gpa);
    self.lines.deinit(gpa);
    for (self.undo_stack.items) |*snap| snap.deinit(gpa);
    self.undo_stack.deinit(gpa);
    if (self.filename) |f| gpa.free(f);
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

    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line_slice| {
        var line: std.ArrayList(u8) = .empty;
        try line.appendSlice(gpa, line_slice);
        try buf.lines.append(gpa, line);
    }
    if (buf.lines.items.len == 0) try buf.lines.append(gpa, .empty);
    return buf;
}

pub fn save(self: *Buffer, gpa: std.mem.Allocator, io: std.Io) !void {
    const path = self.filename orelse return error.NoFilename;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (self.lines.items, 0..) |line, i| {
        try out.appendSlice(gpa, line.items);
        if (i != self.lines.items.len - 1) try out.append(gpa, '\n');
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
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
    try self.undo_stack.append(gpa, .{
        .lines = try self.cloneLines(gpa),
        .cursor_row = self.cursor_row,
        .cursor_col = self.cursor_col,
        .mark = self.mark,
    });
    self.undo_group = kind;
}

/// C-x u: restore the state from before the last undo group. There is no
/// redo yet — undoing is a one-way trip back through history.
pub fn undo(self: *Buffer, gpa: std.mem.Allocator) void {
    const snap = self.undo_stack.pop() orelse return;
    for (self.lines.items) |*line| line.deinit(gpa);
    self.lines.deinit(gpa);
    self.lines = snap.lines;
    self.cursor_row = snap.cursor_row;
    self.cursor_col = snap.cursor_col;
    self.mark = snap.mark;
    self.undo_group = .none;
    self.dirty = true;
}

fn insertSliceRaw(self: *Buffer, gpa: std.mem.Allocator, text: []const u8) !void {
    try self.lines.items[self.cursor_row].insertSlice(gpa, self.cursor_col, text);
    self.cursor_col += text.len;
    self.dirty = true;
}

pub fn insertSlice(self: *Buffer, gpa: std.mem.Allocator, text: []const u8) !void {
    try self.recordUndo(gpa, .typing);
    try self.insertSliceRaw(gpa, text);
}

fn insertNewlineRaw(self: *Buffer, gpa: std.mem.Allocator) !void {
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

fn rememberKill(gpa: std.mem.Allocator, kill_ring: *std.ArrayList(u8), text: []const u8, append: bool) !void {
    if (!append) kill_ring.clearRetainingCapacity();
    try kill_ring.appendSlice(gpa, text);
}

/// C-k: kill to end of line, or kill the newline itself when already at end of line.
pub fn killLine(self: *Buffer, gpa: std.mem.Allocator, kill_ring: *std.ArrayList(u8), append: bool) !void {
    const row = self.cursor_row;
    const col = self.cursor_col;
    const nothing_to_kill = col >= self.lines.items[row].items.len and row + 1 >= self.lines.items.len;
    if (nothing_to_kill) return;
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
pub fn killRegion(self: *Buffer, gpa: std.mem.Allocator, kill_ring: *std.ArrayList(u8), append: bool) !void {
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

/// M-w: copy the region between point and mark without deleting it.
pub fn copyRegion(self: *Buffer, gpa: std.mem.Allocator, kill_ring: *std.ArrayList(u8), append: bool) !void {
    const region = self.orderedRegion() orelse return;
    const text = try self.extractRange(gpa, region.start, region.end);
    defer gpa.free(text);
    try rememberKill(gpa, kill_ring, text, append);
}

/// C-y: insert the most recent kill at point.
pub fn yank(self: *Buffer, gpa: std.mem.Allocator, kill_ring: *std.ArrayList(u8)) !void {
    if (kill_ring.items.len == 0) return;
    try self.recordUndo(gpa, .yank);
    var it = std.mem.splitScalar(u8, kill_ring.items, '\n');
    try self.insertSliceRaw(gpa, it.next().?);
    while (it.next()) |seg| {
        try self.insertNewlineRaw(gpa);
        try self.insertSliceRaw(gpa, seg);
    }
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

/// Keep the cursor row within [top_line, top_line + height) by adjusting top_line.
pub fn scrollToCursor(self: *Buffer, height: usize) void {
    if (height == 0) return;
    if (self.cursor_row < self.top_line) {
        self.top_line = self.cursor_row;
    } else if (self.cursor_row >= self.top_line + height) {
        self.top_line = self.cursor_row - height + 1;
    }
}

pub const SearchDirection = enum { forward, backward };

/// Find the next occurrence of `query` from `from`, wrapping around the
/// buffer if needed. Search never crosses a line boundary within a single
/// match. Returns the position of the start of the match.
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
                    if (std.mem.indexOfPos(u8, line, col_start, query)) |c| {
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
                if (std.mem.lastIndexOf(u8, line[0..limit], query)) |c| {
                    return .{ .row = row, .col = c };
                }
                row = if (row == 0) n - 1 else row - 1;
                end_col = null;
            }
            return null;
        },
    }
}
