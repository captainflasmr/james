const std = @import("std");
const vaxis = @import("vaxis");
const Buffer = @import("Buffer.zig");
const Dired = @import("Dired.zig");

/// Suppress vaxis's std.log output: stderr shares the terminal, so its
/// startup chatter ("kitty keyboard capability", resize notices, ...)
/// would otherwise be painted on top of the editor screen.
pub const std_options: std.Options = .{
    .logFn = silence,
};

fn silence(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = message_level;
    _ = scope;
    _ = format;
    _ = args;
}

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
/// Render one buffer's text plus its own compact modeline into `win`, which
/// may be the whole screen or one pane of a split. Used for split panes,
/// where there's no room for isearch/mark-set decoration — just enough to
/// tell panes apart and see where you are.
fn renderPane(win: vaxis.Window, buf: *Buffer, is_focused: bool, row_base: u16, height: u16, modeline_buf: []u8) void {
    const text_height: usize = if (height > 1) height - 1 else height;
    buf.scrollToCursor(text_height);

    var row: u16 = 0;
    var i = buf.top_line;
    while (i < buf.lines.items.len and row < text_height) : (i += 1) {
        const h = highlightFor(buf, i, false, null, 0);
        var seg_storage: [3]vaxis.Segment = undefined;
        const segs = lineSegments(buf.lines.items[i].items, h.hl, h.empty_marker, &seg_storage);
        _ = win.print(segs, .{ .row_offset = row_base + row });
        row += 1;
    }

    const modeline = std.fmt.bufPrint(modeline_buf, "{s}{s}  L{d}:C{d}", .{
        buf.display_name orelse buf.filename orelse "?",
        if (buf.dirty) " [modified]" else "",
        buf.cursor_row + 1,
        buf.cursor_col + 1,
    }) catch "?";
    // The modeline is a bar spanning the pane's full width, like Emacs's
    // mode line: reverse video when focused, dimmed otherwise. The whole
    // row (text + spaces) is one segment built in `modeline_buf`, which the
    // caller keeps alive until after render — vaxis stores grapheme slices,
    // not copies, so a stack-local fill buffer would dangle and show
    // garbage once this frame returns.
    const style: vaxis.Style = if (is_focused) highlight_style else .{ .dim = true, .reverse = true };
    const text_w = win.gwidth(modeline);
    const fill_n = @min(@as(usize, @intCast(win.width -| text_w)), modeline_buf.len - modeline.len);
    if (fill_n > 0) @memset(modeline_buf[modeline.len .. modeline.len + fill_n], ' ');
    _ = win.printSegment(.{ .text = modeline_buf[0 .. modeline.len + fill_n], .style = style }, .{ .row_offset = row_base + (height -| 1) });

    if (is_focused) {
        win.showCursor(@intCast(buf.cursor_col), @intCast(row_base + buf.cursor_row - buf.top_line));
    }
}

/// How a split pane divides its space. `.horizontal` stacks its children
/// (divider runs left-to-right); `.vertical` places them side-by-side
/// (divider runs top-to-bottom).
const SplitDir = enum { horizontal, vertical };

