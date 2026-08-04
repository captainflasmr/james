const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const windows = std.os.windows;
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

/// Tracks the last C-y so M-y (yank-pop) can replace it: the buffer the
/// yank landed in, the ring entry that was yanked, and where it went.
const YankState = struct {
    buf_idx: usize,
    entry: usize,
    start: Buffer.Pos,
    end: Buffer.Pos,
};

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    /// The terminal's answer to an OSC 52 clipboard request; the text is
    /// allocated with gpa and must be freed by the handler.
    paste: []const u8,
};

// The mark region and the isearch match keep this reverse-video
// highlight. The dired selection and the modelines are plain — the
// blinking block cursor marks position there.
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
            if (row == m.row) {
                // Clamp the highlight to the line: the match always lies
                // within the searched buffer, but this is called from panes
                // that may show other buffers.
                const line_len = buf.lines.items[row].items.len;
                return .{ .hl = .{
                    .start = @min(m.col, line_len),
                    .end = @min(m.col + search_len, line_len),
                }, .empty_marker = false };
            }
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
/// The isearch state, for rendering a search in whatever pane is being
/// searched: the match highlight plus the "I-search:" prompt in the
/// pane's own modeline, so the window layout never changes while
/// searching. Null when no search is active.
const IsearchView = struct {
    failed: bool,
    match: ?Buffer.Pos,
    query: []const u8,
    backward: bool,
};

const DiredPromptKind = enum { copy, rename, delete, create_dir, create_file };

/// An in-pane dired prompt (copy / rename target, delete confirmation):
/// the listing stays in its window and the prompt text appears in that
/// pane's modeline, so the layout never changes.
const DiredPromptView = struct {
    kind: DiredPromptKind,
    query: []const u8 = &.{},
};

