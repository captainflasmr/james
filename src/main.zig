const std = @import("std");
const vaxis = @import("vaxis");
const Buffer = @import("Buffer.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

const highlight_style: vaxis.Style = .{ .reverse = true };

const Highlight = struct { start: usize, end: usize };

/// Build the segments needed to draw a line, reverse-videoing the given
/// column range (if any). `empty_line_marker` shows a single highlighted
/// space for a blank line that's fully inside a highlighted span, since
/// there's otherwise nothing to invert. `storage` just gives the segments
/// somewhere to live; at most 3 are ever needed (before/inside/after).
fn lineSegments(line: []const u8, hl: ?Highlight, empty_line_marker: bool, storage: *[3]vaxis.Segment) []const vaxis.Segment {
    const range = hl orelse {
        storage[0] = .{ .text = line };
        return storage[0..1];
    };

    if (line.len == 0) {
        storage[0] = if (empty_line_marker)
            .{ .text = " ", .style = highlight_style }
        else
            .{ .text = line };
        return storage[0..1];
    }

    var n: usize = 0;
    if (range.start > 0) {
        storage[n] = .{ .text = line[0..range.start] };
        n += 1;
    }
    if (range.end > range.start) {
        storage[n] = .{ .text = line[range.start..range.end], .style = highlight_style };
        n += 1;
    }
    if (range.end < line.len) {
        storage[n] = .{ .text = line[range.end..] };
        n += 1;
    }
    if (n == 0) {
        storage[0] = .{ .text = line };
        n = 1;
    }
    return storage[0..n];
}

/// The highlight range (if any) for `row`. While a search is active, only
/// the current match is highlighted (even if there isn't one yet); otherwise
/// falls back to the mark/point region, same as before incremental search.
fn highlightFor(
    buf: *const Buffer,
    row: usize,
    searching: bool,
    search_match: ?Buffer.Pos,
    search_len: usize,
) struct { hl: ?Highlight, empty_marker: bool } {
    if (searching) {
        if (search_match) |m| {
            if (row == m.row) return .{ .hl = .{ .start = m.col, .end = m.col + search_len }, .empty_marker = false };
        }
        return .{ .hl = null, .empty_marker = false };
    }

    const region = buf.orderedRegion() orelse return .{ .hl = null, .empty_marker = false };
    if (row < region.start.row or row > region.end.row) return .{ .hl = null, .empty_marker = false };
    const line_len = buf.lines.items[row].items.len;
    const s = if (row == region.start.row) region.start.col else 0;
    const e = if (row == region.end.row) region.end.col else line_len;
    const empty_marker = line_len == 0 and row > region.start.row and row < region.end.row;
    return .{ .hl = .{ .start = s, .end = e }, .empty_marker = empty_marker };
}

/// Switch to the buffer visiting `path` if one is already open, otherwise
/// load it fresh and open it as a new buffer. Returns its index.
fn openBuffer(gpa: std.mem.Allocator, io: std.Io, buffers: *std.ArrayList(*Buffer), path: []const u8) !usize {
    for (buffers.items, 0..) |b, idx| {
        if (b.filename) |f| {
            if (std.mem.eql(u8, f, path)) return idx;
        }
    }
    const new_buf = try gpa.create(Buffer);
    errdefer gpa.destroy(new_buf);
    new_buf.* = try Buffer.loadFile(gpa, io, path);
    try buffers.append(gpa, new_buf);
    return buffers.items.len - 1;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // Every non-program argument is a file to open as its own buffer.
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();
    _ = args_it.next();

    var buffers: std.ArrayList(*Buffer) = .empty;
    defer {
        for (buffers.items) |b| {
            b.deinit(gpa);
            gpa.destroy(b);
        }
        buffers.deinit(gpa);
    }
    while (args_it.next()) |arg| {
        _ = try openBuffer(gpa, io, &buffers, arg);
    }
    if (buffers.items.len == 0) {
        std.debug.print("usage: zemacs <file> [file...]\n", .{});
        return;
    }
    var current: usize = 0;

    // Kill ring is shared across all buffers, same as real Emacs.
    var kill_ring: std.ArrayList(u8) = .empty;
    defer kill_ring.deinit(gpa);
    var kill_active = false;

    var tty_buf: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();

    var vx = try vaxis.init(io, gpa, init.environ_map, .{});
    defer vx.deinit(null, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    var pending_ctrl_x = false;
    var confirming_quit = false;

    // Switch/open-buffer prompt state (C-x b).
    var switching_buffer = false;
    var switch_query: std.ArrayList(u8) = .empty;
    defer switch_query.deinit(gpa);

    // Incremental search state.
    var isearch_active = false;
    var isearch_dir: Buffer.SearchDirection = .forward;
    var isearch_query: std.ArrayList(u8) = .empty;
    defer isearch_query.deinit(gpa);
    var isearch_origin: Buffer.Pos = .{ .row = 0, .col = 0 };
    var isearch_match: ?Buffer.Pos = null;
    var isearch_failed = false;

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .winsize => |ws| try vx.resize(gpa, tty.writer(), ws),
            .key_press => |key| {
                const buf: *Buffer = buffers.items[current];

                if (confirming_quit) {
                    if (key.matches('y', .{}) or key.matches('Y', .{})) {
                        buf.save(gpa, io) catch {};
                        return;
                    } else if (key.matches('n', .{}) or key.matches('N', .{})) {
                        return;
                    } else if (key.matches('g', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                        confirming_quit = false;
                    }
                    // Any other key is ignored — stay in the prompt rather
                    // than risk a stray keystroke saving or discarding work.
                } else if (switching_buffer) {
                    if (key.matches('g', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                        switching_buffer = false;
                    } else if (key.matches(vaxis.Key.backspace, .{})) {
                        if (switch_query.items.len > 0) _ = switch_query.pop();
                    } else if (key.matches(vaxis.Key.enter, .{})) {
                        switching_buffer = false;
                        const name = std.mem.trim(u8, switch_query.items, " ");
                        if (name.len > 0) {
                            current = try openBuffer(gpa, io, &buffers, name);
                            kill_active = false;
                        }
                    } else if (key.text) |t| {
                        try switch_query.appendSlice(gpa, t);
                    } else {
                        switching_buffer = false;
                    }
                } else if (isearch_active) {
                    if (key.matches('g', .{ .ctrl = true })) {
                        buf.cursor_row = isearch_origin.row;
                        buf.cursor_col = isearch_origin.col;
                        isearch_active = false;
                        isearch_match = null;
                        isearch_query.clearRetainingCapacity();
                    } else if (key.matches('s', .{ .ctrl = true })) {
                        isearch_dir = .forward;
                        if (isearch_query.items.len > 0) {
                            const from: Buffer.Pos = if (isearch_match) |m|
                                .{ .row = m.row, .col = m.col + 1 }
                            else
                                isearch_origin;
                            if (buf.findNext(isearch_query.items, from, .forward)) |m| {
                                buf.cursor_row = m.row;
                                buf.cursor_col = m.col;
                                isearch_match = m;
                                isearch_failed = false;
                            } else {
                                isearch_failed = true;
                            }
                        }
                    } else if (key.matches('r', .{ .ctrl = true })) {
                        isearch_dir = .backward;
                        if (isearch_query.items.len > 0) {
                            const from: Buffer.Pos = isearch_match orelse isearch_origin;
                            if (buf.findNext(isearch_query.items, from, .backward)) |m| {
                                buf.cursor_row = m.row;
                                buf.cursor_col = m.col;
                                isearch_match = m;
                                isearch_failed = false;
                            } else {
                                isearch_failed = true;
                            }
                        }
                    } else if (key.matches(vaxis.Key.backspace, .{})) {
                        if (isearch_query.items.len > 0) _ = isearch_query.pop();
                        if (isearch_query.items.len == 0) {
                            buf.cursor_row = isearch_origin.row;
                            buf.cursor_col = isearch_origin.col;
                            isearch_match = null;
                            isearch_failed = false;
                        } else if (buf.findNext(isearch_query.items, isearch_origin, isearch_dir)) |m| {
                            buf.cursor_row = m.row;
                            buf.cursor_col = m.col;
                            isearch_match = m;
                            isearch_failed = false;
                        } else {
                            isearch_failed = true;
                        }
                    } else if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.escape, .{})) {
                        isearch_active = false;
                    } else if (key.text) |t| {
                        try isearch_query.appendSlice(gpa, t);
                        if (buf.findNext(isearch_query.items, isearch_origin, isearch_dir)) |m| {
                            buf.cursor_row = m.row;
                            buf.cursor_col = m.col;
                            isearch_match = m;
                            isearch_failed = false;
                        } else {
                            isearch_failed = true;
                        }
                    } else {
                        isearch_active = false;
                    }
                } else if (pending_ctrl_x) {
                    pending_ctrl_x = false;
                    if (key.matches('s', .{ .ctrl = true })) {
                        buf.save(gpa, io) catch {};
                    } else if (key.matches('c', .{ .ctrl = true })) {
                        if (buf.dirty) {
                            confirming_quit = true;
                        } else {
                            return;
                        }
                    } else if (key.matches('u', .{}) or key.matches('u', .{ .ctrl = true })) {
                        buf.undo(gpa);
                    } else if (key.matches('b', .{}) or key.matches('f', .{ .ctrl = true })) {
                        switching_buffer = true;
                        switch_query.clearRetainingCapacity();
                    }
                } else {
                    const was_kill = kill_active;
                    kill_active = false;

                    if (key.matches('x', .{ .ctrl = true })) {
                        pending_ctrl_x = true;
                    } else if (key.matches('s', .{ .ctrl = true })) {
                        isearch_active = true;
                        isearch_dir = .forward;
                        isearch_origin = .{ .row = buf.cursor_row, .col = buf.cursor_col };
                        isearch_match = null;
                        isearch_failed = false;
                        isearch_query.clearRetainingCapacity();
                    } else if (key.matches('r', .{ .ctrl = true })) {
                        isearch_active = true;
                        isearch_dir = .backward;
                        isearch_origin = .{ .row = buf.cursor_row, .col = buf.cursor_col };
                        isearch_match = null;
                        isearch_failed = false;
                        isearch_query.clearRetainingCapacity();
                    } else if (key.matches(' ', .{ .ctrl = true }) or key.matches('@', .{ .ctrl = true })) {
                        buf.setMark();
                    } else if (key.matches('k', .{ .ctrl = true })) {
                        try buf.killLine(gpa, &kill_ring, was_kill);
                        kill_active = true;
                    } else if (key.matches('w', .{ .ctrl = true })) {
                        try buf.killRegion(gpa, &kill_ring, was_kill);
                        kill_active = true;
                    } else if (key.matches('w', .{ .alt = true })) {
                        try buf.copyRegion(gpa, &kill_ring, was_kill);
                        kill_active = true;
                    } else if (key.matches('y', .{ .ctrl = true })) {
                        try buf.yank(gpa, &kill_ring);
                    } else if (key.matches('f', .{ .ctrl = true }) or key.matches(vaxis.Key.right, .{})) {
                        buf.moveRight();
                    } else if (key.matches('b', .{ .ctrl = true }) or key.matches(vaxis.Key.left, .{})) {
                        buf.moveLeft();
                    } else if (key.matches('n', .{ .ctrl = true }) or key.matches(vaxis.Key.down, .{})) {
                        buf.moveDown();
                    } else if (key.matches('p', .{ .ctrl = true }) or key.matches(vaxis.Key.up, .{})) {
                        buf.moveUp();
                    } else if (key.matches('a', .{ .ctrl = true })) {
                        buf.moveLineStart();
                    } else if (key.matches('e', .{ .ctrl = true })) {
                        buf.moveLineEnd();
                    } else if (key.matches('d', .{ .ctrl = true }) or key.matches(vaxis.Key.delete, .{})) {
                        try buf.deleteForward(gpa);
                    } else if (key.matches(vaxis.Key.backspace, .{})) {
                        try buf.deleteBackward(gpa);
                    } else if (key.matches(vaxis.Key.enter, .{})) {
                        try buf.insertNewline(gpa);
                    } else if (key.text) |t| {
                        try buf.insertSlice(gpa, t);
                    }
                }
            },
        }

        const buf: *Buffer = buffers.items[current];
        const win = vx.window();
        win.clear();

        const text_height: usize = if (win.height > 1) win.height - 1 else win.height;
        buf.scrollToCursor(text_height);

        var row: u16 = 0;
        var i = buf.top_line;
        while (i < buf.lines.items.len and row < text_height) : (i += 1) {
            const h = highlightFor(buf, i, isearch_active, if (isearch_failed) null else isearch_match, isearch_query.items.len);
            var seg_storage: [3]vaxis.Segment = undefined;
            const segs = lineSegments(buf.lines.items[i].items, h.hl, h.empty_marker, &seg_storage);
            _ = win.print(segs, .{ .row_offset = row });
            row += 1;
        }

        const modeline = if (confirming_quit)
            try std.fmt.allocPrint(init.arena.allocator(), "Save file {s} before exiting? (y / n / C-g cancels)", .{buf.filename orelse "?"})
        else if (switching_buffer)
            try std.fmt.allocPrint(init.arena.allocator(), "Switch to buffer (open if new): {s}", .{switch_query.items})
        else if (isearch_active) blk: {
            const label = if (isearch_failed)
                (if (isearch_dir == .backward) "Failing I-search backward" else "Failing I-search")
            else
                (if (isearch_dir == .backward) "I-search backward" else "I-search");
            break :blk try std.fmt.allocPrint(init.arena.allocator(), "{s}: {s}", .{ label, isearch_query.items });
        } else blk: {
            const buf_count = if (buffers.items.len > 1)
                try std.fmt.allocPrint(init.arena.allocator(), "  ({d}/{d})", .{ current + 1, buffers.items.len })
            else
                "";
            break :blk try std.fmt.allocPrint(init.arena.allocator(), "-- {s}{s}{s}{s}  L{d}:C{d} --", .{
                buf.filename orelse "?",
                if (buf.dirty) " [modified]" else "",
                if (buf.mark != null) " [mark set]" else "",
                buf_count,
                buf.cursor_row + 1,
                buf.cursor_col + 1,
            });
        };
        _ = win.printSegment(.{ .text = modeline }, .{ .row_offset = win.height -| 1 });

        win.showCursor(
            @intCast(buf.cursor_col),
            @intCast(buf.cursor_row - buf.top_line),
        );

        try vx.render(tty.writer());
    }
}