/// A pane in the window tree. A leaf shows one buffer; a split pane lays
/// its two children out in `dir`. Splitting always subdivides the focused
/// leaf, so directions can nest freely (e.g. a vertical split inside a
/// horizontal one).
const Pane = struct {
    dir: SplitDir = .vertical,
    buf_idx: usize = 0,
    left: ?*Pane = null,
    right: ?*Pane = null,
    /// Share of the space given to the left/top child, in 256ths
    /// (128 = half). Adjusted by the resize bindings (M-C-h / M-C-l / ...).
    left_frac: u8 = 128,

    fn isLeaf(self: *const Pane) bool {
        return self.left == null and self.right == null;
    }

    fn leafCount(self: *const Pane) usize {
        if (self.isLeaf()) return 1;
        return self.left.?.leafCount() + self.right.?.leafCount();
    }

    /// Split this leaf pane into two, both showing its buffer. The original
    /// pane keeps the focus; the new one appears below (`.horizontal`) or to
    /// the right (`.vertical`), matching Emacs C-x 2 / C-x 3.
    fn split(self: *Pane, gpa: std.mem.Allocator, dir: SplitDir) !void {
        if (!self.isLeaf()) return error.AlreadySplit;
        const left = try gpa.create(Pane);
        left.* = .{ .buf_idx = self.buf_idx };
        const right = try gpa.create(Pane);
        right.* = .{ .buf_idx = self.buf_idx };
        self.left = left;
        self.right = right;
        self.dir = dir;
        self.buf_idx = 0;
    }

    /// Free this pane and all of its descendants.
    fn destroy(self: *Pane, gpa: std.mem.Allocator) void {
        if (self.isLeaf()) {
            gpa.destroy(self);
        } else {
            self.left.?.destroy(gpa);
            self.right.?.destroy(gpa);
            gpa.destroy(self);
        }
    }

    /// The parent of `target` in the subtree rooted at `self`, if any.
    fn findParent(self: *Pane, target: *const Pane) ?*Pane {
        if (self == target) return null;
        if (self.isLeaf()) return null;
        if (self.left.? == target or self.right.? == target) return self;
        return self.left.?.findParent(target) orelse self.right.?.findParent(target);
    }

    /// The nearest ancestor of `target` whose divider runs in `dir`, if any.
    /// Width-resizing looks for a `.vertical` ancestor, depth-resizing a
    /// `.horizontal` one.
    fn nearestDirAncestor(self: *Pane, target: *const Pane, dir: SplitDir) ?*Pane {
        const parent = self.findParent(target) orelse return null;
        if (parent.dir == dir) return parent;
        return self.nearestDirAncestor(parent, dir);
    }

    /// Move the divider of the nearest matching ancestor by `frac_delta`
    /// 256ths, so the focused pane's window grows or shrinks.
    fn resizeDivider(self: *Pane, focused: *const Pane, dir: SplitDir, frac_delta: i16) void {
        const ancestor = self.nearestDirAncestor(focused, dir) orelse return;
        const lo: i16 = 16;
        const hi: i16 = 240;
        const next: i16 = std.math.clamp(@as(i16, ancestor.left_frac) + frac_delta, lo, hi);
        ancestor.left_frac = @intCast(next);
    }

    /// Append the leaves of this subtree to `out` in render order.
    fn collectLeaves(self: *Pane, out: []*Pane, n: *usize) void {
        if (self.isLeaf()) {
            out[n.*] = self;
            n.* += 1;
        } else {
            self.left.?.collectLeaves(out, n);
            self.right.?.collectLeaves(out, n);
        }
    }
};

const MAX_PANES = 16;

/// C-x 0 / M-q: delete the focused pane, giving its space to the sibling.
/// Returns the new focused leaf (the sibling's leftmost pane), or null if
/// there was only one pane. `root` is in/out: it can shrink to a leaf.
fn deleteFocusedPane(gpa: std.mem.Allocator, root: **Pane, focused: *Pane) ?*Pane {
    const r = root.*;
    if (r.isLeaf()) return null;
    const parent = r.findParent(focused) orelse unreachable;
    const sib = if (parent.left == focused) parent.right.? else parent.left.?;
    const gp = r.findParent(parent);
    if (gp) |g| {
        if (g.left == parent) g.left = sib else g.right = sib;
    } else {
        root.* = sib;
    }
    gpa.destroy(focused);
    gpa.destroy(parent);
    var leaf = sib;
    while (!leaf.isLeaf()) leaf = leaf.left.?;
    return leaf;
}

/// C-x o / M-n / M-p: the pane `step` places away from `focused` in render
/// order (wrapping around), or null if there aren't two panes to choose
/// between.
fn moveFocus(root: *Pane, focused: *Pane, step: isize) ?*Pane {
    var leaves: [MAX_PANES]*Pane = undefined;
    var n: usize = 0;
    root.collectLeaves(&leaves, &n);
    if (n < 2) return null;
    for (leaves[0..n], 0..) |leaf, i| {
        if (leaf == focused) {
            const idx: isize = @as(isize, @intCast(i)) + step;
            return leaves[@intCast(@mod(idx, @as(isize, @intCast(n))))];
        }
    }
    return null;
}

/// C-x 1 / M-a: collapse the whole tree back to a single pane showing the
/// focused buffer. Returns the buffer index the single pane should show.
fn deleteOtherWindows(gpa: std.mem.Allocator, root: *Pane, focused: *Pane) usize {
    const keep = focused.buf_idx;
    if (!root.isLeaf()) {
        root.left.?.destroy(gpa);
        root.right.?.destroy(gpa);
        root.left = null;
        root.right = null;
        root.buf_idx = keep;
    }
    return keep;
}

