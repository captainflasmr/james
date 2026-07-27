const std = @import("std");

const Buffer = @This();

lines: std.ArrayList(std.ArrayList(u8)),
cursor_row: usize = 0,
cursor_col: usize = 0,
top_line: usize = 0,
filename: ?[]const u8 = null,
dirty: bool = false,
mark: ?Pos = null,
kill_ring: std.ArrayList(u8) = .empty,
/// True if the previous command was a kill, so a fresh kill should append to
/// kill_ring instead of replacing it (matches Emacs's last-command tracking).
kill_active: bool = false,

pub const Pos = struct { row: usize, col: usize };

pub fn initEmpty() Buffer {
    return .{ .lines = .empty };
}

pub fn deinit(self: *Buffer, gpa: std.mem.Allocator) void {
    for (self.lines.items) |*line| line.deinit(gpa);
    self.lines.deinit(gpa);
    self.kill_ring.deinit(gpa);
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

pub fn insertSlice(self: *Buffer, gpa: std.mem.Allocator, text: []const u8) !void {
    try self.lines.items[self.cursor_row].insertSlice(gpa, self.cursor_col, text);
    self.cursor_col += text.len;
    self.dirty = true;
}

pub fn insertNewline(self: *Buffer, gpa: std.mem.Allocator) !void {
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

pub fn deleteBackward(self: *Buffer, gpa: std.mem.Allocator) void {
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

pub fn deleteForward(self: *Buffer, gpa: std.mem.Allocator) void {
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
fn orderedRegion(self: Buffer) ?struct { start: Pos, end: Pos } {
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

fn rememberKill(self: *Buffer, gpa: std.mem.Allocator, text: []const u8, append: bool) !void {
    if (!append) self.kill_ring.clearRetainingCapacity();
    try self.kill_ring.appendSlice(gpa, text);
}

/// C-k: kill to end of line, or kill the newline itself when already at end of line.
pub fn killLine(self: *Buffer, gpa: std.mem.Allocator, append: bool) !void {
    const row = self.cursor_row;
    const col = self.cursor_col;
    if (col < self.lines.items[row].items.len) {
        const owned = try gpa.dupe(u8, self.lines.items[row].items[col..]);
        defer gpa.free(owned);
        self.lines.items[row].shrinkRetainingCapacity(col);
        try self.rememberKill(gpa, owned, append);
    } else if (row + 1 < self.lines.items.len) {
        try self.lines.items[row].appendSlice(gpa, self.lines.items[row + 1].items);
        var removed = self.lines.orderedRemove(row + 1);
        removed.deinit(gpa);
        try self.rememberKill(gpa, "\n", append);
    } else {
        return;
    }
    self.dirty = true;
}

/// C-w: kill the region between point and mark.
pub fn killRegion(self: *Buffer, gpa: std.mem.Allocator, append: bool) !void {
    const region = self.orderedRegion() orelse return;
    const text = try self.extractRange(gpa, region.start, region.end);
    defer gpa.free(text);
    try self.deleteRange(gpa, region.start, region.end);
    self.cursor_row = region.start.row;
    self.cursor_col = region.start.col;
    self.mark = null;
    try self.rememberKill(gpa, text, append);
    self.dirty = true;
}

/// M-w: copy the region between point and mark without deleting it.
pub fn copyRegion(self: *Buffer, gpa: std.mem.Allocator, append: bool) !void {
    const region = self.orderedRegion() orelse return;
    const text = try self.extractRange(gpa, region.start, region.end);
    defer gpa.free(text);
    try self.rememberKill(gpa, text, append);
}

/// C-y: insert the most recent kill at point.
pub fn yank(self: *Buffer, gpa: std.mem.Allocator) !void {
    if (self.kill_ring.items.len == 0) return;
    var it = std.mem.splitScalar(u8, self.kill_ring.items, '\n');
    try self.insertSlice(gpa, it.next().?);
    while (it.next()) |seg| {
        try self.insertNewline(gpa);
        try self.insertSlice(gpa, seg);
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