/// Render one buffer's text plus its own compact modeline into `win`, which
/// may be the whole screen or one pane of a split. An active isearch shows
/// its match highlight and prompt in this pane, exactly as if the pane were
/// the whole screen.
fn renderPane(win: vaxis.Window, buf: *Buffer, is_focused: bool, row_base: u16, height: u16, modeline_buf: []u8, search: ?IsearchView, status: ?[]const u8) void {
    const text_height: usize = if (height > 1) height - 1 else height;
    buf.scrollToCursor(text_height);

    const searching = search != null;
    const match: ?Buffer.Pos = if (search) |s| (if (s.failed) null else s.match) else null;
    const query_len: usize = if (search) |s| s.query.len else 0;

    var row: u16 = 0;
    var i = buf.top_line;
    while (i < buf.lines.items.len and row < text_height) : (i += 1) {
        const h = highlightFor(buf, i, searching, match, query_len);
        var seg_storage: [3]vaxis.Segment = undefined;
        const segs = lineSegments(buf.lines.items[i].items, h.hl, h.empty_marker, &seg_storage);
        _ = win.print(segs, .{ .row_offset = row_base + row });
        row += 1;
    }

    const modeline = if (search) |s| blk: {
        const label = if (s.failed)
            (if (s.backward) "Failing I-search backward" else "Failing I-search")
        else
            (if (s.backward) "I-search backward" else "I-search");
        break :blk std.fmt.bufPrint(modeline_buf, "{s}: {s}", .{ label, s.query }) catch label;
    } else if (status) |m|
        std.fmt.bufPrint(modeline_buf, "{s}", .{m}) catch "Save failed"
    else std.fmt.bufPrint(modeline_buf, "{s}{s}{s}  L{d}:C{d}", .{
        // Emacs-style modified marker in the bottom-left corner of the
        // modeline.
        if (buf.dirty) "*" else "",
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
    const style: vaxis.Style = if (is_focused) highlight_style else .{ .dim = true };
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

/// The Emacs dired-dwim-target: the buffer index of the next dired window
/// after the focused one in render order (wrapping around). With two dired
/// windows — a source on one side, a destination on the other — C in either
/// copies the focused window's selected entry into the other window's
/// directory; whichever window holds the cursor is the source. Null when no
/// other window shows a dired.
fn dwimTargetBuf(root: *Pane, focused: *Pane, direds: []?Dired) ?usize {
    var leaves: [MAX_PANES]*Pane = undefined;
    var n: usize = 0;
    root.collectLeaves(&leaves, &n);
    if (n < 2) return null;
    var i: usize = 0;
    while (i < n and leaves[i] != focused) : (i += 1) {}
    if (i == n) return null;
    var j = (i + 1) % n;
    while (j != i) : (j = (j + 1) % n) {
        const b = leaves[j].buf_idx;
        if (direds[b] != null) return b;
    }
    return null;
}

/// The pre-filled target text for a dired copy/rename prompt: the dwim
/// target (the next dired window's directory, per Emacs
/// dired-dwim-target) followed by the selected entry's name, or just the
/// name when there is no other dired window. Caller frees with gpa.
fn diredTargetPrefill(gpa: std.mem.Allocator, direds: []?Dired, root: *Pane, focused: *Pane, name: []const u8) ![]u8 {
    if (dwimTargetBuf(root, focused, direds)) |ti| {
        const base = direds[ti].?.path.items;
        const slash: usize = if (base.len == 0 or base[base.len - 1] == '/') 0 else 1;
        const out = try gpa.alloc(u8, base.len + slash + name.len);
        @memcpy(out[0..base.len], base);
        if (slash == 1) out[base.len] = '/';
        @memcpy(out[base.len + slash ..], name);
        return out;
    }
    return gpa.dupe(u8, name);
}

/// How many entries are marked (excluding "..", which the copy/rename
/// operations skip): the operands of the next C or R, defaulting to the
/// selected entry alone when nothing is marked.
fn diredMarkedCount(d: *const Dired) usize {
    var n: usize = 0;
    for (d.entries.items) |e| {
        if (e.marked and !std.mem.eql(u8, e.name, "..")) n += 1;
    }
    return n;
}

/// Append the indices of the entries an operation (C / R / D) applies to:
/// every marked entry, or just the selected one when nothing is marked.
/// ".." is never included. The indices point into the dired's current
/// entries, so the listing must not change between the call and the
/// operation.
fn diredOpIndices(gpa: std.mem.Allocator, d: *const Dired, out: *std.ArrayList(usize)) void {
    for (d.entries.items, 0..) |en, i| {
        if (en.marked and !std.mem.eql(u8, en.name, "..")) {
            out.append(gpa, i) catch return;
        }
    }
    if (out.items.len == 0 and !std.mem.eql(u8, d.entries.items[d.selected].name, "..")) {
        out.append(gpa, d.selected) catch {};
    }
}

/// Open the dired copy/rename target prompt for `d` (a no-op when the
/// selection is ".." and nothing is marked). With more than one marked
/// entry the query is pre-filled with just the dwim target directory, and
/// each entry lands in it keeping its own name; with none or one it is the
/// full dwim target path of that single entry (the marked one when exactly
/// one is marked, else the selected one).
fn openDiredTargetPrompt(gpa: std.mem.Allocator, direds: *std.ArrayList(?Dired), root: *Pane, focused: *Pane, d: *Dired, prompt: *bool, query: *std.ArrayList(u8)) void {
    const e = d.entries.items[d.selected];
    const marked = diredMarkedCount(d);
    if (marked == 0 and std.mem.eql(u8, e.name, "..")) return;
    prompt.* = true;
    query.clearRetainingCapacity();
    if (marked > 1) {
        if (dwimTargetBuf(root, focused, direds.items)) |ti| {
            const base = direds.items[ti].?.path.items;
            query.appendSlice(gpa, base) catch {};
            if (base.len == 0 or base[base.len - 1] != '/') {
                query.appendSlice(gpa, "/") catch {};
            }
        }
    } else {
        const name = if (marked == 1) blk: {
            for (d.entries.items) |en| {
                if (en.marked) break :blk en.name;
            }
            break :blk e.name;
        } else e.name;
        if (diredTargetPrefill(gpa, direds.items, root, focused, name)) |prefill| {
            defer gpa.free(prefill);
            query.appendSlice(gpa, prefill) catch {};
        } else |_| {
            query.appendSlice(gpa, name) catch {};
        }
    }
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

// The thin box-drawing lines drawn between the panes of a split. A
// vertical split's children are already separated by one blank column,
// and a horizontal split's by one blank row (see renderTree); these fill
// that gap. A separator only spans its own node's rect, so junctions
// with a nested split's separator are T-junctions of adjacent cells.
const split_hline = "─";
const split_vline = "│";

/// Draw a `split_vline` down `height` rows starting at (`col`, `row`),
/// all coordinates relative to `win`.
fn drawVLine(win: vaxis.Window, col: u16, row: u16, height: u16) void {
    var r: u16 = 0;
    while (r < height) : (r += 1) {
        _ = win.printSegment(.{ .text = split_vline, .style = .{} }, .{ .row_offset = row + r, .col_offset = col });
    }
}

/// Draw a `split_hline` across `width` columns starting at (`col`, `row`),
/// all coordinates relative to `win`.
fn drawHLine(win: vaxis.Window, col: u16, row: u16, width: u16) void {
    var c: u16 = 0;
    while (c < width) : (c += 1) {
        _ = win.printSegment(.{ .text = split_hline, .style = .{} }, .{ .row_offset = row, .col_offset = col + c });
    }
}

// --- C-x j shell (suspend-and-swap) -------------------------------------
//
// POSIX-only for now: dropping to a real shell means handing the terminal
// to a child process group (tcsetpgrp), which Windows' console model has
// no equivalent of (ConPTY would be the proper approach there).
//
// The shell owns the whole screen until it exits (exit / C-d) or is
// suspended with C-z, which brings the editor back with the shell still
// stopped — C-x j then resumes that same session.

// Zig 0.16's std.c has no tcsetpgrp/tcgetpgrp bindings on darwin; libc
// does. Only called from the macOS paths (Linux uses std.posix, which
// goes through raw syscalls).
extern "c" fn tcsetpgrp(fd: c_int, pgrp: c_int) c_int;
extern "c" fn tcgetpgrp(fd: c_int) c_int;

const ShellWait = enum { exited, stopped };

/// Block until the shell child `pid` exits or is stopped by a job-control
/// signal (C-z). waitpid with WUNTRACED, bypassing std.process.Child.wait
/// which only reports exit.
fn shellWait(pid: std.posix.pid_t) ShellWait {
    if (comptime builtin.os.tag == .windows) return .exited;
    if (comptime builtin.os.tag == .linux) {
        // Raw wait4 syscall: no libc dependency (james is statically
        // linked on Linux).
        var status: u32 = 0;
        while (true) {
            const rc = std.os.linux.waitpid(pid, &status, std.os.linux.W.UNTRACED);
            if (rc == 0) return if ((status & 0xff) == 0x7f) .stopped else .exited;
            // EINTR: interrupted by a signal, wait again. Anything else
            // (ECHILD etc.) treat as exit.
            const rc_isize: isize = @bitCast(rc);
            if (rc_isize != -@as(isize, @intFromEnum(std.os.linux.E.INTR))) return .exited;
        }
    }
    // macOS (libc is always linked there): WUNTRACED is 2 on BSD too.
    while (true) {
        var status: c_int = 0;
        const rc = std.c.waitpid(pid, &status, 2);
        if (rc == -1) {
            if (std.c._errno().* != @intFromEnum(std.c.E.INTR)) return .exited;
            continue;
        }
        return if ((status & 0xff) == 0x7f) .stopped else .exited;
    }
}

/// Make `pgrp` the foreground process group of the terminal. When the
/// editor reclaims the terminal it is itself a background member, and
/// tcsetpgrp from a background process group would stop it with SIGTTOU —
/// so that signal is blocked around the call. The block is cleared on the
/// shell's exec, so nothing leaks into it.
fn setForeground(tty: *vaxis.Tty, pgrp: std.posix.pid_t) void {
    if (comptime builtin.os.tag == .windows) return;
    if (comptime builtin.os.tag == .macos) {
        // Zig 0.16's std.c has no tcsetpgrp binding on darwin; libc does.
        _ = tcsetpgrp(tty.fd.handle, pgrp);
        return;
    }
    var set = std.posix.sigemptyset();
    std.posix.sigaddset(&set, std.posix.SIG.TTOU);
    var old: std.posix.sigset_t = undefined;
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &set, &old);
    std.posix.tcsetpgrp(tty.fd.handle, pgrp) catch {};
    std.posix.sigprocmask(std.posix.SIG.SETMASK, &old, null);
}

/// The process group currently in the foreground of the terminal — at
/// startup that is the editor's own group, remembered so the shell swap
/// can hand the terminal back to it.
fn shellForegroundPgrp(tty: *vaxis.Tty) ?std.posix.pid_t {
    if (comptime builtin.os.tag == .windows) return null;
    if (comptime builtin.os.tag == .macos) {
        const pgrp = tcgetpgrp(tty.fd.handle);
        if (pgrp == -1) return null;
        return pgrp;
    }
    return std.posix.tcgetpgrp(tty.fd.handle) catch null;
}

/// C-x j: hand the terminal to a real shell. Returns the pid of a shell
/// suspended with C-z (to resume on the next C-x j), or null when the
/// shell exited or none could be started.
fn enterShell(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    loop: *vaxis.Loop(Event),
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    shell_pid: ?std.posix.pid_t,
    editor_pgrp: ?std.posix.pid_t,
) !?std.posix.pid_t {
    if (comptime builtin.os.tag == .windows) {
        return enterShellWindows(gpa, io, environ_map, loop, vx, tty);
    }

    // Stop the input thread first: while the shell owns the terminal the
    // editor must not race it for keystrokes.
    loop.stop();
    // Discard anything the dying input thread posted while the swap was
    // in progress — e.g. a keystroke that woke it when no terminal was
    // there to answer stop()'s DSR. Left in the queue it would leak
    // back into the editor as a phantom key after the shell returns.
    while (loop.tryEvent() catch null) |_| {}

    // Give the shell a pristine terminal: show the cursor, reset SGR and
    // mouse/bracketed-paste modes, leave the alternate screen, and
    // restore the original cooked termios (job control, echo, ...).
    vx.resetState(tty.writer()) catch {};
    std.posix.tcsetattr(tty.fd.handle, .FLUSH, tty.termios) catch {};

    var pid: std.posix.pid_t = undefined;
    var resuming = false;
    if (shell_pid) |p| {
        pid = p;
        resuming = true;
    } else {
        const shell_path = environ_map.get("SHELL") orelse "/bin/sh";
        const child = std.process.spawn(io, .{ .argv = &.{shell_path}, .pgid = 0 }) catch
            std.process.spawn(io, .{ .argv = &.{"/bin/sh"}, .pgid = 0 }) catch {
            // No usable shell: come back to the editor untouched.
            restoreEditor(gpa, vx, tty) catch {};
            loop.start() catch {};
            return null;
        };
        pid = @intCast(child.id.?);
    }

    setForeground(tty, pid);
    if (resuming) std.posix.kill(pid, std.posix.SIG.CONT) catch {};
    const result = shellWait(pid);

    // The shell is done (or stopped): reclaim the terminal and the
    // editor's raw/alt-screen state, forcing a full repaint since the
    // shell may have resized the window or left the terminal anywhere.
    setForeground(tty, editor_pgrp orelse pid);
    restoreEditor(gpa, vx, tty) catch {};
    loop.start() catch {};
    return if (result == .stopped) pid else null;
}

/// The Windows variant of C-x j: the console has no process groups or
/// job-control stop, so the shell (=$SHELL=, =COMSPEC=, or cmd.exe) simply
/// takes the console over and returns when it exits. The console's normal
/// mode and codepage are restored for the shell's duration.
fn enterShellWindows(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    loop: *vaxis.Loop(Event),
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
) !?std.posix.pid_t {
    loop.stop();
    while (loop.tryEvent() catch null) |_| {}

    // Reset the editor's terminal state and hand the console back to the
    // user's normal mode and codepage, so cmd.exe behaves as usual.
    vx.resetState(tty.writer()) catch {};
    vaxis.Tty.setConsoleMode(tty.stdin, tty.initial_input_mode) catch {};
    vaxis.Tty.setConsoleMode(tty.stdout, tty.initial_output_mode) catch {};
    if (vaxis.Tty.SetConsoleOutputCP(tty.initial_codepage) == .FALSE) {}

    const shell_path = environ_map.get("SHELL") orelse
        (environ_map.get("COMSPEC") orelse "cmd.exe");
    var child = std.process.spawn(io, .{ .argv = &.{shell_path} }) catch {
        // No usable shell: come back to the editor untouched.
        restoreEditorWindows(gpa, vx, tty) catch {};
        loop.start() catch {};
        return null;
    };
    _ = child.wait(io) catch {};

    // The shell is done: raw console mode again, back into the alternate
    // screen, forcing a full repaint.
    restoreEditorWindows(gpa, vx, tty) catch {};
    loop.start() catch {};
    return null;
}

/// Re-enter the editor after a shell on Windows: raw console mode and the
/// UTF-8 codepage, the alternate screen, and a resize to force a full
/// repaint.
fn restoreEditorWindows(gpa: std.mem.Allocator, vx: *vaxis.Vaxis, tty: *vaxis.Tty) !void {
    vaxis.Tty.setConsoleMode(tty.stdin, vaxis.Tty.input_raw_mode) catch {};
    vaxis.Tty.setConsoleMode(tty.stdout, vaxis.Tty.output_raw_mode) catch {};
    if (vaxis.Tty.SetConsoleOutputCP(65001) == .FALSE) {}
    try vx.enterAltScreen(tty.writer());
    if (tty.getWinsize() catch null) |ws| {
        if (ws.cols > 0 and ws.rows > 0) {
            vx.resize(gpa, tty.writer(), ws) catch {};
        }
    }
}

fn restoreEditor(gpa: std.mem.Allocator, vx: *vaxis.Vaxis, tty: *vaxis.Tty) !void {
    if (comptime builtin.os.tag == .windows) return;
    _ = vaxis.Tty.makeRaw(tty.fd.handle) catch {};
    try vx.enterAltScreen(tty.writer());
    if (tty.getWinsize() catch null) |ws| {
        if (ws.cols > 0 and ws.rows > 0) {
            vx.resize(gpa, tty.writer(), ws) catch {};
        }
    }
}

/// W in dired: open `path` with the system's default handler — xdg-open
/// on Linux/BSD, `open` on macOS, cmd's =start= on Windows. The opener
/// runs with its stdio thrown away so the editor's terminal stays clean;
/// xdg-open / open hand the file to the desktop and exit, and start
/// returns after ShellExecute launches the app, so waiting for it never
/// blocks the editor on the viewer itself. Returns false when nothing
/// could be spawned (no xdg-open, no desktop session, ...).
fn openExternal(io: std.Io, gpa: std.mem.Allocator, environ_map: *std.process.Environ.Map, path: []const u8) bool {
    if (comptime builtin.os.tag == .windows) {
        // cmd's start builtin ShellExecutes the file with its default
        // handler (a directory gets a file-manager window) and returns
        // immediately. The path is quoted so spaces and & stay safe, and
        // the child inherits the editor's cwd, so relative dired paths
        // resolve exactly where they should.
        const comspec = environ_map.get("COMSPEC") orelse "cmd.exe";
        const quoted = std.fmt.allocPrint(gpa, "\"{s}\"", .{path}) catch return false;
        defer gpa.free(quoted);
        var child = std.process.spawn(io, .{ .argv = &.{ comspec, "/c", "start", "", quoted }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return false;
        _ = child.wait(io) catch return false;
        return true;
    }
    const opener: []const u8 = if (comptime builtin.os.tag == .macos) "open" else "xdg-open";
    var child = std.process.spawn(io, .{ .argv = &.{ opener, path }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return false;
    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Mirror the kill ring onto the system clipboard (OSC 52), so a kill or
/// copy in james is available to other applications — even over ssh, since
/// the terminal forwards the sequence. Terminals without OSC 52 support
/// simply ignore it.
fn syncClipboard(vx: *vaxis.Vaxis, tty: *vaxis.Tty, gpa: std.mem.Allocator, kill_ring: []const u8) void {
    vx.copyToSystemClipboard(tty.writer(), kill_ring, gpa) catch {};
}

// --- terminal-size watchdog ---------------------------------------------
//
// Changing the font size in a terminal like foot or alacritty rescales
// the cell grid, and while these terminals usually do send SIGWINCH for
// it, not every grid change is delivered reliably. Since the editor only
// re-checks its size on events, a terminal that stays quiet would leave
// it stuck at the old dimensions — the content shrinks with gaps to the
// right and bottom — until the next keystroke. A dedicated thread
// re-reads the kernel's ioctl size every 100ms and posts a winsize event
// only when it actually changed, so the editor tracks the terminal on
// its own, fast enough to land well before the next keystroke.
//
// A thread rather than a signal handler: postEvent takes the event
// queue's mutex, and a handler that interrupted the main thread inside a
// queue critical section would deadlock on it. The thread holds no
// locks across the editor's fork for the C-x j shell (spawn does no
// allocation between fork and exec), so the swap stays safe too.
fn sizeWatchdogMain(io: std.Io, tty: *vaxis.Tty, loop: *vaxis.Loop(Event)) void {
    var last: vaxis.Winsize = tty.getWinsize() catch std.mem.zeroes(vaxis.Winsize);
    while (true) {
        io.sleep(std.Io.Duration.fromMilliseconds(100), .real) catch continue;
        const ws = tty.getWinsize() catch continue;
        if (ws.cols == 0 or ws.rows == 0) continue;
        if (last.cols == ws.cols and last.rows == ws.rows) continue;
        // Only remember the size if the event actually got posted, so a
        // full queue doesn't swallow the change forever.
        if (loop.postEvent(.{ .winsize = ws })) |_| {
            last = ws;
        } else |_| {}
    }
}

fn armSizeWatchdog(io: std.Io, tty: *vaxis.Tty, loop: *vaxis.Loop(Event)) void {
    // The future is deliberately dropped: its thread runs for the life of
    // the editor, and the dropped wrapper keeps the context alive.
    _ = io.concurrent(sizeWatchdogMain, .{ io, tty, loop }) catch {};
}

/// Render one dired listing plus its own compact modeline into `win`, which
/// may be the whole screen or one pane of a split. Same shape as
/// `renderPane`, so dired lives inside the current window instead of
/// taking over the whole screen; when a file is chosen it's simply
/// replaced by the newly opened buffer. An active isearch shows its prompt
/// in the modeline; the match is the selected entry.
fn renderDiredPane(win: vaxis.Window, dired: *Dired, is_focused: bool, row_base: u16, height: u16, modeline_buf: []u8, search: ?IsearchView, dired_prompt: ?DiredPromptView, status: ?[]const u8) void {
    const text_height: usize = if (height > 1) height - 1 else height;
    dired.scrollToSelected(text_height);
    // Entries print their own heap-allocated metadata prefix and name
    // (plus a "/" segment for directories), never a stack-local copy —
    // vaxis stores grapheme slices, so a scratch buffer would be clobbered
    // by the next pane rendered in the same frame. An active isearch
    // highlights the matched part of the entry's name.
    const searching = search != null;
    const match: ?Buffer.Pos = if (search) |s| (if (s.failed) null else s.match) else null;
    const query_len: usize = if (search) |s| s.query.len else 0;

    var row: u16 = 0;
    var i = dired.top;
    while (i < dired.entries.items.len and row < text_height) : (i += 1) {
        const e = dired.entries.items[i];
        const style: vaxis.Style = .{};
        // Column 0 is the mark column, like Emacs: "*" for a marked
        // entry, a blank otherwise.
        _ = win.printSegment(.{ .text = if (e.marked) "*" else " ", .style = style }, .{ .row_offset = row_base + row });
        _ = win.printSegment(.{ .text = e.meta, .style = style }, .{ .row_offset = row_base + row, .col_offset = 1 });
        const name_col = 1 + win.gwidth(e.meta);
        const hl: ?Highlight = if (searching) blk: {
            if (match) |m| {
                if (i == m.row) {
                    const start = @min(m.col, e.name.len);
                    const end = @min(m.col + query_len, e.name.len);
                    if (end > start) break :blk .{ .start = start, .end = end };
                }
            }
            break :blk null;
        } else null;
        if (hl) |h| {
            var col = name_col;
            if (h.start > 0) {
                _ = win.printSegment(.{ .text = e.name[0..h.start], .style = style }, .{ .row_offset = row_base + row, .col_offset = col });
                col += win.gwidth(e.name[0..h.start]);
            }
            _ = win.printSegment(.{ .text = e.name[h.start..h.end], .style = highlight_style }, .{ .row_offset = row_base + row, .col_offset = col });
            col += win.gwidth(e.name[h.start..h.end]);
            if (h.end < e.name.len) {
                _ = win.printSegment(.{ .text = e.name[h.end..], .style = style }, .{ .row_offset = row_base + row, .col_offset = col });
            }
        } else {
            _ = win.printSegment(.{ .text = e.name, .style = style }, .{ .row_offset = row_base + row, .col_offset = name_col });
        }
        if (e.is_dir) {
            _ = win.printSegment(.{ .text = "/", .style = style }, .{ .row_offset = row_base + row, .col_offset = name_col + win.gwidth(e.name) });
        }
        row += 1;
    }

    const modeline = if (search) |s| blk: {
        const label = if (s.failed)
            (if (s.backward) "Failing I-search backward" else "Failing I-search")
        else
            (if (s.backward) "I-search backward" else "I-search");
        break :blk std.fmt.bufPrint(modeline_buf, "{s}: {s}", .{ label, s.query }) catch label;
    } else if (dired_prompt) |p| blk: {
        const is_dir = dired.selected < dired.entries.items.len and dired.entries.items[dired.selected].is_dir;
        const name = if (dired.selected < dired.entries.items.len) dired.entries.items[dired.selected].name else "";
        break :blk switch (p.kind) {
            .copy => prompt_blk: {
                const n = diredMarkedCount(dired);
                if (n > 1) break :prompt_blk std.fmt.bufPrint(modeline_buf, "Copy {d} entries to (C-g cancels): {s}", .{ n, p.query }) catch "Copy to: ...";
                break :prompt_blk std.fmt.bufPrint(modeline_buf, "Copy {s}{s} to (C-g cancels): {s}", .{ if (is_dir) "directory " else "", name, p.query }) catch "Copy to: ...";
            },
            .rename => prompt_blk: {
                const n = diredMarkedCount(dired);
                if (n > 1) break :prompt_blk std.fmt.bufPrint(modeline_buf, "Rename {d} entries to (C-g cancels): {s}", .{ n, p.query }) catch "Rename to: ...";
                break :prompt_blk std.fmt.bufPrint(modeline_buf, "Rename {s}{s} to (C-g cancels): {s}", .{ if (is_dir) "directory " else "", name, p.query }) catch "Rename to: ...";
            },
            .create_dir => std.fmt.bufPrint(modeline_buf, "Create directory (C-g cancels): {s}", .{p.query}) catch "Create directory: ...",
            .create_file => std.fmt.bufPrint(modeline_buf, "Create file (C-g cancels): {s}", .{p.query}) catch "Create file: ...",
            .delete => if (diredMarkedCount(dired) > 1)
                std.fmt.bufPrint(modeline_buf, "Delete {d} entries? (y / n / C-g cancels)", .{diredMarkedCount(dired)}) catch "Delete?"
            else
                std.fmt.bufPrint(modeline_buf, "{s}{s}? (y / n / C-g cancels)", .{ if (is_dir) "Recursively delete " else "Delete ", name }) catch "Delete?",
        };
    } else if (status) |m|
        std.fmt.bufPrint(modeline_buf, "{s}", .{m}) catch "Save failed"
    else std.fmt.bufPrint(modeline_buf, "Dired: {s}   (Enter opens, ^ up, q quits)", .{dired.path.items}) catch "Dired";
    const style: vaxis.Style = if (is_focused) highlight_style else .{ .dim = true };
    const text_w = win.gwidth(modeline);
    const fill_n = @min(@as(usize, @intCast(win.width -| text_w)), modeline_buf.len - modeline.len);
    if (fill_n > 0) @memset(modeline_buf[modeline.len .. modeline.len + fill_n], ' ');
    _ = win.printSegment(.{ .text = modeline_buf[0 .. modeline.len + fill_n], .style = style }, .{ .row_offset = row_base + (height -| 1) });

    if (is_focused) {
        // The cursor sits at the start of the entry's name, after the
        // mark column and the metadata prefix, rather than at the start
        // of the line.
        const sel = dired.selected;
        const name_col: u16 = if (sel < dired.entries.items.len)
            1 + win.gwidth(dired.entries.items[sel].meta)
        else
            0;
        win.showCursor(name_col, @intCast(sel - dired.top));
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
    slot_counter: *usize,
    buffers: []*Buffer,
    direds: []?Dired,
    focused: *Pane,
    search: ?IsearchView,
    dired_prompt: ?DiredPromptView,
    status: ?[]const u8,
    focused_h: *usize,
) void {
    if (pane.isLeaf()) {
        // The focused pane's text area height, for C-l (recenter-top-
        // bottom) and anything else that needs to know its window.
        if (pane == focused) focused_h.* = if (height > 1) height - 1 else height;
        // Each leaf gets its own scratch slot, in render order — the
        // buffer must not be shared between panes, since vaxis stores
        // grapheme slices into it until the end of the frame.
        const slot = slot_counter.*;
        slot_counter.* += 1;
        // isearch operates on the focused buffer only: passing the match
        // to every pane would highlight the wrong window and could slice
        // past a shorter line in a neighbouring buffer.
        const pane_search: ?IsearchView = if (pane == focused) search else null;
        const pane_prompt: ?DiredPromptView = if (pane == focused) dired_prompt else null;
        const pane_status: ?[]const u8 = if (pane == focused) status else null;
        const child = win.child(.{ .x_off = x_off, .y_off = y_off, .width = width, .height = height });
        if (direds[pane.buf_idx]) |*d| {
            renderDiredPane(child, d, pane == focused, 0, height, &modeline_bufs[slot % MAX_PANES], pane_search, pane_prompt, pane_status);
        } else {
            renderPane(child, buffers[pane.buf_idx], pane == focused, 0, height, &modeline_bufs[slot % MAX_PANES], pane_search, pane_status);
        }
        return;
    }

    switch (pane.dir) {
        .vertical => {
            const left_w: u16 = @intCast((@as(u32, width) * pane.left_frac) / 256);
            const right_w = width -| (left_w + 1);
            const right_x: i17 = x_off + @as(i17, @intCast(left_w)) + 1;
            // The one blank column between the panes gets the separator.
            drawVLine(win, @intCast(x_off + @as(i17, @intCast(left_w))), y_off, height);
            renderTree(win, pane.left.?, x_off, y_off, left_w, height, modeline_bufs, slot_counter, buffers, direds, focused, search, dired_prompt, status, focused_h);
            renderTree(win, pane.right.?, right_x, y_off, right_w, height, modeline_bufs, slot_counter, buffers, direds, focused, search, dired_prompt, status, focused_h);
        },
        .horizontal => {
            const top_h: u16 = @intCast((@as(u32, height) * pane.left_frac) / 256);
            // The bottom pane starts one row lower than it used to, leaving
            // a blank row between the panes for the separator (mirroring
            // the one blank column of a vertical split).
            drawHLine(win, @intCast(x_off), y_off + top_h, width);
            renderTree(win, pane.left.?, x_off, y_off, width, top_h, modeline_bufs, slot_counter, buffers, direds, focused, search, dired_prompt, status, focused_h);
            renderTree(win, pane.right.?, x_off, y_off + top_h + 1, width, height -| (top_h + 1), modeline_bufs, slot_counter, buffers, direds, focused, search, dired_prompt, status, focused_h);
        },
    }
}

/// The home screen shown when james starts without any file arguments.
/// It's a plain buffer (so movement, search and every C-x command work on
/// it) with no backing file; C-x d / C-x C-f lead somewhere real.
const welcome_text =
    \\          _   _    __  __ _____ ____
    \\         | | / \  |  \/  | ____/ ___|
    \\      _  | |/ _ \ | |\/| |  _| \___ \
    \\     | |_| / ___ \| |  | | |___ ___) |
    \\      \___/_/   \_\_|  |_|_____|____/
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
    \\    C-space       set the mark; C-x C-k kills the region, C-y yanks
    \\    C-w           save (as does C-x C-s)
    \\    C-x u         undo
    \\    C-x C-s       save
    \\    C-x j / C-x c  drop to a real shell (C-z / exit returns)
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

/// True if `path` names a directory (so it should be browsed, not read).
fn isDirectory(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

/// Open a buffer for `path`: an existing buffer if one already visits it
/// (matched by exact path), else a dired buffer if the path is a directory,
/// else a file buffer. Dired buffers are ordinary members of the buffer
/// list — one per directory, so several can be open at once, exactly like
/// Emacs.
fn openBufferOrDired(
    gpa: std.mem.Allocator,
    io: std.Io,
    buffers: *std.ArrayList(*Buffer),
    direds: *std.ArrayList(?Dired),
    path: []const u8,
) !usize {
    for (buffers.items, 0..) |b, idx| {
        if (b.filename) |f| {
            if (std.mem.eql(u8, f, path)) return idx;
        }
    }
    if (isDirectory(io, path)) {
        const new_buf = try gpa.create(Buffer);
        errdefer gpa.destroy(new_buf);
        new_buf.* = Buffer.initEmpty();
        errdefer new_buf.deinit(gpa);
        new_buf.filename = try gpa.dupe(u8, path);

        var d: Dired = .{};
        errdefer d.deinit(gpa);
        try d.open(gpa, io, path);

        // Mirror the listing into the buffer's lines (name, with a "/"
        // for directories) so incremental search and the prompt-mode
        // rendering see the file names like any other buffer. The listing
        // never changes while the dired is open, so this stays in sync.
        for (d.entries.items) |e| {
            var line: std.ArrayList(u8) = .empty;
            errdefer line.deinit(gpa);
            try line.appendSlice(gpa, e.name);
            if (e.is_dir) try line.append(gpa, '/');
            try new_buf.lines.append(gpa, line);
        }

        try direds.append(gpa, d);
        errdefer {
            var popped = direds.pop().?.?;
            popped.deinit(gpa);
        }
        try buffers.append(gpa, new_buf);
        return buffers.items.len - 1;
    }
    const new_buf = try gpa.create(Buffer);
    errdefer gpa.destroy(new_buf);
    new_buf.* = try Buffer.loadFile(gpa, io, path);
    try buffers.append(gpa, new_buf);
    try direds.append(gpa, null);
    return buffers.items.len - 1;
}

/// q / C-g / C-c C-k on a dired buffer: close it (like Emacs's
/// dired-kill-buffer) and leave the focused window showing whatever buffer
/// took its place. Every window's buffer index is fixed up, since the
/// indices of all later buffers shift down by one.
fn closeDiredBuffer(
    gpa: std.mem.Allocator,
    buffers: *std.ArrayList(*Buffer),
    direds: *std.ArrayList(?Dired),
    root: *Pane,
    focused: *Pane,
    current: usize,
) usize {
    if (buffers.items.len <= 1) return current; // never leave zero buffers
    if (current >= direds.items.len or direds.items[current] == null) return current;

    var d = direds.orderedRemove(current).?;
    d.deinit(gpa);
    var b = buffers.orderedRemove(current);
    b.deinit(gpa);
    gpa.destroy(b);

    // Rebase every window's buffer index onto the shrunken list; a pane
    // that showed the closed dired now shows the buffer that took its slot.
    fixupBufIndices(root, current, buffers.items.len);
    const next = @min(current, buffers.items.len - 1);
    focused.buf_idx = next;
    return next;
}

/// True if `path` is `prefix` itself or lives underneath it — used to
/// refuse copying a directory into itself.
fn pathStartsWith(path: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, path, prefix) and
        (path.len == prefix.len or path[prefix.len] == std.fs.path.sep);
}

/// Recursively copy the directory `src` to a new directory `dst`. Files
/// (and symlinks, followed) are copied with std's copyFile; directories
/// recurse. std's copyFile itself cannot copy a directory — it panics with
/// EISDIR — so directories must come through here.
fn copyTree(gpa: std.mem.Allocator, io: std.Io, src: []const u8, dst: []const u8) void {
    std.Io.Dir.cwd().createDirPath(io, dst) catch return;
    var dir = std.Io.Dir.cwd().openDir(io, src, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        switch (entry.kind) {
            .directory => {
                const sub_src = std.fs.path.join(gpa, &.{ src, entry.name }) catch continue;
                defer gpa.free(sub_src);
                const sub_dst = std.fs.path.join(gpa, &.{ dst, entry.name }) catch continue;
                defer gpa.free(sub_dst);
                copyTree(gpa, io, sub_src, sub_dst);
            },
            .file, .sym_link => {
                const sub_src = std.fs.path.join(gpa, &.{ src, entry.name }) catch continue;
                defer gpa.free(sub_src);
                const sub_dst = std.fs.path.join(gpa, &.{ dst, entry.name }) catch continue;
                defer gpa.free(sub_dst);
                std.Io.Dir.cwd().copyFile(sub_src, std.Io.Dir.cwd(), sub_dst, io, .{}) catch {};
            },
            else => {},
        }
    }
}

/// Keep a dired's selection following an isearch match: search moves
/// point, and in a dired buffer point *is* the selected entry.
fn syncDiredSelection(direds: []?Dired, current: usize, buf: *Buffer) void {
    if (direds[current]) |*d| d.selected = buf.cursor_row;
}

/// Winner-mode style window history (C-c j / C-c k): the window layout is
/// snapshotted before each layout change, so you can step back and forward
/// through them. A snapshot is the pane tree serialized in pre-order.
const WinNode = struct {
    is_leaf: bool,
    dir: SplitDir = .vertical,
    left_frac: u8 = 128,
    buf_idx: usize = 0,
};

const WindowSnapshot = struct {
    nodes: std.ArrayList(WinNode) = .empty,
    /// Pre-order index of the focused leaf.
    focused: usize = 0,
    /// The buffer index of the focused pane.
    current: usize = 0,

    fn deinit(self: *WindowSnapshot, gpa: std.mem.Allocator) void {
        self.nodes.deinit(gpa);
    }
};

fn serializePane(gpa: std.mem.Allocator, pane: *Pane, focused: *Pane, out: *std.ArrayList(WinNode), idx: *usize, focused_idx: *usize) !void {
    if (pane == focused) focused_idx.* = idx.*;
    if (pane.isLeaf()) {
        try out.append(gpa, .{ .is_leaf = true, .buf_idx = pane.buf_idx });
    } else {
        try out.append(gpa, .{ .is_leaf = false, .dir = pane.dir, .left_frac = pane.left_frac });
        try serializePane(gpa, pane.left.?, focused, out, idx, focused_idx);
        try serializePane(gpa, pane.right.?, focused, out, idx, focused_idx);
    }
    idx.* += 1;
}

fn deserializePane(gpa: std.mem.Allocator, nodes: []const WinNode, idx: *usize) !*Pane {
    const n = nodes[idx.*];
    idx.* += 1;
    if (n.is_leaf) {
        const p = try gpa.create(Pane);
        p.* = .{ .buf_idx = n.buf_idx };
        return p;
    }
    const p = try gpa.create(Pane);
    p.* = .{ .dir = n.dir, .left_frac = n.left_frac };
    p.left = try deserializePane(gpa, nodes, idx);
    p.right = try deserializePane(gpa, nodes, idx);
    return p;
}

/// The pane at pre-order index `target` (counting splits and leaves alike,
/// matching the serializer).
fn paneAt(pane: *Pane, idx: *usize, target: usize) ?*Pane {
    if (idx.* == target) return pane;
    idx.* += 1;
    if (pane.isLeaf()) return null;
    if (paneAt(pane.left.?, idx, target)) |p| return p;
    return paneAt(pane.right.?, idx, target);
}

fn snapshotWindow(gpa: std.mem.Allocator, root: *Pane, focused: *Pane, current: usize) !WindowSnapshot {
    var snap: WindowSnapshot = .{ .current = current };
    errdefer snap.deinit(gpa);
    var idx: usize = 0;
    var focused_idx: usize = 0;
    try serializePane(gpa, root, focused, &snap.nodes, &idx, &focused_idx);
    snap.focused = focused_idx;
    return snap;
}

fn snapshotsEqual(a: *const WindowSnapshot, b: *const WindowSnapshot) bool {
    if (a.focused != b.focused or a.current != b.current) return false;
    if (a.nodes.items.len != b.nodes.items.len) return false;
    for (a.nodes.items, b.nodes.items) |x, y| {
        if (x.is_leaf != y.is_leaf or x.dir != y.dir or x.left_frac != y.left_frac or x.buf_idx != y.buf_idx) return false;
    }
    return true;
}

/// Record the current layout on the undo stack before a change; identical
/// consecutive states are skipped, and any redo branch is abandoned.
fn recordWindow(gpa: std.mem.Allocator, root: *Pane, focused: *Pane, current: usize, undo: *std.ArrayList(WindowSnapshot), redo: *std.ArrayList(WindowSnapshot)) void {
    var snap = snapshotWindow(gpa, root, focused, current) catch return;
    if (undo.items.len > 0 and snapshotsEqual(&snap, &undo.items[undo.items.len - 1])) {
        snap.deinit(gpa);
        return;
    }
    undo.append(gpa, snap) catch {
        snap.deinit(gpa);
        return;
    };
    for (redo.items) |*s| s.deinit(gpa);
    redo.clearRetainingCapacity();
}

/// Rebuild the tree from `snap`, freeing the old one. Returns the buffer
/// index the focused pane should show.
fn restoreSnapshot(gpa: std.mem.Allocator, root: **Pane, focused: **Pane, snap_in: WindowSnapshot) ?usize {
    var snap = snap_in;
    const result = snap.current;
    root.*.destroy(gpa);
    var idx: usize = 0;
    root.* = deserializePane(gpa, snap.nodes.items, &idx) catch blk: {
        // Shouldn't happen; fall back to a single pane.
        const p = gpa.create(Pane) catch return null;
        p.* = .{ .buf_idx = result };
        break :blk p;
    };
    idx = 0;
    const target = @min(snap.focused, snap.nodes.items.len -| 1);
    focused.* = paneAt(root.*, &idx, target) orelse root.*;
    snap.deinit(gpa);
    return result;
}

/// C-c j: step back to the previous window layout.
fn windowUndo(gpa: std.mem.Allocator, root: **Pane, focused: **Pane, current: usize, undo: *std.ArrayList(WindowSnapshot), redo: *std.ArrayList(WindowSnapshot)) ?usize {
    if (undo.items.len == 0) return null;
    var cur = snapshotWindow(gpa, root.*, focused.*, current) catch return null;
    redo.append(gpa, cur) catch {
        cur.deinit(gpa);
        return null;
    };
    return restoreSnapshot(gpa, root, focused, undo.pop().?);
}

/// C-c k: step forward to the next window layout.
fn windowRedo(gpa: std.mem.Allocator, root: **Pane, focused: **Pane, current: usize, undo: *std.ArrayList(WindowSnapshot), redo: *std.ArrayList(WindowSnapshot)) ?usize {
    if (redo.items.len == 0) return null;
    var cur = snapshotWindow(gpa, root.*, focused.*, current) catch return null;
    undo.append(gpa, cur) catch {
        cur.deinit(gpa);
        return null;
    };
    return restoreSnapshot(gpa, root, focused, redo.pop().?);
}

/// Reload a dired's listing and re-mirror it into its buffer's lines
/// (used after copy / delete change the directory contents).
/// Re-mirror a dired's listing into its buffer's lines (name, with a "/"
/// for directories) so incremental search and the prompt-mode rendering
/// see the file names like any other buffer. The mirror must be rebuilt
/// whenever the listing changes or is re-sorted.
fn mirrorDiredLines(gpa: std.mem.Allocator, buf: *Buffer, d: *const Dired) void {
    for (buf.lines.items) |*l| l.deinit(gpa);
    buf.lines.clearRetainingCapacity();
    for (d.entries.items) |e| {
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(gpa);
        line.appendSlice(gpa, e.name) catch return;
        if (e.is_dir) line.append(gpa, '/') catch return;
        buf.lines.append(gpa, line) catch return;
    }
    // Keep the mirror's cursor on the dired selection (isearch in dired
    // syncs it anyway, but the two should never drift).
    buf.cursor_row = @min(d.selected, buf.lines.items.len -| 1);
}

fn refreshDired(gpa: std.mem.Allocator, io: std.Io, buffers: *std.ArrayList(*Buffer), direds: *std.ArrayList(?Dired), idx: usize) void {
    if (idx >= direds.items.len or direds.items[idx] == null) return;
    const d = &direds.items[idx].?;
    d.refresh(gpa, io) catch return;
    mirrorDiredLines(gpa, buffers.items[idx], d);
}

/// Move a dired's selection (and its buffer mirror) to the entry named
/// `name` after a refresh — used to land on a just-created entry, like
/// Emacs dired moving point to a newly created directory.
fn selectDiredEntry(gpa: std.mem.Allocator, buffers: *std.ArrayList(*Buffer), direds: *std.ArrayList(?Dired), idx: usize, name: []const u8) void {
    if (idx >= direds.items.len or direds.items[idx] == null) return;
    const d = &direds.items[idx].?;
    for (d.entries.items, 0..) |e, i| {
        if (std.mem.eql(u8, e.name, name)) {
            d.selected = i;
            mirrorDiredLines(gpa, buffers.items[idx], d);
            return;
        }
    }
}

/// A named (file, position) pair, like an Emacs bookmark. Persisted to
/// ~/.james-bookmarks as "name<TAB>path<TAB>row<TAB>col" lines.
const Bookmark = struct {
    name: []u8,
    path: []u8,
    row: usize,
    col: usize,
};

/// C-x r m: record the current buffer's file and cursor position under
/// `name`. Setting a name that already exists replaces it, like Emacs.
fn bookmarkSet(gpa: std.mem.Allocator, bookmarks: *std.ArrayList(Bookmark), name: []const u8, buf: *Buffer) void {
    const path = buf.filename orelse return;
    for (bookmarks.items) |*b| {
        if (std.mem.eql(u8, b.name, name)) {
            const new_path = gpa.dupe(u8, path) catch return;
            gpa.free(b.path);
            b.path = new_path;
            b.row = buf.cursor_row;
            b.col = buf.cursor_col;
            return;
        }
    }
    const b: Bookmark = .{
        .name = gpa.dupe(u8, name) catch return,
        .path = gpa.dupe(u8, path) catch return,
        .row = buf.cursor_row,
        .col = buf.cursor_col,
    };
    bookmarks.append(gpa, b) catch return;
}

/// C-x r b / Enter in the bookmark list: open the bookmarked file (or
/// dired) and move point to the recorded position. Returns the buffer
/// index, or null if `name` isn't a bookmark.
fn bookmarkJump(
    gpa: std.mem.Allocator,
    io: std.Io,
    buffers: *std.ArrayList(*Buffer),
    direds: *std.ArrayList(?Dired),
    bookmarks: []const Bookmark,
    name: []const u8,
) ?usize {
    for (bookmarks) |b| {
        if (std.mem.eql(u8, b.name, name)) {
            const idx = openBufferOrDired(gpa, io, buffers, direds, b.path) catch return null;
            const tgt = buffers.items[idx];
            if (direds.items[idx]) |*d| {
                d.selected = @min(b.row, d.entries.items.len -| 1);
            } else if (tgt.lines.items.len > 0) {
                tgt.cursor_row = @min(b.row, tgt.lines.items.len - 1);
                tgt.cursor_col = @min(b.col, tgt.lines.items[tgt.cursor_row].items.len);
            }
            return idx;
        }
    }
    return null;
}

/// Persist bookmarks to ~/.james-bookmarks (tab-separated lines).
fn saveBookmarks(gpa: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map, bookmarks: *const std.ArrayList(Bookmark)) void {
    const home_raw = env_map.get("HOME") orelse return;
    const home = gpa.dupe(u8, home_raw) catch return;
    defer gpa.free(home);
    const path = std.fs.path.join(gpa, &.{ home, ".james-bookmarks" }) catch return;
    defer gpa.free(path);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (bookmarks.items) |b| {
        const line = std.fmt.allocPrint(gpa, "{s}\t{s}\t{d}\t{d}\n", .{ b.name, b.path, b.row, b.col }) catch continue;
        defer gpa.free(line);
        out.appendSlice(gpa, line) catch return;
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items }) catch {};
}

/// Load bookmarks from ~/.james-bookmarks, if it exists.
fn loadBookmarks(gpa: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map, bookmarks: *std.ArrayList(Bookmark)) void {
    const home_raw = env_map.get("HOME") orelse return;
    const home = gpa.dupe(u8, home_raw) catch return;
    defer gpa.free(home);
    const path = std.fs.path.join(gpa, &.{ home, ".james-bookmarks" }) catch return;
    defer gpa.free(path);

    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch return;
    defer gpa.free(contents);

    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const name = fields.next() orelse continue;
        const fpath = fields.next() orelse continue;
        const row = fields.next() orelse continue;
        const col = fields.next() orelse continue;
        if (name.len == 0) continue;
        bookmarks.append(gpa, .{
            .name = gpa.dupe(u8, name) catch continue,
            .path = gpa.dupe(u8, fpath) catch continue,
            .row = std.fmt.parseUnsigned(usize, row, 10) catch 0,
            .col = std.fmt.parseUnsigned(usize, col, 10) catch 0,
        }) catch continue;
    }
}

/// The user's home directory the way the my-jump-keymap elisp sees it:
/// $USERPROFILE on Windows (the elisp's `~` expands there; its explicit
/// `(getenv "USERPROFILE")` check is the same lookup), $HOME elsewhere.
fn jumpHome(env_map: *std.process.Environ.Map) ?[]const u8 {
    if (comptime builtin.os.tag == .windows) {
        return env_map.get("USERPROFILE") orelse env_map.get("HOME");
    }
    return env_map.get("HOME");
}

/// Join path components onto the user's home directory — the `~`
/// expansion the my-jump-keymap elisp gets for free from Emacs. Returns
/// an allocated path, or null when the home directory can't be found.
fn jumpHomePath(gpa: std.mem.Allocator, env_map: *std.process.Environ.Map, sub: []const []const u8) ?[]u8 {
    const home = jumpHome(env_map) orelse return null;
    const parts: [][]const u8 = gpa.alloc([]const u8, 1 + sub.len) catch return null;
    defer gpa.free(parts);
    parts[0] = home;
    @memcpy(parts[1..], sub);
    return std.fs.path.join(gpa, parts) catch null;
}

/// M-l jump: open `path` (file or directory) in the focused window,
/// recording the layout first so winner-mode can undo the jump. A path
/// that can't be opened (e.g. ~/bin on a fresh machine) leaves the
/// current window alone and reports it in the modeline instead of
/// dropping the whole editor, which is what the try-version would do.
fn jumpOpen(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    buffers: *std.ArrayList(*Buffer),
    direds: *std.ArrayList(?Dired),
    root: *Pane,
    focused: *Pane,
    current: usize,
    undo: *std.ArrayList(WindowSnapshot),
    redo: *std.ArrayList(WindowSnapshot),
    status_msg: *?[]const u8,
) usize {
    recordWindow(gpa, root, focused, current, undo, redo);
    const idx = openBufferOrDired(gpa, io, buffers, direds, path) catch {
        status_msg.* = "No such file or directory";
        return current;
    };
    focused.buf_idx = idx;
    return idx;
}

fn fixupBufIndices(pane: *Pane, removed: usize, len: usize) void {
    if (pane.isLeaf()) {
        if (pane.buf_idx > removed) pane.buf_idx -= 1;
        if (pane.buf_idx >= len) pane.buf_idx = len - 1;
        return;
    }
    fixupBufIndices(pane.left.?, removed, len);
    fixupBufIndices(pane.right.?, removed, len);
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
    var direds: std.ArrayList(?Dired) = .empty;
    defer {
        for (direds.items) |*d| {
            if (d.*) |*dd| dd.deinit(gpa);
        }
        direds.deinit(gpa);
    }
    while (args_it.next()) |arg| {
        _ = try openBufferOrDired(gpa, io, &buffers, &direds, arg);
    }
    var current: usize = 0;
    // Index of the cwd dired in the default no-files layout; null when
    // the layout wasn't built (files were given, or scratch.txt couldn't
    // be created in a read-only directory).
    var default_dired_idx: ?usize = null;
    if (buffers.items.len == 0) {
        // No files given: land on the home screen, where C-x d makes it
        // easy to navigate to something real. The scratch buffer and a
        // dired of the current directory join it in a three-pane layout:
        // welcome | (scratch / dired).
        try openWelcome(gpa, &buffers);
        try direds.append(gpa, null);

        // The scratch buffer is tied to a real scratch.txt file (created
        // here if missing, never truncated if it exists), so it saves and
        // prompts like any other file.
        if (std.Io.Dir.cwd().createFile(io, "scratch.txt", .{ .truncate = false })) |f| {
            f.close(io);
            const scratch_idx = try openBufferOrDired(gpa, io, &buffers, &direds, "scratch.txt");
            default_dired_idx = try openBufferOrDired(gpa, io, &buffers, &direds, ".");
            current = scratch_idx;
        } else |_| {
            // A read-only cwd falls back to the plain single-window home
            // screen.
        }
    }

    // Kill ring is shared across all buffers, same as real Emacs.
    var kill_ring: Buffer.KillRing = .{};
    defer kill_ring.deinit(gpa);
    // The last C-y, for M-y (yank-pop); cleared by any other key.
    var yank_state: ?YankState = null;
    var kill_active = false;

    var tty_buf: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);

    // When launched from a .desktop file with Terminal=true (e.g. via
    // rofi drun or a similar launcher), the desktop environment opens a
    // terminal whose shell runs james. On quit that shell is the blank
    // remnant left behind — killing it closes the terminal window. Gated
    // by an env var so an interactive `james` from your own shell never
    // touches it; only the .desktop launch sets the var.
    const kill_parent_on_exit = blk: {
        if (init.environ_map.get("JAMES_KILL_PARENT_ON_EXIT")) |v| {
            if (std.mem.eql(u8, v, "1")) break :blk true;
        }
        break :blk false;
    };
    defer if (comptime builtin.os.tag != .windows) {
        if (kill_parent_on_exit) {
            // Ignore SIGHUP so the terminal's death-rattle (sent to the
            // process group when the shell exits and the terminal closes)
            // doesn't cut our own cleanup short.
            var sa = std.posix.Sigaction{
                .handler = .{ .handler = std.posix.SIG.IGN },
                .mask = switch (builtin.os.tag) {
                    .macos => 0,
                    else => std.posix.sigemptyset(),
                },
                .flags = 0,
            };
            std.posix.sigaction(std.posix.SIG.HUP, &sa, null);
            const ppid = std.posix.getppid();
            if (ppid > 1) std.posix.kill(ppid, std.posix.SIG.HUP) catch {};
        }
    };

    defer tty.deinit();

    // A transient status message for the modeline (e.g. a failed save);
    // shown until the next keypress.
    var status_msg: ?[]const u8 = null;

    // The editor's foreground process group, remembered before the shell
    // swap ever happens so C-x j can hand the terminal back to it.
    const editor_pgrp: ?std.posix.pid_t = shellForegroundPgrp(&tty);

    var vx = try vaxis.init(io, gpa, init.environ_map, .{ .system_clipboard_allocator = gpa });
    defer vx.deinit(null, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    // loop.stop() is deliberately not deferred here. It sends a
    // device-status-report to wake the input thread, then blocks on
    // thread.await() until the terminal answers — and that await can
    // hang (the thread never wakes), leaving the alt screen up as a
    // blank window only C-c could escape. Instead the vx.deinit() and
    // tty.deinit() defers restore the terminal, and the still-blocked
    // input thread is killed when the process exits. The C-x j
    // shell-swap path still calls loop.stop() explicitly — it needs
    // the thread dead before handing the tty to a shell, so the
    // blocking await is correct there.

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    // Size the screen from the kernel's ioctl right away, before the event
    // loop drains the queue: the first winsize event may carry a stale
    // in-band report (see the .winsize handler), and this guarantees the
    // very first frame is already at the true console size no matter what
    // the terminal reported.
    var last_winsize: ?vaxis.Winsize = null;
    // Height of the focused pane's text area, tracked during rendering so
    // C-l (recenter-top-bottom) can center within the right window.
    var focused_text_height: usize = 0;
    // True while consecutive C-l presses are cycling recenter positions
    // (center → top → bottom); any other key resets the next C-l to center.
    var last_was_recenter = false;
    if (tty.getWinsize() catch null) |ws| {
        if (ws.cols > 0 and ws.rows > 0) {
            try vx.resize(gpa, tty.writer(), ws);
            last_winsize = ws;
        }
    }
    // The size watchdog is portable (a thread + ioctl/console query), so
    // every platform gets the same safety net.
    armSizeWatchdog(io, &tty, &loop);

    var pending_ctrl_x = false;
    var pending_ctrl_x_r = false;
    var pending_ctrl_c = false;
    // M-l: the my-jump prefix keymap from the author's Emacs init.el — a
    // jump to a well-known directory is two keys, like every Emacs prefix.
    var pending_alt_l = false;
    var confirming_quit = false;

    // Directory-browser state: one slot per buffer. A buffer with a non-null
    // slot is a dired buffer (its `filename` is the directory being
    // browsed); direds are ordinary buffers, so several can be open at once
    // and they live in windows like any other, matching Emacs.

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

    // The default no-files layout: one vertical split, then the right
    // pane split horizontally — welcome left (full height), scratch
    // top right, the cwd dired bottom right. The scratch pane starts
    // focused.
    if (default_dired_idx) |dired_idx| {
        try root.split(gpa, .vertical);
        root.left.?.buf_idx = 0; // the welcome buffer
        try root.right.?.split(gpa, .horizontal);
        root.right.?.right.?.buf_idx = dired_idx;
        focused = root.right.?.left.?;
        current = focused.buf_idx;
    }

    var switching_buffer = false;
    var switch_query: std.ArrayList(u8) = .empty;
    defer switch_query.deinit(gpa);

    // Bookmarks (C-x r m / C-x r b / C-x r l), like Emacs: a named
    // (file, position) pair, persisted to ~/.james-bookmarks. `bookmark_
    // prompt` is a modal name prompt (set or jump); `bookmark_list` is a
    // modal picker over all bookmarks.
    var bookmarks: std.ArrayList(Bookmark) = .empty;
    defer {
        for (bookmarks.items) |b| {
            gpa.free(b.name);
            gpa.free(b.path);
        }
        bookmarks.deinit(gpa);
    }
    defer saveBookmarks(gpa, io, init.environ_map, &bookmarks);
    loadBookmarks(gpa, io, init.environ_map, &bookmarks);
    var bookmark_prompt: ?enum { set, jump } = null;
    var bookmark_query: std.ArrayList(u8) = .empty;
    defer bookmark_query.deinit(gpa);
    var bookmark_list_active = false;
    var bookmark_list_selected: usize = 0;
    var bookmark_list_top: usize = 0;

    // Buffer-list picker (C-x b): a modal list of every open buffer, the
    // same shape as the bookmark picker — n/p move, Enter switches, q
    // closes. C-x C-f keeps the type-a-name prompt instead.
    var buffer_list_active = false;
    var buffer_list_selected: usize = 0;
    var buffer_list_top: usize = 0;

    // C-x j shell: the pid of a shell suspended with C-z (null while one
    // is merely running, or none). On quit, a stopped shell would be
    // orphaned forever, so kill it.
    var shell_pid: ?std.posix.pid_t = null;
    defer if (comptime builtin.os.tag != .windows) {
        if (shell_pid) |pid| std.posix.kill(pid, std.posix.SIG.KILL) catch {};
    };

    // Dired copy / rename / delete prompts (C / R / D in a dired buffer).
    var dired_copy_prompt = false;
    // What the target prompt will do on Enter (C = copy, R = rename).
    var dired_copy_kind: DiredPromptKind = .copy;
    var dired_copy_query: std.ArrayList(u8) = .empty;
    defer dired_copy_query.deinit(gpa);
    var confirming_delete = false;

    // Winner-mode style window history: layouts are recorded before each
    // change; C-c j / C-c k step back / forward.
    var window_undo: std.ArrayList(WindowSnapshot) = .empty;
    defer {
        for (window_undo.items) |*s| s.deinit(gpa);
        window_undo.deinit(gpa);
    }
    var window_redo: std.ArrayList(WindowSnapshot) = .empty;
    defer {
        for (window_redo.items) |*s| s.deinit(gpa);
        window_redo.deinit(gpa);
    }

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
                if (real.cols > 0 and real.rows > 0) {
                    try vx.resize(gpa, tty.writer(), real);
                    last_winsize = real;
                }
            },
            .paste => |text| {
                defer gpa.free(text);
                // The terminal answered an OSC 52 clipboard request (C-y
                // with an empty kill ring): insert the text at the cursor
                // as a normal edit. Dired buffers are read-only.
                const b: *Buffer = buffers.items[current];
                if (direds.items[current] == null) {
                    b.insertSlice(gpa, text) catch {};
                    // A clipboard paste is yankable too, and heads the
                    // kill ring like any fresh kill.
                    kill_ring.remember(gpa, text, false) catch {};
                }
                yank_state = null;
            },
            .key_press => |key| {
                // C-l cycles recenter positions only when pressed back to
                // back (Emacs recenter-top-bottom); any other key makes the
                // next C-l recenter to the middle again. A transient status
                // message (failed save) lives until the next keypress too.
                if (!key.matches('l', .{ .ctrl = true })) last_was_recenter = false;
                if (!key.matches('y', .{ .alt = true })) yank_state = null;
                status_msg = null;
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
                        syncClipboard(&vx, &tty, gpa, kill_ring.current() orelse "");
                        kill_active = true;
                    } else if (key.matches('w', .{})) {
                        try buf.copyRegion(gpa, &kill_ring, false);
                        syncClipboard(&vx, &tty, gpa, kill_ring.current() orelse "");
                        buf.mark = null;
                        kill_active = true;
                    } else if (key.matches('k', .{ .ctrl = true })) {
                        // C-c C-k: close the dired buffer, if that's what's
                        // showing (the file-browser-close key from the
                        // Jasspa setup).
                        if (direds.items[current] != null) {
                            recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                            current = closeDiredBuffer(gpa, &buffers, &direds, root, focused, current);
                        }
                    } else if (key.matches('o', .{})) {
                        // C-c o: open the bookmark picker (the "favorites"
                        // key from the Jasspa setup — bookmarks are this
                        // editor's favourites).
                        bookmark_list_active = true;
                        bookmark_list_selected = 0;
                        bookmark_list_top = 0;
                    } else if (key.matches('j', .{})) {
                        // C-c j: step back through window layouts
                        // (winner-mode undo).
                        if (windowUndo(gpa, &root, &focused, current, &window_undo, &window_redo)) |nc| {
                            current = nc;
                        }
                    } else if (key.matches('k', .{})) {
                        // C-c k: step forward through window layouts
                        // (winner-mode redo).
                        if (windowRedo(gpa, &root, &focused, current, &window_undo, &window_redo)) |nc| {
                            current = nc;
                        }
                    }
                } else if (switching_buffer) {
                    if (key.matches('g', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                        switching_buffer = false;
                    } else if (key.matches(vaxis.Key.backspace, .{})) {
                        if (switch_query.items.len > 0) _ = switch_query.pop();
                    } else if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true }) or key.matches('m', .{ .ctrl = true })) {
                        switching_buffer = false;
                        const name = std.mem.trim(u8, switch_query.items, " ");
                        if (name.len > 0) {
                            recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                            current = openBufferOrDired(gpa, io, &buffers, &direds, name) catch current;
                            focused.buf_idx = current;
                            kill_active = false;
                        }
                    } else if (key.text) |t| {
                        try switch_query.appendSlice(gpa, t);
                    } else {
                        switching_buffer = false;
                    }
                } else if (bookmark_prompt) |mode| {
                    if (key.matches('g', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                        bookmark_prompt = null;
                    } else if (key.matches(vaxis.Key.backspace, .{})) {
                        if (bookmark_query.items.len > 0) _ = bookmark_query.pop();
                    } else if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true }) or key.matches('m', .{ .ctrl = true })) {
                        const name = std.mem.trim(u8, bookmark_query.items, " ");
                        bookmark_prompt = null;
                        if (name.len > 0) switch (mode) {
                            .set => {
                                bookmarkSet(gpa, &bookmarks, name, buf);
                                saveBookmarks(gpa, io, init.environ_map, &bookmarks);
                            },
                            .jump => if (bookmarkJump(gpa, io, &buffers, &direds, bookmarks.items, name)) |idx| {
                                recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                                current = idx;
                                focused.buf_idx = idx;
                            },
                        };
                    } else if (key.text) |t| {
                        try bookmark_query.appendSlice(gpa, t);
                    } else {
                        bookmark_prompt = null;
                    }
                } else if (dired_copy_prompt) {
                    if (key.matches('g', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                        dired_copy_prompt = false;
                    } else if (key.matches(vaxis.Key.backspace, .{})) {
                        if (dired_copy_query.items.len > 0) _ = dired_copy_query.pop();
                    } else if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true }) or key.matches('m', .{ .ctrl = true })) {
                        const target_raw = std.mem.trim(u8, dired_copy_query.items, " ");
                        dired_copy_prompt = false;
                        if (target_raw.len > 0 and direds.items[current] != null) {
                            const d = &direds.items[current].?;
                            const target = if (std.fs.path.isAbsolute(target_raw))
                                try gpa.dupe(u8, target_raw)
                            else
                                try std.fs.path.join(gpa, &.{ d.path.items, target_raw });
                            defer gpa.free(target);
                            switch (dired_copy_kind) {
                                .create_dir, .create_file => {
                                    // + / _: make a directory or an empty
                                    // file here, then land the selection on
                                    // it, like Emacs dired moving point to a
                                    // newly created directory.
                                    const ok = if (dired_copy_kind == .create_dir) blk: {
                                        std.Io.Dir.cwd().createDirPath(io, target) catch break :blk false;
                                        break :blk true;
                                    } else blk: {
                                        if (std.Io.Dir.cwd().createFile(io, target, .{ .truncate = false })) |f| {
                                            f.close(io);
                                            break :blk true;
                                        } else |_| break :blk false;
                                    };
                                    if (ok) {
                                        refreshDired(gpa, io, &buffers, &direds, current);
                                        selectDiredEntry(gpa, &buffers, &direds, current, std.fs.path.basename(target));
                                    }
                                },
                                .delete => unreachable,
                                else => {
                                    // C / R: apply to every marked entry,
                                    // or just the selected one when nothing
                                    // is marked. A single entry's target is
                                    // the query as typed (it includes the
                                    // name); a marked set treats the query
                                    // as a directory and keeps each entry's
                                    // own name.
                                    var idxs: std.ArrayList(usize) = .empty;
                                    defer idxs.deinit(gpa);
                                    diredOpIndices(gpa, d, &idxs);
                                    var any = false;
                                    for (idxs.items) |i| {
                                        const en = d.entries.items[i];
                                        const src = try std.fs.path.join(gpa, &.{ d.path.items, en.name });
                                        defer gpa.free(src);
                                        const multi = idxs.items.len > 1;
                                        const dst = if (multi)
                                            try std.fs.path.join(gpa, &.{ target, en.name })
                                        else
                                            target;
                                        defer if (multi) gpa.free(dst);
                                        if (!std.mem.eql(u8, src, dst) and !pathStartsWith(dst, src)) {
                                            if (dired_copy_kind == .rename) {
                                                // R: move the entry. rename()
                                                // is the whole job — atomic
                                                // and copy-free — except
                                                // across filesystems, where it
                                                // fails with CrossDevice and
                                                // the fallback is copy +
                                                // delete, like Emacs's
                                                // dired-do-rename.
                                                if (std.Io.Dir.cwd().rename(src, std.Io.Dir.cwd(), dst, io)) |_| {
                                                } else |err| switch (err) {
                                                    error.CrossDevice => {
                                                        if (en.is_dir) {
                                                            copyTree(gpa, io, src, dst);
                                                            std.Io.Dir.cwd().deleteTree(io, src) catch {};
                                                        } else {
                                                            std.Io.Dir.cwd().copyFile(src, std.Io.Dir.cwd(), dst, io, .{}) catch {};
                                                            std.Io.Dir.cwd().deleteFile(io, src) catch {};
                                                        }
                                                    },
                                                    else => {},
                                                }
                                            } else if (en.is_dir) {
                                                copyTree(gpa, io, src, dst);
                                            } else {
                                                std.Io.Dir.cwd().copyFile(src, std.Io.Dir.cwd(), dst, io, .{}) catch {};
                                            }
                                            any = true;
                                        }
                                    }
                                    if (any) {
                                        refreshDired(gpa, io, &buffers, &direds, current);
                                        // The destination dired (the other
                                        // window, if there is one) needs a
                                        // refresh too, so the moved/copied
                                        // entries show up there as well.
                                        if (dwimTargetBuf(root, focused, direds.items)) |ti| {
                                            refreshDired(gpa, io, &buffers, &direds, ti);
                                        }
                                    }
                                },
                            }
                        }
                    } else if (key.text) |t| {
                        try dired_copy_query.appendSlice(gpa, t);
                    } else {
                        dired_copy_prompt = false;
                    }
                } else if (confirming_delete) {
                    if (key.matches('y', .{}) or key.matches('Y', .{})) {
                        confirming_delete = false;
                        if (direds.items[current]) |*d| {
                            // Delete every marked entry, or just the
                            // selected one when nothing is marked.
                            var idxs: std.ArrayList(usize) = .empty;
                            defer idxs.deinit(gpa);
                            diredOpIndices(gpa, d, &idxs);
                            var any = false;
                            for (idxs.items) |i| {
                                const en = d.entries.items[i];
                                const path = try std.fs.path.join(gpa, &.{ d.path.items, en.name });
                                defer gpa.free(path);
                                if (en.is_dir) {
                                    std.Io.Dir.cwd().deleteTree(io, path) catch {};
                                } else {
                                    std.Io.Dir.cwd().deleteFile(io, path) catch {};
                                }
                                any = true;
                            }
                            if (any) refreshDired(gpa, io, &buffers, &direds, current);
                        }
                    } else if (key.matches('n', .{}) or key.matches('n', .{ .ctrl = true }) or key.matches('g', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                        confirming_delete = false;
                    }
                    // Any other key is ignored while confirming.
                } else if (bookmark_list_active) {
                    if (key.matches('g', .{ .ctrl = true }) or key.matches('q', .{})) {
                        bookmark_list_active = false;
                    } else if (key.matches('n', .{}) or key.matches('n', .{ .ctrl = true }) or key.matches(vaxis.Key.down, .{})) {
                        if (bookmark_list_selected + 1 < bookmarks.items.len) bookmark_list_selected += 1;
                    } else if (key.matches('p', .{}) or key.matches('p', .{ .ctrl = true }) or key.matches(vaxis.Key.up, .{})) {
                        if (bookmark_list_selected > 0) bookmark_list_selected -= 1;
                    } else if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true }) or key.matches('m', .{ .ctrl = true })) {
                        if (bookmark_list_selected < bookmarks.items.len) {
                            const name = bookmarks.items[bookmark_list_selected].name;
                            bookmark_list_active = false;
                            if (bookmarkJump(gpa, io, &buffers, &direds, bookmarks.items, name)) |idx| {
                                recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                                current = idx;
                                focused.buf_idx = idx;
                            }
                        }
                    }
                } else if (buffer_list_active) {
                    if (key.matches('g', .{ .ctrl = true }) or key.matches('q', .{})) {
                        buffer_list_active = false;
                    } else if (key.matches('n', .{}) or key.matches('n', .{ .ctrl = true }) or key.matches(vaxis.Key.down, .{})) {
                        if (buffer_list_selected + 1 < buffers.items.len) buffer_list_selected += 1;
                    } else if (key.matches('p', .{}) or key.matches('p', .{ .ctrl = true }) or key.matches(vaxis.Key.up, .{})) {
                        if (buffer_list_selected > 0) buffer_list_selected -= 1;
                    } else if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true }) or key.matches('m', .{ .ctrl = true })) {
                        if (buffer_list_selected < buffers.items.len) {
                            buffer_list_active = false;
                            recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                            current = buffer_list_selected;
                            focused.buf_idx = current;
                            kill_active = false;
                        }
                    }
                } else if (isearch_active) {
                    if (key.matches('g', .{ .ctrl = true })) {
                        buf.cursor_row = isearch_origin.row;
                        buf.cursor_col = isearch_origin.col;
                        syncDiredSelection(direds.items, current, buf);
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
                                syncDiredSelection(direds.items, current, buf);
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
                                syncDiredSelection(direds.items, current, buf);
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
                            syncDiredSelection(direds.items, current, buf);
                            isearch_match = null;
                            isearch_failed = false;
                        } else if (buf.findNext(isearch_query.items, isearch_origin, isearch_dir)) |m| {
                            buf.cursor_row = m.row;
                            buf.cursor_col = m.col;
                            syncDiredSelection(direds.items, current, buf);
                            isearch_match = m;
                            isearch_failed = false;
                        } else {
                            isearch_failed = true;
                        }
                    } else if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true }) or key.matches('m', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                        // Confirm the search: the match stays selected.
                        syncDiredSelection(direds.items, current, buf);
                        isearch_active = false;
                    } else if (key.text) |t| {
                        try isearch_query.appendSlice(gpa, t);
                        if (buf.findNext(isearch_query.items, isearch_origin, isearch_dir)) |m| {
                            buf.cursor_row = m.row;
                            buf.cursor_col = m.col;
                            syncDiredSelection(direds.items, current, buf);
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
                        buf.save(gpa, io) catch {
                            status_msg = "Save failed";
                        };
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
                    } else if (key.matches('b', .{})) {
                        // C-x b: pick from a list of every open buffer, like
                        // the bookmark picker (real Emacs splits C-x b from
                        // C-x C-f too).
                        buffer_list_active = true;
                        buffer_list_selected = current;
                        buffer_list_top = 0;
                    } else if (key.matches('f', .{ .ctrl = true })) {
                        // C-x C-f: open-or-switch by typing a path, the old
                        // C-x b prompt.
                        switching_buffer = true;
                        switch_query.clearRetainingCapacity();
                    } else if (key.matches('r', .{})) {
                        pending_ctrl_x_r = true;
                    } else if (key.matches('d', .{}) or key.matches('m', .{})) {
                        // C-x d / C-x m: open (or switch to) a dired buffer
                        // for the current file's directory.
                        const start = try Dired.startingDir(gpa, buf.filename orelse ".");
                        defer gpa.free(start);
                        current = try openBufferOrDired(gpa, io, &buffers, &direds, start);
                        focused.buf_idx = current;
                    } else if (key.matches('g', .{})) {
                        buf.reread(gpa, io) catch {};
                    } else if (key.matches('h', .{})) {
                        buf.moveBufStart();
                        buf.setMark();
                        buf.moveBufEnd();
                    } else if (key.matches('k', .{ .ctrl = true })) {
                        try buf.killRegion(gpa, &kill_ring, kill_active);
                        syncClipboard(&vx, &tty, gpa, kill_ring.current() orelse "");
                        kill_active = true;
                    } else if (key.matches('2', .{}) or key.matches('3', .{})) {
                        recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                        if (root.leafCount() < MAX_PANES) {
                            const dir: SplitDir = if (key.matches('2', .{})) .horizontal else .vertical;
                            try focused.split(gpa, dir);
                            focused = focused.left.?;
                            current = focused.buf_idx;
                        }
                    } else if (key.matches('1', .{})) {
                        recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                        current = deleteOtherWindows(gpa, root, focused);
                        focused = root;
                    } else if (key.matches('0', .{})) {
                        recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                        if (deleteFocusedPane(gpa, &root, focused)) |nf| {
                            focused = nf;
                            current = focused.buf_idx;
                        }
                    } else if (key.matches('o', .{})) {
                        if (moveFocus(root, focused, 1)) |nf| {
                            focused = nf;
                            current = focused.buf_idx;
                        }
                    } else if (key.matches('j', .{}) or key.matches('c', .{})) {
                        // C-x j / C-x c: drop out of the editor into a real
                        // shell on the terminal. The shell takes over the
                        // whole screen until it exits (exit / C-d) or is
                        // suspended with C-z, which brings the editor back;
                        // C-x j (or C-x c) then resumes that same shell.
                        shell_pid = try enterShell(gpa, io, init.environ_map, &loop, &vx, &tty, shell_pid, editor_pgrp);
                    }
                } else if (pending_ctrl_x_r) {
                    pending_ctrl_x_r = false;
                    if (key.matches('m', .{})) {
                        // C-x r m: bookmark the current position. The name
                        // prompt is prefilled with the file name, like
                        // Emacs.
                        bookmark_prompt = .set;
                        bookmark_query.clearRetainingCapacity();
                        if (buf.filename) |f| {
                            bookmark_query.appendSlice(gpa, std.fs.path.basename(f)) catch {};
                        }
                    } else if (key.matches('b', .{})) {
                        bookmark_prompt = .jump;
                        bookmark_query.clearRetainingCapacity();
                    } else if (key.matches('l', .{})) {
                        bookmark_list_active = true;
                        bookmark_list_selected = 0;
                        bookmark_list_top = 0;
                    }
                } else if (pending_alt_l) {
                    // M-l: the my-jump keymap from the author's Emacs
                    // init.el, a prefix of jumps to well-known places. The
                    // Windows path resolution mirrors the elisp's
                    // system-type checks: %USERPROFILE% / %APPDATA% first,
                    // ~-relative fallbacks second. C-g / Esc aborts the
                    // prefix; any other key is ignored, like an undefined
                    // binding in a real keymap.
                    pending_alt_l = false;
                    if (key.matches('g', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                        // abort the prefix
                    } else if (key.matches('o', .{})) {
                        // M-l o: bookmark-jump — the bookmark picker
                        // (the C-x r l / C-c o favorites list).
                        bookmark_list_active = true;
                        bookmark_list_selected = 0;
                        bookmark_list_top = 0;
                    } else if (key.matches('r', .{})) {
                        // M-l r: switch to the *scratch* buffer — the
                        // scratch.txt file the home-screen layout also
                        // opens (created here if missing, never truncated).
                        var found: ?usize = null;
                        for (buffers.items, 0..) |b, idx| {
                            if (b.filename) |f| {
                                if (std.mem.eql(u8, std.fs.path.basename(f), "scratch.txt")) {
                                    found = idx;
                                    break;
                                }
                            }
                        }
                        if (found) |idx| {
                            recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                            current = idx;
                            focused.buf_idx = idx;
                        } else if (std.Io.Dir.cwd().createFile(io, "scratch.txt", .{ .truncate = false })) |f| {
                            f.close(io);
                            if (openBufferOrDired(gpa, io, &buffers, &direds, "scratch.txt")) |idx| {
                                recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                                current = idx;
                                focused.buf_idx = idx;
                            } else |_| {}
                        } else |_| {
                            // A read-only cwd can't attach the scratch
                            // buffer to anything — say so rather than
                            // silently doing nothing.
                            status_msg = "Can't open scratch buffer";
                        }
                    } else if (key.matches('h', .{})) {
                        // M-l h: the home directory (the elisp's `~`,
                        // USERPROFILE on Windows).
                        if (jumpHome(init.environ_map)) |home| {
                            current = jumpOpen(gpa, io, home, &buffers, &direds, root, focused, current, &window_undo, &window_redo, &status_msg);
                        }
                    } else if (key.matches('b', .{})) {
                        // M-l b: ~/bin.
                        if (jumpHomePath(gpa, init.environ_map, &.{"bin"})) |p| {
                            defer gpa.free(p);
                            current = jumpOpen(gpa, io, p, &buffers, &direds, root, focused, current, &window_undo, &window_redo, &status_msg);
                        }
                    } else if (key.matches('d', .{})) {
                        // M-l d: Downloads — %USERPROFILE%\Downloads on
                        // Windows (or ~/Downloads), ~/Downloads elsewhere,
                        // exactly the elisp's system-type branch.
                        if (jumpHomePath(gpa, init.environ_map, &.{"Downloads"})) |p| {
                            defer gpa.free(p);
                            current = jumpOpen(gpa, io, p, &buffers, &direds, root, focused, current, &window_undo, &window_redo, &status_msg);
                        }
                    } else if (key.matches('g', .{})) {
                        // M-l g: the config directory — %APPDATA% on
                        // Windows (with the elisp's ~/AppData/Roaming
                        // fallback), ~/.config elsewhere.
                        if (comptime builtin.os.tag == .windows) {
                            if (init.environ_map.get("APPDATA")) |appdata| {
                                current = jumpOpen(gpa, io, appdata, &buffers, &direds, root, focused, current, &window_undo, &window_redo, &status_msg);
                            } else if (jumpHomePath(gpa, init.environ_map, &.{ "AppData", "Roaming" })) |p| {
                                defer gpa.free(p);
                                current = jumpOpen(gpa, io, p, &buffers, &direds, root, focused, current, &window_undo, &window_redo, &status_msg);
                            }
                        } else if (jumpHomePath(gpa, init.environ_map, &.{".config"})) |p| {
                            defer gpa.free(p);
                            current = jumpOpen(gpa, io, p, &buffers, &direds, root, focused, current, &window_undo, &window_redo, &status_msg);
                        }
                    } else if (key.matches('i', .{})) {
                        // M-l i: the Emacs-vanilla config directory.
                        if (jumpHomePath(gpa, init.environ_map, &.{ ".emacs.d", "Emacs-vanilla" })) |p| {
                            defer gpa.free(p);
                            current = jumpOpen(gpa, io, p, &buffers, &direds, root, focused, current, &window_undo, &window_redo, &status_msg);
                        }
                    } else if (key.matches('y', .{})) {
                        // M-l y: the Emacs-DIYer config directory.
                        if (jumpHomePath(gpa, init.environ_map, &.{ ".emacs.d", "Emacs-DIYer" })) |p| {
                            defer gpa.free(p);
                            current = jumpOpen(gpa, io, p, &buffers, &direds, root, focused, current, &window_undo, &window_redo, &status_msg);
                        }
                    } else if (key.matches('s', .{})) {
                        // M-l s: the ~/source tree.
                        if (jumpHomePath(gpa, init.environ_map, &.{"source"})) |p| {
                            defer gpa.free(p);
                            current = jumpOpen(gpa, io, p, &buffers, &direds, root, focused, current, &window_undo, &window_redo, &status_msg);
                        }
                    }
                } else {
                    const was_kill = kill_active;
                    kill_active = false;

                    // A dired buffer is showing. It takes over the plain
                    // navigation keys (n/p/Enter/...), but behaves like any
                    // other buffer for everything else — C-x commands (C-x o,
                    // C-x b, splits), C-s search, C-g. This block is
                    // deliberately NOT an else-if chain: keys it doesn't
                    // consume fall through to the editing dispatch below.
                    //
                    // `editing` is captured BEFORE the dired block runs: it
                    // must describe the buffer this keypress actually acts
                    // on. Opening a file from dired changes `current` mid-
                    // keypress, and a stale true value would let the same
                    // key fall through into the editing dispatch against the
                    // zero-line dired buffer.
                    const editing = direds.items[current] == null;
                    if (direds.items[current]) |*d| {
                        if (key.matches('g', .{ .ctrl = true }) or key.matches('q', .{})) {
                            recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                            current = closeDiredBuffer(gpa, &buffers, &direds, root, focused, current);
                        } else if (key.matches('n', .{}) or key.matches('n', .{ .ctrl = true }) or key.matches(vaxis.Key.down, .{})) {
                            d.moveDown();
                        } else if (key.matches('p', .{}) or key.matches('p', .{ .ctrl = true }) or key.matches(vaxis.Key.up, .{})) {
                            d.moveUp();
                        } else if (key.matches('m', .{})) {
                            // m: mark the selected entry (Emacs dired-mark)
                            // and move down, so a run of m's marks a block.
                            d.entries.items[d.selected].marked = true;
                            d.moveDown();
                        } else if (key.matches('u', .{})) {
                            // u: unmark the selected entry (Emacs
                            // dired-unmark) and move down.
                            d.entries.items[d.selected].marked = false;
                            d.moveDown();
                        } else if (key.matches('U', .{})) {
                            // U: unmark every entry (Emacs
                            // dired-unmark-all-marks).
                            for (d.entries.items) |*e| e.marked = false;
                        } else if (key.matches('t', .{})) {
                            // t: toggle marks (Emacs dired-toggle-marks).
                            // Nothing marked marks everything; a partial or
                            // full set is inverted. ".." is never marked.
                            for (d.entries.items) |*en| {
                                if (!std.mem.eql(u8, en.name, "..")) en.marked = !en.marked;
                            }
                        } else if (key.matches('l', .{ .ctrl = true })) {
                            // C-l: recenter the listing on the selection.
                            d.recenterTopBottom(focused_text_height, last_was_recenter);
                            last_was_recenter = true;
                        } else if (key.matches('s', .{})) {
                            // s: dired-sort-toggle-or-edit — toggle between
                            // name and date sorting (the classic dired
                            // pair); from any other sort, back to name.
                            d.sortBy(if (d.sort_mode == .name) Dired.SortMode.date else Dired.SortMode.name);
                            mirrorDiredLines(gpa, buffers.items[current], d);
                            buffers.items[current].cursor_row = d.selected;
                        } else if (key.matches('3', .{}) or key.matches('4', .{}) or key.matches('5', .{}) or key.matches('6', .{})) {
                            // 3-6: sort the listing by size / date / name
                            // / extension (the digit bindings from the
                            // author's Emacs dired setup).
                            d.sortBy(switch (key.text.?[0]) {
                                '3' => Dired.SortMode.size,
                                '4' => Dired.SortMode.date,
                                '5' => Dired.SortMode.name,
                                else => Dired.SortMode.extension,
                            });
                            mirrorDiredLines(gpa, buffers.items[current], d);
                            buffers.items[current].cursor_row = d.selected;
                        } else if (key.matches('e', .{ .alt = true }) or key.matches('^', .{})) {
                            if (try d.upPath(gpa)) |parent| {
                                defer gpa.free(parent);
                                recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                                current = try openBufferOrDired(gpa, io, &buffers, &direds, parent);
                                focused.buf_idx = current;
                            }
                        } else if (key.matches('<', .{ .alt = true })) {
                            // M-<: beginning of the listing.
                            d.selected = 0;
                        } else if (key.matches('>', .{ .alt = true })) {
                            // M->: end of the listing.
                            d.selected = d.entries.items.len -| 1;
                        } else if (key.matches('j', .{ .alt = true })) {
                            // M-j: 5 entries down.
                            d.selected = @min(d.selected + 5, d.entries.items.len -| 1);
                        } else if (key.matches('k', .{ .alt = true })) {
                            // M-k: 5 entries up.
                            d.selected -|= 5;
                        } else if (key.matches('C', .{})) {
                            // C: copy the marked entries, or just the
                            // selected one when nothing is marked (Emacs
                            // dired-do-copy). With another dired window in
                            // the split, the target defaults to that
                            // window's directory (Emacs dired-dwim-target):
                            // a single entry pre-fills the full target path,
                            // a marked set just the target directory, so
                            // Enter copies the entries across as-is.
                            dired_copy_kind = .copy;
                            openDiredTargetPrompt(gpa, &direds, root, focused, d, &dired_copy_prompt, &dired_copy_query);
                        } else if (key.matches('R', .{})) {
                            // R: rename (move) the marked entries, or just
                            // the selected one when nothing is marked
                            // (Emacs dired-do-rename). The same target
                            // prompt as C, but Enter moves the entries
                            // instead of copying them — with another dired
                            // window open, that moves them into that
                            // window's directory.
                            dired_copy_kind = .rename;
                            openDiredTargetPrompt(gpa, &direds, root, focused, d, &dired_copy_prompt, &dired_copy_query);
                        } else if (key.matches('+', .{})) {
                            // +: create a directory in this dired (Emacs
                            // dired). Enter makes it (nested paths too) and
                            // the selection lands on it.
                            dired_copy_kind = .create_dir;
                            dired_copy_prompt = true;
                            dired_copy_query.clearRetainingCapacity();
                        } else if (key.matches('_', .{})) {
                            // _: create an empty file in this dired. Enter
                            // creates it (without clobbering an existing
                            // file) and the selection lands on it.
                            dired_copy_kind = .create_file;
                            dired_copy_prompt = true;
                            dired_copy_query.clearRetainingCapacity();
                        } else if (key.matches('D', .{})) {
                            // D: delete the marked entries, or just the
                            // selected one when nothing is marked (Emacs
                            // dired-do-delete).
                            if (diredMarkedCount(d) > 0 or !std.mem.eql(u8, d.entries.items[d.selected].name, "..")) {
                                confirming_delete = true;
                            }
                        } else if (key.matches('W', .{})) {
                            // W: open the selected entry with the system's
                            // default handler — xdg-open on Linux/BSD, `open`
                            // on macOS, cmd's start on Windows — so a file
                            // opens in its default application and a
                            // directory in the file manager. ".." is skipped
                            // like C and D.
                            const e = d.entries.items[d.selected];
                            if (!std.mem.eql(u8, e.name, "..")) {
                                if (std.fs.path.join(gpa, &.{ d.path.items, e.name }) catch null) |full| {
                                    defer gpa.free(full);
                                    if (!openExternal(io, gpa, init.environ_map, full)) status_msg = "Failed to open externally";
                                }
                            }
                        } else if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true }) or key.matches('f', .{})) {
                            // Enter / C-j, or "f" (the dirlst-find-file key from
                            // the Jasspa setup): open the selected entry.
                            const choice = d.choose(gpa) catch Dired.Choice.none;
                            switch (choice) {
                                .none => {},
                                .open_file, .open_dir => |path| {
                                    defer gpa.free(path);
                                    recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                                    current = try openBufferOrDired(gpa, io, &buffers, &direds, path);
                                    focused.buf_idx = current;
                                },
                            }
                        }
                    }

                    if (key.matches('x', .{ .ctrl = true })) {
                        pending_ctrl_x = true;
                    } else if (key.matches('c', .{ .ctrl = true })) {
                        pending_ctrl_c = true;
                    } else if (key.matches('l', .{ .alt = true })) {
                        // M-l: the my-jump prefix (see the pending_alt_l
                        // branch above).
                        pending_alt_l = true;
                    } else if (key.matches('/', .{ .ctrl = true }) or key.matches(0x1F, .{})) {
                        buf.undo(gpa);
                    } else if (key.matches(';', .{ .ctrl = true })) {
                        if (editing) try buf.toggleComment(gpa);
                    } else if (key.matches('s', .{ .ctrl = true })) {
                        isearch_active = true;
                        isearch_dir = .forward;
                        isearch_origin = if (direds.items[current]) |d|
                            .{ .row = d.selected, .col = 0 }
                        else
                            .{ .row = buf.cursor_row, .col = buf.cursor_col };
                        isearch_match = null;
                        isearch_failed = false;
                        isearch_query.clearRetainingCapacity();
                    } else if (key.matches('r', .{ .ctrl = true })) {
                        isearch_active = true;
                        isearch_dir = .backward;
                        isearch_origin = if (direds.items[current]) |d|
                            .{ .row = d.selected, .col = 0 }
                        else
                            .{ .row = buf.cursor_row, .col = buf.cursor_col };
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
                        syncClipboard(&vx, &tty, gpa, kill_ring.current() orelse "");
                        kill_active = true;
                    } else if (key.matches('w', .{ .ctrl = true })) {
                        // C-w is save-buffer; kill-region lives at C-x C-k.
                        buf.save(gpa, io) catch {
                            status_msg = "Save failed";
                        };
                    } else if (key.matches('w', .{ .alt = true })) {
                        try buf.copyRegion(gpa, &kill_ring, was_kill);
                        syncClipboard(&vx, &tty, gpa, kill_ring.current() orelse "");
                        buf.mark = null; // copy drops the mark, like C-c w
                        kill_active = true;
                    } else if (key.matches('y', .{ .ctrl = true })) {
                        if (editing) {
                            if (kill_ring.current()) |text| {
                                const start: Buffer.Pos = .{ .row = buf.cursor_row, .col = buf.cursor_col };
                                try buf.yank(gpa, text);
                                yank_state = .{
                                    .buf_idx = current,
                                    .entry = kill_ring.head,
                                    .start = start,
                                    .end = .{ .row = buf.cursor_row, .col = buf.cursor_col },
                                };
                            } else {
                                // Nothing has been killed yet: yank the
                                // system clipboard instead (Emacs consults
                                // the interprogram clipboard when the kill
                                // ring is empty). The terminal answers
                                // asynchronously with a .paste event.
                                vx.requestSystemClipboard(tty.writer()) catch {};
                            }
                        }
                    } else if (key.matches('y', .{ .alt = true })) {
                        // M-y: yank-pop — replace the previous yank with
                        // the next older kill, staying inside the original
                        // yank's undo step.
                        if (editing) {
                            if (yank_state) |ys| {
                                if (ys.buf_idx == current and kill_ring.count() > 1) {
                                    const next = kill_ring.beforeIdx(ys.entry, 1);
                                    try buf.yankPop(gpa, kill_ring.at(next), ys.start, ys.end);
                                    yank_state = .{
                                        .buf_idx = current,
                                        .entry = next,
                                        .start = ys.start,
                                        .end = .{ .row = buf.cursor_row, .col = buf.cursor_col },
                                    };
                                }
                            }
                        }
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
                    } else if (key.matches('l', .{ .ctrl = true })) {
                        // C-l: recenter the window on the cursor line
                        // (recenter-top-bottom), within the focused pane.
                        buf.recenterTopBottom(focused_text_height, last_was_recenter);
                        last_was_recenter = true;
                    } else if (key.matches('d', .{ .ctrl = true }) or key.matches(vaxis.Key.delete, .{})) {
                        try buf.deleteForward(gpa);
                    } else if (key.matches(vaxis.Key.backspace, .{})) {
                        try buf.deleteBackward(gpa);
                    } else if (key.matches(';', .{ .alt = true }) or key.matches('m', .{ .alt = true })) {
                        recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                        if (root.leafCount() < MAX_PANES) {
                            const dir: SplitDir = if (key.matches(';', .{ .alt = true })) .vertical else .horizontal;
                            try focused.split(gpa, dir);
                            focused = focused.right.?;
                            current = focused.buf_idx;
                        }
                    } else if (key.matches('q', .{ .alt = true }) or key.matches('\'', .{ .alt = true })) {
                        // M-q / M-': delete the current window, giving its
                        // space to the sibling.
                        recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                        if (deleteFocusedPane(gpa, &root, focused)) |nf| {
                            focused = nf;
                            current = focused.buf_idx;
                        }
                    } else if (key.matches('a', .{ .alt = true })) {
                        recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                        current = deleteOtherWindows(gpa, root, focused);
                        focused = root;
                    } else if (editing and key.matches('e', .{ .alt = true })) {
                        // M-e: dired-jump — open dired at the current
                        // file's directory (in a dired buffer M-e goes up,
                        // matching my/dired-jump-or-up, and is handled above
                        // — this branch must not fire for direds, or the
                        // two M-e handlers would fight: e.g. at the root
                        // "/" going up does nothing, while dirname("/") is
                        // null and dired-jump would fall back to ".").
                        const start = try Dired.startingDir(gpa, buf.filename orelse ".");
                        defer gpa.free(start);
                        recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                        current = try openBufferOrDired(gpa, io, &buffers, &direds, start);
                        focused.buf_idx = current;
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
                        recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                        root.resizeDivider(focused, .vertical, -8);
                    } else if (key.matches('l', .{ .alt = true, .ctrl = true })) {
                        recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                        root.resizeDivider(focused, .vertical, 8);
                    } else if (key.matches('k', .{ .alt = true, .ctrl = true })) {
                        recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                        root.resizeDivider(focused, .horizontal, -8);
                    } else if (key.matches('j', .{ .alt = true, .ctrl = true })) {
                        recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                        root.resizeDivider(focused, .horizontal, 8);
                    } else if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true }) or key.matches('m', .{ .ctrl = true })) {
                        if (editing) try buf.insertNewline(gpa);
                    } else if (key.text) |t| {
                        // Dired buffers are read-only: typing is ignored.
                        if (editing) try buf.insertSlice(gpa, t);
                    }
                }
            },
        }

        // Resize anchor: re-check the kernel's ioctl size every frame. A
        // terminal that fails to deliver its resize notification (a missed
        // SIGWINCH or a dropped in-band report) would otherwise leave the
        // screen stuck at a fraction of the real size indefinitely — the
        // ioctl is always authoritative on a real terminal, and comparing
        // against it here is one cheap syscall per event.
        if (tty.getWinsize() catch null) |ws| {
            if (ws.cols > 0 and ws.rows > 0) {
                const changed = if (last_winsize) |lw| lw.cols != ws.cols or lw.rows != ws.rows else true;
                if (changed) {
                    try vx.resize(gpa, tty.writer(), ws);
                    last_winsize = ws;
                }
            }
        }

        const buf: *Buffer = buffers.items[current];
        const win = vx.window();
        win.clear();
        // The blinking block cursor is the position indicator: there are no
        // reverse-video line highlights, so this is what marks the dired
        // selection, the isearch match, and point.
        win.setCursorShape(.block_blink);

        const text_height: usize = if (win.height > 1) win.height - 1 else win.height;
        // The focused pane's text area (the whole window when unsplit),
        // remembered for C-l so it can recenter within the right window.
        focused_text_height = text_height;
        // Dired and isearch are not modal: they render inside whichever
        // pane they apply to, leaving the window layout untouched. Only the
        // prompt-style modes take over the whole screen.
        const is_modal = confirming_quit or switching_buffer or bookmark_prompt != null or bookmark_list_active or buffer_list_active;

        const search_view: ?IsearchView = if (isearch_active)
            .{ .failed = isearch_failed, .match = isearch_match, .query = isearch_query.items, .backward = isearch_dir == .backward }
        else
            null;

        const dired_prompt_view: ?DiredPromptView = if (dired_copy_prompt)
            .{ .kind = dired_copy_kind, .query = dired_copy_query.items }
        else if (confirming_delete)
            .{ .kind = .delete }
        else
            null;

        if (!is_modal and !root.isLeaf()) {
            var modeline_bufs: [MAX_PANES][1024]u8 = undefined;
            var slot_counter: usize = 0;
            renderTree(win, root, 0, 0, win.width, win.height, &modeline_bufs, &slot_counter, buffers.items, direds.items, focused, search_view, dired_prompt_view, status_msg, &focused_text_height);
            try vx.render(tty.writer());
            continue;
        }

        if (bookmark_list_active) {
            // The bookmark picker: one name per row, Enter jumps.
            if (text_height > 0) {
                if (bookmark_list_selected < bookmark_list_top) {
                    bookmark_list_top = bookmark_list_selected;
                } else if (bookmark_list_selected >= bookmark_list_top + text_height) {
                    bookmark_list_top = bookmark_list_selected - text_height + 1;
                }
            }
            var list_row: u16 = 0;
            var i = bookmark_list_top;
            while (i < bookmarks.items.len and list_row < text_height) : (i += 1) {
                // The bookmark name, then its base directory dimmed after
                // it. For a dired bookmark the path is a directory, so it
                // shows itself; for a file bookmark, its parent directory.
                const b = bookmarks.items[i];
                _ = win.printSegment(.{ .text = b.name, .style = .{} }, .{ .row_offset = list_row });
                const dir: ?[]const u8 = if (isDirectory(io, b.path))
                    b.path
                else
                    std.fs.path.dirname(b.path);
                if (dir) |d| {
                    _ = win.printSegment(.{ .text = d, .style = .{ .dim = true } }, .{ .row_offset = list_row, .col_offset = win.gwidth(b.name) + 2 });
                }
                list_row += 1;
            }
            var list_ml_buf: [2048]u8 = undefined;
            const list_ml = std.fmt.bufPrint(&list_ml_buf, "Bookmarks ({d}/{d})   (Enter jumps, n/p move, q closes)", .{
                bookmark_list_selected + 1,
                bookmarks.items.len,
            }) catch "Bookmarks";
            _ = win.printSegment(.{ .text = list_ml, .style = .{} }, .{ .row_offset = win.height -| 1 });
            // No highlights: the block cursor marks the selected bookmark.
            win.showCursor(0, @intCast(bookmark_list_selected - bookmark_list_top));
            try vx.render(tty.writer());
            continue;
        }

        if (buffer_list_active) {
            // The buffer picker: one buffer name per row, Enter switches.
            if (text_height > 0) {
                if (buffer_list_selected < buffer_list_top) {
                    buffer_list_top = buffer_list_selected;
                } else if (buffer_list_selected >= buffer_list_top + text_height) {
                    buffer_list_top = buffer_list_selected - text_height + 1;
                }
            }
            var list_row: u16 = 0;
            var i = buffer_list_top;
            while (i < buffers.items.len and list_row < text_height) : (i += 1) {
                const b: *Buffer = buffers.items[i];
                _ = win.printSegment(.{ .text = b.display_name orelse b.filename orelse "?", .style = .{} }, .{ .row_offset = list_row });
                list_row += 1;
            }
            var list_ml_buf: [2048]u8 = undefined;
            const list_ml = std.fmt.bufPrint(&list_ml_buf, "Buffers ({d}/{d})   (Enter switches, n/p move, q closes)", .{
                buffer_list_selected + 1,
                buffers.items.len,
            }) catch "Buffers";
            _ = win.printSegment(.{ .text = list_ml, .style = .{} }, .{ .row_offset = win.height -| 1 });
            // No highlights: the block cursor marks the selected buffer.
            win.showCursor(0, if (text_height > 0) @intCast(buffer_list_selected - buffer_list_top) else 0);
            try vx.render(tty.writer());
            continue;
        }

        if (!is_modal) {
            if (direds.items[current]) |*d| {
                var modeline_buf: [2048]u8 = undefined;
                renderDiredPane(win, d, true, 0, win.height, &modeline_buf, search_view, dired_prompt_view, status_msg);
                try vx.render(tty.writer());
                continue;
            }
        }
        // The prompt-style modal states (buffer switch, quit confirm)
        // render a dired through the normal buffer renderer instead: its
        // lines mirror the listing, so the prompt modeline works exactly as
        // it does in a file buffer. isearch is handled natively above.

        buf.scrollToCursor(text_height);
        var row: u16 = 0;
        var i = buf.top_line;
        while (i < buf.lines.items.len and row < text_height) : (i += 1) {
            const h = highlightFor(buf, i, search_view != null, if (search_view) |s| (if (s.failed) null else s.match) else null, if (search_view) |s| s.query.len else 0);
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
        else if (status_msg) |m|
            std.fmt.bufPrint(&modeline_buf, "{s}", .{m}) catch "Save failed"
        else if (switching_buffer)
            std.fmt.bufPrint(&modeline_buf, "Switch to buffer (open if new): {s}", .{switch_query.items}) catch "Switch to buffer: ..."
        else if (bookmark_prompt) |mode| blk: {
            break :blk if (mode == .set)
                (std.fmt.bufPrint(&modeline_buf, "Bookmark name (C-g cancels): {s}", .{bookmark_query.items}) catch "Bookmark name")
            else
                (std.fmt.bufPrint(&modeline_buf, "Jump to bookmark (C-g cancels): {s}", .{bookmark_query.items}) catch "Jump to bookmark");
        } else if (isearch_active) blk: {
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
            break :blk std.fmt.bufPrint(&modeline_buf, "{s}-- {s}{s}{s}{s}  L{d}:C{d} --", .{
                // Emacs-style modified marker in the bottom-left corner of
                // the modeline.
                if (buf.dirty) "*" else "",
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