/// Render one dired listing plus its own compact modeline into `win`, which
/// may be the whole screen or one pane of a split. Same shape as
/// `renderPane`, so dired lives inside the current window instead of
/// taking over the whole screen; when a file is chosen it's simply
/// replaced by the newly opened buffer.
fn renderDiredPane(win: vaxis.Window, dired: *Dired, is_focused: bool, row_base: u16, height: u16, modeline_buf: []u8) void {
    const text_height: usize = if (height > 1) height - 1 else height;
    dired.scrollToSelected(text_height);
    var name_bufs: [256][300]u8 = undefined;
    var row: u16 = 0;
    var i = dired.top;
    while (i < dired.entries.items.len and row < text_height and row < name_bufs.len) : (i += 1) {
        const e = dired.entries.items[i];
        const label = std.fmt.bufPrint(&name_bufs[row], "{s}{s}", .{ e.name, if (e.is_dir) "/" else "" }) catch e.name;
        const style: vaxis.Style = if (i == dired.selected) highlight_style else .{};
        _ = win.printSegment(.{ .text = label, .style = style }, .{ .row_offset = row_base + row });
        row += 1;
    }

    const modeline = std.fmt.bufPrint(modeline_buf, "Dired: {s}   (Enter opens, ^ up, q quits)", .{dired.path.items}) catch "Dired";
    const style: vaxis.Style = if (is_focused) highlight_style else .{ .dim = true, .reverse = true };
    const text_w = win.gwidth(modeline);
    const fill_n = @min(@as(usize, @intCast(win.width -| text_w)), modeline_buf.len - modeline.len);
    if (fill_n > 0) @memset(modeline_buf[modeline.len .. modeline.len + fill_n], ' ');
    _ = win.printSegment(.{ .text = modeline_buf[0 .. modeline.len + fill_n], .style = style }, .{ .row_offset = row_base + (height -| 1) });

    if (is_focused) {
        win.showCursor(0, @intCast(dired.selected - dired.top));
    }
}

/// Render the pane tree rooted at `pane` into `win`. Each leaf gets a child
/// window at its computed rect and renders through `renderPane`; the focused
/// pane is the one showing the cursor. `modeline_bufs` gives every leaf
/// somewhere scratchy to format its modeline. While dired is open it takes
/// over the focused pane (via `renderDiredPane`) and every other pane keeps
/// showing its buffer.
fn renderTree(
    win: vaxis.Window,
    pane: *Pane,
    x_off: i17,
    y_off: u16,
    width: u16,
    height: u16,
    modeline_bufs: *[MAX_PANES][1024]u8,
    slot: usize,
    buffers: []*Buffer,
    focused: *Pane,
    dired: *Dired,
    dired_active: bool,
) void {
    if (pane.isLeaf()) {
        const child = win.child(.{ .x_off = x_off, .y_off = y_off, .width = width, .height = height });
        if (pane == focused and dired_active) {
            renderDiredPane(child, dired, true, 0, height, &modeline_bufs[slot % MAX_PANES]);
        } else {
            renderPane(child, buffers[pane.buf_idx], pane == focused, 0, height, &modeline_bufs[slot % MAX_PANES]);
        }
        return;
    }

    switch (pane.dir) {
        .vertical => {
            const left_w: u16 = @intCast((@as(u32, width) * pane.left_frac) / 256);
            const right_w = width -| (left_w + 1);
            const right_x: i17 = x_off + @as(i17, @intCast(left_w)) + 1;
            renderTree(win, pane.left.?, x_off, y_off, left_w, height, modeline_bufs, slot * 2, buffers, focused, dired, dired_active);
            renderTree(win, pane.right.?, right_x, y_off, right_w, height, modeline_bufs, slot * 2 + 1, buffers, focused, dired, dired_active);
        },
        .horizontal => {
            const top_h: u16 = @intCast((@as(u32, height) * pane.left_frac) / 256);
            renderTree(win, pane.left.?, x_off, y_off, width, top_h, modeline_bufs, slot * 2, buffers, focused, dired, dired_active);
            renderTree(win, pane.right.?, x_off, y_off + top_h, width, height -| top_h, modeline_bufs, slot * 2 + 1, buffers, focused, dired, dired_active);
        },
    }
}

