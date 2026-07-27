const std = @import("std");

const Buffer = @This();

lines: std.ArrayList(std.ArrayList(u8)),
cursor_row: usize = 0,
cursor_col: usize = 0,
top_line: usize = 0,
filename: ?[]const u8 = null,
dirty: bool = false,

pub fn initEmpty() Buffer {
    return .{ .lines = .empty };
}

pub fn deinit(self: *Buffer, gpa: std.mem.Allocator) void {
    for (self.lines.items) |*line| line.deinit(gpa);
    self.lines.deinit(gpa);
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