/// The home screen shown when james starts without any file arguments.
/// It's a plain buffer (so movement, search and every C-x command work on
/// it) with no backing file; C-x d / C-x C-f lead somewhere real.
const welcome_text =
    \\          ██╗ █████╗ ███╗   ███╗███████╗███████╗
    \\          ██║██╔══██╗████╗ ████║██╔════╝██╔════╝
    \\          ██║███████║██╔████╔██║█████╗  ███████╗
    \\          ██║██╔══██║██║╚██╔╝██║██╔══╝  ╚════██║
    \\          ██║██║  ██║██║ ╚═╝ ██║███████╗███████║
    \\          ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝╚══════╝╚══════╝
    \\
    \\  Welcome to james, a minimal Emacs-inspired editor for the terminal.
    \\
    \\  No file was given, so this is the home screen. Get to work with:
    \\
    \\    C-x d         browse files (dired)
    \\    C-x C-f       open or create a file
    \\    C-x b         switch to an open buffer
    \\
    \\  The essentials, once you're editing:
    \\
    \\    C-s / C-r     incremental search
    \\    C-x 2 / C-x 3 split the window, C-x o moves to the next one
    \\    C-space       set the mark; C-w kills the region, C-y yanks
    \\    C-x u         undo
    \\    C-x C-s       save
    \\    C-x C-c       quit
;

/// Add a fresh buffer containing `welcome_text` to `buffers`. Used only at
/// startup when no files were given.
fn openWelcome(gpa: std.mem.Allocator, buffers: *std.ArrayList(*Buffer)) !void {
    const new_buf = try gpa.create(Buffer);
    errdefer gpa.destroy(new_buf);
    new_buf.* = try Buffer.fromText(gpa, welcome_text);
    new_buf.display_name = try gpa.dupe(u8, "*welcome*");
    try buffers.append(gpa, new_buf);
}

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
        // No files given: land on the home screen, where C-x d makes it
        // easy to navigate to something real.
        try openWelcome(gpa, &buffers);
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
    var pending_ctrl_c = false;
    var confirming_quit = false;

    // Directory-browser (dired) state.
    var dired_active = false;
    var dired: Dired = .{};
    defer dired.deinit(gpa);

    // Switch/open-buffer prompt state (C-x b).
    // Split-window state. `root` is a tree of panes; a leaf shows one
    // buffer, a split pane lays its two children out side-by-side
    // (`.vertical`) or stacked (`.horizontal`). `focused` is the currently
    // selected leaf. With a single pane the screen just shows `current`
    // full-size as it always has.
    var root = try gpa.create(Pane);
    root.* = .{ .buf_idx = current };
    defer root.destroy(gpa);
    var focused = root;

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
            .winsize => |ws| {
                // Trust the kernel's ioctl size over the reported one: some
                // terminals emit a stale "CSI 48;...t" in-band report (e.g.
                // while the window is still being created), which would
                // otherwise leave the editor stuck at a fraction of the real
                // size.
                const real = tty.getWinsize() catch ws;
                try vx.resize(gpa, tty.writer(), real);
            },
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
                } else if (pending_ctrl_c) {
                    pending_ctrl_c = false;
                    if (key.matches('b', .{})) {
                        try buf.copyWholeBuffer(gpa, &kill_ring);
                        kill_active = true;
                    } else if (key.matches('w', .{})) {
                        try buf.copyRegion(gpa, &kill_ring, false);
                        buf.mark = null;
                        kill_active = true;
                    } else if (key.matches('k', .{ .ctrl = true })) {
                        if (dired_active) dired_active = false;
                    }
                } else if (dired_active) {
                    if (key.matches('g', .{ .ctrl = true }) or key.matches('q', .{})) {
                        dired_active = false;
                    } else if (key.matches('n', .{}) or key.matches('n', .{ .ctrl = true }) or key.matches(vaxis.Key.down, .{})) {
                        dired.moveDown();
                    } else if (key.matches('p', .{}) or key.matches('p', .{ .ctrl = true }) or key.matches(vaxis.Key.up, .{})) {
                        dired.moveUp();
                    } else if (key.matches('e', .{ .alt = true }) or key.matches('^', .{})) {
                        dired.goUp(gpa, io) catch {};
                    } else if (key.matches(vaxis.Key.enter, .{})) {
                        const choice = dired.choose(gpa, io) catch Dired.Choice.none;
                        switch (choice) {
                            .navigated, .none => {},
                            .open_file => |file_path| {
                                defer gpa.free(file_path);
                                current = openBuffer(gpa, io, &buffers, file_path) catch current;
                                focused.buf_idx = current;
                                dired_active = false;
                            },
                        }
                    }
                } else if (switching_buffer) {
                    if (key.matches('g', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                        switching_buffer = false;
                    } else if (key.matches(vaxis.Key.backspace, .{})) {
                        if (switch_query.items.len > 0) _ = switch_query.pop();
                    } else if (key.matches(vaxis.Key.enter, .{})) {
                        switching_buffer = false;
                        const name = std.mem.trim(u8, switch_query.items, " ");
                        if (name.len > 0) {
                            current = openBuffer(gpa, io, &buffers, name) catch current;
                            focused.buf_idx = current;
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
                        // Buffers with no backing file (the home screen) are
                        // scratch space — quitting them never prompts.
                        if (buf.dirty and buf.filename != null) {
                            confirming_quit = true;
                        } else {
                            return;
                        }
                    } else if (key.matches('u', .{}) or key.matches('u', .{ .ctrl = true })) {
                        buf.undo(gpa);
                    } else if (key.matches('b', .{}) or key.matches('f', .{ .ctrl = true })) {
                        switching_buffer = true;
                        switch_query.clearRetainingCapacity();
                    } else if (key.matches('d', .{}) or key.matches('m', .{})) {
                        const start = try Dired.startingDir(gpa, buf.filename orelse ".");
                        defer gpa.free(start);
                        dired.open(gpa, io, start) catch {};
                        dired_active = true;
                    } else if (key.matches('g', .{})) {
                        buf.reread(gpa, io) catch {};
                    } else if (key.matches('h', .{})) {
                        buf.moveBufStart();
                        buf.setMark();
                        buf.moveBufEnd();
                    } else if (key.matches('k', .{ .ctrl = true })) {
                        try buf.killRegion(gpa, &kill_ring, kill_active);
                        kill_active = true;
                    } else if (key.matches('2', .{}) or key.matches('3', .{})) {
                        if (root.leafCount() < MAX_PANES) {
                            const dir: SplitDir = if (key.matches('2', .{})) .horizontal else .vertical;
                            try focused.split(gpa, dir);
                            focused = focused.left.?;
                            current = focused.buf_idx;
                        }
                    } else if (key.matches('1', .{})) {
                        current = deleteOtherWindows(gpa, root, focused);
                        focused = root;
                    } else if (key.matches('0', .{})) {
                        if (deleteFocusedPane(gpa, &root, focused)) |nf| {
                            focused = nf;
                            current = focused.buf_idx;
                        }
                    } else if (key.matches('o', .{})) {
                        if (moveFocus(root, focused, 1)) |nf| {
                            focused = nf;
                            current = focused.buf_idx;
                        }
                    }
                } else {
                    const was_kill = kill_active;
                    kill_active = false;

                    if (key.matches('x', .{ .ctrl = true })) {
                        pending_ctrl_x = true;
                    } else if (key.matches('c', .{ .ctrl = true })) {
                        pending_ctrl_c = true;
                    } else if (key.matches('/', .{ .ctrl = true }) or key.matches(0x1F, .{})) {
                        buf.undo(gpa);
                    } else if (key.matches(';', .{ .ctrl = true })) {
                        try buf.toggleComment(gpa);
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
                    } else if (key.matches('g', .{ .ctrl = true })) {
                        // C-g cancels the mark (deselects the region), like
                        // the quit/cancel key in every prompt mode.
                        buf.mark = null;
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
                    } else if (key.matches(';', .{ .alt = true }) or key.matches('m', .{ .alt = true })) {
                        if (root.leafCount() < MAX_PANES) {
                            const dir: SplitDir = if (key.matches(';', .{ .alt = true })) .vertical else .horizontal;
                            try focused.split(gpa, dir);
                            focused = focused.right.?;
                            current = focused.buf_idx;
                        }
                    } else if (key.matches('q', .{ .alt = true })) {
                        if (deleteFocusedPane(gpa, &root, focused)) |nf| {
                            focused = nf;
                            current = focused.buf_idx;
                        }
                    } else if (key.matches('a', .{ .alt = true })) {
                        current = deleteOtherWindows(gpa, root, focused);
                        focused = root;
                    } else if (key.matches('e', .{ .alt = true })) {
                        // M-e: dired-jump — open dired at the current
                        // file's directory (in dired mode M-e already goes
                        // up a directory, matching my/dired-jump-or-up).
                        const start = try Dired.startingDir(gpa, buf.filename orelse ".");
                        defer gpa.free(start);
                        dired.open(gpa, io, start) catch {};
                        dired_active = true;
                    } else if (key.matches('n', .{ .alt = true })) {
                        if (moveFocus(root, focused, 1)) |nf| {
                            focused = nf;
                            current = focused.buf_idx;
                        }
                    } else if (key.matches('p', .{ .alt = true })) {
                        if (moveFocus(root, focused, -1)) |nf| {
                            focused = nf;
                            current = focused.buf_idx;
                        }
                    } else if (key.matches('j', .{ .alt = true })) {
                        buf.moveLines(5);
                    } else if (key.matches('k', .{ .alt = true })) {
                        buf.moveLines(-5);
                    } else if (key.matches('<', .{ .alt = true })) {
                        buf.moveBufStart();
                    } else if (key.matches('>', .{ .alt = true })) {
                        buf.moveBufEnd();
                    } else if (key.matches('h', .{ .alt = true, .ctrl = true })) {
                        root.resizeDivider(focused, .vertical, -8);
                    } else if (key.matches('l', .{ .alt = true, .ctrl = true })) {
                        root.resizeDivider(focused, .vertical, 8);
                    } else if (key.matches('k', .{ .alt = true, .ctrl = true })) {
                        root.resizeDivider(focused, .horizontal, -8);
                    } else if (key.matches('j', .{ .alt = true, .ctrl = true })) {
                        root.resizeDivider(focused, .horizontal, 8);
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
        // Dired is not modal: it renders inside the focused pane, leaving
        // any other split panes untouched. Only the prompt-style modes take
        // over the whole screen.
        const is_modal = confirming_quit or switching_buffer or isearch_active;

        if (!is_modal and !root.isLeaf()) {
            var modeline_bufs: [MAX_PANES][1024]u8 = undefined;
            renderTree(win, root, 0, 0, win.width, win.height, &modeline_bufs, 0, buffers.items, focused, &dired, dired_active);
            try vx.render(tty.writer());
            continue;
        }

        if (dired_active) {
            var modeline_buf: [2048]u8 = undefined;
            renderDiredPane(win, &dired, true, 0, win.height, &modeline_buf);
            try vx.render(tty.writer());
            continue;
        }

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

        // Fixed scratch space for the modeline text: it's redrawn every
        // frame, so this avoids growing `init.arena` (which lives for the
        // whole process) by one small allocation per keystroke forever.
        var modeline_buf: [2048]u8 = undefined;
        var count_buf: [32]u8 = undefined;

        const modeline = if (confirming_quit)
            std.fmt.bufPrint(&modeline_buf, "Save file {s} before exiting? (y / n / C-g cancels)", .{buf.filename orelse "?"}) catch "Save before exiting? (y/n)"
        else if (switching_buffer)
            std.fmt.bufPrint(&modeline_buf, "Switch to buffer (open if new): {s}", .{switch_query.items}) catch "Switch to buffer: ..."
        else if (isearch_active) blk: {
            const label = if (isearch_failed)
                (if (isearch_dir == .backward) "Failing I-search backward" else "Failing I-search")
            else
                (if (isearch_dir == .backward) "I-search backward" else "I-search");
            break :blk std.fmt.bufPrint(&modeline_buf, "{s}: {s}", .{ label, isearch_query.items }) catch label;
        } else blk: {
            const buf_count = if (buffers.items.len > 1)
                (std.fmt.bufPrint(&count_buf, "  ({d}/{d})", .{ current + 1, buffers.items.len }) catch "")
            else
                "";
            break :blk std.fmt.bufPrint(&modeline_buf, "-- {s}{s}{s}{s}  L{d}:C{d} --", .{
                buf.display_name orelse buf.filename orelse "?",
                if (buf.dirty) " [modified]" else "",
                if (buf.mark != null) " [mark set]" else "",
                buf_count,
                buf.cursor_row + 1,
                buf.cursor_col + 1,
            }) catch "-- zemacs --";
        };
        // Same full-width bar as the pane modelines: the whole row is one
        // segment in `modeline_buf`, kept alive until after the render.
        const style: vaxis.Style = highlight_style;
        const text_w = win.gwidth(modeline);
        const fill_n = @min(@as(usize, @intCast(win.width -| text_w)), modeline_buf.len - modeline.len);
        if (fill_n > 0) @memset(modeline_buf[modeline.len .. modeline.len + fill_n], ' ');
        _ = win.printSegment(.{ .text = modeline_buf[0 .. modeline.len + fill_n], .style = style }, .{ .row_offset = win.height -| 1 });

        win.showCursor(
            @intCast(buf.cursor_col),
            @intCast(buf.cursor_row - buf.top_line),
        );

        try vx.render(tty.writer());
    }
}
