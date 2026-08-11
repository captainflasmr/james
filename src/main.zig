const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const windows = std.os.windows;
const Buffer = @import("Buffer.zig");
const Dired = @import("Dired.zig");
const build_options = @import("build_options");

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

/// Tab stops for displaying tabs: every `tab_width` columns (Emacs
/// tab-width; the author's config sets 4). A raw tab byte is dropped by
/// vaxis (its measured width is 0), so lines containing tabs are
/// expanded to spaces at render time (see expandTabs) — without it, the
/// tab-separated fields of the bookmarks file glue together.
const tab_width: usize = 4;

const Highlight = struct { start: usize, end: usize };

/// Build the segments needed to draw a line, reverse-videoing the given
/// column range (if any). `empty_line_marker` shows a single highlighted
/// space for a blank line that's fully inside a highlighted span, since
/// there's otherwise nothing to invert. `current` makes the whole line
/// bold — the cursor's line stands out even where the block cursor is
/// hard to see, and the reverse-video highlight merges with it rather
/// than replacing it. `storage` just gives the segments somewhere to
/// live; at most 3 are ever needed (before/inside/after).
fn lineSegments(line: []const u8, hl: ?Highlight, empty_line_marker: bool, storage: *[3]vaxis.Segment, current: bool) []const vaxis.Segment {
    const base_style: vaxis.Style = if (current) .{ .bold = true } else .{};
    const hl_style: vaxis.Style = if (current) .{ .reverse = true, .bold = true } else highlight_style;
    const range = hl orelse {
        storage[0] = .{ .text = line, .style = base_style };
        return storage[0..1];
    };

    if (line.len == 0) {
        storage[0] = if (empty_line_marker)
            .{ .text = " ", .style = hl_style }
        else
            .{ .text = line, .style = base_style };
        return storage[0..1];
    }

    var n: usize = 0;
    if (range.start > 0) {
        storage[n] = .{ .text = line[0..range.start], .style = base_style };
        n += 1;
    }
    if (range.end > range.start) {
        storage[n] = .{ .text = line[range.start..range.end], .style = hl_style };
        n += 1;
    }
    if (range.end < line.len) {
        storage[n] = .{ .text = line[range.end..], .style = base_style };
        n += 1;
    }
    if (n == 0) {
        storage[0] = .{ .text = line, .style = base_style };
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

// --- visual (soft-wrapped) lines ----------------------------------------
//
// Long logical lines wrap at the pane width, so the cursor can be on any
// visual line of a wrapped paragraph. These helpers share one wrap math —
// the same grapheme-accumulation rule vaxis uses to draw — so movement
// (C-n / C-p / C-e), scrolling, recentering and the cursor position all
// agree with what is on screen. They live here rather than in Buffer.zig
// because they need the terminal's display width tables.

/// The display-width contribution of a tab at display column `col`:
/// spaces up to the next tab stop.
fn tabStop(col: usize) usize {
    return tab_width - (col % tab_width);
}

/// The display width of `line[start..end]` with tabs counted up to the
/// next tab stop — the raw byte range as it maps into the expanded
/// rendering.
fn tabAwareWidth(line: []const u8, start: usize, end: usize, method: vaxis.gwidth.Method) usize {
    var col: usize = 0;
    var it = vaxis.unicode.graphemeIterator(line[start..end]);
    while (it.next()) |g| {
        const s = g.bytes(line[start..end]);
        if (std.mem.eql(u8, s, "\t")) {
            col += tabStop(col);
        } else {
            col += vaxis.gwidth.gwidth(s, method);
        }
    }
    return col;
}

/// The byte offsets at which `line`'s visual (wrapped) lines begin, for a
/// pane `width` columns wide: offsets[0] = 0, each later entry a wrap
/// point. Returns the segment count.
fn wrapOffsets(line: []const u8, wrap: bool, width: usize, method: vaxis.gwidth.Method, offsets: *[1024]usize) usize {
    if (!wrap) {
        // Soft wrap off (M-z): every line is a single visual line.
        offsets[0] = 0;
        return 1;
    }
    if (line.len == 0 or width == 0) {
        offsets[0] = 0;
        return 1;
    }
    var n: usize = 1;
    offsets[0] = 0;
    var vis_col: usize = 0;
    // Tabs count up to the next tab stop from the LOGICAL line's start
    // (not the wrap), so the stop is computed on the absolute column.
    var abs_col: usize = 0;
    var it = vaxis.unicode.graphemeIterator(line);
    while (it.next()) |g| {
        const s = g.bytes(line);
        const w = if (std.mem.eql(u8, s, "\t")) tabStop(abs_col) else vaxis.gwidth.gwidth(s, method);
        if (w == 0) continue;
        if (vis_col >= width) {
            if (n >= 1024) break;
            offsets[n] = g.start;
            n += 1;
            vis_col = 0;
        }
        vis_col += w;
        abs_col += w;
    }
    return n;
}

/// How many visual lines `line` occupies at `width`.
fn wrapCount(line: []const u8, wrap: bool, width: usize, method: vaxis.gwidth.Method) usize {
    var offsets: [1024]usize = undefined;
    return wrapOffsets(line, wrap, width, method, &offsets);
}

/// The display column of byte offset `col` within the visual segment of
/// `line` starting at `start`.
fn visualColAt(line: []const u8, start: usize, col: usize, method: vaxis.gwidth.Method) usize {
    // Tab stops are counted from the logical line's start.
    const base = tabAwareWidth(line, 0, start, method);
    var v: usize = 0;
    var it = vaxis.unicode.graphemeIterator(line[start..col]);
    while (it.next()) |g| {
        const s = g.bytes(line[start..col]);
        if (std.mem.eql(u8, s, "\t")) {
            v += tabStop(base + v);
        } else {
            v += vaxis.gwidth.gwidth(s, method);
        }
    }
    return v;
}

/// The byte offset in `line`, at or after segment start `start`, where the
/// display column first reaches `target` — clamped to the segment's end,
/// so it never crosses a wrap point.
fn byteAtVisualCol(line: []const u8, start: usize, target: usize, width: usize, method: vaxis.gwidth.Method) usize {
    // Tab stops are counted from the logical line's start.
    const base = tabAwareWidth(line, 0, start, method);
    var vis_col: usize = 0;
    var it = vaxis.unicode.graphemeIterator(line[start..]);
    while (it.next()) |g| {
        const s = g.bytes(line[start..]);
        const w = if (std.mem.eql(u8, s, "\t")) tabStop(base + vis_col) else vaxis.gwidth.gwidth(s, method);
        if (w == 0) continue;
        if (vis_col >= width) return start + g.start; // the segment's wrap point
        if (vis_col + w > target) return start + g.start; // reached the target column
        vis_col += w;
    }
    return line.len;
}

/// The byte offset in `line` of the first grapheme at or after display
/// column `target` — the cut where a horizontally scrolled view starts
/// drawing (the hscroll offset). Unlike byteAtVisualCol there is no
/// width clamp: the scroll can reach past one windowful. Tabs are
/// already expanded in the caller's line, so the columns count straight
/// graphemes.
fn byteAtColumn(line: []const u8, target: usize, method: vaxis.gwidth.Method) usize {
    var vis_col: usize = 0;
    var it = vaxis.unicode.graphemeIterator(line);
    while (it.next()) |g| {
        const s = g.bytes(line);
        const w = vaxis.gwidth.gwidth(s, method);
        if (w == 0) continue;
        if (vis_col + w > target) return g.start;
        vis_col += w;
    }
    return line.len;
}

/// Heap allocations made while rendering one frame (the tab expansions):
/// vaxis keeps grapheme slices of printed text until the frame renders,
/// so the expansions must outlive the print calls; they're freed after
/// each vx.render (see FrameAllocs.reset).
const FrameAllocs = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList([]u8) = .empty,

    fn reset(self: *FrameAllocs) void {
        for (self.items.items) |a| self.gpa.free(a);
        self.items.clearRetainingCapacity();
    }
};

/// Expand the tabs in `line` to the spaces up to the next tab stop —
/// vaxis drops a raw tab byte (measured width 0), which would glue
/// tab-separated fields together. The expansion is heap-allocated and
/// recorded on `frame` for freeing after the frame renders. Returns null
/// when the line has no tabs, so the common case allocates nothing.
fn expandTabs(frame: *FrameAllocs, line: []const u8, method: vaxis.gwidth.Method) ?[]u8 {
    if (std.mem.indexOfScalar(u8, line, '\t') == null) return null;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(frame.gpa);
    var col: usize = 0;
    var it = vaxis.unicode.graphemeIterator(line);
    while (it.next()) |g| {
        const s = g.bytes(line);
        if (std.mem.eql(u8, s, "\t")) {
            const w = tabStop(col);
            for (0..w) |_| out.append(frame.gpa, ' ') catch return null;
            col += w;
        } else {
            out.appendSlice(frame.gpa, s) catch return null;
            col += vaxis.gwidth.gwidth(s, method);
        }
    }
    const owned = out.toOwnedSlice(frame.gpa) catch return null;
    frame.items.append(frame.gpa, owned) catch {
        frame.gpa.free(owned);
        return null;
    };
    return owned;
}

/// The whitespace-mode display text of `line` (C-z e, Emacs
/// whitespace-mode): every space shows as a · middle dot, every tab as
/// a » marker padded with spaces up to its tab stop — so the line's
/// display width, and with it the wrap, cursor and highlight math, is
/// unchanged — and a $ newline marker at the end when `show_newline`
/// (every line but the buffer's last, which has no line break to mark).
/// Returns null when the line already renders as-is. The result is
/// heap-allocated and recorded on `frame` for freeing after the frame
/// renders, like the expandTabs results.
fn whitespaceLine(frame: *FrameAllocs, line: []const u8, show_newline: bool, method: vaxis.gwidth.Method) ?[]u8 {
    if (!show_newline and std.mem.indexOfAny(u8, line, " \t") == null) return null;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(frame.gpa);
    var col: usize = 0;
    var it = vaxis.unicode.graphemeIterator(line);
    while (it.next()) |g| {
        const s = g.bytes(line);
        if (std.mem.eql(u8, s, " ")) {
            out.appendSlice(frame.gpa, "·") catch return null;
            col += 1;
        } else if (std.mem.eql(u8, s, "\t")) {
            const w = tabStop(col);
            out.appendSlice(frame.gpa, "»") catch return null;
            for (1..w) |_| out.append(frame.gpa, ' ') catch return null;
            col += w;
        } else {
            out.appendSlice(frame.gpa, s) catch return null;
            col += vaxis.gwidth.gwidth(s, method);
        }
    }
    if (show_newline) out.append(frame.gpa, '$') catch return null;
    const owned = out.toOwnedSlice(frame.gpa) catch return null;
    frame.items.append(frame.gpa, owned) catch {
        frame.gpa.free(owned);
        return null;
    };
    return owned;
}

/// The byte offset in the whitespace-display text (see whitespaceLine)
/// of raw byte offset `p` in `line`: every space and tab before it adds
/// its display expansion (a space becomes the 2-byte ·, a tab the 2-byte
/// » plus its stop padding). `p` should sit on a grapheme boundary — the
/// highlight ranges are byte offsets into the raw line.
fn whitespaceDispAt(line: []const u8, p: usize, method: vaxis.gwidth.Method) usize {
    var col: usize = 0;
    var disp: usize = 0;
    var it = vaxis.unicode.graphemeIterator(line[0..p]);
    while (it.next()) |g| {
        const s = g.bytes(line[0..p]);
        if (std.mem.eql(u8, s, " ")) {
            col += 1;
            disp += 2;
        } else if (std.mem.eql(u8, s, "\t")) {
            const w = tabStop(col);
            col += w;
            disp += w + 1;
        } else {
            col += vaxis.gwidth.gwidth(s, method);
            disp += s.len;
        }
    }
    return disp;
}

/// The longest prefix of `text` that fits in `width` display columns —
/// for truncated (soft-wrap-off) lines. `text` must already have its
/// tabs expanded (the render path passes the expandTabs result).
fn clipToWidth(text: []const u8, width: usize, method: vaxis.gwidth.Method) []const u8 {
    if (width == 0) return "";
    var col: usize = 0;
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |g| {
        const s = g.bytes(text);
        const w = vaxis.gwidth.gwidth(s, method);
        if (col + w > width) return text[0..g.start];
        col += w;
    }
    return text;
}

/// The visual segment of the cursor within its logical line, and its
/// display column within that segment.
const CursorVisual = struct { seg: usize, col: usize };

fn cursorVisual(buf: *const Buffer, width: usize, method: vaxis.gwidth.Method) CursorVisual {
    const line = buf.lines.items[buf.cursor_row].items;
    var offsets: [1024]usize = undefined;
    const n = wrapOffsets(line, buf.soft_wrap, width, method, &offsets);
    var seg: usize = 0;
    while (seg + 1 < n and offsets[seg + 1] <= buf.cursor_col) : (seg += 1) {}
    return .{ .seg = seg, .col = visualColAt(line, offsets[seg], buf.cursor_col, method) };
}

/// C-n: move down one visual (soft-wrapped) line. Inside a wrapped
/// paragraph the cursor steps to the next wrap segment, keeping its
/// display column; past the last segment it moves to the next logical
/// line's first visual line.
fn moveDownVisual(buf: *Buffer, width: usize, method: vaxis.gwidth.Method) void {
    if (width == 0) return buf.moveDown();
    const line = buf.lines.items[buf.cursor_row].items;
    var offsets: [1024]usize = undefined;
    const n = wrapOffsets(line, buf.soft_wrap, width, method, &offsets);
    var seg: usize = 0;
    while (seg + 1 < n and offsets[seg + 1] <= buf.cursor_col) : (seg += 1) {}
    const goal = visualColAt(line, offsets[seg], buf.cursor_col, method);
    if (seg + 1 < n) {
        buf.cursor_col = byteAtVisualCol(line, offsets[seg + 1], goal, width, method);
    } else if (buf.cursor_row + 1 < buf.lines.items.len) {
        buf.cursor_row += 1;
        const nl = buf.lines.items[buf.cursor_row].items;
        buf.cursor_col = byteAtVisualCol(nl, 0, goal, width, method);
    }
}

/// C-p: move up one visual line, keeping the display column.
fn moveUpVisual(buf: *Buffer, width: usize, method: vaxis.gwidth.Method) void {
    if (width == 0) return buf.moveUp();
    const line = buf.lines.items[buf.cursor_row].items;
    var offsets: [1024]usize = undefined;
    const n = wrapOffsets(line, buf.soft_wrap, width, method, &offsets);
    var seg: usize = 0;
    while (seg + 1 < n and offsets[seg + 1] <= buf.cursor_col) : (seg += 1) {}
    const goal = visualColAt(line, offsets[seg], buf.cursor_col, method);
    if (seg > 0) {
        buf.cursor_col = byteAtVisualCol(line, offsets[seg - 1], goal, width, method);
    } else if (buf.cursor_row > 0) {
        buf.cursor_row -= 1;
        const nl = buf.lines.items[buf.cursor_row].items;
        var no: [1024]usize = undefined;
        const nn = wrapOffsets(nl, buf.soft_wrap, width, method, &no);
        buf.cursor_col = byteAtVisualCol(nl, no[nn - 1], goal, width, method);
    }
}

/// C-e: move to the end of the current visual line. On a wrapped segment
/// that means its last character — the wrap point itself displays at the
/// start of the next visual line, so a cursor parked there would appear
/// to have moved on. On the last visual line it is the true end of the
/// logical line.
fn moveEndVisual(buf: *Buffer, width: usize, method: vaxis.gwidth.Method) void {
    if (width == 0) return buf.moveLineEnd();
    const line = buf.lines.items[buf.cursor_row].items;
    var offsets: [1024]usize = undefined;
    const n = wrapOffsets(line, buf.soft_wrap, width, method, &offsets);
    var seg: usize = 0;
    while (seg + 1 < n and offsets[seg + 1] <= buf.cursor_col) : (seg += 1) {}
    buf.cursor_col = if (seg + 1 < n)
        lastGraphemeStart(line, offsets[seg], offsets[seg + 1])
    else
        line.len;
}

/// C-a: move to the start of the current visual line — the segment's
/// wrap point, or the true start of the logical line on its first visual
/// line.
fn moveStartVisual(buf: *Buffer, width: usize, method: vaxis.gwidth.Method) void {
    if (width == 0) return buf.moveLineStart();
    const line = buf.lines.items[buf.cursor_row].items;
    var offsets: [1024]usize = undefined;
    const n = wrapOffsets(line, buf.soft_wrap, width, method, &offsets);
    var seg: usize = 0;
    while (seg + 1 < n and offsets[seg + 1] <= buf.cursor_col) : (seg += 1) {}
    buf.cursor_col = offsets[seg];
}

/// The byte offset of the last grapheme within `line[start..end]`, or
/// `end` itself when the range is empty.
fn lastGraphemeStart(line: []const u8, start: usize, end: usize) usize {
    var last = end;
    var it = vaxis.unicode.graphemeIterator(line[start..end]);
    while (it.next()) |g| {
        last = start + g.start;
    }
    return last;
}

/// The cursor's visual row when the window's first logical line is `top`:
/// the wrapped heights of the lines above the cursor's, plus the cursor's
/// own segment.
fn visualRowOfCursor(buf: *const Buffer, top: usize, width: usize, method: vaxis.gwidth.Method) usize {
    var v: usize = 0;
    var i = top;
    while (i < buf.cursor_row) : (i += 1) {
        v += wrapCount(buf.lines.items[i].items, buf.soft_wrap, width, method);
    }
    return v + cursorVisual(buf, width, method).seg;
}

/// Keep the cursor's visual row within [0, height): raise top_line while
/// the cursor's wrapped line falls below the window's bottom. With scroll
/// lock on (C-x l) the cursor instead stays on its locked screen row — the
/// text scrolls under it (Emacs scroll-lock-mode) — up to the ends of the
/// buffer.
fn scrollToCursorVisual(buf: *Buffer, height: usize, width: usize, method: vaxis.gwidth.Method) void {
    if (height == 0) return;
    if (buf.scroll_lock) {
        // The smallest top_line whose cursor visual row is still at or
        // above the locked row, clamped to the last screenful so the
        // window never runs past the end of the buffer. visualRowOfCursor
        // falls as top_line rises, so the predicate is monotone and the
        // binary search is exact.
        const max_top = buf.lines.items.len -| height;
        var lo: usize = 0;
        var hi = max_top;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (visualRowOfCursor(buf, mid, width, method) <= buf.scroll_row) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        buf.top_line = lo;
        // At the ends of the buffer (or on a line wrapped taller than the
        // window) the locked row is unreachable and the search leaves the
        // cursor where the text can go; if that is off the bottom of the
        // window, bring it back like a plain scroll.
        if (visualRowOfCursor(buf, buf.top_line, width, method) >= height) {
            buf.top_line = @min(buf.cursor_row -| (height - 1), max_top);
        }
        return;
    }
    if (buf.cursor_row < buf.top_line) {
        buf.top_line = buf.cursor_row;
        return;
    }
    // The cursor's visual row shrinks as top_line rises, so the first
    // top_line that fits is found by binary search — a handful of
    // O(n) passes instead of the previous loop of single-line
    // increments, each re-walking the buffer (a jump deep into a large
    // file took seconds).
    if (visualRowOfCursor(buf, buf.top_line, width, method) < height) return;
    var lo = buf.top_line;
    var hi = buf.cursor_row;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (visualRowOfCursor(buf, mid, width, method) >= height) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    buf.top_line = lo;
}

/// Keep the cursor's display column within [hscroll, hscroll + width) —
/// the horizontal twin of scrollToCursorVisual, for truncated
/// (soft-wrap-off) lines. The view scrolls right as the cursor walks
/// past the pane edge, so C-e lands the cursor at the right edge with
/// the line's tail on screen, and back left when the cursor returns to
/// earlier columns. Soft-wrapped lines never scroll horizontally.
fn scrollToCursorHorizontal(buf: *Buffer, width: usize, method: vaxis.gwidth.Method) void {
    if (width == 0 or buf.soft_wrap) return;
    const cv = cursorVisual(buf, width, method);
    if (cv.col < buf.hscroll) {
        buf.hscroll = cv.col;
    } else if (cv.col >= buf.hscroll + width) {
        buf.hscroll = cv.col - width + 1;
    }
    // A line that fits in the window starts at the left edge — don't
    // leave the view scrolled past it (the cursor at the very end of a
    // line sits one column past its last character, so keep that one
    // spot even if it shows a blank column after the text).
    const line = buf.lines.items[buf.cursor_row].items;
    const line_width = tabAwareWidth(line, 0, line.len, method);
    const clamped = @min(buf.hscroll, line_width -| width);
    if (cv.col -| clamped < width) buf.hscroll = clamped;
}

/// C-l: recenter the window on the cursor's visual line, cycling middle
/// → top → bottom like Emacs recenter-top-bottom.
fn recenterVisual(buf: *Buffer, height: usize, width: usize, method: vaxis.gwidth.Method, cycling: bool) void {
    if (height == 0) return;
    const pos: u8 = if (cycling) (buf.recenter_pos + 1) % 3 else 0;
    buf.recenter_pos = pos;
    var tl = buf.cursor_row;
    if (pos != 1) {
        const target: usize = if (pos == 0) height / 2 else height - 1;
        while (tl > 0 and visualRowOfCursor(buf, tl, width, method) < target) {
            tl -= 1;
        }
    }
    buf.top_line = tl;
    // C-l with scroll lock on re-anchors the lock to the recentered row,
    // so the next movement keeps the cursor where C-l put it.
    if (buf.scroll_lock) {
        buf.scroll_row = @min(visualRowOfCursor(buf, tl, width, method), height - 1);
    }
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
    /// isearch-lazy-count: the 1-based position of the current match and
    /// the total number of matches for the query, shown as (N/M) in the
    /// modeline while searching.
    count: usize,
    pos: usize,
};

/// The query-replace prompt phase (M-%): which of the two prompts is
/// showing — the string to find, then its replacement.
const ReplacePhase = enum { query, with };

/// The query-replace state (M-%), for rendering in the focused pane: the
/// "Query replace:" prompt phase or the y / n walk, the current candidate
/// highlighted like an isearch match. Null when no replace is active.
const ReplaceView = struct {
    /// The prompt phase, or null during the match walk.
    prompt: ?ReplacePhase,
    query: []const u8,
    with: []const u8,
    match: ?Buffer.Pos,
};

/// Sticky keys / repeat-mode (Emacs windmove-repeat-map, the author's
/// my/repeat-history): after C-x o the plain n / p / o keep moving
/// between windows, and after C-c j / C-c k the plain j / k keep
/// stepping the window layouts. The map stays armed while a repeat key
/// is pressed; any other key clears it and acts normally.
const RepeatMap = enum { window_history, window_move };

/// The M-o quick-jump labels (the author's my/quick-window-jump, the
/// ace-window corner labels): each window's one-char name in render
/// order, drawn in its top-left corner while the jump map is armed.
const quick_jump_labels = "jkl;asdf";

const DiredPromptKind = enum { copy, rename, delete, create_dir, create_file, open };

/// The dired compress formats (Z, Emacs dired-compress-file / the
/// author's my/dired-compress-transient): the single-file tools replace
/// the file in place (gzip -9 style); the archive formats build a new
/// archive, named after the entry (or prompted for, when several entries
/// are marked).
const CompressFmt = enum { gzip, xz, bzip2, zstd, lzip, tar_gz, tar_xz, tar_bz2, tar_zst, tar_lz, zip, seven_z };

/// One choice of the one-key compress menu: the letter that runs it.
const CompressChoice = struct { key: u8, fmt: CompressFmt };

/// The Z format menu, for the dired's modeline: the label ("Compress foo
/// as: ") and the choices ("g gzip, z xz, ..."). Both slices point into
/// fixed buffers that outlive the frame.
const CompressMenuView = struct {
    label: []const u8,
    choices: []const u8,
};

/// An in-pane dired prompt (copy / rename target, delete confirmation):
/// the listing stays in its window and the prompt text appears in that
/// pane's modeline, so the layout never changes.
const DiredPromptView = struct {
    kind: DiredPromptKind,
    query: []const u8 = &.{},
    /// Extra detail for the prompt, e.g. the app the external-open
    /// confirmation would run.
    detail: []const u8 = &.{},
};

/// An in-pane find-file prompt (C-x C-f): the current buffer stays in its
/// window and the path prompt appears in that pane's modeline, so the
/// layout never changes — the same shape as the isearch and dired prompts.
const FindFileView = struct {
    query: []const u8,
};

/// The bookmark name prompt (C-x r m) / jump prompt (C-x r b) rendered
/// in the focused window's modeline, like the find-file prompt — setting
/// or jumping to a bookmark never disturbs the window layout.
const BookmarkPromptView = struct {
    query: []const u8,
    set: bool,
};

/// The M-g goto-line prompt rendered in the focused window's modeline,
/// like the find-file prompt — the cursor jumps without disturbing the
/// window layout.
const GotoPromptView = struct {
    query: []const u8,
};

/// The grep / occur term prompt rendered in the focused window's
/// modeline, like the goto-line prompt — the search runs without
/// disturbing the window layout. `label` is the bold prompt text
/// ("Grep: " / "Occur: ").
const GrepPromptView = struct {
    query: []const u8,
    label: []const u8,
};

/// The modeline text split into its prompt label and the rest: the prompt
/// a command shows while waiting for input is rendered bold so it stands
/// out from the typed query.
const PromptModeline = struct {
    /// Total length of the modeline text written into the buffer.
    len: usize,
    /// Byte length of the bold label — the whole text when the prompt has
    /// no query (a y/n confirmation), zero when no prompt is showing.
    label_len: usize,
};

/// Write a modeline into `out`: `label_fmt` formatted with `label_args`
/// (the label ends in ": " when a query follows), then the typed `query`.
/// Returns the total length and the bold-label boundary.
fn fillPromptModeline(out: []u8, comptime label_fmt: []const u8, label_args: anytype, query: []const u8) PromptModeline {
    const label = std.fmt.bufPrint(out, label_fmt, label_args) catch return .{ .len = 0, .label_len = 0 };
    const tail = std.fmt.bufPrint(out[label.len..], "{s}", .{query}) catch return .{ .len = label.len, .label_len = label.len };
    return .{ .len = label.len + tail.len, .label_len = label.len };
}

/// The isearch lazy-count suffix — " (3/12)" — formatted into `buf`, the
/// twin of Emacs's isearch-lazy-count (%s/%s): the current match's
/// position and the query's total, shown after the query while searching.
/// Empty when the query is empty (a count has nothing to say yet).
fn isearchCountSuffix(buf: []u8, query: []const u8, pos: usize, count: usize) []const u8 {
    if (query.len == 0) return "";
    return std.fmt.bufPrint(buf, " ({d}/{d})", .{ pos, count }) catch "";
}

/// Remember a completed isearch query as the last search, so a fresh
/// C-s repeats it (see isearch_last). An empty query (never searched,
/// or cancelled before anything was typed) is not remembered.
fn rememberIsearch(gpa: std.mem.Allocator, last: *std.ArrayList(u8), query: []const u8) void {
    if (query.len == 0) return;
    last.clearRetainingCapacity();
    last.appendSlice(gpa, query) catch {};
}

/// M-% query-replace, one match: replace the match at `at` (a match of
/// `query`, so `query.len` bytes, never crossing a line boundary) with
/// `with`, carrying the match's capitalization like Emacs's case-replace.
/// Returns where the replacement ends — the next search starts there.
/// Null on an allocation failure (the match is left unreplaced).
fn doReplace(gpa: std.mem.Allocator, buf: *Buffer, at: Buffer.Pos, query: []const u8, with: []const u8) ?Buffer.Pos {
    const line = buf.lines.items[at.row].items;
    const col = @min(at.col, line.len);
    const len = @min(query.len, line.len - col);
    if (len == 0) return null;
    const repl = replaceWithCase(gpa, line[col .. col + len], with) catch return null;
    defer gpa.free(repl);
    return buf.replaceAt(gpa, .{ .row = at.row, .col = col }, len, repl) catch null;
}

/// The replacement `with` carrying the match's capitalization, like
/// Emacs's case-replace (on by default): an all-caps match (FOO) uppercases
/// the whole replacement, a match starting with a capital (Foo) capitalizes
/// its first letter, anything else uses `with` verbatim. Only ASCII is
/// folded, like the case-insensitive search itself. Caller must free.
fn replaceWithCase(gpa: std.mem.Allocator, match: []const u8, with: []const u8) ![]u8 {
    var has_letters = false;
    var all_caps = true;
    for (match) |c| {
        if (std.ascii.isAlphabetic(c)) {
            has_letters = true;
            if (std.ascii.isLower(c)) all_caps = false;
        }
    }
    if (!has_letters) return gpa.dupe(u8, with);
    if (all_caps) return std.ascii.allocUpperString(gpa, with);
    if (std.ascii.isUpper(match[0])) {
        const out = try gpa.dupe(u8, with);
        if (out.len > 0 and std.ascii.isLower(out[0])) out[0] = std.ascii.toUpper(out[0]);
        return out;
    }
    return gpa.dupe(u8, with);
}

/// End a query-replace walk: leave the walk (the key dispatch must go back
/// to normal editing!) and report how many replacements were made on the
/// modeline (via the transient status slot, like every copy echo).
fn endReplace(replace_active: *bool, status_msg: *?[]const u8, status_buf: *[2048]u8, count: usize) void {
    replace_active.* = false;
    const n = std.fmt.bufPrint(status_buf, "Replaced {d} occurrence{s}", .{ count, if (count == 1) "" else "s" }) catch {
        status_msg.* = "Replaced";
        return;
    };
    status_msg.* = status_buf[0..n.len];
}

/// Print a full-width modeline bar: the row in `buf` padded with spaces
/// across `win`, the prompt label bold when one is active (see
/// PromptModeline), the rest in the base `style`. The text lives in `buf`,
/// which the caller keeps alive until after the frame — vaxis stores
/// grapheme slices, not copies.
fn printModeline(win: vaxis.Window, buf: []u8, ml: PromptModeline, style: vaxis.Style, row: u16) void {
    const text_w = win.gwidth(buf[0..ml.len]);
    const fill_n = @min(@as(usize, @intCast(win.width -| text_w)), buf.len - ml.len);
    if (fill_n > 0) @memset(buf[ml.len .. ml.len + fill_n], ' ');
    const total = ml.len + fill_n;
    if (ml.label_len == 0) {
        _ = win.printSegment(.{ .text = buf[0..total], .style = style }, .{ .row_offset = row });
        return;
    }
    var label_style = style;
    label_style.bold = true;
    const label_len = @min(ml.label_len, total);
    if (label_len < total) {
        _ = win.printSegment(.{ .text = buf[0..label_len], .style = label_style }, .{ .row_offset = row });
        _ = win.printSegment(.{ .text = buf[label_len..total], .style = style }, .{ .row_offset = row, .col_offset = win.gwidth(buf[0..label_len]) });
    } else {
        _ = win.printSegment(.{ .text = buf[0..total], .style = label_style }, .{ .row_offset = row });
    }
}

/// Render one buffer's text plus its own compact modeline into `win`, which
/// may be the whole screen or one pane of a split. An active isearch shows
/// its match highlight and prompt in this pane, exactly as if the pane were
/// the whole screen.
fn renderPane(win: vaxis.Window, frame: *FrameAllocs, buf: *Buffer, is_focused: bool, row_base: u16, height: u16, modeline_buf: []u8, find_file: ?FindFileView, bookmark_prompt: ?BookmarkPromptView, goto_prompt: ?GotoPromptView, grep_prompt: ?GrepPromptView, grep_view: ?GrepView, files_view: ?FilesView, occur_view: ?GrepView, grep_hl: ?GrepHl, search: ?IsearchView, replace: ?ReplaceView, status: ?[]const u8) void {
    const text_height: usize = if (height > 1) height - 1 else height;
    const method = win.screen.width_method;
    scrollToCursorVisual(buf, text_height, win.width, method);
    scrollToCursorHorizontal(buf, win.width, method);

    const searching = search != null;
    const match: ?Buffer.Pos = if (search) |s| (if (s.failed) null else s.match) else null;
    const query_len: usize = if (search) |s| s.query.len else 0;

    var row: u16 = 0;
    var i = buf.top_line;
    while (i < buf.lines.items.len and row < text_height) : (i += 1) {
        const raw = buf.lines.items[i].items;
        // Tabs render as spaces up to the next tab stop — vaxis drops a
        // raw tab byte, gluing tab-separated fields together. With the
        // whitespace markers on (C-z e) the line renders through
        // whitespaceLine instead, which marks the spaces, tabs and the
        // line break itself.
        const ws_mode = buf.show_whitespace;
        const ws_text = if (ws_mode)
            whitespaceLine(frame, raw, i + 1 < buf.lines.items.len, method)
        else
            null;
        const expanded = if (!ws_mode) expandTabs(frame, raw, method) else null;
        const line = ws_text orelse expanded orelse raw;
        var h = highlightFor(buf, i, searching, match, query_len);
        // The transient grep-match highlight: shown on the match's line in
        // the target file after a jump (see GrepHl), losing to an active
        // isearch highlight.
        if (h.hl == null) {
            if (grep_hl) |gh| {
                if (i == gh.row) {
                    const line_len = buf.lines.items[i].items.len;
                    const start = @min(gh.col, line_len);
                    const end = @min(gh.col + gh.len, line_len);
                    if (end > start) h.hl = .{ .start = start, .end = end };
                }
            }
        }
        if (h.hl) |hl| {
            if (ws_text != null) {
                // Map the raw highlight offsets through the whitespace
                // markers (a space becomes the 2-byte ·, a tab the 2-byte
                // » plus its stop padding).
                h.hl = .{ .start = whitespaceDispAt(raw, hl.start, method), .end = whitespaceDispAt(raw, hl.end, method) };
            } else if (expanded != null) {
                // Map the raw highlight offsets through the expansion.
                h.hl = .{ .start = tabAwareWidth(raw, 0, hl.start, method), .end = tabAwareWidth(raw, 0, hl.end, method) };
            }
        }
        var seg_storage3: [3]vaxis.Segment = undefined;
        var seg_storage129: [129]vaxis.Segment = undefined;
        // The *files* buffer's filter highlight: the matched characters
        // of each visible row, drawn via fuzzySegments.
        const row_hl: ?FuzzyHl = if (files_view) |fv| blk: {
            if (buf == fv.buf and fv.filter.len > 0 and i < fv.row_hl.len and fv.row_hl[i].len > 0) break :blk fv.row_hl[i];
            break :blk null;
        } else null;
        const segs = if (row_hl) |fh|
            fuzzySegments(line, fh, is_focused and i == buf.cursor_row, &seg_storage129)
        else
            lineSegments(line, h.hl, h.empty_marker, &seg_storage3, is_focused and i == buf.cursor_row);
        // Advance by the line's wrapped height, so a soft-wrapped line
        // takes all of its visual rows instead of the next line
        // clobbering its continuation.
        const wraps = wrapCount(raw, buf.soft_wrap, win.width, method);
        if (buf.soft_wrap) {
            _ = win.print(segs, .{ .row_offset = row_base + row });
        } else {
            // Soft wrap off (M-z): the line truncates at the pane edge —
            // each segment is clipped to the remaining width, one row.
            // The view scrolls right with the cursor (Buffer.hscroll),
            // so the tail of a wide line — and the cursor on it — stays
            // on screen.
            var col: u16 = 0;
            var seg_off: usize = 0;
            const skip = if (buf.hscroll > 0) byteAtColumn(line, buf.hscroll, method) else 0;
            for (segs) |seg| {
                if (col >= win.width) break;
                // Cut the segment at the scroll boundary: the segments
                // tile the line in byte order, so a running offset picks
                // out the part after the scrolled-off columns.
                const rest = if (seg_off < skip)
                    seg.text[@min(skip - seg_off, seg.text.len)..]
                else
                    seg.text;
                seg_off += seg.text.len;
                if (rest.len == 0) continue;
                const clipped = clipToWidth(rest, win.width - col, method);
                if (clipped.len == 0) continue;
                _ = win.printSegment(.{ .text = clipped, .style = seg.style }, .{ .row_offset = row_base + row, .col_offset = col });
                col += win.gwidth(clipped);
            }
        }
        row += @intCast(wraps);
    }

    const ml: PromptModeline = if (find_file) |f|
        fillPromptModeline(modeline_buf, "Find file: ", .{}, f.query)
    else if (bookmark_prompt) |p| blk: {
        if (p.set) break :blk fillPromptModeline(modeline_buf, "Bookmark name (C-g cancels): ", .{}, p.query);
        break :blk fillPromptModeline(modeline_buf, "Jump to bookmark (C-g cancels): ", .{}, p.query);
    } else if (goto_prompt) |g|
        fillPromptModeline(modeline_buf, "Goto line (C-g cancels): ", .{}, g.query)
    else if (grep_prompt) |g|
        fillPromptModeline(modeline_buf, "{s}", .{g.label}, g.query)
    else if (replace) |r| blk: {
        if (r.prompt) |phase| {
            switch (phase) {
                .query => break :blk fillPromptModeline(modeline_buf, "Query replace: ", .{}, r.query),
                .with => break :blk fillPromptModeline(modeline_buf, "Query replace {s} with: ", .{r.query}, r.with),
            }
        }
        const n = std.fmt.bufPrint(modeline_buf, "Replace {s} with {s}? (y / n / q / ! / . / ^)", .{ r.query, r.with }) catch break :blk .{ .len = 0, .label_len = 0 };
        break :blk .{ .len = n.len, .label_len = n.len };
    } else if (search) |s| blk: {
        const label = if (s.failed)
            (if (s.backward) "Failing I-search backward" else "Failing I-search")
        else
            (if (s.backward) "I-search backward" else "I-search");
        // The lazy count ("I-search: term (3/12)", like Emacs) trails the
        // query in the same plain style.
        var count_buf: [32]u8 = undefined;
        const suffix = isearchCountSuffix(&count_buf, s.query, s.pos, s.count);
        var query_buf: [2048]u8 = undefined;
        const query_with_count = if (suffix.len > 0)
            (std.fmt.bufPrint(&query_buf, "{s}{s}", .{ s.query, suffix }) catch s.query)
        else
            s.query;
        break :blk fillPromptModeline(modeline_buf, "{s}: ", .{label}, query_with_count);
    } else if (status) |m| blk: {
        const n = std.fmt.bufPrint(modeline_buf, "{s}", .{m}) catch break :blk .{ .len = 0, .label_len = 0 };
        break :blk .{ .len = n.len, .label_len = 0 };
    } else blk: {
        // The results buffers show their position and keys in the
        // modeline instead of the L:C readout.
        if (grep_view) |gv| {
            if (buf == gv.buf) {
                const n = std.fmt.bufPrint(modeline_buf, "{s}{s} {d}/{d}{s}{s}   (n/p move, Enter opens, F follows, g rerun, q close)", .{
                    gv.buf.display_name orelse "?",
                    if (gv.follow) " [follow]" else "",
                    buf.cursor_row + 1,
                    gv.count,
                    if (!buf.soft_wrap) " [truncate]" else "",
                    if (buf.scroll_lock) " [scroll-lock]" else "",
                }) catch break :blk .{ .len = 0, .label_len = 0 };
                break :blk .{ .len = n.len, .label_len = 0 };
            }
        }
        if (files_view) |fv| {
            if (buf == fv.buf) {
                const n = if (fv.filter.len > 0)
                    std.fmt.bufPrint(modeline_buf, "{s}{s} {d}/{d}{s}{s}   filter: {s}   (C-g/Esc clears, Enter opens, F follows, g rerun)", .{
                        fv.buf.display_name orelse "?",
                        if (fv.follow) " [follow]" else "",
                        buf.cursor_row + 1,
                        fv.count,
                        if (!buf.soft_wrap) " [truncate]" else "",
                        if (buf.scroll_lock) " [scroll-lock]" else "",
                        fv.filter,
                    }) catch break :blk .{ .len = 0, .label_len = 0 }
                else
                    std.fmt.bufPrint(modeline_buf, "{s}{s} {d}/{d}{s}{s}   (type to filter, C-s searches, Enter opens, F follows, g rerun, C-g/Esc closes)", .{
                        fv.buf.display_name orelse "?",
                        if (fv.follow) " [follow]" else "",
                        buf.cursor_row + 1,
                        fv.count,
                        if (!buf.soft_wrap) " [truncate]" else "",
                        if (buf.scroll_lock) " [scroll-lock]" else "",
                    }) catch break :blk .{ .len = 0, .label_len = 0 };
                break :blk .{ .len = n.len, .label_len = 0 };
            }
        }
        if (occur_view) |ov| {
            if (buf == ov.buf) {
                const n = std.fmt.bufPrint(modeline_buf, "{s}{s} {d}/{d}{s}{s}   (n/p move, Enter jumps, F follows, g rerun, q close)", .{
                    ov.buf.display_name orelse "?",
                    if (ov.follow) " [follow]" else "",
                    buf.cursor_row + 1,
                    ov.count,
                    if (!buf.soft_wrap) " [truncate]" else "",
                    if (buf.scroll_lock) " [scroll-lock]" else "",
                }) catch break :blk .{ .len = 0, .label_len = 0 };
                break :blk .{ .len = n.len, .label_len = 0 };
            }
        }
        const n = std.fmt.bufPrint(modeline_buf, "{s}{s}{s}{s}{s}{s}  L{d}:C{d}", .{
            // Emacs-style modified marker in the bottom-left corner of the
            // modeline.
            if (buf.dirty) "*" else "",
            buf.display_name orelse buf.filename orelse "?",
            if (buf.dirty) " [modified]" else "",
            // M-z: soft wrap off (truncated lines) shows like Emacs's
            // Truncate mode-line marker; its absence means wrap is on.
            if (!buf.soft_wrap) " [truncate]" else "",
            // C-x l: scroll lock shows like Emacs's Scroll-Lock
            // mode-line marker; its absence means the cursor scrolls
            // with the text.
            if (buf.scroll_lock) " [scroll-lock]" else "",
            // C-z e: whitespace markers show like Emacs's whitespace-mode
            // "WS" mode-line lighter.
            if (buf.show_whitespace) " [whitespace]" else "",
            buf.cursor_row + 1,
            buf.cursor_col + 1,
        }) catch break :blk .{ .len = 0, .label_len = 0 };
        break :blk .{ .len = n.len, .label_len = 0 };
    };
    // The modeline is a bar spanning the pane's full width, like Emacs's
    // mode line: reverse video when focused, dimmed otherwise. An active
    // prompt's label is bold too, so it stands out from the query text.
    // The whole row is built in `modeline_buf`, which the caller keeps
    // alive until after render — vaxis stores grapheme slices, not copies,
    // so a stack-local fill buffer would dangle and show garbage once this
    // frame returns.
    const style: vaxis.Style = if (is_focused) highlight_style else .{ .dim = true };
    printModeline(win, modeline_buf, ml, style, row_base + (height -| 1));

    if (is_focused) {
        // The cursor sits on the cursor's visual line, at its display
        // column within that wrapped segment — past the number column.
        const cv = cursorVisual(buf, win.width, method);
        // In truncate mode the view may have scrolled right (hscroll), so
        // the cursor's display column counts from the scrolled edge.
        win.showCursor(@intCast(if (buf.soft_wrap) cv.col else cv.col -| buf.hscroll), @intCast(visualRowOfCursor(buf, buf.top_line, win.width, method)));
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

    /// C-x +: balance-windows — every split's divider returns to the
    /// middle (128 of 256), so all windows end up equal, like Emacs.
    fn balance(self: *Pane) void {
        if (self.isLeaf()) return;
        self.left_frac = 128;
        self.left.?.balance();
        self.right.?.balance();
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

/// The resize step for the C-M-h / C-M-l width keys, in 256ths of the
/// split's total: ~2 columns per press, scaled by the window width —
/// the old fixed 8/256 step moved about six columns on a 200-column
/// terminal, a jump per keypress on any wide screen.
fn resizeColsStep(total: usize) i16 {
    return @intCast(512 / @max(total, 1));
}

/// The resize step for the C-M-j / C-M-k height keys: ~1 row per press.
/// A terminal is far shorter than it is wide, so the width formula's
/// fraction would move the divider proportionally much further per
/// press (2 of 30 rows is a 6% jump, 2 of 100 columns barely 2%).
fn resizeRowsStep(total: usize) i16 {
    return @intCast(256 / @max(total, 1));
}

/// A tab: an independent window layout (its own pane tree) over the
/// shared buffer list, numbered 1..N and shown as blocks at the top of
/// the screen once a second one exists. M-l = opens a new tab at the
/// right end of the set, M-l - closes the current one, M-1..M-9 selects
/// by number, M-i / M-u step right / left. The active tab's layout is
/// tracked directly in main's root/focused/current; the other tabs live
/// here, saved on switch.
const Tab = struct {
    root: *Pane,
    focused: *Pane,
    current: usize,
};

/// The tab set is capped at this many tabs: the tab bar gives each tab
/// its own label buffer, and beyond a screenful of blocks a numbered
/// tab bar stops meaning anything.
const MAX_TABS = 16;

/// The tab bar: one numbered block per tab, in the top row of `win`.
/// Only drawn when more than one tab exists; the active tab's block is
/// highlighted. `labels` gives each tab its own buffer — vaxis stores
/// grapheme slices into the label text until the frame is drawn, so one
/// shared buffer would show the last tab's number on every block.
fn renderTabBar(win: vaxis.Window, labels: *[MAX_TABS][16]u8, tabs_len: usize, active: usize) void {
    const shown = @min(tabs_len, MAX_TABS);
    var col: u16 = 0;
    var i: usize = 0;
    while (i < shown) : (i += 1) {
        const label = std.fmt.bufPrint(&labels[i], "[ {d} ]", .{i + 1}) catch break;
        const style: vaxis.Style = if (i == active) highlight_style else .{ .dim = true };
        _ = win.printSegment(.{ .text = label, .style = style }, .{ .row_offset = 0, .col_offset = col });
        col += win.gwidth(label) + 1;
    }
}

/// Make tab `idx` the active tab: save the current tab's layout into
/// its slot, load the target's into the editor, and reset the window
/// history (it never crosses tabs). A no-op for the already-active or
/// out-of-range tab.
fn selectTab(tabs: *std.ArrayList(Tab), active_tab: *usize, idx: usize, root: **Pane, focused: **Pane, current: *usize, window_undo: *std.ArrayList(WindowSnapshot), window_redo: *std.ArrayList(WindowSnapshot)) void {
    if (idx >= tabs.items.len or idx == active_tab.*) return;
    tabs.items[active_tab.*] = .{ .root = root.*, .focused = focused.*, .current = current.* };
    active_tab.* = idx;
    root.* = tabs.items[idx].root;
    focused.* = tabs.items[idx].focused;
    current.* = tabs.items[idx].current;
    window_undo.clearRetainingCapacity();
    window_redo.clearRetainingCapacity();
}

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

/// True when `target` is a pane of the tree rooted at `root`. Panes can
/// be destroyed by window deletion, the C-c j/k layout restores, and tab
/// switches, so a remembered pane (the grep target window) is validated
/// against the tree before it is reused.
fn paneInTree(root: *const Pane, target: *const Pane) bool {
    if (root == target) return true;
    if (root.isLeaf()) return false;
    return paneInTree(root.left.?, target) or paneInTree(root.right.?, target);
}

/// What a persistent results buffer holds: grep matches (C-c g) or the
/// file list from a find (C-c f).
const ResultsKind = enum { grep, files, occur };

/// Open `path` — a grep match's file at `line`/`col` (0 = start of the
/// file, as with a find result) — in the target window (see
/// results_target): a lone results window splits to the right, otherwise
/// the window last used for a jump (or the next one over) is replaced.
/// Focus stays on the results buffer, so n/p + Enter — or F follow mode —
/// steps through the results without the layout changing.
fn resultsOpenMatch(
    gpa: std.mem.Allocator,
    io: std.Io,
    buffers: *std.ArrayList(*Buffer),
    direds: *std.ArrayList(?Dired),
    recent: *std.ArrayList([]u8),
    root: *Pane,
    focused: **Pane,
    current: usize,
    undo: *std.ArrayList(WindowSnapshot),
    redo: *std.ArrayList(WindowSnapshot),
    path: []const u8,
    line: usize,
    col: usize,
    results_target: *?*Pane,
    term: ?[]const u8,
    grep_hl: *?GrepHl,
) void {
    const idx = openBufferOrDired(gpa, io, buffers, direds, recent, path) catch return;
    resultsOpenAt(gpa, io, buffers, root, focused, current, undo, redo, idx, line, col, results_target, term, grep_hl);
}

/// Open an already-resolved buffer (a grep match's file, or the in-memory
/// source of an occur over a file-less buffer like the home screen) in
/// the target window: a lone results window splits to the right,
/// otherwise the window last used for a jump is reused. Focus stays on
/// the results buffer, so n/p + Enter — or F follow mode — steps through
/// the results without the layout changing.
fn resultsOpenAt(
    gpa: std.mem.Allocator,
    io: std.Io,
    buffers: *std.ArrayList(*Buffer),
    root: *Pane,
    focused: **Pane,
    current: usize,
    undo: *std.ArrayList(WindowSnapshot),
    redo: *std.ArrayList(WindowSnapshot),
    idx: usize,
    line: usize,
    col: usize,
    results_target: *?*Pane,
    term: ?[]const u8,
    grep_hl: *?GrepHl,
) void {
    const tgt = buffers.items[idx];
    if (line > 0 and tgt.lines.items.len > 0) {
        tgt.cursor_row = @min(line -| 1, tgt.lines.items.len - 1);
        const l = tgt.lines.items[tgt.cursor_row].items;
        tgt.cursor_col = @min(col -| 1, l.len);
        // A transient highlight of the term at the match, so it's easy to
        // spot while stepping (see GrepHl).
        if (term) |t| {
            // The Windows fallback (findstr) prints no column, and plain
            // grep is no better: locate the term in the line ourselves, so
            // the cursor and highlight land on the match all the same.
            const c = if (col == 0 and t.len > 0)
                (std.ascii.findIgnoreCase(l, t) orelse tgt.cursor_col)
            else
                tgt.cursor_col;
            if (c < l.len) {
                const hl_len = @min(t.len, l.len - c);
                if (hl_len > 0 and std.ascii.eqlIgnoreCase(l[c .. c + hl_len], t[0..hl_len])) {
                    grep_hl.* = .{ .buf = tgt, .row = tgt.cursor_row, .col = c, .len = hl_len, .set_at = std.Io.Clock.now(.real, io).nanoseconds };
                    tgt.cursor_col = c;
                }
            }
        }
    }
    recordWindow(gpa, root, focused.*, current, undo, redo);
    if (root.isLeaf()) {
        // Only the results window: split to the right, the file on the
        // right, focus staying on the results buffer.
        if (root.leafCount() < MAX_PANES) {
            focused.*.split(gpa, .vertical) catch return;
            focused.*.right.?.buf_idx = idx;
            results_target.* = focused.*.right.?;
            focused.* = focused.*.left.?;
        }
    } else if (results_target.*) |t| {
        if (paneInTree(root, t)) {
            t.buf_idx = idx;
        } else {
            results_target.* = null;
        }
    }
    if (results_target.* == null) {
        // Replace the next window over and remember it for the next jump.
        if (moveFocus(root, focused.*, 1)) |nf| {
            nf.buf_idx = idx;
            results_target.* = nf;
        }
    }
}

/// Jump to the occur match at `row` in the target window (see
/// resultsOpenMatch): the source reopens at the match with a transient
/// highlight of the term, focus staying on the *occur* buffer, so
/// n/p + Enter — or F follow mode — steps through the matches without
/// the layout changing. `source_buf` is the in-memory source buffer —
/// always set after an occur run; it is used directly when it still
/// exists in the buffer list, so an occur over a file-less buffer (the
/// home screen) jumps to the matches all the same. `source` (the path)
/// is the fallback for a closed file buffer, which reopens from disk.
fn occurJump(
    gpa: std.mem.Allocator,
    io: std.Io,
    buffers: *std.ArrayList(*Buffer),
    direds: *std.ArrayList(?Dired),
    recent: *std.ArrayList([]u8),
    root: *Pane,
    focused: **Pane,
    current: usize,
    undo: *std.ArrayList(WindowSnapshot),
    redo: *std.ArrayList(WindowSnapshot),
    source: ?[]const u8,
    source_buf: ?*Buffer,
    matches: []const OccurMatch,
    row: usize,
    results_target: *?*Pane,
    term: ?[]const u8,
    grep_hl: *?GrepHl,
) void {
    if (row >= matches.len) return;
    const m = matches[row];
    if (source_buf) |sb| {
        for (buffers.items, 0..) |b, idx| {
            if (b == sb) {
                resultsOpenAt(gpa, io, buffers, root, focused, current, undo, redo, idx, m.row + 1, m.col + 1, results_target, term, grep_hl);
                return;
            }
        }
    }
    if (source) |s| {
        resultsOpenMatch(gpa, io, buffers, direds, recent, root, focused, current, undo, redo, s, m.row + 1, m.col + 1, results_target, term, grep_hl);
    }
}

/// Run an occur of `term` over `buf`: every line matching (case-
/// insensitive) lands in a fresh "*occur*" buffer that becomes current,
/// an old results buffer replaced on a re-run. Shared by the occur
/// prompt's Enter and M-c in isearch, which runs it straight from the
/// search string — the prompt only exists so a term can be edited
/// before running. Any editing buffer works, named or not: the source
/// buffer is remembered in memory (see occur_source_buf), so an occur
/// over the file-less home screen works too — only the g re-run needs
/// the path, to reopen a closed file. Returns the new current buffer
/// index, or null when nothing ran (empty term, no matches, or an
/// allocation failure — "No matches" is the only status set).
fn occurRun(
    gpa: std.mem.Allocator,
    io: std.Io,
    buffers: *std.ArrayList(*Buffer),
    direds: *std.ArrayList(?Dired),
    recent: *std.ArrayList([]u8),
    root: *Pane,
    focused: **Pane,
    current: usize,
    undo: *std.ArrayList(WindowSnapshot),
    redo: *std.ArrayList(WindowSnapshot),
    buf: *Buffer,
    term: []const u8,
    occur_source: *?[]u8,
    occur_source_buf: *?*Buffer,
    occur_last_term: *?[]u8,
    occur_matches: *std.ArrayList(OccurMatch),
    occur_buf_idx: *?usize,
    results_target: *?*Pane,
    results_follow: *bool,
    grep_hl: *?GrepHl,
    status_msg: *?[]const u8,
) ?usize {
    if (term.len == 0) return null;
    // The source buffer: the remembered in-memory source on a re-run
    // (edits made since are picked up; a file-less buffer like the home
    // screen can only be re-run this way), else the re-opened source
    // file, else the current buffer on a fresh M-c.
    const src: *Buffer = blk: {
        if (occur_source_buf.*) |sp| {
            for (buffers.items) |b| if (b == sp) break :blk sp;
        }
        if (occur_source.*) |s| {
            const idx = openBufferOrDired(gpa, io, buffers, direds, recent, s) catch break :blk buf;
            break :blk buffers.items[idx];
        }
        break :blk buf;
    };
    if (occur_last_term.*) |t| gpa.free(t);
    occur_last_term.* = gpa.dupe(u8, term) catch null;
    // The path is only remembered for named sources, so a g re-run can
    // reopen a file that was closed meanwhile.
    if (occur_source.* == null) {
        if (src.filename) |f| occur_source.* = gpa.dupe(u8, f) catch null;
    }
    if (occur_source_buf.* == null) {
        occur_source_buf.* = src;
    }
    // One row per matching line: "N: text", the matches collected into
    // a fresh list so a failed re-run leaves the old buffer intact.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var fresh: std.ArrayList(OccurMatch) = .empty;
    defer fresh.deinit(gpa);
    var nbuf: [24]u8 = undefined;
    for (src.lines.items, 0..) |line, row| {
        if (std.ascii.findIgnoreCasePos(line.items, 0, term)) |c| {
            const num = std.fmt.bufPrint(&nbuf, "{d}: ", .{row + 1}) catch continue;
            text.appendSlice(gpa, num) catch break;
            text.appendSlice(gpa, line.items) catch break;
            text.append(gpa, '\n') catch break;
            fresh.append(gpa, .{ .row = row, .col = c }) catch break;
        }
    }
    if (fresh.items.len == 0) {
        status_msg.* = "No matches";
        return null;
    }
    // An old results buffer is replaced.
    if (occur_buf_idx.*) |old| {
        if (old < buffers.items.len) {
            recordWindow(gpa, root, focused.*, current, undo, redo);
            _ = closeBuffer(gpa, buffers, direds, root, focused.*, old, undo, redo);
        }
        occur_buf_idx.* = null;
        results_target.* = null;
        results_follow.* = false;
        grep_hl.* = null;
    }
    occur_matches.clearRetainingCapacity();
    occur_matches.appendSlice(gpa, fresh.items) catch return null;
    const new_buf = gpa.create(Buffer) catch return null;
    errdefer gpa.destroy(new_buf);
    new_buf.* = Buffer.fromText(gpa, text.items) catch return null;
    new_buf.display_name = gpa.dupe(u8, "*occur*") catch return null;
    // Results always truncate: one match per row, however long the line.
    new_buf.soft_wrap = false;
    buffers.append(gpa, new_buf) catch return null;
    direds.append(gpa, null) catch return null;
    occur_buf_idx.* = buffers.items.len - 1;
    recordWindow(gpa, root, focused.*, current, undo, redo);
    focused.*.buf_idx = occur_buf_idx.*.?;
    return occur_buf_idx.*;
}

/// Build the segments for `line` with the fuzzy matched characters (see
/// FuzzyHl) highlighted — one segment per matched grapheme — the same
/// shape as lineSegments, for the *files* buffer's filter highlight.
fn fuzzySegments(line: []const u8, fh: FuzzyHl, current: bool, storage: *[129]vaxis.Segment) []const vaxis.Segment {
    const base_style: vaxis.Style = if (current) .{ .bold = true } else .{};
    const hl_style: vaxis.Style = if (current) .{ .reverse = true, .bold = true } else highlight_style;
    var n: usize = 0;
    var seg_start: usize = 0;
    for (fh.positions[0..fh.len]) |p| {
        if (p >= line.len) break;
        // A position is a byte offset; step past the continuation bytes so
        // a match landing mid-UTF-8 highlights the whole grapheme.
        var e = p + 1;
        while (e < line.len and (line[e] & 0xC0) == 0x80) e += 1;
        if (p > seg_start) {
            storage[n] = .{ .text = line[seg_start..p], .style = base_style };
            n += 1;
        }
        storage[n] = .{ .text = line[p..e], .style = hl_style };
        n += 1;
        seg_start = e;
    }
    if (seg_start < line.len) {
        storage[n] = .{ .text = line[seg_start..], .style = base_style };
        n += 1;
    }
    if (n == 0) {
        storage[0] = .{ .text = line, .style = base_style };
        n = 1;
    }
    return storage[0..n];
}

/// Mirror the *files* buffer's rows into its lines — the filtered subset
/// when a filter is active, the whole list otherwise — with the matched
/// character positions per row. The buffer's cursor_row is a position in
/// the mirrored rows.
fn filesMirror(gpa: std.mem.Allocator, buf: *Buffer, paths: []const []const u8, filter: []const u8, visible: *std.ArrayList(usize), hl_out: *std.ArrayList(FuzzyHl)) void {
    for (buf.lines.items) |*l| l.deinit(gpa);
    buf.lines.clearRetainingCapacity();
    visible.clearRetainingCapacity();
    hl_out.clearRetainingCapacity();
    var matches: std.ArrayList(PickerMatch) = .empty;
    defer matches.deinit(gpa);
    for (paths, 0..) |p, i| {
        if (filter.len == 0 or partialMatch(filter, p) != null) {
            matches.append(gpa, .{ .idx = i, .rank = 0, .hl = if (filter.len > 0) partialMatch(filter, p).?.hl else .{} }) catch return;
        }
    }
    if (filter.len > 0) std.mem.sort(PickerMatch, matches.items, {}, PickerMatch.lessThan);
    for (matches.items) |m| {
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(gpa);
        line.appendSlice(gpa, paths[m.idx]) catch return;
        buf.lines.append(gpa, line) catch return;
        visible.append(gpa, m.idx) catch return;
        hl_out.append(gpa, m.hl) catch return;
    }
    if (buf.cursor_row >= buf.lines.items.len) buf.cursor_row = buf.lines.items.len -| 1;
    buf.cursor_col = 0;
}

/// Run the file-finder over `dir` and (re)fill the *files* buffer: the
/// existing one is re-mirrored, or a new buffer is created. Returns the
/// buffer index; null when the find fails or finds nothing.
fn filesRun(
    gpa: std.mem.Allocator,
    io: std.Io,
    buffers: *std.ArrayList(*Buffer),
    direds: *std.ArrayList(?Dired),
    dir: []const u8,
    find_paths: *std.ArrayList([]u8),
    find_dir: *?[]u8,
    find_filter: *std.ArrayList(u8),
    find_visible: *std.ArrayList(usize),
    find_hl: *std.ArrayList(FuzzyHl),
    find_buf_idx: *?usize,
) ?usize {
    const out = findRun(io, gpa, dir) orelse return null;
    defer gpa.free(out);
    for (find_paths.items) |p| gpa.free(p);
    find_paths.clearRetainingCapacity();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t\r");
        if (p.len == 0) continue;
        find_paths.append(gpa, gpa.dupe(u8, p) catch continue) catch continue;
        text.appendSlice(gpa, p) catch break;
        text.append(gpa, '\n') catch break;
    }
    if (find_paths.items.len == 0) return null;
    if (find_dir.*) |d| gpa.free(d);
    find_dir.* = gpa.dupe(u8, dir) catch null;
    find_filter.clearRetainingCapacity();

    // Reuse the existing *files* buffer (re-mirror), or create it.
    if (find_buf_idx.*) |old| {
        if (old < buffers.items.len and std.mem.eql(u8, buffers.items[old].display_name orelse "", "*files*")) {
            const buf = buffers.items[old];
            for (buf.lines.items) |*l| l.deinit(gpa);
            buf.lines.clearRetainingCapacity();
            buf.cursor_row = 0;
            buf.cursor_col = 0;
            var lit = std.mem.splitScalar(u8, text.items, '\n');
            while (lit.next()) |ls| {
                var line: std.ArrayList(u8) = .empty;
                errdefer line.deinit(gpa);
                line.appendSlice(gpa, ls) catch return null;
                buf.lines.append(gpa, line) catch return null;
            }
            filesMirror(gpa, buf, find_paths.items, "", find_visible, find_hl);
            return old;
        }
    }
    const new_buf = gpa.create(Buffer) catch return null;
    new_buf.* = Buffer.fromText(gpa, text.items) catch {
        gpa.destroy(new_buf);
        return null;
    };
    new_buf.display_name = gpa.dupe(u8, "*files*") catch {
        new_buf.deinit(gpa);
        gpa.destroy(new_buf);
        return null;
    };
    // Results always truncate: one row per file.
    new_buf.soft_wrap = false;
    buffers.append(gpa, new_buf) catch {
        new_buf.deinit(gpa);
        gpa.destroy(new_buf);
        return null;
    };
    direds.append(gpa, null) catch return null;
    find_buf_idx.* = buffers.items.len - 1;
    filesMirror(gpa, new_buf, find_paths.items, "", find_visible, find_hl);
    return find_buf_idx.*;
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

// --- Windows console input flush ----------------------------------------
//
// loop.stop() wakes the input thread by sending a Device Status Report
// (CSI 5n); the terminal's "CSI 0n" answer lands in the console input
// buffer as key records. The dying input thread often exits before
// consuming them — or, if the response arrives late, before it ever
// starts — leaving ESC [ 0 n queued for the next reader. cmd.exe reads
// and echoes that, so the shell's very first prompt comes out as
// "C:\...\>^[[0n". FlushConsoleInputBuffer discards the residue before
// the shell starts, and again after it exits, so stale records can
// neither decorate the prompt nor leak back into the editor as phantom
// keys once the loop restarts.
extern "kernel32" fn FlushConsoleInputBuffer(hConsoleInput: windows.HANDLE) callconv(.winapi) windows.BOOL;

fn winFlushConsoleInput(tty: *vaxis.Tty) void {
    if (comptime builtin.os.tag != .windows) return;
    _ = FlushConsoleInputBuffer(tty.stdin);
}

/// C-x j: hand the terminal to a real shell. Returns the pid of a shell
/// suspended with C-z (to resume on the next C-x j), or null when the
/// shell exited or none could be started. The shell starts in
/// `shell_dir` when one is given — the dired's directory while browsing,
/// the current file's directory otherwise — so a fresh shell lands where
/// the cursor is, ready to work (null keeps the editor's own directory).
fn enterShell(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    loop: *vaxis.Loop(Event),
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    shell_pid: ?std.posix.pid_t,
    editor_pgrp: ?std.posix.pid_t,
    shell_dir: ?[]const u8,
) !?std.posix.pid_t {
    if (comptime builtin.os.tag == .windows) {
        return enterShellWindows(gpa, io, environ_map, loop, vx, tty, shell_dir);
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
        // The shell starts in the buffer's directory when one is given:
        // spawn's cwd option chdirs in the child (POSIX) or passes the
        // path to CreateProcessW (Windows), so a fresh shell lands where
        // the cursor is.
        var shell_opts: std.process.SpawnOptions = .{ .argv = &.{shell_path}, .pgid = 0 };
        if (shell_dir) |d| shell_opts.cwd = .{ .path = d };
        const child = std.process.spawn(io, shell_opts) catch blk: {
            var fallback: std.process.SpawnOptions = .{ .argv = &.{"/bin/sh"}, .pgid = 0 };
            if (shell_dir) |d| fallback.cwd = .{ .path = d };
            break :blk std.process.spawn(io, fallback) catch {
                // No usable shell: come back to the editor untouched.
                restoreEditor(gpa, vx, tty) catch {};
                loop.start() catch {};
                return null;
            };
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
    shell_dir: ?[]const u8,
) !?std.posix.pid_t {
    loop.stop();
    while (loop.tryEvent() catch null) |_| {}
    // The DSR that woke the input thread answers in the console input
    // buffer; whatever the dying thread left unread (or that arrived
    // after it exited) would be echoed by the shell as garbage — flush
    // it before the shell ever reads.
    winFlushConsoleInput(tty);

    // Reset the editor's terminal state and hand the console back to the
    // user's normal mode and codepage, so cmd.exe behaves as usual.
    vx.resetState(tty.writer()) catch {};
    vaxis.Tty.setConsoleMode(tty.stdin, tty.initial_input_mode) catch {};
    vaxis.Tty.setConsoleMode(tty.stdout, tty.initial_output_mode) catch {};
    if (vaxis.Tty.SetConsoleOutputCP(tty.initial_codepage) == .FALSE) {}

    const shell_path = environ_map.get("SHELL") orelse
        (environ_map.get("COMSPEC") orelse "cmd.exe");
    // The shell starts in the buffer's directory when one is given (the
    // spawn's cwd option passes the path to CreateProcessW).
    var shell_opts: std.process.SpawnOptions = .{ .argv = &.{shell_path} };
    if (shell_dir) |d| shell_opts.cwd = .{ .path = d };
    var child = std.process.spawn(io, shell_opts) catch {
        // No usable shell: come back to the editor untouched.
        restoreEditorWindows(gpa, vx, tty) catch {};
        loop.start() catch {};
        return null;
    };
    _ = child.wait(io) catch {};
    // The shell's own input residue (and any DSR answer that was still
    // in flight while it ran) must not leak back into the editor as
    // phantom keypresses once the loop restarts.
    winFlushConsoleInput(tty);

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

/// Run `argv` and capture its stdout, trailing whitespace trimmed.
/// Returns null if the command can't spawn or writes nothing.
fn runCapture(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore }) catch return null;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    if (child.stdout) |f| {
        var buf: [256]u8 = undefined;
        var r = f.reader(io, &buf);
        var chunk: [256]u8 = undefined;
        while (true) {
            const n = r.interface.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            out.appendSlice(gpa, chunk[0..n]) catch break;
        }
        // The pipe must not be closed here: child.wait's cleanup closes
        // the handles, and closing the fd twice panics (BADF) in Debug
        // builds and corrupts the descriptor table in Release ones.
    }
    _ = child.wait(io) catch null;
    const trimmed = std.mem.trimEnd(u8, out.items, " \t\r\n");
    return if (trimmed.len > 0) gpa.dupe(u8, trimmed) catch null else null;
}

/// Read the system clipboard through the platform's clipboard tool
/// (wl-paste on Wayland, xsel / xclip on X11), returning the exact text
/// — untrimmed, so a trailing newline in the clipboard survives. Null
/// when the tool can't spawn or there's no clipboard to read. Used as
/// the Linux paste path for C-y, since many terminals (alacritty among
/// them) never answer an OSC 52 clipboard read.
fn clipboardGet(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore }) catch return null;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    if (child.stdout) |f| {
        var buf: [256]u8 = undefined;
        var r = f.reader(io, &buf);
        var chunk: [256]u8 = undefined;
        while (true) {
            const n = r.interface.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            out.appendSlice(gpa, chunk[0..n]) catch break;
        }
    }
    _ = child.wait(io) catch null;
    return if (out.items.len > 0) gpa.dupe(u8, out.items) catch null else null;
}

/// Run `argv` to completion; the exit code, or null when it can't run.
/// robocopy reports success as 0-7, so the raw code is needed there.
fn runToolCode(io: std.Io, argv: []const []const u8) ?u8 {
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return null;
    const term = child.wait(io) catch return null;
    return switch (term) {
        .exited => |code| code,
        else => null,
    };
}

/// Run `argv` to completion, both outputs ignored; true when it exits 0.
fn runTool(io: std.Io, argv: []const []const u8) bool {
    return (runToolCode(io, argv) orelse return false) == 0;
}

/// The base name and last extension of `name`, the way the author's
/// Emacs config's file-name-base / file-name-extension see them — a
/// leading dot is not an extension (".bashrc" is all base) — for the
/// trash name-collision counter.
fn trashNameParts(name: []const u8) struct { base: []const u8, ext: []const u8 } {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return .{ .base = name, .ext = "" };
    if (dot == 0) return .{ .base = name, .ext = "" };
    return .{ .base = name[0..dot], .ext = name[dot + 1 ..] };
}

/// "2026-08-09T14:30:00" — the current UTC time, ISO 8601, the
/// DeletionDate of a trashinfo sidecar (the same epoch math the dired
/// dates use).
fn trashDeletionDate(buf: []u8, io: std.Io) []const u8 {
    const now = std.Io.Timestamp.now(io, .real);
    const secs: u64 = @intCast(@max(@divTrunc(now.nanoseconds, 1_000_000_000), 0));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = es.getEpochDay();
    const ds = es.getDaySeconds();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch "";
}

/// Move one file or directory to the platform trash — the Windows
/// Recycle Bin via PowerShell's Microsoft.VisualBasic API (the author's
/// Emacs config), or the freedesktop.org trash elsewhere: the file lands
/// in XDG_DATA_HOME/Trash/files (or ~/.local/share/Trash/files) with a
/// .trashinfo sidecar in Trash/info and a name-collision counter
/// (foo.tar.gz → foo.tar.1.gz), exactly like the config's Linux branch.
/// Returns true on success.
fn trashFile(io: std.Io, gpa: std.mem.Allocator, environ_map: *std.process.Environ.Map, path: []const u8) bool {
    if (comptime builtin.os.tag == .windows) {
        // The same VisualBasic FileSystem API the config calls:
        // DeleteFile / DeleteDirectory with SendToRecycleBin.
        const q = psQuote(gpa, path) catch return false;
        defer gpa.free(q);
        const ps = std.fmt.allocPrint(
            gpa,
            "Add-Type -AssemblyName Microsoft.VisualBasic; $ErrorActionPreference='Stop'; $p={s}; try {{ if (Test-Path -LiteralPath $p -PathType Container) {{ [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($p,'OnlyErrorDialogs','SendToRecycleBin') }} else {{ [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p,'OnlyErrorDialogs','SendToRecycleBin') }} }} catch {{ Write-Error $_; exit 1 }}",
            .{q},
        ) catch return false;
        defer gpa.free(ps);
        return runTool(io, &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", ps });
    }

    // freedesktop.org trash: XDG_DATA_HOME/Trash, or the default
    // ~/.local/share/Trash.
    const xdg = environ_map.get("XDG_DATA_HOME");
    var owned_base: ?[]u8 = null;
    defer if (owned_base) |b| gpa.free(b);
    const base: []const u8 = if (xdg) |x|
        x
    else blk: {
        const home = jumpHome(environ_map) orelse return false;
        owned_base = std.fs.path.join(gpa, &.{ home, ".local", "share" }) catch return false;
        break :blk owned_base.?;
    };

    const files_dir = std.fs.path.join(gpa, &.{ base, "Trash", "files" }) catch return false;
    defer gpa.free(files_dir);
    const info_dir = std.fs.path.join(gpa, &.{ base, "Trash", "info" }) catch return false;
    defer gpa.free(info_dir);
    std.Io.Dir.cwd().createDirPath(io, files_dir) catch return false;
    std.Io.Dir.cwd().createDirPath(io, info_dir) catch return false;
    var files = std.Io.Dir.cwd().openDir(io, files_dir, .{}) catch return false;
    defer files.close(io);

    // A trash name that doesn't already exist, with the config's
    // counter. A broken symlink counts as free (like file-exists-p).
    const parts = trashNameParts(std.fs.path.basename(path));
    var trash_name: []u8 = if (parts.ext.len > 0)
        (std.fmt.allocPrint(gpa, "{s}.{s}", .{ parts.base, parts.ext }) catch return false)
    else
        (gpa.dupe(u8, parts.base) catch return false);
    defer gpa.free(trash_name);
    var counter: usize = 1;
    while (files.statFile(io, trash_name, .{ .follow_symlinks = true }) catch null) |_| {
        const next = if (parts.ext.len > 0)
            (std.fmt.allocPrint(gpa, "{s}.{d}.{s}", .{ parts.base, counter, parts.ext }) catch return false)
        else
            (std.fmt.allocPrint(gpa, "{s}.{d}", .{ parts.base, counter }) catch return false);
        gpa.free(trash_name);
        trash_name = next;
        counter += 1;
        if (counter > 10000) return false;
    }

    // The .trashinfo sidecar: the original path as-is (like the config),
    // and the deletion time in UTC, ISO 8601.
    const abs = Dired.absPathOf(gpa, io, path) catch return false;
    defer gpa.free(abs);
    var date_buf: [32]u8 = undefined;
    const date = trashDeletionDate(&date_buf, io);
    var info: std.ArrayList(u8) = .empty;
    defer info.deinit(gpa);
    info.appendSlice(gpa, "[Trash Info]\nPath=") catch return false;
    info.appendSlice(gpa, abs) catch return false;
    info.appendSlice(gpa, "\nDeletionDate=") catch return false;
    info.appendSlice(gpa, date) catch return false;
    info.append(gpa, '\n') catch return false;
    const info_name = std.fmt.allocPrint(gpa, "{s}.trashinfo", .{trash_name}) catch return false;
    defer gpa.free(info_name);
    const info_full = std.fs.path.join(gpa, &.{ info_dir, info_name }) catch return false;
    defer gpa.free(info_full);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = info_full, .data = info.items }) catch return false;

    const trash_full = std.fs.path.join(gpa, &.{ files_dir, trash_name }) catch return false;
    defer gpa.free(trash_full);
    return runTool(io, &.{ "mv", path, trash_full });
}

/// The base name and extension (with its dot) of `name`, for the
/// duplicate counter — the config's file-name-sans-extension /
/// file-name-extension-with-dot pair: "foo.tar.gz" → ("foo.tar",
/// ".gz"), ".bashrc" → (".bashrc", "").
fn duplicateNameParts(name: []const u8) struct { base: []const u8, ext: []const u8 } {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return .{ .base = name, .ext = "" };
    if (dot == 0) return .{ .base = name, .ext = "" };
    return .{ .base = name[0..dot], .ext = name[dot..] };
}

/// Duplicate `path` to `new_path` — a file or a directory — like the
/// author's my/dired-duplicate-file: cp -a (the built-in twin of its
/// rsync -a) on POSIX, robocopy for directories and PowerShell's
/// Copy-Item for files on Windows. Returns true on success (robocopy
/// reports success as exit codes 0-7).
fn diredDuplicateRun(io: std.Io, gpa: std.mem.Allocator, path: []const u8, new_path: []const u8, is_dir: bool) bool {
    if (comptime builtin.os.tag == .windows) {
        if (is_dir) {
            const code = runToolCode(io, &.{ "robocopy", path, new_path, "/E", "/COPY:DAT", "/R:0", "/W:0", "/NP", "/NJH", "/NJS", "/NDL", "/NFL", "/BYTES", "/MT:8" }) orelse return false;
            return code <= 7;
        }
        const qs = psQuote(gpa, path) catch return false;
        defer gpa.free(qs);
        const qd = psQuote(gpa, new_path) catch return false;
        defer gpa.free(qd);
        const ps = std.fmt.allocPrint(gpa, "Copy-Item -LiteralPath {s} -Destination {s}", .{ qs, qd }) catch return false;
        defer gpa.free(ps);
        return runTool(io, &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", ps });
    }
    return runTool(io, &.{ "cp", "-a", path, new_path });
}

/// Whether `argv` runs at all on this machine: spawned with both outputs
/// captured, "yes" on any output (some tools --version to stderr). The
/// probe for the compress menu — a format is only offered when its tool
/// actually exists, so the menu is honest (and Windows, which ships
/// tar.exe and PowerShell but no gzip, sees zip / tar.gz / tar.xz /
/// tar.bz2 / 7z).
fn toolRuns(io: std.Io, argv: []const []const u8) bool {
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe }) catch return false;
    var any = false;
    if (child.stdout) |f| {
        var buf: [256]u8 = undefined;
        var r = f.reader(io, &buf);
        var chunk: [256]u8 = undefined;
        while (true) {
            const n = r.interface.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            if (n > 0) any = true;
        }
    }
    if (child.stderr) |f| {
        var buf: [256]u8 = undefined;
        var r = f.reader(io, &buf);
        var chunk: [256]u8 = undefined;
        while (true) {
            const n = r.interface.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            if (n > 0) any = true;
        }
    }
    _ = child.wait(io) catch null;
    return any;
}

/// Whether a standard tool named `name` exists, probed with --version.
fn toolAvailable(io: std.Io, name: []const u8) bool {
    return toolRuns(io, &.{ name, "--version" });
}

/// The one-key format choices for this platform and target — `archive`
/// when the target is a directory or several files (tar-style formats),
/// a single plain file getting the gzip-style tools instead. Only tools
/// that actually exist are offered. The letter keys mirror the author's
/// my/dired-compress-transient (z g t b s l 7), with p for zip.
fn compressChoices(io: std.Io, gpa: std.mem.Allocator, out: *std.ArrayList(CompressChoice), archive: bool) void {
    out.clearRetainingCapacity();
    if (comptime builtin.os.tag == .windows) {
        // zip: PowerShell's Compress-Archive, present on every Windows
        // since 10; tar.exe (bsdtar) with -a picking the compressor from
        // the suffix; 7z when installed.
        out.append(gpa, .{ .key = 'p', .fmt = .zip }) catch {};
        if (toolAvailable(io, "tar")) {
            out.append(gpa, .{ .key = 't', .fmt = .tar_gz }) catch {};
            out.append(gpa, .{ .key = 'z', .fmt = .tar_xz }) catch {};
            out.append(gpa, .{ .key = 'b', .fmt = .tar_bz2 }) catch {};
        }
        if (toolRuns(io, &.{ "7z", "i" })) out.append(gpa, .{ .key = '7', .fmt = .seven_z }) catch {};
        return;
    }
    if (!archive) {
        if (toolAvailable(io, "gzip")) out.append(gpa, .{ .key = 'g', .fmt = .gzip }) catch {};
        if (toolAvailable(io, "xz")) out.append(gpa, .{ .key = 'z', .fmt = .xz }) catch {};
        if (toolAvailable(io, "bzip2")) out.append(gpa, .{ .key = 'b', .fmt = .bzip2 }) catch {};
        if (toolAvailable(io, "zstd")) out.append(gpa, .{ .key = 's', .fmt = .zstd }) catch {};
        if (toolAvailable(io, "lzip")) out.append(gpa, .{ .key = 'l', .fmt = .lzip }) catch {};
    } else {
        if (toolAvailable(io, "tar")) out.append(gpa, .{ .key = 't', .fmt = .tar_gz }) catch {};
        if (toolAvailable(io, "xz")) out.append(gpa, .{ .key = 'z', .fmt = .tar_xz }) catch {};
        if (toolAvailable(io, "bzip2")) out.append(gpa, .{ .key = 'b', .fmt = .tar_bz2 }) catch {};
        if (toolAvailable(io, "zstd")) out.append(gpa, .{ .key = 's', .fmt = .tar_zst }) catch {};
        if (toolAvailable(io, "lzip")) out.append(gpa, .{ .key = 'l', .fmt = .tar_lz }) catch {};
    }
    if (toolAvailable(io, "zip")) out.append(gpa, .{ .key = 'p', .fmt = .zip }) catch {};
    if (toolRuns(io, &.{ "7z", "i" })) out.append(gpa, .{ .key = '7', .fmt = .seven_z }) catch {};
}

fn compressFmtName(fmt: CompressFmt) []const u8 {
    return switch (fmt) {
        .gzip => "gzip",
        .xz => "xz",
        .bzip2 => "bzip2",
        .zstd => "zstd",
        .lzip => "lzip",
        .tar_gz => "tar.gz",
        .tar_xz => "tar.xz",
        .tar_bz2 => "tar.bz2",
        .tar_zst => "tar.zst",
        .tar_lz => "tar.lz",
        .zip => "zip",
        .seven_z => "7z",
    };
}

fn compressFmtSuffix(fmt: CompressFmt) []const u8 {
    return switch (fmt) {
        .gzip => ".gz",
        .xz => ".xz",
        .bzip2 => ".bz2",
        .zstd => ".zst",
        .lzip => ".lz",
        .tar_gz => ".tar.gz",
        .tar_xz => ".tar.xz",
        .tar_bz2 => ".tar.bz2",
        .tar_zst => ".tar.zst",
        .tar_lz => ".tar.lz",
        .zip => ".zip",
        .seven_z => ".7z",
    };
}

/// Whether `fmt` builds an archive (tar / zip / 7z) rather than
/// compressing a single file in place.
fn compressFmtArchives(fmt: CompressFmt) bool {
    return switch (fmt) {
        .gzip, .xz, .bzip2, .zstd, .lzip => false,
        else => true,
    };
}

/// "g gzip, z xz, ..." — the choice list for the modeline menu.
fn compressMenuText(buf: []u8, choices: []const CompressChoice) []const u8 {
    var pos: usize = 0;
    for (choices, 0..) |c, i| {
        const piece = if (i == 0)
            (std.fmt.bufPrint(buf[pos..], "{c} {s}", .{ c.key, compressFmtName(c.fmt) }) catch return buf[0..pos])
        else
            (std.fmt.bufPrint(buf[pos..], ", {c} {s}", .{ c.key, compressFmtName(c.fmt) }) catch return buf[0..pos]);
        pos += piece.len;
    }
    return buf[0..pos];
}

/// `s` single-quoted for the shell, embedded single quotes escaped as
/// '\'' — the argument quoting for the tar pipelines james builds.
fn shellQuote(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.append(gpa, '\'');
    for (s) |c| {
        if (c == '\'') try out.appendSlice(gpa, "'\\''")
        else try out.append(gpa, c);
    }
    try out.append(gpa, '\'');
    return out.toOwnedSlice(gpa);
}

/// `s` single-quoted for PowerShell, embedded single quotes doubled.
fn psQuote(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.append(gpa, '\'');
    for (s) |c| {
        if (c == '\'') try out.appendSlice(gpa, "''")
        else try out.append(gpa, c);
    }
    try out.append(gpa, '\'');
    return out.toOwnedSlice(gpa);
}

/// The POSIX pipeline for a tar.* format — "tar --force-local -cf - <opds>
/// | <tool> <flag> > <out>" through /bin/sh (spawn can't express a pipe).
fn tarPipeline(gpa: std.mem.Allocator, fmt: CompressFmt, opds: []const []const u8, out: []const u8) ![]const []const u8 {
    var cmd: std.ArrayList(u8) = .empty;
    defer cmd.deinit(gpa);
    try cmd.appendSlice(gpa, "tar --force-local -cf -");
    for (opds) |p| {
        try cmd.append(gpa, ' ');
        const q = try shellQuote(gpa, p);
        defer gpa.free(q);
        try cmd.appendSlice(gpa, q);
    }
    const tool: []const u8 = switch (fmt) {
        .tar_xz => "xz",
        .tar_bz2 => "bzip2",
        .tar_zst => "zstd",
        .tar_lz => "lzip",
        else => unreachable,
    };
    const flag: []const u8 = switch (fmt) {
        .tar_xz => "-9e",
        else => "-9",
    };
    try cmd.appendSlice(gpa, " | ");
    try cmd.appendSlice(gpa, tool);
    try cmd.append(gpa, ' ');
    try cmd.appendSlice(gpa, flag);
    try cmd.appendSlice(gpa, " > ");
    const qout = try shellQuote(gpa, out);
    defer gpa.free(qout);
    try cmd.appendSlice(gpa, qout);
    const sh_cmd = try gpa.dupe(u8, cmd.items);
    return &.{ "sh", "-c", sh_cmd };
}

/// Run the chosen compression on `opds` (full paths). Archive formats
/// create `out` (the full output path); the single-file tools compress
/// each operand in place, replacing it. Returns true on success.
fn diredCompressRun(io: std.Io, gpa: std.mem.Allocator, fmt: CompressFmt, opds: []const []const u8, out: ?[]const u8) bool {
    // The argv james builds itself (the PowerShell command, the tar
    // pipeline string, the archive argv arrays) is freed after the run.
    var owned: []const u8 = &.{};
    defer if (owned.len > 0) gpa.free(owned);
    var owned_argv: ?[]const []const u8 = null;
    defer if (owned_argv) |a| gpa.free(a);
    const argv: ?[]const []const u8 = if (comptime builtin.os.tag == .windows)
        switch (fmt) {
            .zip => blk: {
                // PowerShell's Compress-Archive: a comma-separated list of
                // single-quoted paths, then the destination.
                var ps: std.ArrayList(u8) = .empty;
                ps.appendSlice(gpa, "Compress-Archive -Path ") catch break :blk null;
                for (opds, 0..) |p, i| {
                    if (i > 0) ps.append(gpa, ',') catch break :blk null;
                    ps.append(gpa, '\'') catch break :blk null;
                    const q = psQuote(gpa, p) catch break :blk null;
                    ps.appendSlice(gpa, q) catch break :blk null;
                    gpa.free(q);
                    ps.append(gpa, '\'') catch break :blk null;
                }
                ps.appendSlice(gpa, " -DestinationPath '") catch break :blk null;
                const qout = psQuote(gpa, out orelse break :blk null) catch break :blk null;
                ps.appendSlice(gpa, qout) catch break :blk null;
                gpa.free(qout);
                ps.appendSlice(gpa, "'") catch break :blk null;
                owned = ps.toOwnedSlice(gpa) catch break :blk null;
                break :blk &.{ "powershell.exe", "-NoProfile", "-Command", owned };
            },
            .tar_gz, .tar_xz, .tar_bz2 => blk: {
                // tar.exe (bsdtar): -a picks the compressor from the
                // output suffix, so one command serves all three.
                const n = 3 + opds.len;
                const argv2 = gpa.alloc([]const u8, n) catch break :blk null;
                argv2[0] = "tar";
                argv2[1] = "-acf";
                argv2[2] = out orelse break :blk null;
                @memcpy(argv2[3..], opds);
                owned_argv = argv2;
                break :blk argv2;
            },
            .seven_z => blk: {
                const n = 3 + opds.len;
                const argv2 = gpa.alloc([]const u8, n) catch break :blk null;
                argv2[0] = "7z";
                argv2[1] = "a";
                argv2[2] = out orelse break :blk null;
                @memcpy(argv2[3..], opds);
                owned_argv = argv2;
                break :blk argv2;
            },
            else => null,
        }
    else
        switch (fmt) {
            .gzip => &.{ "gzip", "-9", opds[0] },
            .xz => &.{ "xz", "-9e", opds[0] },
            .bzip2 => &.{ "bzip2", "-9", opds[0] },
            .zstd => &.{ "zstd", "-19", opds[0] },
            .lzip => &.{ "lzip", "-9", opds[0] },
            .tar_gz => blk: {
                const n = 4 + opds.len;
                const argv2 = gpa.alloc([]const u8, n) catch break :blk null;
                argv2[0] = "tar";
                argv2[1] = "--force-local";
                argv2[2] = "-czf";
                argv2[3] = out orelse break :blk null;
                @memcpy(argv2[4..], opds);
                owned_argv = argv2;
                break :blk argv2;
            },
            .tar_xz, .tar_bz2, .tar_zst, .tar_lz => blk: {
                // A pipeline ("tar -cf - <opds> | xz -9e > <out>"), through
                // the shell; the command string is freed after the run.
                const cmd = tarPipeline(gpa, fmt, opds, out orelse return false) catch return false;
                owned = cmd[2];
                break :blk cmd;
            },
            .zip => blk: {
                const n = 3 + opds.len;
                const argv2 = gpa.alloc([]const u8, n) catch break :blk null;
                argv2[0] = "zip";
                argv2[1] = "-r";
                argv2[2] = out orelse break :blk null;
                @memcpy(argv2[3..], opds);
                owned_argv = argv2;
                break :blk argv2;
            },
            .seven_z => blk: {
                const n = 3 + opds.len;
                const argv2 = gpa.alloc([]const u8, n) catch break :blk null;
                argv2[0] = "7z";
                argv2[1] = "a";
                argv2[2] = out orelse break :blk null;
                @memcpy(argv2[3..], opds);
                owned_argv = argv2;
                break :blk argv2;
            },
        };
    const a = argv orelse return false;
    return runTool(io, a);
}

/// Ends with `suffix`, ASCII case-insensitive (the compressed-file suffix
/// check: ".TAR.GZ" counts).
fn endsWithIgnoreCase(s: []const u8, suffix: []const u8) bool {
    if (s.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(s[s.len - suffix.len ..], suffix);
}

/// The compression kind a file name carries (case-insensitive), or null.
const CompressedKind = enum { gzip, bzip2, xz, zstd, lzip, seven_z, zip, tar, tgz, tar_gz, tar_bz2, tar_xz, tar_zst, tar_lz };

fn compressedKindOf(name: []const u8) ?CompressedKind {
    if (endsWithIgnoreCase(name, ".tar.gz")) return .tar_gz;
    if (endsWithIgnoreCase(name, ".tar.bz2")) return .tar_bz2;
    if (endsWithIgnoreCase(name, ".tar.xz")) return .tar_xz;
    if (endsWithIgnoreCase(name, ".tar.zst")) return .tar_zst;
    if (endsWithIgnoreCase(name, ".tar.lz")) return .tar_lz;
    if (endsWithIgnoreCase(name, ".tgz")) return .tgz;
    if (endsWithIgnoreCase(name, ".gz")) return .gzip;
    if (endsWithIgnoreCase(name, ".bz2")) return .bzip2;
    if (endsWithIgnoreCase(name, ".xz")) return .xz;
    if (endsWithIgnoreCase(name, ".zst")) return .zstd;
    if (endsWithIgnoreCase(name, ".lz")) return .lzip;
    if (endsWithIgnoreCase(name, ".7z")) return .seven_z;
    if (endsWithIgnoreCase(name, ".zip")) return .zip;
    if (endsWithIgnoreCase(name, ".tar")) return .tar;
    return null;
}

/// Decompress one file: the single-file formats replace the file in place
/// (foo.tar.gz's .gz stripped), the archives extract into the file's
/// directory. True on success; a suffix with no standard tool on this
/// platform (e.g. a bare .gz on Windows) reports failure.
fn diredDecompressRun(io: std.Io, gpa: std.mem.Allocator, path: []const u8) bool {
    const kind = compressedKindOf(path) orelse return false;
    const dir = std.fs.path.dirname(path) orelse ".";
    // The argv james builds itself (the -o and PowerShell command
    // strings) is freed after the run.
    var owned: []const u8 = &.{};
    defer if (owned.len > 0) gpa.free(owned);
    const cmd: ?[]const []const u8 = switch (kind) {
        .gzip => if (comptime builtin.os.tag == .windows) null else &.{ "gzip", "-d", path },
        .bzip2 => if (comptime builtin.os.tag == .windows) null else &.{ "bzip2", "-d", path },
        .xz => if (comptime builtin.os.tag == .windows) null else &.{ "xz", "-d", path },
        .zstd => if (comptime builtin.os.tag == .windows) null else &.{ "zstd", "-d", path },
        .lzip => if (comptime builtin.os.tag == .windows) null else &.{ "lzip", "-d", path },
        .seven_z => if (toolRuns(io, &.{ "7z", "i" })) blk: {
            owned = std.fmt.allocPrint(gpa, "-o{s}", .{dir}) catch break :blk null;
            break :blk &.{ "7z", "x", path, owned };
        } else null,
        .zip => if (comptime builtin.os.tag == .windows) blk: {
            const qp = psQuote(gpa, path) catch break :blk null;
            defer gpa.free(qp);
            const qd = psQuote(gpa, dir) catch break :blk null;
            defer gpa.free(qd);
            owned = std.fmt.allocPrint(gpa, "Expand-Archive -Path {s} -DestinationPath {s} -Force", .{ qp, qd }) catch break :blk null;
            break :blk &.{ "powershell.exe", "-NoProfile", "-Command", owned };
        } else if (toolAvailable(io, "unzip")) &.{ "unzip", path, "-d", dir } else null,
        .tar, .tgz, .tar_gz, .tar_bz2, .tar_xz, .tar_zst, .tar_lz => &.{ "tar", "-xf", path, "-C", dir },
    };
    const a = cmd orelse return false;
    return runTool(io, a);
}

/// "1.2K", "34M" — `bytes` humanized, into `buf`.
fn humanSize(bytes: u64, buf: []u8) []const u8 {
    const units = "KMGT";
    if (bytes < 1024) return std.fmt.bufPrint(buf, "{d}B", .{bytes}) catch "";
    var v: f64 = @floatFromInt(bytes);
    var u: usize = 0;
    while (v >= 1024 and u < units.len) : (u += 1) v /= 1024;
    return std.fmt.bufPrint(buf, "{d:.1}{c}", .{ v, units[u - 1] }) catch "";
}

/// The transient status for a finished compression: "Compressed
/// foo.tar.gz (1.2K)", the size from a stat of `result` when it exists.
fn compressStatus(io: std.Io, status_msg: *?[]const u8, status_buf: *[2048]u8, result: []const u8) void {
    var size_buf: [16]u8 = undefined;
    var size_str: []const u8 = "";
    if (std.Io.Dir.cwd().statFile(io, result, .{ .follow_symlinks = false })) |st| {
        size_str = humanSize(st.size, &size_buf);
    } else |_| {}
    const n = if (size_str.len > 0)
        (std.fmt.bufPrint(status_buf, "Compressed {s} ({s})", .{ std.fs.path.basename(result), size_str }) catch unreachable)
    else
        (std.fmt.bufPrint(status_buf, "Compressed {s}", .{std.fs.path.basename(result)}) catch unreachable);
    status_msg.* = status_buf[0..n.len];
}

// --- C-c g grep (my/grep) ----------------------------------------------
//
// Mirrors the author's Emacs my/grep: ripgrep when it's on the PATH
// (--smart-case, columns and line numbers), with the platform's built-in
// grep as fallback — grep -rni on POSIX, findstr /s /n /i on Windows
// (Windows has no grep, but findstr has shipped with every Windows since
// NT 4, so the fallback always exists there).

/// One parsed grep result: the file, the 1-based line and column of the
/// match (column 0 when the tool didn't report one), and the text the
/// buffer shows for it. `path` is heap-allocated.
const GrepMatch = struct {
    path: []u8,
    line: usize,
    col: usize,
};

/// One occur result: the 0-based row of a matching line and the byte
/// column of its first match — the match itself is the occur term,
/// matched ASCII case-insensitively like isearch. No heap, so the
/// occur list clears without per-item frees.
const OccurMatch = struct {
    row: usize,
    col: usize,
};

/// A transient highlight of the grepped term in the target file, like
/// Emacs's next-error-highlight: set on every grep jump and drawn for a
/// moment (GREP_HL_NS), so the match is easy to spot while stepping
/// through the results. `buf` is the buffer pointer (stable across
/// buffer-index shifts); `row`/`col` are the match position and `len`
/// the matched bytes.
const GrepHl = struct {
    buf: *Buffer,
    row: usize,
    col: usize,
    len: usize,
    set_at: i128,
};

/// How long the grep match highlight stays visible after a jump.
const GREP_HL_NS: i128 = 2 * std.time.ns_per_s;

/// The *grep* results buffer state threaded into the renderers: the
/// modeline (label, count, follow) and the transient match highlight.
const GrepView = struct {
    buf: *Buffer,
    count: usize,
    follow: bool,
    hl: ?GrepHl,
};

/// The *files* results buffer state threaded into the renderers: the
/// modeline (label, count, follow, filter) and the per-row filter
/// highlight.
const FilesView = struct {
    buf: *Buffer,
    count: usize,
    follow: bool,
    filter: []const u8,
    row_hl: []const FuzzyHl,
};

/// Parse one grep result line into a match: the first "colon, digits,
/// [colon, digits], colon" segment ends the file path — ripgrep prints
/// "path:line:col: text", grep and findstr "path:line:text" (findstr with
/// a trailing \r). Returns null when the line isn't a result.
fn parseGrepLine(gpa: std.mem.Allocator, line: []const u8) ?GrepMatch {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != ':') continue;
        const line_start = i + 1;
        var j = line_start;
        while (j < line.len and std.ascii.isDigit(line[j])) j += 1;
        if (j == line_start) continue;
        const line_num = std.fmt.parseUnsigned(usize, line[line_start..j], 10) catch continue;
        var col: usize = 0;
        if (j < line.len and line[j] == ':') {
            // "line:col: text" (rg) or "line:text" (grep): try the column.
            const col_start = j + 1;
            var k = col_start;
            while (k < line.len and std.ascii.isDigit(line[k])) k += 1;
            if (k > col_start and k < line.len and line[k] == ':') {
                col = std.fmt.parseUnsigned(usize, line[col_start..k], 10) catch 0;
                j = k;
            }
        }
        if (j >= line.len or line[j] != ':') continue;
        const path = std.mem.trim(u8, line[0..i], " \t");
        if (path.len == 0) continue;
        return .{
            .path = gpa.dupe(u8, path) catch return null,
            .line = line_num,
            .col = col,
        };
    }
    return null;
}

/// Run the grep over `dir` for `term`, returning the raw output (null on
/// failure or no matches): ripgrep first, then grep (POSIX) / findstr
/// (Windows).
fn grepRun(io: std.Io, gpa: std.mem.Allocator, dir: []const u8, term: []const u8) ?[]u8 {
    if (comptime builtin.os.tag == .windows) {
        if (runCapture(io, gpa, &.{ "rg", "--color=never", "--column", "--line-number", "--no-heading", "--smart-case", "-e", term, dir })) |out| return out;
        const literal = std.fmt.allocPrint(gpa, "/c:{s}", .{term}) catch return null;
        defer gpa.free(literal);
        const pattern = if (dir.len > 0 and dir[dir.len - 1] == std.fs.path.sep)
            std.fmt.allocPrint(gpa, "{s}*", .{dir}) catch return null
        else
            std.fmt.allocPrint(gpa, "{s}{c}*", .{ dir, std.fs.path.sep }) catch return null;
        defer gpa.free(pattern);
        return runCapture(io, gpa, &.{ "findstr", "/s", "/n", "/i", literal, pattern });
    }
    if (runCapture(io, gpa, &.{ "rg", "--color=never", "--column", "--line-number", "--no-heading", "--smart-case", "-e", term, dir })) |out| return out;
    return runCapture(io, gpa, &.{ "grep", "-rni", "-e", term, dir });
}

/// Run the platform's file-finder over `dir`, returning the file list
/// (null on failure): ripgrep --files when available, then the built-in
/// find — `find -type f` on POSIX, Windows' `dir /s /b` (Windows has no
/// find that lists names: its find.exe searches file contents, the
/// DOS-era grep — dir is the name lister).
fn findRun(io: std.Io, gpa: std.mem.Allocator, dir: []const u8) ?[]u8 {
    if (comptime builtin.os.tag == .windows) {
        if (runCapture(io, gpa, &.{ "rg", "--files", dir })) |out| return out;
        return runCapture(io, gpa, &.{ "cmd.exe", "/c", "dir", "/s", "/b", dir });
    }
    if (runCapture(io, gpa, &.{ "rg", "--files", dir })) |out| return out;
    return runCapture(io, gpa, &.{ "find", dir, "-type", "f" });
}

/// The application the desktop would use to open `path` externally: on
/// Linux the MIME default handler from xdg-mime (firefox.desktop →
/// firefox), otherwise the generic opener that `openExternal` would run
/// (open on macOS, start on Windows). Null when the handler can't be
/// looked up.
fn defaultOpenApp(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    if (comptime builtin.os.tag == .linux) {
        const ftype = runCapture(io, gpa, &.{ "xdg-mime", "query", "filetype", path }) orelse return null;
        defer gpa.free(ftype);
        const raw = runCapture(io, gpa, &.{ "xdg-mime", "query", "default", ftype }) orelse return null;
        defer gpa.free(raw);
        const app = std.fs.path.stem(raw);
        return if (app.len > 0) gpa.dupe(u8, app) catch null else null;
    }
    const name: []const u8 = if (comptime builtin.os.tag == .macos) "open" else "start";
    return gpa.dupe(u8, name) catch null;
}

// --- native Windows clipboard ------------------------------------------
//
// The Windows console's OSC 52 support is spotty (the legacy console
// ignores it entirely, and Windows Terminal gates it behind settings), so
// on Windows the kill-ring <-> clipboard sync goes through the Win32
// clipboard API instead of an OSC 52 round trip through the terminal.
// These externs are only analyzed when the Windows helpers are called, so
// Unix builds never reference them (or need user32).

const CF_UNICODETEXT: windows.UINT = 13;
const GMEM_MOVEABLE: windows.UINT = 0x2;

extern "user32" fn OpenClipboard(hWndNewOwner: ?windows.HWND) callconv(.winapi) windows.BOOL;
extern "user32" fn EmptyClipboard() callconv(.winapi) windows.BOOL;
extern "user32" fn CloseClipboard() callconv(.winapi) windows.BOOL;
extern "user32" fn SetClipboardData(uFormat: windows.UINT, hMem: windows.HANDLE) callconv(.winapi) ?windows.HANDLE;
extern "user32" fn GetClipboardData(uFormat: windows.UINT) callconv(.winapi) ?windows.HANDLE;
extern "user32" fn IsClipboardFormatAvailable(format: windows.UINT) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GlobalAlloc(uFlags: windows.UINT, dwBytes: usize) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn GlobalLock(hMem: windows.HANDLE) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(hMem: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GlobalFree(hMem: windows.HANDLE) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn GlobalSize(hMem: windows.HANDLE) callconv(.winapi) usize;

/// Put `text` on the Win32 clipboard as CF_UNICODETEXT. The clipboard
/// owns the allocated block once SetClipboardData succeeds; on any
/// failure the block is freed here. Returns whether the clipboard was
/// written.
fn winClipboardSet(gpa: std.mem.Allocator, text: []const u8) bool {
    var utf16: std.ArrayList(u16) = .empty;
    defer utf16.deinit(gpa);
    utf16.ensureTotalCapacity(gpa, text.len) catch return false;
    const n = std.unicode.utf8ToUtf16Le(utf16.unusedCapacitySlice(), text) catch return false;
    utf16.items.len = n;

    const bytes: usize = (utf16.items.len + 1) * @sizeOf(u16);
    const h = GlobalAlloc(GMEM_MOVEABLE, bytes) orelse return false;
    if (GlobalLock(h)) |p| {
        const dst: [*]u16 = @ptrCast(@alignCast(p));
        @memcpy(dst[0..utf16.items.len], utf16.items);
        dst[utf16.items.len] = 0;
        _ = GlobalUnlock(h);
    } else {
        _ = GlobalFree(h);
        return false;
    }
    if (OpenClipboard(null) == .FALSE) {
        _ = GlobalFree(h);
        return false;
    }
    defer _ = CloseClipboard();
    _ = EmptyClipboard();
    if (SetClipboardData(CF_UNICODETEXT, h) == null) {
        _ = GlobalFree(h);
        return false;
    }
    return true;
}

/// Read the Win32 clipboard's CF_UNICODETEXT as UTF-8, or null when there
/// is no text on the clipboard. Caller frees with gpa.
fn winClipboardGet(gpa: std.mem.Allocator) ?[]u8 {
    if (IsClipboardFormatAvailable(CF_UNICODETEXT) == .FALSE) return null;
    if (OpenClipboard(null) == .FALSE) return null;
    defer _ = CloseClipboard();
    const h = GetClipboardData(CF_UNICODETEXT) orelse return null;
    const p = GlobalLock(h) orelse return null;
    defer _ = GlobalUnlock(h);
    const len = GlobalSize(h) / @sizeOf(u16);
    if (len == 0) return null;
    const src: [*]const u16 = @ptrCast(@alignCast(p));
    var n: usize = 0;
    while (n < len and src[n] != 0) : (n += 1) {}
    return std.unicode.utf16LeToUtf8Alloc(gpa, src[0..n]) catch null;
}

/// Mirror the kill ring onto the system clipboard (OSC 52), so a kill or
/// copy in james is available to other applications — even over ssh, since
/// the terminal forwards the sequence. Terminals without OSC 52 support
/// simply ignore it. On Windows the Win32 clipboard API is used instead,
/// since the console's OSC 52 support is spotty.
fn syncClipboard(vx: *vaxis.Vaxis, tty: *vaxis.Tty, gpa: std.mem.Allocator, kill_ring: []const u8) void {
    if (comptime builtin.os.tag == .windows) {
        _ = winClipboardSet(gpa, kill_ring);
        return;
    }
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
fn renderDiredPane(win: vaxis.Window, dired: *Dired, is_focused: bool, row_base: u16, height: u16, modeline_buf: []u8, find_file: ?FindFileView, bookmark_prompt: ?BookmarkPromptView, goto_prompt: ?GotoPromptView, grep_prompt: ?GrepPromptView, grep_view: ?GrepView, files_view: ?FilesView, occur_view: ?GrepView, grep_hl: ?GrepHl, search: ?IsearchView, replace: ?ReplaceView, compress_menu: ?CompressMenuView, archive_query: ?[]const u8, dired_prompt: ?DiredPromptView, status: ?[]const u8) void {
    // Query-replace never runs in a dired (editing buffers only), so the
    // replace view is ignored here; the parameter keeps the call chain
    // uniform with renderPane.
    _ = replace;
    // The results buffers never render through a dired pane; the
    // parameters exist so both leaf renderers share the renderTree
    // signature.
    _ = grep_view;
    _ = files_view;
    _ = occur_view;
    _ = grep_hl;
    const text_height: usize = if (height > 1) height - 1 else height;
    // The full directory path heads the listing (the classic dired header
    // line), taking one row unless the pane is too small to spare it.
    const show_header = text_height >= 2;
    const entry_rows = if (show_header) text_height - 1 else text_height;
    dired.scrollToSelected(entry_rows);
    // Entries print their own heap-allocated metadata prefix and name
    // (plus a "/" segment for directories), never a stack-local copy —
    // vaxis stores grapheme slices, so a scratch buffer would be clobbered
    // by the next pane rendered in the same frame. An active isearch
    // highlights the matched part of the entry's name.
    const searching = search != null;
    const match: ?Buffer.Pos = if (search) |s| (if (s.failed) null else s.match) else null;
    const query_len: usize = if (search) |s| s.query.len else 0;

    var row: u16 = 0;
    if (show_header) {
        _ = win.printSegment(.{ .text = dired.display_path.items }, .{ .row_offset = row_base });
        row = 1;
    }
    var i = dired.top;
    while (i < dired.entries.items.len and row < text_height) : (i += 1) {
        const e = dired.entries.items[i];
        // A marked entry's whole row is highlighted in reverse video (the
        // * in column 0 is the mark itself); the selected entry's row is
        // bold, like the cursor's line in a file buffer. An isearch match
        // on a highlighted row drops the reverse (plain bold) so it stays
        // distinct against the row.
        const is_marked = e.marked;
        const current = i == dired.selected;
        const style: vaxis.Style = if (is_marked) highlight_style else if (current) .{ .bold = true } else .{};
        const hl_style: vaxis.Style = if (is_marked) .{ .bold = true } else if (current) .{ .reverse = true, .bold = true } else highlight_style;
        // Column 0 is the mark column, like Emacs: "*" for a marked
        // entry, a blank otherwise.
        _ = win.printSegment(.{ .text = if (e.marked) "*" else " ", .style = style }, .{ .row_offset = row_base + row });
        // ( toggles dired-hide-details-mode: with the details hidden the
        // metadata prefix (permissions, size, date) is skipped, so only
        // the names remain — the mark column and name line up as usual.
        const name_col: u16 = if (dired.hide_details) 1 else 1 + win.gwidth(e.meta);
        if (!dired.hide_details) {
            _ = win.printSegment(.{ .text = e.meta, .style = style }, .{ .row_offset = row_base + row, .col_offset = 1 });
        }
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
            _ = win.printSegment(.{ .text = e.name[h.start..h.end], .style = hl_style }, .{ .row_offset = row_base + row, .col_offset = col });
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

    const ml: PromptModeline = if (find_file) |f|
        fillPromptModeline(modeline_buf, "Find file: ", .{}, f.query)
    else if (bookmark_prompt) |p| blk: {
        if (p.set) break :blk fillPromptModeline(modeline_buf, "Bookmark name (C-g cancels): ", .{}, p.query);
        break :blk fillPromptModeline(modeline_buf, "Jump to bookmark (C-g cancels): ", .{}, p.query);
    } else if (goto_prompt) |g|
        fillPromptModeline(modeline_buf, "Goto line (C-g cancels): ", .{}, g.query)
    else if (grep_prompt) |g|
        fillPromptModeline(modeline_buf, "{s}", .{g.label}, g.query)
    else if (search) |s| blk: {
        const label = if (s.failed)
            (if (s.backward) "Failing I-search backward" else "Failing I-search")
        else
            (if (s.backward) "I-search backward" else "I-search");
        // The lazy count ("I-search: term (3/12)", like Emacs) trails the
        // query in the same plain style.
        var count_buf: [32]u8 = undefined;
        const suffix = isearchCountSuffix(&count_buf, s.query, s.pos, s.count);
        var query_buf: [2048]u8 = undefined;
        const query_with_count = if (suffix.len > 0)
            (std.fmt.bufPrint(&query_buf, "{s}{s}", .{ s.query, suffix }) catch s.query)
        else
            s.query;
        break :blk fillPromptModeline(modeline_buf, "{s}: ", .{label}, query_with_count);
    } else if (compress_menu) |m| blk: {
        // Z's format menu: the label bold, the one-key choices plain.
        break :blk fillPromptModeline(modeline_buf, "{s}", .{m.label}, m.choices);
    } else if (archive_query) |q| blk: {
        break :blk fillPromptModeline(modeline_buf, "Archive name (C-g cancels): ", .{}, q);
    } else if (dired_prompt) |p| blk: {
        const is_dir = dired.selected < dired.entries.items.len and dired.entries.items[dired.selected].is_dir;
        const name = if (dired.selected < dired.entries.items.len) dired.entries.items[dired.selected].name else "";
        break :blk switch (p.kind) {
            .copy => copy_blk: {
                const n = diredMarkedCount(dired);
                if (n > 1) break :copy_blk fillPromptModeline(modeline_buf, "Copy {d} entries to (C-g cancels): ", .{n}, p.query);
                break :copy_blk fillPromptModeline(modeline_buf, "Copy {s}{s} to (C-g cancels): ", .{ if (is_dir) "directory " else "", name }, p.query);
            },
            .rename => rename_blk: {
                const n = diredMarkedCount(dired);
                if (n > 1) break :rename_blk fillPromptModeline(modeline_buf, "Rename {d} entries to (C-g cancels): ", .{n}, p.query);
                break :rename_blk fillPromptModeline(modeline_buf, "Rename {s}{s} to (C-g cancels): ", .{ if (is_dir) "directory " else "", name }, p.query);
            },
            .create_dir => fillPromptModeline(modeline_buf, "Create directory (C-g cancels): ", .{}, p.query),
            .create_file => fillPromptModeline(modeline_buf, "Create file (C-g cancels): ", .{}, p.query),
            .delete => if (diredMarkedCount(dired) > 1)
                fillPromptModeline(modeline_buf, "Move {d} entries to the trash? (y / n / C-g cancels)", .{diredMarkedCount(dired)}, "")
            else
                fillPromptModeline(modeline_buf, "Move {s}{s} to the trash? (y / n / C-g cancels)", .{ if (is_dir) "directory " else "", name }, ""),
            .open => fillPromptModeline(modeline_buf, "Open {s} with {s}? (y / n / C-g cancels)", .{ name, p.detail }, ""),
        };
    } else if (status) |m| blk: {
        const n = std.fmt.bufPrint(modeline_buf, "{s}", .{m}) catch break :blk .{ .len = 0, .label_len = 0 };
        break :blk .{ .len = n.len, .label_len = 0 };
    } else blk: {
        const n = std.fmt.bufPrint(modeline_buf, "Dired: {s}{s}", .{ dired.display_path.items, if (dired.hide_details) " (Hide-Details)" else "" }) catch break :blk .{ .len = 0, .label_len = 0 };
        break :blk .{ .len = n.len, .label_len = 0 };
    };
    const style: vaxis.Style = if (is_focused) highlight_style else .{ .dim = true };
    printModeline(win, modeline_buf, ml, style, row_base + (height -| 1));

    if (is_focused) {
        // The cursor sits at the start of the entry's name, after the
        // mark column and the metadata prefix, rather than at the start
        // of the line.
        const sel = dired.selected;
        const name_col: u16 = if (sel < dired.entries.items.len)
            1 + win.gwidth(dired.entries.items[sel].meta)
        else
            0;
        win.showCursor(name_col, @intCast(sel - dired.top + @as(usize, @intFromBool(show_header))));
    }
}

/// Render the pane tree rooted at `pane` into `win`. Each leaf gets a child
/// window at its computed rect and renders through `renderPane`; the focused
/// pane is the one showing the cursor. `modeline_bufs` gives every leaf
/// somewhere scratchy to format its modeline. While dired is open it takes
/// over the focused pane (via `renderDiredPane`), the list picker renders
/// inside it too (via `renderPicker`), and every other pane keeps showing
/// its buffer.
/// Render the list picker (buffers / bookmarks / recent files) into
/// `win`: one row per visible entry with the filter's matched characters
/// highlighted, the modeline naming the list and the filter, the block
/// cursor on the selection. `win` is the whole window for a lone pane,
/// the focused pane of a split otherwise, so the layout stays intact
/// while picking. The modeline text is built in `modeline_buf`, which
/// the caller keeps alive until after the frame — vaxis stores grapheme
/// slices, not copies.
fn renderPicker(
    win: vaxis.Window,
    io: std.Io,
    view: PickerView,
    buffers: []*Buffer,
    bookmarks: []const Bookmark,
    recent: []const []const u8,
    modeline_buf: []u8,
    search: ?IsearchView,
) void {
    const text_height: usize = if (win.height > 1) win.height - 1 else win.height;
    const sel_pos = pickerSelectionPos(view.visible, view.selected);
    if (text_height > 0) {
        if (sel_pos < view.top.*) {
            view.top.* = sel_pos;
        } else if (sel_pos >= view.top.* + text_height) {
            view.top.* = sel_pos - text_height + 1;
        }
    }
    const label = switch (view.kind) {
        .buffers => "Buffers",
        .bookmarks => "Bookmarks",
        .recent => "Recent files",
    };
    var list_row: u16 = 0;
    var i = view.top.*;
    while (i < view.visible.len and list_row < text_height) : (i += 1) {
        const full = view.visible[i];
        const name = pickerRowName(view.kind, buffers, bookmarks, recent, full);
        // For bookmarks and recent files the base directory is dimmed
        // after the name (a dired bookmark's path is a directory, so it
        // shows itself; otherwise the parent).
        const dir: ?[]const u8 = switch (view.kind) {
            .bookmarks => blk: {
                const b = bookmarks[full];
                break :blk if (isDirectory(io, b.path)) b.path else std.fs.path.dirname(b.path);
            },
            .recent => std.fs.path.dirname(recent[full]),
            .buffers => null,
        };
        // An active isearch highlights the matched part of the name,
        // like the dired and file-buffer match highlights; otherwise an
        // active filter highlights the characters the fuzzy match hit,
        // so the rows show why they're there.
        const hl: ?Highlight = if (search != null and !search.?.failed) blk: {
            if (search.?.match) |m| {
                if (full == m.row) {
                    const start = @min(m.col, name.len);
                    const end = @min(m.col + search.?.query.len, name.len);
                    if (end > start) break :blk .{ .start = start, .end = end };
                }
            }
            break :blk null;
        } else null;
        const fuzzy_hl: ?FuzzyHl = if (hl == null and view.query.len > 0 and i < view.hl.len) view.hl[i] else null;
        if (hl) |h| {
            var col: u16 = 0;
            if (h.start > 0) {
                _ = win.printSegment(.{ .text = name[0..h.start], .style = .{} }, .{ .row_offset = list_row });
                col += win.gwidth(name[0..h.start]);
            }
            _ = win.printSegment(.{ .text = name[h.start..h.end], .style = highlight_style }, .{ .row_offset = list_row, .col_offset = col });
            col += win.gwidth(name[h.start..h.end]);
            if (h.end < name.len) {
                _ = win.printSegment(.{ .text = name[h.end..], .style = .{} }, .{ .row_offset = list_row, .col_offset = col });
            }
        } else if (fuzzy_hl) |fh| {
            // The filter's matched characters, highlighted one grapheme
            // at a time (the positions are byte offsets, and a match can
            // land mid-UTF-8).
            var seg_start: usize = 0;
            var col: u16 = 0;
            for (fh.positions[0..fh.len]) |p| {
                if (p >= name.len) break;
                var e = p + 1;
                while (e < name.len and (name[e] & 0xC0) == 0x80) e += 1;
                if (p > seg_start) {
                    _ = win.printSegment(.{ .text = name[seg_start..p], .style = .{} }, .{ .row_offset = list_row, .col_offset = col });
                    col += win.gwidth(name[seg_start..p]);
                }
                _ = win.printSegment(.{ .text = name[p..e], .style = highlight_style }, .{ .row_offset = list_row, .col_offset = col });
                col += win.gwidth(name[p..e]);
                seg_start = e;
            }
            if (seg_start < name.len) {
                _ = win.printSegment(.{ .text = name[seg_start..], .style = .{} }, .{ .row_offset = list_row, .col_offset = col });
            }
        } else {
            _ = win.printSegment(.{ .text = name, .style = .{} }, .{ .row_offset = list_row });
        }
        if (dir) |d| {
            _ = win.printSegment(.{ .text = d, .style = .{ .dim = true } }, .{ .row_offset = list_row, .col_offset = win.gwidth(name) + 2 });
        }
        list_row += 1;
    }
    if (search) |s| {
        const search_label = if (s.failed)
            (if (s.backward) "Failing I-search backward" else "Failing I-search")
        else
            (if (s.backward) "I-search backward" else "I-search");
        // The lazy count ("I-search: term (3/12)", like Emacs) trails
        // the query in the same plain style.
        var count_buf: [32]u8 = undefined;
        const suffix = isearchCountSuffix(&count_buf, s.query, s.pos, s.count);
        var query_buf: [2048]u8 = undefined;
        const query_with_count = if (suffix.len > 0)
            (std.fmt.bufPrint(&query_buf, "{s}{s}", .{ s.query, suffix }) catch s.query)
        else
            s.query;
        const ml = fillPromptModeline(modeline_buf, "{s}: ", .{search_label}, query_with_count);
        _ = win.printSegment(.{ .text = modeline_buf[0..ml.label_len], .style = .{ .bold = true } }, .{ .row_offset = win.height -| 1 });
        if (ml.label_len < ml.len) {
            _ = win.printSegment(.{ .text = modeline_buf[ml.label_len..ml.len], .style = .{} }, .{ .row_offset = win.height -| 1, .col_offset = win.gwidth(modeline_buf[0..ml.label_len]) });
        }
    } else if (view.query.len > 0) {
        const shown = if (view.visible.len > 0) sel_pos + 1 else 0;
        const list_ml = std.fmt.bufPrint(modeline_buf, "{s} ({d}/{d})   filter: {s}   (C-g/Esc closes, Enter opens, arrows move)", .{
            label,
            shown,
            view.visible.len,
            view.query,
        }) catch label;
        _ = win.printSegment(.{ .text = list_ml, .style = .{} }, .{ .row_offset = win.height -| 1 });
    } else {
        const count = pickerRowCount(view.kind, buffers, bookmarks, recent);
        const list_ml = std.fmt.bufPrint(modeline_buf, "{s} ({d}/{d})   (type to filter, C-s searches, Enter opens, arrows move, C-g/Esc closes)", .{
            label,
            sel_pos + 1,
            count,
        }) catch label;
        _ = win.printSegment(.{ .text = list_ml, .style = .{} }, .{ .row_offset = win.height -| 1 });
    }
    // No highlights: the block cursor marks the selection.
    win.showCursor(0, if (text_height > 0) @intCast(sel_pos - view.top.*) else 0);
}

fn renderTree(
    win: vaxis.Window,
    frame: *FrameAllocs,
    pane: *Pane,
    x_off: i17,
    y_off: u16,
    width: u16,
    height: u16,
    modeline_bufs: *[MAX_PANES][2048]u8,
    slot_counter: *usize,
    buffers: []*Buffer,
    direds: []?Dired,
    focused: *Pane,
    io: std.Io,
    picker: ?PickerView,
    bookmarks: []const Bookmark,
    recent: []const []const u8,
    quick_jump: bool,
    find_file: ?FindFileView,
    bookmark_prompt: ?BookmarkPromptView,
    goto_prompt: ?GotoPromptView,
    grep_prompt: ?GrepPromptView,
    grep_view: ?GrepView,
    files_view: ?FilesView,
    occur_view: ?GrepView,
    grep_hl: ?GrepHl,
    search: ?IsearchView,
    replace: ?ReplaceView,
    compress_menu: ?CompressMenuView,
    archive_query: ?[]const u8,
    dired_prompt: ?DiredPromptView,
    status: ?[]const u8,
    focused_h: *usize,
    focused_w: *usize,
) void {
    if (pane.isLeaf()) {
        // The focused pane's text area height and width, for C-l
        // (recenter-top-bottom), the visual-line navigation and anything
        // else that needs to know its window.
        if (pane == focused) {
            focused_h.* = if (height > 1) height - 1 else height;
            focused_w.* = width;
        }
        // Each leaf gets its own scratch slot, in render order — the
        // buffer must not be shared between panes, since vaxis stores
        // grapheme slices into it until the end of the frame.
        const slot = slot_counter.*;
        slot_counter.* += 1;
        // isearch operates on the focused buffer only: passing the match
        // to every pane would highlight the wrong window and could slice
        // past a shorter line in a neighbouring buffer.
        const pane_search: ?IsearchView = if (pane == focused) search else null;
        const pane_replace: ?ReplaceView = if (pane == focused) replace else null;
        const pane_prompt: ?DiredPromptView = if (pane == focused) dired_prompt else null;
        const pane_compress_menu: ?CompressMenuView = if (pane == focused) compress_menu else null;
        const pane_archive_query: ?[]const u8 = if (pane == focused) archive_query else null;
        const pane_find_file: ?FindFileView = if (pane == focused) find_file else null;
        const pane_bookmark_prompt: ?BookmarkPromptView = if (pane == focused) bookmark_prompt else null;
        const pane_goto_prompt: ?GotoPromptView = if (pane == focused) goto_prompt else null;
        const pane_grep_prompt: ?GrepPromptView = if (pane == focused) grep_prompt else null;
        const pane_grep_view: ?GrepView = if (grep_view) |gv| (if (buffers[pane.buf_idx] == gv.buf) gv else null) else null;
        const pane_files_view: ?FilesView = if (files_view) |fv| (if (buffers[pane.buf_idx] == fv.buf) fv else null) else null;
        const pane_occur_view: ?GrepView = if (occur_view) |ov| (if (buffers[pane.buf_idx] == ov.buf) ov else null) else null;
        const pane_grep_hl: ?GrepHl = if (grep_hl) |gh| (if (buffers[pane.buf_idx] == gh.buf) gh else null) else null;
        const pane_status: ?[]const u8 = if (pane == focused) status else null;
        const child = win.child(.{ .x_off = x_off, .y_off = y_off, .width = width, .height = height });
        if (pane == focused and picker != null) {
            // The list picker renders inside the focused pane, leaving
            // the split layout visible; a lone window shows it
            // full-screen (the single pane covers the whole window).
            renderPicker(child, io, picker.?, buffers, bookmarks, recent, &modeline_bufs[slot % MAX_PANES], pane_search);
        } else if (direds[pane.buf_idx]) |*d| {
            renderDiredPane(child, d, pane == focused, 0, height, &modeline_bufs[slot % MAX_PANES], pane_find_file, pane_bookmark_prompt, pane_goto_prompt, pane_grep_prompt, pane_grep_view, pane_files_view, pane_occur_view, pane_grep_hl, pane_search, pane_replace, pane_compress_menu, pane_archive_query, pane_prompt, pane_status);
        } else {
            renderPane(child, frame, buffers[pane.buf_idx], pane == focused, 0, height, &modeline_bufs[slot % MAX_PANES], pane_find_file, pane_bookmark_prompt, pane_goto_prompt, pane_grep_prompt, pane_grep_view, pane_files_view, pane_occur_view, pane_grep_hl, pane_search, pane_replace, pane_status);
        }
        // The M-o quick-jump label in the pane's top-left corner, on top
        // of the pane's own content (the slots count leaves in render
        // order, so the label index matches the label keys' window order).
        if (quick_jump and slot < quick_jump_labels.len) {
            _ = child.printSegment(.{ .text = quick_jump_labels[slot .. slot + 1], .style = highlight_style }, .{ .row_offset = 0, .col_offset = 0 });
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
            renderTree(win, frame, pane.left.?, x_off, y_off, left_w, height, modeline_bufs, slot_counter, buffers, direds, focused, io, picker, bookmarks, recent, quick_jump, find_file, bookmark_prompt, goto_prompt, grep_prompt, grep_view, files_view, occur_view, grep_hl, search, replace, compress_menu, archive_query, dired_prompt, status, focused_h, focused_w);
            renderTree(win, frame, pane.right.?, right_x, y_off, right_w, height, modeline_bufs, slot_counter, buffers, direds, focused, io, picker, bookmarks, recent, quick_jump, find_file, bookmark_prompt, goto_prompt, grep_prompt, grep_view, files_view, occur_view, grep_hl, search, replace, compress_menu, archive_query, dired_prompt, status, focused_h, focused_w);
        },
        .horizontal => {
            const top_h: u16 = @intCast((@as(u32, height) * pane.left_frac) / 256);
            // The bottom pane starts one row lower than it used to, leaving
            // a blank row between the panes for the separator (mirroring
            // the one blank column of a vertical split).
            drawHLine(win, @intCast(x_off), y_off + top_h, width);
            renderTree(win, frame, pane.left.?, x_off, y_off, width, top_h, modeline_bufs, slot_counter, buffers, direds, focused, io, picker, bookmarks, recent, quick_jump, find_file, bookmark_prompt, goto_prompt, grep_prompt, grep_view, files_view, occur_view, grep_hl, search, replace, compress_menu, archive_query, dired_prompt, status, focused_h, focused_w);
            renderTree(win, frame, pane.right.?, x_off, y_off + top_h + 1, width, height -| (top_h + 1), modeline_bufs, slot_counter, buffers, direds, focused, io, picker, bookmarks, recent, quick_jump, find_file, bookmark_prompt, goto_prompt, grep_prompt, grep_view, files_view, occur_view, grep_hl, search, replace, compress_menu, archive_query, dired_prompt, status, focused_h, focused_w);
        },
    }
}

/// The home screen shown when james starts without any file arguments.
/// It's a plain buffer (so movement, search and every C-x command work on
/// it) with no backing file; C-x d / C-x C-f lead somewhere real. The
/// version line is inserted between `welcome_head` and `welcome_tail` at
/// startup (see openWelcome), centered under the art so it's visible
/// however short the terminal is.
const welcome_head =
    \\      _   _    __  __ _____ ____
    \\     | | / \  |  \/  | ____/ ___|
    \\  _  | |/ _ \ | |\/| |  _| \___ \
    \\ | |_| / ___ \| |  | | |___ ___) |
    \\  \___/_/   \_\_|  |_|_____|____/
    \\
;

/// The greeting line under the version block: the one-line summary of
/// what james is. Shares the caption block's three-space margin, so the
/// whole block under the art reads as one left-aligned column.
const welcome_greeting =
    \\   Welcome to james, a minimal Emacs-inspired editor for the terminal.
;

/// The keybinding reference under the greeting, grouped by prefix (C-x,
/// C-c, M-l) and by context (dired, pickers, prompts). Kept in sync with
/// the dispatch in the event loop.
const welcome_tail =
    \\  No file was given, so this is the home screen. Get to work with:
    \\
    \\    C-x d / C-x m       browse files (dired)
    \\    C-x C-f             open or create a file
    \\    C-x b               pick an open buffer
    \\
    \\  C-x — files, buffers and windows:
    \\
    \\    C-x C-s             save the buffer (C-w saves too)
    \\    C-x C-c             quit (asks first if modified)
    \\    C-x u               undo
    \\    C-x k               kill the current buffer
    \\    C-x C-f             open or create a file
    \\    C-x g               re-read the file from disk
    \\    C-x h               mark the whole buffer
    \\    C-x l               toggle scroll lock (cursor stays put, text scrolls)
    \\    C-x C-k             kill the region
    \\    C-x d / C-x m       browse the file's directory
    \\    C-x 2 / C-x 3       split the window (below / to the right)
    \\    C-x 1               one window
    \\    C-x 0               delete the focused window
    \\    C-x +               balance the windows
    \\    C-x o               move to the next window (n / p / o repeat)
    \\    C-x j / C-x c       drop to a shell (C-z suspends, C-x j resumes)
    \\    C-x r m             set a bookmark at point
    \\    C-x r b             jump to a bookmark
    \\    C-x r l             list the bookmarks
    \\    C-z e               show spaces / tabs / newlines (whitespace)
    \\
    \\  C-c — kill ring and window history:
    \\
    \\    C-c b               copy the whole buffer
    \\    C-c d               duplicate the selected entry in dired
    \\    C-c w               copy the region
    \\    C-c C-k             close the dired buffer
    \\    C-c o               open the bookmark list
    \\    C-c f               find files (fuzzy list)
    \\    C-c g               grep the current directory (Enter opens, F follows)
    \\    C-c j / C-c k       step back / forward through window layouts (j / k repeat)
    \\
    \\  M-l — jumps and tabs (the my-jump prefix):
    \\
    \\    M-l h               the home directory
    \\    M-l b               ~/bin
    \\    M-l d               Downloads
    \\    M-l s               ~/source
    \\    M-l g               the config directory
    \\    M-l i               the Emacs-vanilla config
    \\    M-l y               the Emacs-DIYer config
    \\    M-l r             the scratch buffer
    \\    M-l o             the bookmark list
    \\    M-l l             pick a recently opened file
    \\    M-l = / M-l -     new / close tab
    \\
    \\  Tabs and windows:
    \\
    \\    M-1 .. M-9          select a tab by number
    \\    M-i / M-u           next / previous tab
    \\    M-n / M-p           next / previous window
    \\    M-o                 jump to a window (j k l ; a s d f labels)
    \\    M-; / M-m           split below / to the right
    \\    M-q / M-'           delete the window
    \\    M-a                 one window
    \\    M-e                 open dired at the file's directory
    \\    C-M-h / C-M-l       resize the window left / right
    \\    C-M-j / C-M-k       resize the window up / down
    \\
    \\  Movement:
    \\
    \\    C-f / C-b           forward / backward character (arrows too)
    \\    C-n / C-p           next / previous line (arrows too)
    \\    C-a / C-e           start / end of the visual line
    \\    M-f / M-b           forward / backward word
    \\    M-j / M-k           5 lines down / up
    \\    M-J / M-K           page down / up
    \\    M-< / M->           start / end of the buffer
    \\    M-g                 go to a line
    \\
    \\  Editing:
    \\
    \\    C-k                 kill to the end of the line
    \\    M-d                 kill one word forward
    \\    M-Backspace         kill one word backward
    \\    C-d / Delete        delete forward
    \\    Backspace           delete backward (or the region)
    \\    C-;                 comment / uncomment the line
    \\    M-z                 toggle soft wrap (truncate)
    \\    M-%                 query-replace (from a search too; y/n/q/!/./^)
    \\    C-l                 recenter the window
    \\    C-space             set the mark (C-@ too)
    \\    M-h                 mark the whole paragraph (block)
    \\    C-g                 cancel the mark / a prompt
    \\
    \\  Kill ring, undo and redo:
    \\
    \\    C-y                 yank (paste)
    \\    M-y                 yank-pop (cycle through older kills)
    \\    M-w                 copy the region (or the line)
    \\    C-/                 undo
    \\    C-g C-/ / M-/       redo
    \\    C-w                 save the buffer
    \\
    \\  Search (C-s / C-r):
    \\
    \\    C-s                 search forward
    \\    C-r                 search backward
    \\    C-g                 leave the search
    \\    M-c                 collect the matching lines (occur, from the search too)
    \\
    \\  Dired:
    \\
    \\    n / p               next / previous entry (arrows too)
    \\    Enter / f           open the selected entry
    \\    m / u               mark / unmark the entry
    \\    U                   unmark everything
    \\    t                   toggle all marks
    \\    w                   copy the names to the kill ring
    \\    0 w                 copy the full paths to the kill ring
    \\    (                   hide / show the details
    \\    s                   toggle name / date sort
    \\    3 / 4 / 5 / 6       sort by size / date / name / extension
    \\    g                   re-read the listing
    \\    M-e / ^             go up to the parent directory
    \\    C                   copy the marked entries
    \\    R                   rename the marked entries
    \\    D                   delete the marked entries
    \\    +                   create a directory
    \\    _                   create a file
    \\    W                   open externally
    \\    z                   compress / decompress the marked entries
    \\    q / C-g             close the dired
    \\
    \\  Pickers (buffers, bookmarks and recent files):
    \\
    \\    type              filter the list (fuzzy, as you type)
    \\    arrows / C-n/C-p  move the selection
    \\    Enter             open the selection
    \\    C-s / C-r         search the list
    \\    Backspace         shorten the filter
    \\    q                 close (C-g clears the filter first)
    \\
    \\  Prompts and confirmations:
    \\
    \\    Enter               confirm
    \\    y / n               answer a confirmation
    \\    Backspace           edit the input
    \\    C-g / Esc           cancel
    \\
;

/// Add a fresh buffer containing the home screen to `buffers`. Used only
/// at startup when no files were given. The greeting sits right under
/// the art, then the caption — the terminal this instance is running in,
/// and the version block (version, release date, and the last change,
/// baked in at build time from CHANGELOG.org, see build.zig) with the
/// build time and the change description below it.
fn openWelcome(gpa: std.mem.Allocator, buffers: *std.ArrayList(*Buffer), environ_map: *std.process.Environ.Map) !void {
    const new_buf = try gpa.create(Buffer);
    errdefer gpa.destroy(new_buf);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, welcome_head);
    // The greeting sits just under the banner; the terminal and version
    // caption follow below it.
    try text.appendSlice(gpa, welcome_greeting);
    try text.appendSlice(gpa, "\n\n");
    // The terminal this instance is running in — TERM_PROGRAM where the
    // terminal sets it (alacritty, kitty, wezterm, vscode, ...), the
    // Windows consoles' own variables (Windows Terminal and ConEmu each
    // have one, and an interactive console session is SESSIONNAME
    // "Console"), the TERM value otherwise, so the console is easy to
    // see and report.
    var term_name: []const u8 = "an unknown terminal";
    if (environ_map.get("TERM_PROGRAM")) |tp| {
        term_name = tp;
    } else if (environ_map.get("WT_SESSION") != null) {
        term_name = "Windows Terminal";
    } else if (environ_map.get("ConEmuPID") != null) {
        term_name = "ConEmu";
    } else if (environ_map.get("TERM")) |t| {
        term_name = t;
    } else if (std.mem.eql(u8, environ_map.get("SESSIONNAME") orelse "", "Console")) {
        term_name = "the Windows console";
    }
    try text.appendSlice(gpa, "   running in ");
    try text.appendSlice(gpa, term_name);
    if (environ_map.get("TERM_PROGRAM_VERSION")) |v| {
        try text.appendSlice(gpa, " (");
        try text.appendSlice(gpa, v);
        try text.appendSlice(gpa, ")");
    }
    try text.appendSlice(gpa, "\n\n");
    if (build_options.version.len > 0) {
        // The version line shares the caption's three-space margin, so
        // the block lines up as one left-aligned column.
        try text.appendSlice(gpa, "   ");
        try text.appendSlice(gpa, build_options.version);
        try text.appendSlice(gpa, " (");
        try text.appendSlice(gpa, build_options.date);
        if (build_options.built.len > 0) {
            try text.appendSlice(gpa, " ");
            try text.appendSlice(gpa, build_options.built);
        }
        try text.appendSlice(gpa, ")");
        if (build_options.theme.len > 0) {
            try text.appendSlice(gpa, "\n   ");
            try text.appendSlice(gpa, build_options.theme);
        }
        try text.appendSlice(gpa, "\n\n");
    }
    try text.appendSlice(gpa, welcome_tail);

    new_buf.* = try Buffer.fromText(gpa, text.items);
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
    recent: *std.ArrayList([]u8),
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
    // A freshly opened file joins the recent-files list (M-l l), like
    // Emacs recentf — directories are not remembered.
    recordRecent(gpa, recent, path);
    return buffers.items.len - 1;
}

/// C-x k: kill the current buffer (Emacs kill-buffer) and leave the
/// focused window showing whatever buffer took its place. Every window's
/// buffer index is fixed up, since the indices of all later buffers shift
/// down by one. The last buffer is never killed — the editor never runs
/// with zero buffers.
fn closeBuffer(
    gpa: std.mem.Allocator,
    buffers: *std.ArrayList(*Buffer),
    direds: *std.ArrayList(?Dired),
    root: *Pane,
    focused: *Pane,
    current: usize,
    window_undo: *std.ArrayList(WindowSnapshot),
    window_redo: *std.ArrayList(WindowSnapshot),
) usize {
    if (buffers.items.len <= 1) return current; // never leave zero buffers
    if (current >= buffers.items.len) return current;

    if (direds.orderedRemove(current)) |d| {
        var dd = d;
        dd.deinit(gpa);
    }
    var b = buffers.orderedRemove(current);
    b.deinit(gpa);
    gpa.destroy(b);

    // Rebase every window's buffer index onto the shrunken list; a pane
    // that showed the killed buffer now shows the buffer that took its slot.
    fixupBufIndices(root, current, buffers.items.len);
    // Saved layouts (C-c j / C-c k) hold raw buffer indices too: rebase
    // them the same way, or stepping back into a stale snapshot could land
    // on a shifted — or out-of-range — buffer and crash the next frame.
    for (window_undo.items) |*s| fixupSnapshot(s, current, buffers.items.len);
    for (window_redo.items) |*s| fixupSnapshot(s, current, buffers.items.len);
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

/// The row source of the modal picker: the open buffers (C-x b), the
/// bookmark list (C-x r l / C-c o / M-l o), or the recent files (M-l l).
const PickerKind = enum { buffers, bookmarks, recent };

/// The picker state for rendering: the row kind, the visible rows
/// (positions into the full row list, see pickerFilter), the selection,
/// the first visible row (adjusted each frame so the selection stays on
/// screen), the filter query, and the per-row fuzzy-match highlights.
/// The picker renders inside the focused pane — a lone window shows it
/// full-screen, a split keeps the rest of the layout visible.
const PickerView = struct {
    kind: PickerKind,
    visible: []const usize,
    selected: usize,
    top: *usize,
    query: []const u8,
    hl: []const FuzzyHl,
};

/// The number of rows in a picker of `kind`.
fn pickerRowCount(kind: PickerKind, buffers: []*Buffer, bookmarks: []const Bookmark, paths: []const []const u8) usize {
    return switch (kind) {
        .buffers => buffers.len,
        .bookmarks => bookmarks.len,
        .recent => paths.len,
    };
}

/// The display name of picker row `idx` (a full-list index). The files
/// picker (C-c f) shows the full path, so a fuzzy query matches against
/// the whole path, like fzf.
fn pickerRowName(kind: PickerKind, buffers: []*Buffer, bookmarks: []const Bookmark, paths: []const []const u8, idx: usize) []const u8 {
    return switch (kind) {
        .buffers => buffers[idx].display_name orelse buffers[idx].filename orelse "?",
        .bookmarks => bookmarks[idx].name,
        .recent => std.fs.path.basename(paths[idx]),
    };
}

/// List-isearch find: search the buffer-picker or bookmark-picker rows
/// for `query`, starting at `from_row` (inclusive) and wrapping around
/// the list — the row-granular twin of Buffer.findNext. `visible` maps
/// the search over a filtered subset (see pickerFilter): rows are
/// positions in `visible`, and the returned row is the full-list index.
/// Returns the matched row and the byte offset of the match in that row's
/// text.
fn pickerFindNext(
    kind: PickerKind,
    buffers: []*Buffer,
    bookmarks: []const Bookmark,
    recent: []const []const u8,
    visible: ?[]const usize,
    query: []const u8,
    from_row: usize,
    forward: bool,
) ?Buffer.Pos {
    const count = if (visible) |v| v.len else pickerRowCount(kind, buffers, bookmarks, recent);
    if (count == 0 or query.len == 0) return null;
    var i = from_row % count;
    var n: usize = 0;
    while (n < count) : (n += 1) {
        const full = if (visible) |v| v[i] else i;
        const row_text = pickerRowName(kind, buffers, bookmarks, recent, full);
        if (std.ascii.indexOfIgnoreCase(row_text, query)) |col| return .{ .row = full, .col = col };
        i = if (forward) (i + 1) % count else (i + count - 1) % count;
    }
    return null;
}

/// How many of `visible`'s rows contain `query` — the lazy-count total for
/// list isearch, matching rows the same way pickerFindNext does
/// (case-insensitive substring of the row's text).
fn pickerMatchCount(
    kind: PickerKind,
    buffers: []*Buffer,
    bookmarks: []const Bookmark,
    recent: []const []const u8,
    visible: []const usize,
    query: []const u8,
) usize {
    var n: usize = 0;
    if (query.len == 0) return 0;
    for (visible) |full| {
        const row_text = pickerRowName(kind, buffers, bookmarks, recent, full);
        if (std.ascii.indexOfIgnoreCase(row_text, query) != null) n += 1;
    }
    return n;
}

/// The 1-based position of `match_row` among `visible`'s rows containing
/// `query`, in list order — the "current" half of the list-isearch lazy
/// count.
fn pickerMatchIndex(
    kind: PickerKind,
    buffers: []*Buffer,
    bookmarks: []const Bookmark,
    recent: []const []const u8,
    visible: []const usize,
    query: []const u8,
    match_row: usize,
) usize {
    var n: usize = 0;
    if (query.len == 0) return 0;
    for (visible) |full| {
        const row_text = pickerRowName(kind, buffers, bookmarks, recent, full);
        if (std.ascii.indexOfIgnoreCase(row_text, query) != null) {
            n += 1;
            if (full == match_row) return n;
        }
    }
    return n;
}

/// Fuzzy-match `query` against `text`: a case-insensitive subsequence
/// match, scored so that word starts, camelCase boundaries, and
/// consecutive runs rank higher than scattered hits (an fzf-style filter
/// for the pickers). Null when `query` isn't a subsequence; higher scores
/// are better.
/// The byte positions of the matched characters in a match, for
/// highlighting the filter's hits in the picker rows.
const FuzzyHl = struct {
    positions: [64]usize = undefined,
    len: usize = 0,
};

/// Emacs partial-completion-style match: the query splits at spaces into
/// groups, and every group must be a contiguous case-insensitive
/// substring of `text`, in order — "req b" matches "revert-buffer". The
/// rank is the start of the first group, so earlier matches sort first.
fn partialMatch(query: []const u8, text: []const u8) ?struct { rank: usize, hl: FuzzyHl } {
    var hl: FuzzyHl = .{};
    var pos: usize = 0;
    var first_group_start: ?usize = null;
    var it = std.mem.splitScalar(u8, query, ' ');
    while (it.next()) |group| {
        if (group.len == 0) continue;
        const found = std.ascii.indexOfIgnoreCasePos(text, pos, group) orelse return null;
        if (first_group_start == null) first_group_start = found;
        var k = found;
        while (k < found + group.len) : (k += 1) {
            if (hl.len < hl.positions.len) {
                hl.positions[hl.len] = k;
                hl.len += 1;
            }
        }
        pos = found + group.len;
    }
    return .{ .rank = first_group_start orelse 0, .hl = hl };
}

/// One picker row that matched the filter, with its rank and the matched
/// character positions (for the row highlight).
const PickerMatch = struct {
    idx: usize,
    rank: usize,
    hl: FuzzyHl = .{},

    /// Lower ranks (earlier first-group matches) first; ties keep the
    /// original order.
    fn lessThan(_: void, a: PickerMatch, b: PickerMatch) bool {
        return if (a.rank != b.rank) a.rank < b.rank else a.idx < b.idx;
    }
};

/// Rebuild the picker's visible rows for `query`: the full-list indices
/// of every entry whose name fuzzy-matches, best matches first; the whole
/// list in its original order for an empty query. `hl_out` receives the
/// matched character positions per visible row, parallel to `visible`
/// (empty when the query is empty).
fn pickerFilter(gpa: std.mem.Allocator, kind: PickerKind, buffers: []*Buffer, bookmarks: []const Bookmark, paths: []const []const u8, query: []const u8, visible: *std.ArrayList(usize), hl_out: *std.ArrayList(FuzzyHl)) void {
    visible.clearRetainingCapacity();
    hl_out.clearRetainingCapacity();
    const count = pickerRowCount(kind, buffers, bookmarks, paths);
    if (query.len == 0) {
        visible.ensureTotalCapacity(gpa, count) catch return;
        var i: usize = 0;
        while (i < count) : (i += 1) visible.appendAssumeCapacity(i);
        return;
    }
    var matches: std.ArrayList(PickerMatch) = .empty;
    defer matches.deinit(gpa);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const name = pickerRowName(kind, buffers, bookmarks, paths, i);
        if (partialMatch(query, name)) |m| matches.append(gpa, .{ .idx = i, .rank = m.rank, .hl = m.hl }) catch return;
    }
    std.mem.sort(PickerMatch, matches.items, {}, PickerMatch.lessThan);
    for (matches.items) |m| {
        visible.append(gpa, m.idx) catch return;
        hl_out.append(gpa, m.hl) catch return;
    }
}

/// Refilter a picker, keeping `selected` on its entry when it still
/// shows; with no rows left it stays put (nothing opens), otherwise the
/// top match is selected.
fn filterPicker(gpa: std.mem.Allocator, kind: PickerKind, buffers: []*Buffer, bookmarks: []const Bookmark, paths: []const []const u8, query: []const u8, visible: *std.ArrayList(usize), selected: *usize, hl_out: *std.ArrayList(FuzzyHl)) void {
    const before = selected.*;
    pickerFilter(gpa, kind, buffers, bookmarks, paths, query, visible, hl_out);
    if (visible.items.len == 0) return;
    if (std.mem.indexOfScalar(usize, visible.items, before) == null) selected.* = visible.items[0];
}

/// The position of full-list index `full` among the visible rows — where
/// the selection highlight sits. Zero when it's not visible.
fn pickerSelectionPos(visible: []const usize, full: usize) usize {
    for (visible, 0..) |v, i| {
        if (v == full) return i;
    }
    return 0;
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
    recent: *std.ArrayList([]u8),
    bookmarks: []const Bookmark,
    name: []const u8,
) ?usize {
    for (bookmarks) |b| {
        if (std.mem.eql(u8, b.name, name)) {
            const idx = openBufferOrDired(gpa, io, buffers, direds, recent, b.path) catch return null;
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

/// The bookmarks file james keeps the bookmark list in: <home>/.james-
/// bookmarks, tab-separated name/path/row/col lines. The home directory
/// is %USERPROFILE% on Windows, $HOME elsewhere (see jumpHome). Caller
/// frees the returned path.
fn bookmarksFilePath(gpa: std.mem.Allocator, env_map: *std.process.Environ.Map) ?[]u8 {
    const home_raw = jumpHome(env_map) orelse return null;
    return std.fs.path.join(gpa, &.{ home_raw, ".james-bookmarks" }) catch null;
}

/// Drop the in-memory bookmark list and reload it from the bookmarks
/// file — used after the user edits and saves the file itself, so a
/// hand-edited list takes effect immediately.
fn reloadBookmarks(gpa: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map, bookmarks: *std.ArrayList(Bookmark)) void {
    for (bookmarks.items) |*b| {
        gpa.free(b.name);
        gpa.free(b.path);
    }
    bookmarks.clearRetainingCapacity();
    loadBookmarks(gpa, io, env_map, bookmarks);
}

/// After a save: when the saved buffer is the bookmarks file itself (the
/// e key's edit target), refresh the in-memory list from it — otherwise
/// james's exit-time save would write the stale in-memory list back over
/// the user's edits.
fn refreshBookmarksAfterSave(gpa: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map, bookmarks: *std.ArrayList(Bookmark), buf: *Buffer) void {
    const f = buf.filename orelse return;
    const path = bookmarksFilePath(gpa, env_map) orelse return;
    defer gpa.free(path);
    if (std.mem.eql(u8, f, path)) reloadBookmarks(gpa, io, env_map, bookmarks);
}

/// Persist bookmarks to the bookmarks file (see bookmarksFilePath).
fn saveBookmarks(gpa: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map, bookmarks: *const std.ArrayList(Bookmark)) void {
    const path = bookmarksFilePath(gpa, env_map) orelse return;
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

/// Load bookmarks from the bookmarks file, if it exists (see
/// bookmarksFilePath).
fn loadBookmarks(gpa: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map, bookmarks: *std.ArrayList(Bookmark)) void {
    const path = bookmarksFilePath(gpa, env_map) orelse return;
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

/// The recent-files list (M-l l, mirroring the author's Emacs
/// my/fido-recentf): the paths of files opened in james, newest first,
/// capped at RECENT_MAX. Persisted one path per line to
/// <home>/.james-recent.
const RECENT_MAX = 40;

/// <home>/.james-recent (see bookmarksFilePath for the home lookup).
/// Caller frees the returned path.
fn recentFilePath(gpa: std.mem.Allocator, env_map: *std.process.Environ.Map) ?[]u8 {
    const home_raw = jumpHome(env_map) orelse return null;
    return std.fs.path.join(gpa, &.{ home_raw, ".james-recent" }) catch null;
}

/// Record `path` as a recently opened file: moved to the front (a repeat
/// open doesn't add a duplicate) and capped at RECENT_MAX. The list is
/// persisted on quit (see saveRecent).
fn recordRecent(gpa: std.mem.Allocator, recent: *std.ArrayList([]u8), path: []const u8) void {
    if (path.len == 0) return;
    for (recent.items, 0..) |r, i| {
        if (std.mem.eql(u8, r, path)) {
            gpa.free(recent.orderedRemove(i));
            break;
        }
    }
    const copy = gpa.dupe(u8, path) catch return;
    recent.insert(gpa, 0, copy) catch {
        gpa.free(copy);
        return;
    };
    while (recent.items.len > RECENT_MAX) {
        gpa.free(recent.pop().?);
    }
}

/// Persist the recent-files list to the recent file (see recentFilePath).
fn saveRecent(gpa: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map, recent: *const std.ArrayList([]u8)) void {
    const path = recentFilePath(gpa, env_map) orelse return;
    defer gpa.free(path);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (recent.items) |r| {
        out.appendSlice(gpa, r) catch return;
        out.append(gpa, '\n') catch return;
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items }) catch {};
}

/// Load the recent-files list from the recent file, if it exists (see
/// recentFilePath). Duplicates in a hand-edited file are dropped.
fn loadRecent(gpa: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map, recent: *std.ArrayList([]u8)) void {
    const path = recentFilePath(gpa, env_map) orelse return;
    defer gpa.free(path);

    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return;
    defer gpa.free(contents);

    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        const p = std.mem.trim(u8, line, " \t\r");
        if (p.len == 0 or recent.items.len >= RECENT_MAX) continue;
        var seen = false;
        for (recent.items) |r| {
            if (std.mem.eql(u8, r, p)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        recent.append(gpa, gpa.dupe(u8, p) catch continue) catch continue;
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

/// A leading `~` expanded to the user's home directory — the tilde
/// expansion Emacs's expand-file-name performs. A bare `~` becomes the
/// home directory itself, `~/...` the home directory joined with the
/// rest. Paths with no leading tilde, and `~user` names (another user's
/// home), are returned as-is. Caller must free.
fn expandTilde(gpa: std.mem.Allocator, env_map: *std.process.Environ.Map, path: []const u8) ![]u8 {
    if (path.len == 0 or path[0] != '~') return gpa.dupe(u8, path);
    const home = jumpHome(env_map) orelse return gpa.dupe(u8, path);
    if (path.len == 1) return gpa.dupe(u8, home);
    if (path[1] == '/') {
        if (path.len == 2) return gpa.dupe(u8, home);
        return std.fs.path.join(gpa, &.{ home, path[2..] });
    }
    return gpa.dupe(u8, path);
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
    recent: *std.ArrayList([]u8),
    root: *Pane,
    focused: *Pane,
    current: usize,
    undo: *std.ArrayList(WindowSnapshot),
    redo: *std.ArrayList(WindowSnapshot),
    status_msg: *?[]const u8,
) usize {
    recordWindow(gpa, root, focused, current, undo, redo);
    const idx = openBufferOrDired(gpa, io, buffers, direds, recent, path) catch {
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

/// Rebase a saved window snapshot onto a shrunken buffer list, mirroring
/// the fix-up closeBuffer applies to the live tree: any leaf (and the
/// recorded focus) that sat after the removed slot shifts down by one,
/// and indices beyond the new end clamp to the last buffer.
fn fixupSnapshot(snap: *WindowSnapshot, removed: usize, len: usize) void {
    for (snap.nodes.items) |*n| {
        if (n.is_leaf) {
            if (n.buf_idx > removed) n.buf_idx -= 1;
            if (n.buf_idx >= len) n.buf_idx = len - 1;
        }
    }
    if (snap.current > removed) snap.current -= 1;
    if (snap.current >= len) snap.current = len - 1;
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

    // Recent files (M-l l, my/fido-recentf): the paths of files opened in
    // james, newest first, persisted to <home>/.james-recent on quit.
    var recent: std.ArrayList([]u8) = .empty;
    defer {
        for (recent.items) |r| gpa.free(r);
        recent.deinit(gpa);
    }
    defer saveRecent(gpa, io, init.environ_map, &recent);
    loadRecent(gpa, io, init.environ_map, &recent);

    while (args_it.next()) |arg| {
        _ = try openBufferOrDired(gpa, io, &buffers, &direds, &recent, arg);
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
        try openWelcome(gpa, &buffers, init.environ_map);
        try direds.append(gpa, null);

        // The scratch buffer is tied to a real scratch.txt file (created
        // here if missing, never truncated if it exists), so it saves and
        // prompts like any other file.
        if (std.Io.Dir.cwd().createFile(io, "scratch.txt", .{ .truncate = false })) |f| {
            f.close(io);
            const scratch_idx = try openBufferOrDired(gpa, io, &buffers, &direds, &recent, "scratch.txt");
            default_dired_idx = try openBufferOrDired(gpa, io, &buffers, &direds, &recent, ".");
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
    // Scratch space for a status message that carries text (dired w's
    // "Copied: ..." echo): lives until the next keypress, so a fixed
    // buffer — like the modeline's own — beats a per-copy allocation.
    var status_buf: [2048]u8 = undefined;

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
    // Width of the focused pane's text area, tracked alongside the height
    // for the visual-line navigation (wrapping happens at this width).
    var focused_text_width: usize = 0;
    // True while consecutive C-l presses are cycling recenter positions
    // (center → top → bottom); any other key resets the next C-l to center.
    var last_was_recenter = false;
    // C-g C-/: redo — the author's Emacs habit. C-g leaves this set for
    // the next keypress; anything other than C-/ clears it again.
    var pending_ctrl_g = false;
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
    // M-o: the quick-window-jump prefix (the author's my/quick-window-jump):
    // while armed, each window shows a one-char corner label and the label
    // key jumps to its window.
    var pending_alt_o = false;
    // C-z: the whitespace-marker prefix (the author's Emacs binds C-z e
    // to whitespace-mode) — C-z e toggles the current buffer's markers.
    var pending_ctrl_z = false;
    // The 0 prefix in dired (Emacs dired-copy-filename-as-kill with a
    // prefix of 0): 0 w copies the absolute file name instead of the bare
    // name. Armed by 0, cleared by any key other than w.
    var pending_dired_0 = false;
    // Heap allocations made while rendering one frame (tab expansions),
    // freed after each vx.render.
    var frame_allocs: FrameAllocs = .{ .gpa = gpa };
    var confirming_quit = false;
    var confirming_kill = false;

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

    // Tabs: tab 0 is this initial layout; M-l = appends a new tab at
    // the right end, M-l - removes the current one, M-1..M-9 selects by
    // number. Only the active tab's layout is held in root/focused/
    // current; the others are stored here, saved on every switch. The
    // tab bar appears only once a second tab exists.
    var tabs: std.ArrayList(Tab) = .empty;
    var active_tab: usize = 0;
    defer {
        // The active tab's tree is freed by the root.destroy defer
        // above; the remaining tabs' trees live only here.
        for (tabs.items, 0..) |tab, i| {
            if (i != active_tab) tab.root.destroy(gpa);
        }
        tabs.deinit(gpa);
    }
    tabs.append(gpa, .{ .root = root, .focused = focused, .current = current }) catch {};

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
    // M-g: the goto-line prompt — type a line number, Enter jumps.
    var goto_prompt = false;
    var goto_query: std.ArrayList(u8) = .empty;
    defer goto_query.deinit(gpa);

    // C-c g: the grep prompt (the author's Emacs my/grep key) — type a
    // search term, Enter runs ripgrep (grep / findstr fallbacks) over the
    // current directory. The results live in a buffer (display name
    // "*grep*"); `grep_buf_idx` is its index, `grep_matches` the parsed
    // (path, line, col) per result line, aligned with the buffer lines.
    var grep_prompt = false;
    // The term the prompt started with was auto-inserted (the word at
    // point, or the last term on a g re-run): the first typed character
    // replaces it rather than appending to it — typing "TODO" on top of
    // a prefilled "todo" must search for "TODO", not "todoTODO".
    var grep_prefill = false;
    var grep_query: std.ArrayList(u8) = .empty;
    defer grep_query.deinit(gpa);
    // The term of the last run search, for the results buffer's g key
    // (re-run, prefilled).
    var grep_last_term: ?[]u8 = null;
    defer if (grep_last_term) |t| gpa.free(t);
    var grep_buf_idx: ?usize = null;
    // The pane the last results jump opened its file into — reused for
    // the next jump, so stepping through the matches with n/p + Enter
    // keeps the same window. Null until the first jump; validated
    // against the pane tree before reuse (see paneInTree).
    var results_target: ?*Pane = null;
    // F in a results buffer: follow mode — each n/p (or C-n / C-p /
    // arrow) move auto-opens the entry under point in the target window,
    // focus staying on the results buffer.
    var results_follow = false;
    // A transient highlight of the term in the target file after a grep
    // jump (see GrepHl) — drawn for a moment so the match is easy to spot
    // while stepping.
    var grep_hl: ?GrepHl = null;
    var grep_matches: std.ArrayList(GrepMatch) = .empty;
    defer {
        for (grep_matches.items) |m| gpa.free(m.path);
        grep_matches.deinit(gpa);
    }
    // M-c: occur (the author's Emacs M-c) — every line of the current
    // buffer matching a term lands in a "*occur*" buffer that behaves
    // exactly like *grep*: n/p move, Enter jumps to the match in the
    // source file, F follows, g re-runs (the prompt prefilled with the
    // last term), q / C-g closes. `occur_source` is the source file's
    // path, so a g re-run scans it again — and `occur_source_buf` the
    // source buffer itself, so an occur over a file-less buffer (the
    // home screen) can be re-run and jumped into all the same.
    var occur_prompt = false;
    var occur_prefill = false;
    var occur_query: std.ArrayList(u8) = .empty;
    defer occur_query.deinit(gpa);
    var occur_last_term: ?[]u8 = null;
    defer if (occur_last_term) |t| gpa.free(t);
    var occur_buf_idx: ?usize = null;
    var occur_source: ?[]u8 = null;
    defer if (occur_source) |s| gpa.free(s);
    var occur_source_buf: ?*Buffer = null;
    var occur_matches: std.ArrayList(OccurMatch) = .empty;
    defer occur_matches.deinit(gpa);
    // C-c f: find files — the platform's file-finder (ripgrep --files,
    // find, or Windows dir /s /b) lists the current directory into a
    // persistent *files* buffer, exactly like the *grep* buffer: the list
    // stays open (C-x b returns to it), n/p steps through it, and typing
    // filters it (partial-completion, see filesMirror). `find_paths` is
    // the full list, `find_visible` the filtered subset, `find_hl` the
    // matched characters per visible row, and `find_dir` the last search
    // directory (for g, which re-runs the find).
    var find_buf_idx: ?usize = null;
    var find_paths: std.ArrayList([]u8) = .empty;
    defer {
        for (find_paths.items) |p| gpa.free(p);
        find_paths.deinit(gpa);
    }
    var find_filter: std.ArrayList(u8) = .empty;
    defer find_filter.deinit(gpa);
    var find_visible: std.ArrayList(usize) = .empty;
    defer find_visible.deinit(gpa);
    var find_hl: std.ArrayList(FuzzyHl) = .empty;
    defer find_hl.deinit(gpa);
    var find_dir: ?[]u8 = null;
    defer if (find_dir) |d| gpa.free(d);
    // The modal picker (C-x b buffers, C-x r l / C-c o / M-l o bookmarks,
    // M-l l recent files): one at a time, over rows that filter as you
    // type (see pickerFilter). `picker_kind` selects the row source;
    // `picker_selected` is the full-list index of the selection and
    // `picker_top` the first visible row, both positions in the filtered
    // `picker_visible` list. C-g clears the filter before closing.
    var picker_kind: ?PickerKind = null;
    var picker_selected: usize = 0;
    var picker_top: usize = 0;
    var picker_query: std.ArrayList(u8) = .empty;
    defer picker_query.deinit(gpa);
    var picker_visible: std.ArrayList(usize) = .empty;
    defer picker_visible.deinit(gpa);
    // Matched-character positions per visible picker row, parallel to
    // picker_visible (see pickerFilter) — drawn so the filter's hits are
    // visible in the rows as you type.
    var picker_hl: std.ArrayList(FuzzyHl) = .empty;
    defer picker_hl.deinit(gpa);

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

    // z in dired: compress / decompress the marked entries (Emacs
    // dired-compress-file, the author's my/dired-compress-transient
    // simplified). Already-compressed entries are decompressed straight
    // away; anything else opens a one-key format menu in the modeline,
    // offering only the tools this platform actually has.
    var dired_compress_menu = false;
    var dired_compress_multi = false; // several operands: ask for the archive name
    var dired_compress_fmt: CompressFmt = .gzip; // the format the archive prompt will run
    var dired_compress_opds: std.ArrayList([]u8) = .empty;
    defer {
        for (dired_compress_opds.items) |p| gpa.free(p);
        dired_compress_opds.deinit(gpa);
    }
    var dired_compress_choices: std.ArrayList(CompressChoice) = .empty;
    defer dired_compress_choices.deinit(gpa);
    // The menu's modeline text lives in fixed buffers (like status_buf):
    // slices into them stay valid until the next keypress.
    var dired_compress_label_buf: [192]u8 = undefined;
    var dired_compress_menu_buf: [256]u8 = undefined;
    var dired_compress_label: []const u8 = &.{};
    var dired_compress_menu_text: []const u8 = &.{};
    // Multi-file archive name prompt (the copy prompt's shape): the query
    // starts prefilled with the directory name plus the format's suffix.
    var dired_archive_prompt = false;
    var dired_archive_query: std.ArrayList(u8) = .empty;
    defer dired_archive_query.deinit(gpa);

    // W in dired: confirm opening the selected entry externally. The
    // joined path (and the looked-up handler name, if one was found) is
    // held here until y / n settles the prompt.
    var confirming_open = false;
    var open_confirm_path: ?[]u8 = null;
    var open_confirm_app: ?[]u8 = null;
    defer {
        if (open_confirm_path) |p| gpa.free(p);
        if (open_confirm_app) |a| gpa.free(a);
    }

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
    // The last completed search string, so a fresh C-s repeats the previous
    // search from wherever the cursor is (Emacs isearch-repeat: C-s with an
    // empty query searches for the last string). The first character typed
    // replaces the prefill, like the grep / occur prompts.
    var isearch_last: std.ArrayList(u8) = .empty;
    defer isearch_last.deinit(gpa);
    var isearch_prefill = false;
    var isearch_origin: Buffer.Pos = .{ .row = 0, .col = 0 };
    var isearch_match: ?Buffer.Pos = null;
    var isearch_failed = false;
    // isearch-lazy-count (Emacs): the current match's 1-based position and
    // the query's total match count, shown as (N/M) in the modeline while
    // searching. Recomputed on every isearch keystroke.
    var isearch_count: usize = 0;
    var isearch_pos: usize = 0;

    // Query-replace (M-%, Emacs query-replace): a two-prompt modal — the
    // string to find, then its replacement — followed by a match-by-match
    // confirmation walk over the buffer. `replace_prompt` names the phase;
    // `replace_active` is the walk itself, asking y / n / q / ! / . / ^
    // per match, the current candidate highlighted like an isearch match.
    var replace_prompt: ?ReplacePhase = null;
    var replace_query: std.ArrayList(u8) = .empty;
    defer replace_query.deinit(gpa);
    var replace_with: std.ArrayList(u8) = .empty;
    defer replace_with.deinit(gpa);
    var replace_prefill = false;
    var replace_active = false;
    var replace_match: ?Buffer.Pos = null;
    var replace_count: usize = 0;
    // Sticky keys (see RepeatMap): the armed repeat map, cleared by any
    // key that isn't a repeat key.
    var repeat_map: ?RepeatMap = null;

    // The first frame renders before the first event: the input thread's
    // initial winsize event normally triggers the first draw, and if that
    // thread dies (a terminal it can't negotiate with, say) the screen
    // must not stay blank forever waiting for an event that never comes —
    // draw once with the startup size, then events keep the frames coming.
    var first_frame = true;
    while (true) {
        const event: ?Event = if (first_frame) null else try loop.nextEvent();
        first_frame = false;
        if (event) |ev| switch (ev) {
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
            .key_press => |key| key_blk: {
                // Windows delivers a bare modifier held alone (Ctrl/Alt/Shift)
                // as its own .key_press with no text — the ~/ keypress arrives
                // as a separate record after it. Linux never emits these, so
                // every prompt, isearch and picker cancels on any unmatched
                // text-less key, which would end the prompt mid-keystroke
                // (e.g. Ctrl while typing C-s to continue an isearch). Drop
                // the modifier-only events here, before the bookkeeping, so
                // they don't disarm pending_ctrl_g either.
                if (key.isModifier()) continue;
                // C-l cycles recenter positions only when pressed back to
                // back (Emacs recenter-top-bottom); any other key makes the
                // next C-l recenter to the middle again. A transient status
                // message (failed save) lives until the next keypress too.
                if (!key.matches('l', .{ .ctrl = true })) last_was_recenter = false;
                if (!key.matches('y', .{ .alt = true })) yank_state = null;
                // C-g arms redo for the next keypress; any key other than
                // C-/ disarms it again.
                if (!key.matches('/', .{ .ctrl = true }) and !key.matches(0x1F, .{})) pending_ctrl_g = false;
                if (key.matches('g', .{ .ctrl = true })) pending_ctrl_g = true;
                // The dired 0 prefix (0 w copies the full path) lives until
                // the w it arms; any other key clears it.
                if (!key.matches('w', .{})) pending_dired_0 = false;
                status_msg = null;
                const buf: *Buffer = buffers.items[current];

                // Sticky keys / repeat-mode: while a repeat map is armed,
                // its plain keys repeat the window action instead of their
                // normal binding — j / k keep stepping window history
                // after C-c j / C-c k, n / p / o keep moving between
                // windows after C-x o — and the map stays armed for the
                // next repeat. Any other key clears the map and acts
                // normally below (so the repeat keys never hijack a
                // prompt: opening one always passes through a non-repeat
                // key first).
                if (repeat_map) |rm| {
                    if (rm == .window_history and (key.matches('j', .{}) or key.matches('k', .{}))) {
                        if (key.matches('j', .{})) {
                            if (windowUndo(gpa, &root, &focused, current, &window_undo, &window_redo)) |_| {
                                current = focused.buf_idx;
                            }
                        } else {
                            if (windowRedo(gpa, &root, &focused, current, &window_undo, &window_redo)) |_| {
                                current = focused.buf_idx;
                            }
                        }
                        break :key_blk;
                    }
                    if (rm == .window_move and (key.matches('n', .{}) or key.matches('p', .{}) or key.matches('o', .{}))) {
                        // o repeats the forward step like M-n (Emacs's
                        // other-window-repeat-map); n / p move either way.
                        if (moveFocus(root, focused, if (key.matches('p', .{})) -1 else 1)) |nf| {
                            focused = nf;
                            current = focused.buf_idx;
                        }
                        break :key_blk;
                    }
                    repeat_map = null;
                }

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
                } else if (confirming_kill) {
                    if (key.matches('y', .{}) or key.matches('Y', .{})) {
                        // y: save the buffer, then kill it. A failed save
                        // keeps the buffer — killing would lose the
                        // changes for good.
                        confirming_kill = false;
                        kill: {
                            buf.save(gpa, io) catch {
                                status_msg = "Save failed";
                                break :kill;
                            };
                            recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                            current = closeBuffer(gpa, &buffers, &direds, root, focused, current, &window_undo, &window_redo);
                        }
                    } else if (key.matches('n', .{}) or key.matches('N', .{})) {
                        confirming_kill = false;
                        recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                        current = closeBuffer(gpa, &buffers, &direds, root, focused, current, &window_undo, &window_redo);
                    } else if (key.matches('g', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                        confirming_kill = false;
                    }
                    // Any other key is ignored — stay in the prompt rather
                    // than risk a stray keystroke killing the wrong buffer.
                } else if (pending_ctrl_c) {
                    pending_ctrl_c = false;
                    if (key.matches('b', .{})) {
                        try buf.copyWholeBuffer(gpa, &kill_ring);
                        syncClipboard(&vx, &tty, gpa, kill_ring.current() orelse "");
                        kill_active = true;
                    } else if (key.matches('d', .{})) {
                        // C-c d: duplicate the selected entry with an
                        // incremented counter (the author's
                        // my/dired-duplicate-file): foo.txt → foo_001.txt,
                        // the first free number (a prefix argument sets
                        // the starting counter in Emacs; james always
                        // starts at 1). Directories copy recursively. ".."
                        // is skipped like C and D.
                        if (direds.items[current]) |*d| {
                            const en = d.entries.items[d.selected];
                            if (!std.mem.eql(u8, en.name, "..")) blk: {
                                const path = std.fs.path.join(gpa, &.{ d.path.items, en.name }) catch break :blk;
                                defer gpa.free(path);
                                const parts = duplicateNameParts(en.name);
                                var counter: usize = 1;
                                while (counter <= 9999) : (counter += 1) {
                                    const new_name = if (parts.ext.len > 0)
                                        (std.fmt.allocPrint(gpa, "{s}_{d:0>3}{s}", .{ parts.base, counter, parts.ext }) catch break :blk)
                                    else
                                        (std.fmt.allocPrint(gpa, "{s}_{d:0>3}", .{ parts.base, counter }) catch break :blk);
                                    defer gpa.free(new_name);
                                    const new_path = std.fs.path.join(gpa, &.{ d.path.items, new_name }) catch break :blk;
                                    defer gpa.free(new_path);
                                    const taken = std.Io.Dir.cwd().statFile(io, new_path, .{ .follow_symlinks = true }) catch null;
                                    if (taken == null) {
                                        if (diredDuplicateRun(io, gpa, path, new_path, en.is_dir)) {
                                            refreshDired(gpa, io, &buffers, &direds, current);
                                            const n = std.fmt.bufPrint(&status_buf, "Duplicated: {s}", .{new_name}) catch unreachable;
                                            status_msg = status_buf[0..n.len];
                                        } else {
                                            status_msg = "Duplicate failed";
                                        }
                                        break :blk;
                                    }
                                }
                            }
                        }
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
                            current = closeBuffer(gpa, &buffers, &direds, root, focused, current, &window_undo, &window_redo);
                        }
                    } else if (key.matches('o', .{})) {
                        // C-c o: open the bookmark picker (the "favorites"
                        // key from the Jasspa setup — bookmarks are this
                        // editor's favourites).
                        picker_kind = .bookmarks;
                        picker_selected = 0;
                        picker_top = 0;
                        picker_query.clearRetainingCapacity();
                        pickerFilter(gpa, .bookmarks, buffers.items, bookmarks.items, recent.items, "", &picker_visible, &picker_hl);
                    } else if (key.matches('f', .{})) {
                        // C-c f: find files (the my/find-file key from the
                        // author's Emacs) — the platform's file-finder
                        // lists the current directory (the dired's own
                        // while browsing, else the file's) into a
                        // persistent *files* buffer, like *grep*: n/p
                        // steps through it, Enter opens in another window,
                        // and typing filters it (partial-completion).
                        const dir = if (direds.items[current]) |*d|
                            try gpa.dupe(u8, d.path.items)
                        else
                            try Dired.startingDir(gpa, buf.filename orelse ".");
                        defer gpa.free(dir);
                        if (filesRun(gpa, io, &buffers, &direds, dir, &find_paths, &find_dir, &find_filter, &find_visible, &find_hl, &find_buf_idx)) |idx| {
                            recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                            current = idx;
                            focused.buf_idx = current;
                            kill_active = false;
                        } else {
                            status_msg = "No files found";
                        }
                    } else if (key.matches('g', .{})) {
                        // C-c g: grep (the my/grep key from the author's
                        // Emacs) — prompt for a search term, prefilled
                        // with the word at point, and run ripgrep (grep /
                        // findstr fallbacks) over the current directory.
                        grep_prompt = true;
                        grep_query.clearRetainingCapacity();
                        if (buf.lines.items.len > 0) {
                            const line = buf.lines.items[buf.cursor_row].items;
                            const col = @min(buf.cursor_col, line.len);
                            var s = col;
                            while (s > 0 and (std.ascii.isAlphanumeric(line[s - 1]) or line[s - 1] == '_')) s -= 1;
                            var e = col;
                            while (e < line.len and (std.ascii.isAlphanumeric(line[e]) or line[e] == '_')) e += 1;
                            if (e > s) grep_query.appendSlice(gpa, line[s..e]) catch {};
                            grep_prefill = e > s;
                        }
                    } else if (key.matches('j', .{})) {
                        // C-c j: step back through window layouts
                        // (winner-mode undo). Sticky: the plain j / k
                        // repeat (see RepeatMap).
                        if (windowUndo(gpa, &root, &focused, current, &window_undo, &window_redo)) |_| {
                            // Keys act on the pane the cursor is drawn in —
                            // take its buffer rather than the snapshot's
                            // recorded index so the two never disagree.
                            current = focused.buf_idx;
                        }
                        repeat_map = .window_history;
                    } else if (key.matches('k', .{})) {
                        // C-c k: step forward through window layouts
                        // (winner-mode redo). Sticky like C-c j.
                        if (windowRedo(gpa, &root, &focused, current, &window_undo, &window_redo)) |_| {
                            current = focused.buf_idx;
                        }
                        repeat_map = .window_history;
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
                            current = openBufferOrDired(gpa, io, &buffers, &direds, &recent, name) catch current;
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
                            .jump => if (bookmarkJump(gpa, io, &buffers, &direds, &recent, bookmarks.items, name)) |idx| {
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
                } else if (goto_prompt) {
                    if (key.matches('g', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                        goto_prompt = false;
                    } else if (key.matches(vaxis.Key.backspace, .{})) {
                        if (goto_query.items.len > 0) _ = goto_query.pop();
                    } else if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true }) or key.matches('m', .{ .ctrl = true })) {
                        const n_str = std.mem.trim(u8, goto_query.items, " ");
                        goto_prompt = false;
                        // M-g: jump to the 1-based line, clamped to the
                        // buffer; the view follows on the next render.
                        if (std.fmt.parseUnsigned(usize, n_str, 10)) |n| {
                            if (n > 0 and buf.lines.items.len > 0) {
                                buf.cursor_row = @min(n - 1, buf.lines.items.len - 1);
                                buf.cursor_col = @min(buf.cursor_col, buf.lines.items[buf.cursor_row].items.len);
                            }
                        } else |_| {}
                    } else if (key.text) |t| {
                        try goto_query.appendSlice(gpa, t);
                    } else {
                        goto_prompt = false;
                    }
                } else if (grep_prompt) {
                    if (key.matches('g', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                        grep_prompt = false;
                        grep_prefill = false;
                    } else if (key.matches(vaxis.Key.backspace, .{})) {
                        if (grep_query.items.len > 0) _ = grep_query.pop();
                    } else if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true }) or key.matches('m', .{ .ctrl = true })) {
                        const term = std.mem.trim(u8, grep_query.items, " ");
                        grep_prompt = false;
                        grep_prefill = false;
                        if (term.len > 0) run_blk: {
                            // The search directory: the dired's own while
                            // browsing, else the current buffer's.
                            const dir = if (direds.items[current]) |*d|
                                try gpa.dupe(u8, d.path.items)
                            else
                                try Dired.startingDir(gpa, buf.filename orelse ".");
                            defer gpa.free(dir);
                            // An old results buffer is replaced.
                            if (grep_buf_idx) |old| {
                                if (old < buffers.items.len) {
                                    recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                                    _ = closeBuffer(gpa, &buffers, &direds, root, focused, old, &window_undo, &window_redo);
                                }
                                grep_buf_idx = null;
                                results_target = null;
                                grep_hl = null;
                                for (grep_matches.items) |m| gpa.free(m.path);
                                grep_matches.clearRetainingCapacity();
                            }
                            const out = grepRun(io, gpa, dir, term) orelse {
                                status_msg = "No matches";
                                break :run_blk;
                            };
                            defer gpa.free(out);
                            if (grep_last_term) |t| gpa.free(t);
                            grep_last_term = gpa.dupe(u8, term) catch null;
                            var text: std.ArrayList(u8) = .empty;
                            defer text.deinit(gpa);
                            var it = std.mem.splitScalar(u8, out, '\n');
                            while (it.next()) |raw| {
                                const line = std.mem.trimEnd(u8, raw, "\r");
                                if (parseGrepLine(gpa, line)) |m| {
                                    text.appendSlice(gpa, line) catch break;
                                    text.append(gpa, '\n') catch break;
                                    grep_matches.append(gpa, m) catch {
                                        gpa.free(m.path);
                                        break;
                                    };
                                }
                            }
                            if (grep_matches.items.len == 0) {
                                status_msg = "No matches";
                                break :run_blk;
                            }
                            const new_buf = try gpa.create(Buffer);
                            errdefer gpa.destroy(new_buf);
                            new_buf.* = try Buffer.fromText(gpa, text.items);
                            new_buf.display_name = try gpa.dupe(u8, "*grep*");
                            // Results always truncate: one match per row,
                            // however long the line (the modeline's
                            // [truncate] shows the state).
                            new_buf.soft_wrap = false;
                            try buffers.append(gpa, new_buf);
                            try direds.append(gpa, null);
                            grep_buf_idx = buffers.items.len - 1;
                            recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                            current = grep_buf_idx.?;
                            focused.buf_idx = current;
                        }
                    } else if (key.text) |t| {
                        if (grep_prefill) {
                            // The prompt started prefilled (the word at
                            // point, or the last term on a g re-run): the
                            // first typed character replaces the prefill.
                            grep_prefill = false;
                            grep_query.clearRetainingCapacity();
                        }
                        try grep_query.appendSlice(gpa, t);
                    } else {
                        grep_prompt = false;
                        grep_prefill = false;
                    }
                } else if (occur_prompt) {
                    if (key.matches('g', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                        occur_prompt = false;
                        occur_prefill = false;
                    } else if (key.matches(vaxis.Key.backspace, .{})) {
                        if (occur_query.items.len > 0) _ = occur_query.pop();
                    } else if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true }) or key.matches('m', .{ .ctrl = true })) {
                        const term = std.mem.trim(u8, occur_query.items, " ");
                        occur_prompt = false;
                        occur_prefill = false;
                        if (occurRun(gpa, io, &buffers, &direds, &recent, root, &focused, current, &window_undo, &window_redo, buf, term, &occur_source, &occur_source_buf, &occur_last_term, &occur_matches, &occur_buf_idx, &results_target, &results_follow, &grep_hl, &status_msg)) |idx| {
                            current = idx;
                        }
                    } else if (key.text) |t| {
                        if (occur_prefill) {
                            // The prompt started prefilled (the word at
                            // point, the isearch query, or the last term on
                            // a g re-run): the first typed character
                            // replaces the prefill.
                            occur_prefill = false;
                            occur_query.clearRetainingCapacity();
                        }
                        try occur_query.appendSlice(gpa, t);
                    } else {
                        occur_prompt = false;
                        occur_prefill = false;
                    }
                } else if (replace_prompt) |phase| {
                    if (key.matches('g', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                        replace_prompt = null;
                        replace_prefill = false;
                    } else if (key.matches(vaxis.Key.backspace, .{})) {
                        switch (phase) {
                            .query => if (replace_query.items.len > 0) {
                                _ = replace_query.pop();
                            },
                            .with => if (replace_with.items.len > 0) {
                                _ = replace_with.pop();
                            },
                        }
                    } else if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true }) or key.matches('m', .{ .ctrl = true })) {
                        switch (phase) {
                            .query => {
                                // Enter on the query moves to the
                                // replacement prompt; an empty query cancels.
                                const term = std.mem.trim(u8, replace_query.items, " ");
                                if (term.len == 0) {
                                    replace_prompt = null;
                                } else {
                                    replace_query.clearRetainingCapacity();
                                    replace_query.appendSlice(gpa, term) catch {};
                                    replace_prompt = .with;
                                }
                                replace_prefill = false;
                            },
                            .with => {
                                const term = std.mem.trim(u8, replace_with.items, " ");
                                replace_prompt = null;
                                replace_prefill = false;
                                // An empty replacement deletes the matches,
                                // like Emacs.
                                replace_with.clearRetainingCapacity();
                                replace_with.appendSlice(gpa, term) catch {};
                                // The walk starts from point, replacing
                                // forward — the cursor hasn't moved since
                                // M-% (the prompts don't move it).
                                replace_count = 0;
                                replace_match = buf.findNextEnd(replace_query.items, .{ .row = buf.cursor_row, .col = buf.cursor_col });
                                if (replace_match) |m| {
                                    buf.cursor_row = m.row;
                                    buf.cursor_col = m.col;
                                    replace_active = true;
                                } else {
                                    status_msg = "No matches";
                                }
                            },
                        }
                    } else if (key.text) |t| {
                        if (replace_prefill) {
                            // The query prompt started prefilled (the word
                            // at point, or the isearch query): the first
                            // typed character replaces the prefill.
                            replace_prefill = false;
                            replace_query.clearRetainingCapacity();
                        }
                        switch (phase) {
                            .query => try replace_query.appendSlice(gpa, t),
                            .with => try replace_with.appendSlice(gpa, t),
                        }
                    } else {
                        replace_prompt = null;
                        replace_prefill = false;
                    }
                } else if (replace_active) {
                    if (key.matches('y', .{}) or key.matches(' ', .{})) {
                        // y / SPC: replace this match and move on.
                        if (replace_match) |m| {
                            const after = doReplace(gpa, buf, m, replace_query.items, replace_with.items) orelse
                                Buffer.Pos{ .row = m.row, .col = m.col + replace_query.items.len };
                            replace_count += 1;
                            replace_match = buf.findNextEnd(replace_query.items, after);
                        } else {
                            replace_match = buf.findNextEnd(replace_query.items, .{ .row = buf.cursor_row, .col = buf.cursor_col + 1 });
                        }
                        if (replace_match) |m| {
                            buf.cursor_row = m.row;
                            buf.cursor_col = m.col;
                        } else {
                            endReplace(&replace_active, &status_msg, &status_buf, replace_count);
                        }
                    } else if (key.matches('n', .{}) or key.matches(vaxis.Key.backspace, .{})) {
                        // n / DEL: skip this match and move on.
                        if (replace_match) |m| {
                            const from = Buffer.Pos{ .row = m.row, .col = m.col + replace_query.items.len };
                            replace_match = buf.findNextEnd(replace_query.items, from);
                        }
                        if (replace_match) |m| {
                            buf.cursor_row = m.row;
                            buf.cursor_col = m.col;
                        } else {
                            endReplace(&replace_active, &status_msg, &status_buf, replace_count);
                        }
                    } else if (key.matches('q', .{}) or key.matches('g', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                        // q / C-g / Esc: quit without replacing the rest.
                        endReplace(&replace_active, &status_msg, &status_buf, replace_count);
                    } else if (key.matches('!', .{})) {
                        // !: replace every remaining match, no more asking.
                        var m = replace_match;
                        var guard: usize = 0;
                        while (m) |mm| : (guard += 1) {
                            if (guard > 1_000_000) break;
                            const after = doReplace(gpa, buf, mm, replace_query.items, replace_with.items) orelse
                                Buffer.Pos{ .row = mm.row, .col = mm.col + replace_query.items.len };
                            replace_count += 1;
                            m = buf.findNextEnd(replace_query.items, after);
                        }
                        endReplace(&replace_active, &status_msg, &status_buf, replace_count);
                    } else if (key.matches('.', .{})) {
                        // .: replace this match, then quit.
                        if (replace_match) |m| {
                            _ = doReplace(gpa, buf, m, replace_query.items, replace_with.items);
                            replace_count += 1;
                        }
                        endReplace(&replace_active, &status_msg, &status_buf, replace_count);
                    } else if (key.matches('^', .{})) {
                        // ^: back to the previous match, to the start of
                        // the buffer (the walk never wraps). At the first
                        // match the current one stays.
                        if (replace_match) |m| {
                            if (buf.findPrevEnd(replace_query.items, .{ .row = m.row, .col = m.col })) |pm| {
                                replace_match = pm;
                                buf.cursor_row = pm.row;
                                buf.cursor_col = pm.col;
                            }
                        }
                    }
                    // Any other key is ignored — stay in the prompt rather
                    // than risk a stray keystroke replacing the wrong thing.
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
                } else if (dired_compress_menu) {
                    // Z's one-key format menu: the letters shown in the
                    // modeline run the format, C-g / Esc cancels, any
                    // other key is ignored.
                    if (key.matches('g', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                        dired_compress_menu = false;
                    } else if (key.text) |t| {
                        const ch = t[0];
                        for (dired_compress_choices.items) |c| {
                            if (c.key != ch) continue;
                            dired_compress_menu = false;
                            if (compressFmtArchives(c.fmt) and dired_compress_multi) {
                                // Several files: ask for the archive name,
                                // defaulting to the directory name plus the
                                // suffix (like the copy prompt's prefill).
                                dired_compress_fmt = c.fmt;
                                dired_archive_query.clearRetainingCapacity();
                                if (direds.items[current]) |*dd| {
                                    dired_archive_query.appendSlice(gpa, std.fs.path.basename(dd.display_path.items)) catch {};
                                    dired_archive_query.appendSlice(gpa, compressFmtSuffix(c.fmt)) catch {};
                                }
                                dired_archive_prompt = true;
                            } else {
                                // One entry: single-file tools compress it
                                // in place; an archive is named after it
                                // (foo → foo.tar.gz), sitting beside it.
                                const out: ?[]u8 = if (compressFmtArchives(c.fmt)) blk: {
                                    const o = std.fmt.allocPrint(gpa, "{s}{s}", .{ dired_compress_opds.items[0], compressFmtSuffix(c.fmt) }) catch break :blk null;
                                    break :blk o;
                                } else null;
                                defer if (out) |o| gpa.free(o);
                                const ok = diredCompressRun(io, gpa, c.fmt, dired_compress_opds.items, out);
                                refreshDired(gpa, io, &buffers, &direds, current);
                                if (ok) {
                                    const result = if (out) |o| o else blk: {
                                        const r = std.fmt.allocPrint(gpa, "{s}{s}", .{ dired_compress_opds.items[0], compressFmtSuffix(c.fmt) }) catch "";
                                        break :blk r;
                                    };
                                    defer if (out == null) gpa.free(result);
                                    compressStatus(io, &status_msg, &status_buf, result);
                                } else {
                                    status_msg = "Compression failed";
                                }
                            }
                            break;
                        }
                    }
                    // Any other key is ignored — stay in the menu.
                } else if (dired_archive_prompt) {
                    if (key.matches('g', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                        dired_archive_prompt = false;
                    } else if (key.matches(vaxis.Key.backspace, .{})) {
                        if (dired_archive_query.items.len > 0) _ = dired_archive_query.pop();
                    } else if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true }) or key.matches('m', .{ .ctrl = true })) {
                        const name = std.mem.trim(u8, dired_archive_query.items, " ");
                        dired_archive_prompt = false;
                        if (name.len > 0 and direds.items[current] != null) {
                            const d = &direds.items[current].?;
                            const out = if (std.fs.path.isAbsolute(name))
                                try gpa.dupe(u8, name)
                            else
                                try std.fs.path.join(gpa, &.{ d.path.items, name });
                            defer gpa.free(out);
                            if (diredCompressRun(io, gpa, dired_compress_fmt, dired_compress_opds.items, out)) {
                                refreshDired(gpa, io, &buffers, &direds, current);
                                compressStatus(io, &status_msg, &status_buf, out);
                            } else {
                                status_msg = "Compression failed";
                            }
                        }
                    } else if (key.text) |t| {
                        try dired_archive_query.appendSlice(gpa, t);
                    } else {
                        dired_archive_prompt = false;
                    }
                } else if (confirming_delete) {
                    if (key.matches('y', .{}) or key.matches('Y', .{})) {
                        confirming_delete = false;
                        if (direds.items[current]) |*d| {
                            // Trash every marked entry, or just the
                            // selected one when nothing is marked — the
                            // Windows Recycle Bin via PowerShell, the
                            // freedesktop.org trash elsewhere (like
                            // delete-by-moving-to-trash in the author's
                            // Emacs config), never a hard delete.
                            var idxs: std.ArrayList(usize) = .empty;
                            defer idxs.deinit(gpa);
                            diredOpIndices(gpa, d, &idxs);
                            var any = false;
                            var failed = false;
                            for (idxs.items) |i| {
                                const en = d.entries.items[i];
                                const path = try std.fs.path.join(gpa, &.{ d.path.items, en.name });
                                defer gpa.free(path);
                                if (trashFile(io, gpa, init.environ_map, path)) {
                                    any = true;
                                } else {
                                    failed = true;
                                }
                            }
                            if (any) refreshDired(gpa, io, &buffers, &direds, current);
                            if (failed) status_msg = "Trash failed";
                        }
                    } else if (key.matches('n', .{}) or key.matches('n', .{ .ctrl = true }) or key.matches('g', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                        confirming_delete = false;
                    }
                    // Any other key is ignored while confirming.
                } else if (confirming_open) {
                    if (key.matches('y', .{}) or key.matches('Y', .{})) {
                        const path = open_confirm_path orelse return;
                        confirming_open = false;
                        open_confirm_path = null;
                        defer gpa.free(path);
                        if (open_confirm_app) |a| gpa.free(a);
                        open_confirm_app = null;
                        if (!openExternal(io, gpa, init.environ_map, path)) status_msg = "Failed to open externally";
                    } else if (key.matches('n', .{}) or key.matches('n', .{ .ctrl = true }) or key.matches('g', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                        confirming_open = false;
                        if (open_confirm_path) |p| gpa.free(p);
                        open_confirm_path = null;
                        if (open_confirm_app) |a| gpa.free(a);
                        open_confirm_app = null;
                    }
                    // Any other key is ignored while confirming.
                } else if (isearch_active) {
                    if (picker_kind) |kind| {
                        // List isearch — the buffer, bookmark and recent
                        // pickers: the selection stands in for the cursor,
                        // and the search runs over the rows (row-granular,
                        // like isearch in a dired) — the visible rows when
                        // a filter is active. Confirming leaves the match
                        // selected, so the picker's Enter then opens it.
                        const vis = picker_visible.items;
                        if (key.matches('g', .{ .ctrl = true })) {
                            if (vis.len > 0) picker_selected = vis[isearch_origin.row % vis.len];
                            isearch_active = false;
                            isearch_match = null;
                            isearch_query.clearRetainingCapacity();
                        } else if (key.matches('s', .{ .ctrl = true })) {
                            isearch_dir = .forward;
                            if (isearch_query.items.len > 0) {
                                const from = if (isearch_match) |m| pickerSelectionPos(vis, m.row) + 1 else isearch_origin.row;
                                if (pickerFindNext(kind, buffers.items, bookmarks.items, recent.items, vis, isearch_query.items, from, true)) |m| {
                                    isearch_match = m;
                                    isearch_failed = false;
                                    picker_selected = m.row;
                                } else {
                                    isearch_failed = true;
                                }
                            }
                        } else if (key.matches('r', .{ .ctrl = true })) {
                            isearch_dir = .backward;
                            if (isearch_query.items.len > 0 and vis.len > 0) {
                                const from = if (isearch_match) |m| (pickerSelectionPos(vis, m.row) + vis.len - 1) % vis.len else isearch_origin.row;
                                if (pickerFindNext(kind, buffers.items, bookmarks.items, recent.items, vis, isearch_query.items, from, false)) |m| {
                                    isearch_match = m;
                                    isearch_failed = false;
                                    picker_selected = m.row;
                                } else {
                                    isearch_failed = true;
                                }
                            }
                        } else if (key.matches(vaxis.Key.backspace, .{})) {
                            if (isearch_query.items.len > 0) _ = isearch_query.pop();
                            if (isearch_query.items.len == 0) {
                                if (vis.len > 0) picker_selected = vis[isearch_origin.row % vis.len];
                                isearch_match = null;
                                isearch_failed = false;
                            } else if (pickerFindNext(kind, buffers.items, bookmarks.items, recent.items, vis, isearch_query.items, isearch_origin.row, isearch_dir == .forward)) |m| {
                                isearch_match = m;
                                isearch_failed = false;
                                picker_selected = m.row;
                            } else {
                                isearch_failed = true;
                            }
                        } else if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true }) or key.matches('m', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                            // Confirm the search: the match stays selected,
                            // and the picker's Enter opens it. The query
                            // becomes the remembered last search.
                            rememberIsearch(gpa, &isearch_last, isearch_query.items);
                            isearch_active = false;
                        } else if (key.text) |t| {
                            // The first character typed on a prefilled
                            // search replaces the prefill, like the grep /
                            // occur prompts.
                            if (isearch_prefill) {
                                isearch_prefill = false;
                                isearch_query.clearRetainingCapacity();
                            }
                            try isearch_query.appendSlice(gpa, t);
                            if (pickerFindNext(kind, buffers.items, bookmarks.items, recent.items, vis, isearch_query.items, isearch_origin.row, isearch_dir == .forward)) |m| {
                                isearch_match = m;
                                isearch_failed = false;
                                picker_selected = m.row;
                            } else {
                                isearch_failed = true;
                            }
                        } else {
                            rememberIsearch(gpa, &isearch_last, isearch_query.items);
                            isearch_active = false;
                        }
                    } else {
                        if (key.matches('c', .{ .alt = true })) {
                            // M-c in isearch: occur from the search string,
                            // like the author's my/occur-from-isearch. The
                            // search confirms and the matches land straight
                            // in a *occur* buffer — no prompt, the query is
                            // already in hand (the term is carried over for
                            // the g re-run). Editing buffers only.
                            if (isearch_query.items.len > 0 and direds.items[current] == null) {
                                syncDiredSelection(direds.items, current, buf);
                                const term = std.mem.trim(u8, isearch_query.items, " ");
                                rememberIsearch(gpa, &isearch_last, isearch_query.items);
                                isearch_active = false;
                                isearch_query.clearRetainingCapacity();
                                if (occurRun(gpa, io, &buffers, &direds, &recent, root, &focused, current, &window_undo, &window_redo, buf, term, &occur_source, &occur_source_buf, &occur_last_term, &occur_matches, &occur_buf_idx, &results_target, &results_follow, &grep_hl, &status_msg)) |idx| {
                                    current = idx;
                                }
                            } else {
                                isearch_active = false;
                            }
                        } else if (key.matches('%', .{ .alt = true })) {
                            // M-% in isearch: query-replace from the search
                            // string (Emacs isearch-query-replace) — the
                            // search confirms and the replacement prompt
                            // opens with the query already in hand. Editing
                            // buffers only.
                            const term = std.mem.trim(u8, isearch_query.items, " ");
                            if (term.len > 0 and direds.items[current] == null) {
                                syncDiredSelection(direds.items, current, buf);
                                buf.undoBoundary();
                                rememberIsearch(gpa, &isearch_last, isearch_query.items);
                                isearch_active = false;
                                isearch_match = null;
                                isearch_query.clearRetainingCapacity();
                                replace_prompt = .with;
                                replace_prefill = false;
                                replace_query.clearRetainingCapacity();
                                replace_query.appendSlice(gpa, term) catch {};
                                replace_with.clearRetainingCapacity();
                            } else {
                                isearch_active = false;
                            }
                        } else if (key.matches('g', .{ .ctrl = true })) {
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
                            // Confirm the search: the match stays selected,
                            // and the query becomes the remembered last
                            // search (so the next C-s repeats it).
                            syncDiredSelection(direds.items, current, buf);
                            rememberIsearch(gpa, &isearch_last, isearch_query.items);
                            isearch_active = false;
                        } else if (key.text) |t| {
                            // The first character typed on a prefilled
                            // search replaces the prefill (the repeat
                            // string), like the grep / occur prompts.
                            if (isearch_prefill) {
                                isearch_prefill = false;
                                isearch_query.clearRetainingCapacity();
                            }
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
                            rememberIsearch(gpa, &isearch_last, isearch_query.items);
                            isearch_active = false;
                        }
                    }
                    // isearch-lazy-count: recompute the match position and
                    // total for the modeline's (N/M) — a full scan once per
                    // search keystroke, like Emacs. The buffer search runs
                    // over the buffer's own lines (the dired mirror
                    // included); the list search over the picker's rows.
                    if (isearch_active and isearch_query.items.len > 0) {
                        if (picker_kind) |kind| {
                            isearch_count = pickerMatchCount(kind, buffers.items, bookmarks.items, recent.items, picker_visible.items, isearch_query.items);
                            isearch_pos = if (isearch_match) |m|
                                pickerMatchIndex(kind, buffers.items, bookmarks.items, recent.items, picker_visible.items, isearch_query.items, m.row)
                            else
                                0;
                        } else {
                            isearch_count = buf.matchCount(isearch_query.items);
                            isearch_pos = if (isearch_match) |m| buf.matchIndex(isearch_query.items, m) else 0;
                        }
                    } else {
                        isearch_count = 0;
                        isearch_pos = 0;
                    }
                } else if (picker_kind) |kind| {
                    // C-g (or Esc): clear the filter first; a second one
                    // closes the picker. Every printable key filters —
                    // no single-letter action keys, so typing a name that
                    // starts with any letter works.
                    if (key.matches('g', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                        if (picker_query.items.len > 0) {
                            picker_query.clearRetainingCapacity();
                            filterPicker(gpa, kind, buffers.items, bookmarks.items, recent.items, picker_query.items, &picker_visible, &picker_selected, &picker_hl);
                        } else {
                            picker_kind = null;
                        }
                    } else if (key.matches(vaxis.Key.backspace, .{})) {
                        // Backspace shortens the filter; at the empty query
                        // it's a no-op (C-g closes).
                        if (picker_query.items.len > 0) {
                            _ = picker_query.pop();
                            filterPicker(gpa, kind, buffers.items, bookmarks.items, recent.items, picker_query.items, &picker_visible, &picker_selected, &picker_hl);
                        }
                    } else if (key.matches('n', .{ .ctrl = true }) or key.matches(vaxis.Key.down, .{})) {
                        const pos = pickerSelectionPos(picker_visible.items, picker_selected);
                        if (pos + 1 < picker_visible.items.len) picker_selected = picker_visible.items[pos + 1];
                    } else if (key.matches('p', .{ .ctrl = true }) or key.matches(vaxis.Key.up, .{})) {
                        const pos = pickerSelectionPos(picker_visible.items, picker_selected);
                        if (pos > 0) picker_selected = picker_visible.items[pos - 1];
                    } else if (key.matches('s', .{ .ctrl = true })) {
                        // C-s / C-r: incremental search over the rows (the
                        // selection follows the match), like isearch in a
                        // dired — over the filtered rows when one is active.
                        // The last search string starts prefilled, as in a
                        // file buffer.
                        isearch_active = true;
                        isearch_dir = .forward;
                        isearch_origin = .{ .row = pickerSelectionPos(picker_visible.items, picker_selected), .col = 0 };
                        isearch_match = null;
                        isearch_failed = false;
                        isearch_query.clearRetainingCapacity();
                        isearch_prefill = isearch_last.items.len > 0;
                        if (isearch_prefill) {
                            isearch_query.appendSlice(gpa, isearch_last.items) catch {};
                            if (pickerFindNext(kind, buffers.items, bookmarks.items, recent.items, picker_visible.items, isearch_query.items, isearch_origin.row, true)) |m| {
                                isearch_match = m;
                                picker_selected = m.row;
                            } else {
                                isearch_failed = true;
                            }
                        }
                    } else if (key.matches('r', .{ .ctrl = true })) {
                        isearch_active = true;
                        isearch_dir = .backward;
                        isearch_origin = .{ .row = pickerSelectionPos(picker_visible.items, picker_selected), .col = 0 };
                        isearch_match = null;
                        isearch_failed = false;
                        isearch_query.clearRetainingCapacity();
                        isearch_prefill = isearch_last.items.len > 0;
                        if (isearch_prefill) {
                            isearch_query.appendSlice(gpa, isearch_last.items) catch {};
                            if (picker_visible.items.len > 0) {
                                if (pickerFindNext(kind, buffers.items, bookmarks.items, recent.items, picker_visible.items, isearch_query.items, isearch_origin.row, false)) |m| {
                                    isearch_match = m;
                                    picker_selected = m.row;
                                } else {
                                    isearch_failed = true;
                                }
                            } else {
                                isearch_failed = true;
                            }
                        }
                    } else if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true }) or key.matches('m', .{ .ctrl = true })) {
                        // Enter / C-j: open the selection — switch to the
                        // buffer, jump to the bookmark, or open the recent
                        // file.
                        const count = pickerRowCount(kind, buffers.items, bookmarks.items, recent.items);
                        if (picker_visible.items.len > 0 and picker_selected < count) {
                            picker_kind = null;
                            switch (kind) {
                                .buffers => {
                                    recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                                    current = picker_selected;
                                    focused.buf_idx = current;
                                    kill_active = false;
                                },
                                .bookmarks => {
                                    const name = bookmarks.items[picker_selected].name;
                                    if (bookmarkJump(gpa, io, &buffers, &direds, &recent, bookmarks.items, name)) |idx| {
                                        recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                                        current = idx;
                                        focused.buf_idx = idx;
                                    }
                                },
                                .recent => {
                                    const path = recent.items[picker_selected];
                                    recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                                    current = openBufferOrDired(gpa, io, &buffers, &direds, &recent, path) catch current;
                                    focused.buf_idx = current;
                                    kill_active = false;
                                },

                            }
                        }
                    } else if (key.text) |t| {
                        // Type to filter: every letter (n/p included) narrows
                        // the list (fuzzy, best rows first); arrows and C-n /
                        // C-p move the selection.
                        try picker_query.appendSlice(gpa, t);
                        filterPicker(gpa, kind, buffers.items, bookmarks.items, recent.items, picker_query.items, &picker_visible, &picker_selected, &picker_hl);
                    }
                } else if (pending_ctrl_x) {
                    pending_ctrl_x = false;
                    if (key.matches('s', .{ .ctrl = true })) {
                        buf.save(gpa, io) catch {
                            status_msg = "Save failed";
                        };
                        refreshBookmarksAfterSave(gpa, io, init.environ_map, &bookmarks, buf);
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
                        picker_kind = .buffers;
                        picker_selected = current;
                        picker_top = 0;
                        picker_query.clearRetainingCapacity();
                        pickerFilter(gpa, .buffers, buffers.items, bookmarks.items, recent.items, "", &picker_visible, &picker_hl);
                    } else if (key.matches('k', .{})) {
                        // C-x k: kill the current buffer (Emacs kill-buffer).
                        // A modified file buffer asks first (y saves and
                        // kills, n kills without saving, C-g cancels); a
                        // dired closes like q / C-g; the last buffer is
                        // never killed.
                        if (buf.dirty and buf.filename != null) {
                            confirming_kill = true;
                        } else {
                            const before = buffers.items.len;
                            recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                            current = closeBuffer(gpa, &buffers, &direds, root, focused, current, &window_undo, &window_redo);
                            if (buffers.items.len == before) status_msg = "Can't kill the last buffer";
                        }
                    } else if (key.matches('f', .{ .ctrl = true })) {
                        // C-x C-f: open-or-switch by typing a path, prefilled
                        // with the current buffer's directory (a dired's own
                        // while browsing), like Emacs default-directory —
                        // always absolute and ending in a separator, so
                        // typing a bare file name opens it right there. The
                        // prefill is ordinary prompt text, so Backspace edits
                        // the directory like any other part of the path.
                        switching_buffer = true;
                        switch_query.clearRetainingCapacity();
                        const start = if (direds.items[current]) |d|
                            try gpa.dupe(u8, d.path.items)
                        else
                            try Dired.startingDir(gpa, buf.filename orelse ".");
                        defer gpa.free(start);
                        const abs = Dired.absPathOf(gpa, io, start) catch try gpa.dupe(u8, start);
                        defer gpa.free(abs);
                        try switch_query.appendSlice(gpa, abs);
                        if (switch_query.items.len == 0 or switch_query.items[switch_query.items.len - 1] != std.fs.path.sep) {
                            try switch_query.append(gpa, std.fs.path.sep);
                        }
                    } else if (key.matches('r', .{})) {
                        pending_ctrl_x_r = true;
                    } else if (key.matches('d', .{}) or key.matches('m', .{})) {
                        // C-x d / C-x m: open (or switch to) a dired buffer
                        // for the current file's directory.
                        const start = try Dired.startingDir(gpa, buf.filename orelse ".");
                        defer gpa.free(start);
                        current = try openBufferOrDired(gpa, io, &buffers, &direds, &recent, start);
                        focused.buf_idx = current;
                    } else if (key.matches('g', .{})) {
                        buf.reread(gpa, io) catch {};
                    } else if (key.matches('h', .{})) {
                        buf.moveBufStart();
                        buf.setMark();
                        buf.moveBufEnd();
                    } else if (key.matches('l', .{})) {
                        // C-x l: toggle scroll lock (Emacs
                        // scroll-lock-mode, the same binding). On, the
                        // cursor stays on its current screen row and the
                        // text scrolls under it; the modeline's
                        // [scroll-lock] shows the state. The buffer
                        // remembers its own setting.
                        if (buf.scroll_lock) {
                            buf.scroll_lock = false;
                        } else {
                            buf.scroll_lock = true;
                            buf.scroll_row = visualRowOfCursor(buf, buf.top_line, focused_text_width, vx.screen.width_method);
                        }
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
                    } else if (key.matches('+', .{})) {
                        // C-x +: balance-windows — every split's divider
                        // returns to the middle, so all windows end up
                        // equal (Emacs C-x +).
                        recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                        root.balance();
                    } else if (key.matches('o', .{})) {
                        // C-x o: move to the next window. Sticky: the plain
                        // n / p / o repeat (see RepeatMap) — M-n / M-p stay
                        // single moves, this is the key that keeps stepping.
                        if (moveFocus(root, focused, 1)) |nf| {
                            focused = nf;
                            current = focused.buf_idx;
                        }
                        repeat_map = .window_move;
                    } else if (key.matches('j', .{}) or key.matches('c', .{})) {
                        // C-x j / C-x c: drop out of the editor into a real
                        // shell on the terminal. The shell takes over the
                        // whole screen until it exits (exit / C-d) or is
                        // suspended with C-z, which brings the editor back;
                        // C-x j (or C-x c) then resumes that same shell.
                        // A fresh shell starts in the current context's
                        // directory: the dired's own while browsing, the
                        // file's directory otherwise (the editor's working
                        // directory when the buffer has no file).
                        const shell_dir: ?[]const u8 = if (direds.items[current]) |*d|
                            try gpa.dupe(u8, d.path.items)
                        else if (buf.filename) |f|
                            try Dired.startingDir(gpa, f)
                        else
                            null;
                        defer if (shell_dir) |sd| gpa.free(sd);
                        shell_pid = try enterShell(gpa, io, init.environ_map, &loop, &vx, &tty, shell_pid, editor_pgrp, shell_dir);
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
                        picker_kind = .bookmarks;
                        picker_selected = 0;
                        picker_top = 0;
                        picker_query.clearRetainingCapacity();
                        pickerFilter(gpa, .bookmarks, buffers.items, bookmarks.items, recent.items, "", &picker_visible, &picker_hl);
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
                        picker_kind = .bookmarks;
                        picker_selected = 0;
                        picker_top = 0;
                        picker_query.clearRetainingCapacity();
                        pickerFilter(gpa, .bookmarks, buffers.items, bookmarks.items, recent.items, "", &picker_visible, &picker_hl);
                    } else if (key.matches('l', .{})) {
                        // M-l l: pick a recently opened file (the
                        // my/fido-recentf key from the author's Emacs).
                        if (recent.items.len > 0) {
                            picker_kind = .recent;
                            picker_selected = 0;
                            picker_top = 0;
                            picker_query.clearRetainingCapacity();
                            pickerFilter(gpa, .recent, buffers.items, bookmarks.items, recent.items, "", &picker_visible, &picker_hl);
                        } else {
                            status_msg = "No recent files";
                        }
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
                            if (openBufferOrDired(gpa, io, &buffers, &direds, &recent, "scratch.txt")) |idx| {
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
                            current = jumpOpen(gpa, io, home, &buffers, &direds, &recent, root, focused, current, &window_undo, &window_redo, &status_msg);
                        }
                    } else if (key.matches('b', .{})) {
                        // M-l b: ~/bin.
                        if (jumpHomePath(gpa, init.environ_map, &.{"bin"})) |p| {
                            defer gpa.free(p);
                            current = jumpOpen(gpa, io, p, &buffers, &direds, &recent, root, focused, current, &window_undo, &window_redo, &status_msg);
                        }
                    } else if (key.matches('d', .{})) {
                        // M-l d: Downloads — %USERPROFILE%\Downloads on
                        // Windows (or ~/Downloads), ~/Downloads elsewhere,
                        // exactly the elisp's system-type branch.
                        if (jumpHomePath(gpa, init.environ_map, &.{"Downloads"})) |p| {
                            defer gpa.free(p);
                            current = jumpOpen(gpa, io, p, &buffers, &direds, &recent, root, focused, current, &window_undo, &window_redo, &status_msg);
                        }
                    } else if (key.matches('g', .{})) {
                        // M-l g: the config directory — %APPDATA% on
                        // Windows (with the elisp's ~/AppData/Roaming
                        // fallback), ~/.config elsewhere.
                        if (comptime builtin.os.tag == .windows) {
                            if (init.environ_map.get("APPDATA")) |appdata| {
                                current = jumpOpen(gpa, io, appdata, &buffers, &direds, &recent, root, focused, current, &window_undo, &window_redo, &status_msg);
                            } else if (jumpHomePath(gpa, init.environ_map, &.{ "AppData", "Roaming" })) |p| {
                                defer gpa.free(p);
                                current = jumpOpen(gpa, io, p, &buffers, &direds, &recent, root, focused, current, &window_undo, &window_redo, &status_msg);
                            }
                        } else if (jumpHomePath(gpa, init.environ_map, &.{".config"})) |p| {
                            defer gpa.free(p);
                            current = jumpOpen(gpa, io, p, &buffers, &direds, &recent, root, focused, current, &window_undo, &window_redo, &status_msg);
                        }
                    } else if (key.matches('i', .{})) {
                        // M-l i: the Emacs-vanilla config directory.
                        if (jumpHomePath(gpa, init.environ_map, &.{ ".emacs.d", "Emacs-vanilla" })) |p| {
                            defer gpa.free(p);
                            current = jumpOpen(gpa, io, p, &buffers, &direds, &recent, root, focused, current, &window_undo, &window_redo, &status_msg);
                        }
                    } else if (key.matches('y', .{})) {
                        // M-l y: the Emacs-DIYer config directory.
                        if (jumpHomePath(gpa, init.environ_map, &.{ ".emacs.d", "Emacs-DIYer" })) |p| {
                            defer gpa.free(p);
                            current = jumpOpen(gpa, io, p, &buffers, &direds, &recent, root, focused, current, &window_undo, &window_redo, &status_msg);
                        }
                    } else if (key.matches('s', .{})) {
                        // M-l s: the ~/source tree.
                        if (jumpHomePath(gpa, init.environ_map, &.{"source"})) |p| {
                            defer gpa.free(p);
                            current = jumpOpen(gpa, io, p, &buffers, &direds, &recent, root, focused, current, &window_undo, &window_redo, &status_msg);
                        }
                    } else if (key.matches('=', .{})) {
                        // M-l =: open a new tab at the right end of the
                        // tab set (capped at MAX_TABS). The new tab is a
                        // single window on the current buffer — the one
                        // the cursor is in — so work continues where it
                        // left off.
                        new_tab: {
                            if (tabs.items.len >= MAX_TABS) {
                                status_msg = "Max tabs reached";
                                break :new_tab;
                            }
                            const new_root = gpa.create(Pane) catch break :new_tab;
                            tabs.items[active_tab] = .{ .root = root, .focused = focused, .current = current };
                            new_root.* = .{ .buf_idx = current };
                            tabs.append(gpa, .{ .root = new_root, .focused = new_root, .current = current }) catch {
                                new_root.destroy(gpa);
                                break :new_tab;
                            };
                            active_tab = tabs.items.len - 1;
                            root = new_root;
                            focused = new_root;
                            // Window history doesn't cross tabs.
                            window_undo.clearRetainingCapacity();
                            window_redo.clearRetainingCapacity();
                        }
                    } else if (key.matches('-', .{})) {
                        // M-l -: close the current tab. The last tab can't
                        // be closed; the tab to its left becomes active.
                        if (tabs.items.len > 1) {
                            root.destroy(gpa);
                            _ = tabs.orderedRemove(active_tab);
                            active_tab = @min(active_tab, tabs.items.len - 1);
                            root = tabs.items[active_tab].root;
                            focused = tabs.items[active_tab].focused;
                            current = tabs.items[active_tab].current;
                            // Window history doesn't cross tabs.
                            window_undo.clearRetainingCapacity();
                            window_redo.clearRetainingCapacity();
                        }
                    }
                } else if (pending_alt_o) {
                    // M-o: the quick-jump label key — j k l ; a s d f name
                    // the windows in render order (the corner labels drawn
                    // while the map is armed); C-g / Esc cancels, any other
                    // key is ignored like an undefined binding in a real
                    // keymap.
                    pending_alt_o = false;
                    if (key.matches('g', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                        // abort the jump
                    } else if (std.mem.indexOfScalar(u8, quick_jump_labels, @intCast(key.codepoint))) |idx| {
                        var leaves: [MAX_PANES]*Pane = undefined;
                        var n: usize = 0;
                        root.collectLeaves(&leaves, &n);
                        if (idx < n) {
                            focused = leaves[idx];
                            current = focused.buf_idx;
                        }
                    }
                } else if (pending_ctrl_z) {
                    // C-z e: toggle the current buffer's whitespace markers
                    // (Emacs whitespace-mode — spaces as ·, tabs as »,
                    // line breaks as $); C-g / Esc cancels the prefix, any
                    // other key is ignored like an undefined binding.
                    pending_ctrl_z = false;
                    if (key.matches('e', .{})) {
                        buf.show_whitespace = !buf.show_whitespace;
                    } else if (key.matches('g', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                        // abort the prefix
                    }
                } else if (key.matches('1', .{ .alt = true }) or key.matches('2', .{ .alt = true }) or key.matches('3', .{ .alt = true }) or key.matches('4', .{ .alt = true }) or key.matches('5', .{ .alt = true }) or key.matches('6', .{ .alt = true }) or key.matches('7', .{ .alt = true }) or key.matches('8', .{ .alt = true }) or key.matches('9', .{ .alt = true })) {
                    // M-1..M-9: select a tab by number (the numbered tab
                    // set's natural selector).
                    selectTab(&tabs, &active_tab, @intCast(key.codepoint - '1'), &root, &focused, &current, &window_undo, &window_redo);
                } else if (key.matches('u', .{ .alt = true })) {
                    // M-u: move to the tab on the left (wrapping).
                    if (tabs.items.len > 1) {
                        selectTab(&tabs, &active_tab, (active_tab + tabs.items.len - 1) % tabs.items.len, &root, &focused, &current, &window_undo, &window_redo);
                    }
                } else if (key.matches('i', .{ .alt = true })) {
                    // M-i: move to the tab on the right (wrapping).
                    if (tabs.items.len > 1) {
                        selectTab(&tabs, &active_tab, (active_tab + 1) % tabs.items.len, &root, &focused, &current, &window_undo, &window_redo);
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
                    // The grep results buffer (C-c g) takes over the plain
                    // keys like a dired: n/p move between matches, Enter
                    // jumps to the match, g re-runs the search, q / C-g
                    // closes. The display-name check keeps a stale
                    // `grep_buf_idx` (the buffer killed via C-x k, say)
                    // from hijacking whatever buffer now sits at that
                    // index.
                    // The results buffers (C-c g *grep*, C-c f *files*)
                    // take over the plain keys like a dired: n/p move
                    // between the entries, Enter opens the entry in the
                    // target window, F toggles follow mode, g re-runs, q /
                    // C-g closes (in *files*, q and every letter filter —
                    // see below). The display-name check keeps a stale
                    // `grep_buf_idx` / `find_buf_idx` (the buffer killed
                    // via C-x k, say) from hijacking whatever buffer now
                    // sits at that index.
                    const results_kind: ?ResultsKind = blk: {
                        const name = buffers.items[current].display_name orelse "";
                        if (current == grep_buf_idx and std.mem.eql(u8, name, "*grep*")) break :blk .grep;
                        if (current == find_buf_idx and std.mem.eql(u8, name, "*files*")) break :blk .files;
                        if (current == occur_buf_idx and std.mem.eql(u8, name, "*occur*")) break :blk .occur;
                        break :blk null;
                    };
                    // `editing` is captured BEFORE the dired block runs: it
                    // must describe the buffer this keypress actually acts
                    // on. Opening a file from dired changes `current` mid-
                    // keypress, and a stale true value would let the same
                    // key fall through into the editing dispatch against the
                    // zero-line dired buffer. The results buffers are
                    // read-only like a dired, so keys they don't consume
                    // (kills) don't corrupt their rows.
                    const editing = direds.items[current] == null and results_kind == null;
                    if (results_kind) |rkind| {
                        const is_files = rkind == .files;
                        const is_occur = rkind == .occur;
                        // Close: C-g / Esc for both (clearing the *files*
                        // filter first); q too, except in *files*, where
                        // every letter filters.
                        if (key.matches('g', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{}) or (!is_files and key.matches('q', .{}))) {
                            if (is_files and find_filter.items.len > 0) {
                                find_filter.clearRetainingCapacity();
                                filesMirror(gpa, buf, find_paths.items, find_filter.items, &find_visible, &find_hl);
                            } else {
                                recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                                current = closeBuffer(gpa, &buffers, &direds, root, focused, current, &window_undo, &window_redo);
                                if (is_files) {
                                    find_buf_idx = null;
                                    for (find_paths.items) |p| gpa.free(p);
                                    find_paths.clearRetainingCapacity();
                                } else if (is_occur) {
                                    occur_buf_idx = null;
                                    if (occur_source) |s| gpa.free(s);
                                    occur_source = null;
                                    occur_source_buf = null;
                                    if (occur_last_term) |t| gpa.free(t);
                                    occur_last_term = null;
                                    occur_matches.clearRetainingCapacity();
                                } else {
                                    grep_buf_idx = null;
                                    for (grep_matches.items) |m| gpa.free(m.path);
                                    grep_matches.clearRetainingCapacity();
                                }
                                results_target = null;
                                results_follow = false;
                                grep_hl = null;
                            }
                        } else if (key.matches('n', .{}) or key.matches('n', .{ .ctrl = true }) or key.matches(vaxis.Key.down, .{})) {
                            // n / p (and C-n / C-p / arrows) move between
                            // the entries; with follow mode on (F) the
                            // entry under point opens in the target window
                            // automatically, focus staying here.
                            const limit: usize = if (is_files) buf.lines.items.len else if (is_occur) occur_matches.items.len else grep_matches.items.len;
                            if (buf.cursor_row + 1 < limit) {
                                buf.cursor_row += 1;
                                buf.cursor_col = 0;
                                if (results_follow) {
                                    if (is_files) {
                                        resultsOpenMatch(gpa, io, &buffers, &direds, &recent, root, &focused, current, &window_undo, &window_redo, find_paths.items[find_visible.items[buf.cursor_row]], 0, 0, &results_target, null, &grep_hl);
                                    } else if (is_occur) {
                                        occurJump(gpa, io, &buffers, &direds, &recent, root, &focused, current, &window_undo, &window_redo, occur_source, occur_source_buf, occur_matches.items, buf.cursor_row, &results_target, occur_last_term, &grep_hl);
                                    } else {
                                        const m = grep_matches.items[buf.cursor_row];
                                        resultsOpenMatch(gpa, io, &buffers, &direds, &recent, root, &focused, current, &window_undo, &window_redo, m.path, m.line, m.col, &results_target, grep_last_term, &grep_hl);
                                    }
                                }
                            }
                        } else if (key.matches('p', .{}) or key.matches('p', .{ .ctrl = true }) or key.matches(vaxis.Key.up, .{})) {
                            if (buf.cursor_row > 0) {
                                buf.cursor_row -= 1;
                                buf.cursor_col = 0;
                                if (results_follow) {
                                    if (is_files) {
                                        resultsOpenMatch(gpa, io, &buffers, &direds, &recent, root, &focused, current, &window_undo, &window_redo, find_paths.items[find_visible.items[buf.cursor_row]], 0, 0, &results_target, null, &grep_hl);
                                    } else if (is_occur) {
                                        occurJump(gpa, io, &buffers, &direds, &recent, root, &focused, current, &window_undo, &window_redo, occur_source, occur_source_buf, occur_matches.items, buf.cursor_row, &results_target, occur_last_term, &grep_hl);
                                    } else {
                                        const m = grep_matches.items[buf.cursor_row];
                                        resultsOpenMatch(gpa, io, &buffers, &direds, &recent, root, &focused, current, &window_undo, &window_redo, m.path, m.line, m.col, &results_target, grep_last_term, &grep_hl);
                                    }
                                }
                            }
                        } else if (key.matches('F', .{})) {
                            // F: toggle follow mode — stepping with n/p
                            // opens each entry in the target window.
                            results_follow = !results_follow;
                        } else if (key.matches('g', .{})) {
                            if (is_files) {
                                // g: re-run the find over the last
                                // directory, staying in the buffer.
                                if (find_dir) |d| {
                                    const dir = gpa.dupe(u8, d) catch null;
                                    defer if (dir) |dd| gpa.free(dd);
                                    if (dir) |dd| {
                                        if (filesRun(gpa, io, &buffers, &direds, dd, &find_paths, &find_dir, &find_filter, &find_visible, &find_hl, &find_buf_idx) == null) {
                                            status_msg = "No files found";
                                        }
                                    }
                                }
                            } else if (is_occur) {
                                // g: re-run the occur — the prompt reopens
                                // prefilled with the previous term.
                                occur_prompt = true;
                                occur_prefill = true;
                                occur_query.clearRetainingCapacity();
                                if (occur_last_term) |t| occur_query.appendSlice(gpa, t) catch {};
                            } else {
                                // g: re-run the search — the prompt reopens
                                // prefilled with the previous term.
                                grep_prompt = true;
                                grep_prefill = true;
                                grep_query.clearRetainingCapacity();
                                if (grep_last_term) |t| grep_query.appendSlice(gpa, t) catch {};
                            }
                        } else if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true }) or key.matches('m', .{ .ctrl = true })) {
                            // Enter: open the entry in the target window —
                            // the results buffer stays put and the window
                            // is reused for every jump (see
                            // resultsOpenMatch).
                            if (is_files) {
                                if (buf.cursor_row < find_visible.items.len) {
                                    resultsOpenMatch(gpa, io, &buffers, &direds, &recent, root, &focused, current, &window_undo, &window_redo, find_paths.items[find_visible.items[buf.cursor_row]], 0, 0, &results_target, null, &grep_hl);
                                }
                            } else if (is_occur) {
                                occurJump(gpa, io, &buffers, &direds, &recent, root, &focused, current, &window_undo, &window_redo, occur_source, occur_source_buf, occur_matches.items, buf.cursor_row, &results_target, occur_last_term, &grep_hl);
                            } else {
                                const sel = @min(buf.cursor_row, grep_matches.items.len -| 1);
                                const m = grep_matches.items[sel];
                                resultsOpenMatch(gpa, io, &buffers, &direds, &recent, root, &focused, current, &window_undo, &window_redo, m.path, m.line, m.col, &results_target, grep_last_term, &grep_hl);
                            }
                        } else if (is_files) {
                            if (key.matches(vaxis.Key.backspace, .{})) {
                                // Backspace shortens the filter.
                                if (find_filter.items.len > 0) {
                                    const before_full = if (buf.cursor_row < find_visible.items.len) find_visible.items[buf.cursor_row] else 0;
                                    _ = find_filter.pop();
                                    filesMirror(gpa, buf, find_paths.items, find_filter.items, &find_visible, &find_hl);
                                    if (find_visible.items.len > 0) {
                                        buf.cursor_row = std.mem.indexOfScalar(usize, find_visible.items, before_full) orelse 0;
                                        buf.cursor_col = 0;
                                    }
                                }
                            } else if (key.text) |t| {
                                // Type to filter: every letter narrows the
                                // list (partial-completion, the matches
                                // highlight), the previous entry kept when
                                // it still shows.
                                const before_full = if (buf.cursor_row < find_visible.items.len) find_visible.items[buf.cursor_row] else 0;
                                try find_filter.appendSlice(gpa, t);
                                filesMirror(gpa, buf, find_paths.items, find_filter.items, &find_visible, &find_hl);
                                if (find_visible.items.len > 0) {
                                    buf.cursor_row = std.mem.indexOfScalar(usize, find_visible.items, before_full) orelse 0;
                                    buf.cursor_col = 0;
                                }
                            }
                        }
                    } else if (direds.items[current]) |*d| {
                        if (key.matches('g', .{ .ctrl = true }) or key.matches('q', .{})) {
                            recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                            current = closeBuffer(gpa, &buffers, &direds, root, focused, current, &window_undo, &window_redo);
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
                        } else if (key.matches('0', .{})) {
                            // 0: the numeric prefix for w — 0 w copies the
                            // absolute file name (Emacs
                            // dired-copy-filename-as-kill with a prefix
                            // argument of 0).
                            pending_dired_0 = true;
                        } else if (key.matches('w', .{})) {
                            // w: copy the file names of the marked entries —
                            // or just the selected one when nothing is
                            // marked — to the kill ring (Emacs
                            // dired-copy-filename-as-kill), so C-y pastes
                            // them anywhere. 0 w copies the absolute file
                            // name instead of the bare one — a leading ~
                            // expands to the home directory and a relative
                            // dired path resolves against the process cwd,
                            // like Emacs's expand-file-name. Several names
                            // are newline-joined, and a following kill
                            // appends like C-k after M-w.
                            const full_path = pending_dired_0;
                            pending_dired_0 = false;
                            var idxs: std.ArrayList(usize) = .empty;
                            defer idxs.deinit(gpa);
                            diredOpIndices(gpa, d, &idxs);
                            if (idxs.items.len > 0) {
                                var out: std.ArrayList(u8) = .empty;
                                defer out.deinit(gpa);
                                for (idxs.items, 0..) |i, n| {
                                    const en = d.entries.items[i];
                                    if (n > 0) out.appendSlice(gpa, "\n") catch break;
                                    if (full_path) {
                                        const exp = expandTilde(gpa, init.environ_map, d.path.items) catch break;
                                        defer gpa.free(exp);
                                        const joined = std.fs.path.join(gpa, &.{ exp, en.name }) catch break;
                                        defer gpa.free(joined);
                                        const abs = Dired.absPathOf(gpa, io, joined) catch break;
                                        defer gpa.free(abs);
                                        out.appendSlice(gpa, abs) catch break;
                                    } else {
                                        out.appendSlice(gpa, en.name) catch break;
                                    }
                                }
                                kill_ring.remember(gpa, out.items, was_kill) catch {};
                                syncClipboard(&vx, &tty, gpa, kill_ring.current() orelse "");
                                kill_active = true;
                                // Echo what was copied on the modeline until
                                // the next keypress (the dired twin of Emacs
                                // echoing the kill text in the minibuffer).
                                const n = std.fmt.bufPrint(&status_buf, "Copied: {s}", .{out.items}) catch blk: {
                                    break :blk std.fmt.bufPrint(&status_buf, "Copied {d} names", .{idxs.items.len}) catch unreachable;
                                };
                                status_msg = status_buf[0..n.len];
                            }
                        } else if (key.matches('(', .{})) {
                            // ( : toggle dired-hide-details-mode — hide
                            // the metadata (permissions, size, date) so
                            // only the names remain, like Emacs; the
                            // modeline shows (Hide-Details) while hidden.
                            d.hide_details = !d.hide_details;
                        } else if (key.matches('l', .{ .ctrl = true })) {
                            // C-l: recenter the listing on the selection.
                            // The header line (when shown) takes one of the
                            // pane's rows, so the viewport matches
                            // renderDiredPane's entry_rows.
                            d.recenterTopBottom(if (focused_text_height >= 2) focused_text_height - 1 else focused_text_height, last_was_recenter);
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
                        } else if (key.matches('g', .{})) {
                            // g: re-read the directory listing (Emacs
                            // revert-buffer in dired), keeping the
                            // selection where it was.
                            refreshDired(gpa, io, &buffers, &direds, current);
                        } else if (key.matches('e', .{ .alt = true }) or key.matches('^', .{})) {
                            if (try d.upPath(gpa)) |parent| {
                                defer gpa.free(parent);
                                recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                                current = try openBufferOrDired(gpa, io, &buffers, &direds, &recent, parent);
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
                        } else if (key.matches('J', .{ .alt = true })) {
                            // M-J: a page down the listing (Emacs
                            // scroll-up): the selection moves one
                            // screenful of entries.
                            d.selected = @min(d.selected + (focused_text_height -| 1), d.entries.items.len -| 1);
                        } else if (key.matches('K', .{ .alt = true })) {
                            // M-K: a page up the listing.
                            d.selected -|= focused_text_height -| 1;
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
                            // D: move the marked entries to the platform
                            // trash — the Windows Recycle Bin via
                            // PowerShell, the freedesktop.org trash
                            // elsewhere — or just the selected one when
                            // nothing is marked (Emacs dired-do-delete
                            // with delete-by-moving-to-trash).
                            if (diredMarkedCount(d) > 0 or !std.mem.eql(u8, d.entries.items[d.selected].name, "..")) {
                                confirming_delete = true;
                            }
                        } else if (key.matches('W', .{})) {
                            // W: open the selected entry with the system's
                            // default handler — xdg-open on Linux/BSD, `open`
                            // on macOS, cmd's start on Windows — so a file
                            // opens in its default application and a
                            // directory in the file manager. ".." is skipped
                            // like C and D. The handler the desktop would
                            // use is looked up first and shown in the
                            // modeline; y / n confirms before anything runs.
                            const e = d.entries.items[d.selected];
                            if (!std.mem.eql(u8, e.name, "..")) {
                                if (std.fs.path.join(gpa, &.{ d.path.items, e.name }) catch null) |full| {
                                    open_confirm_path = full;
                                    open_confirm_app = defaultOpenApp(io, gpa, full);
                                    confirming_open = true;
                                }
                            }
                        } else if (key.matches('z', .{})) {
                            // z: compress or decompress the marked entries,
                            // or just the selected one when nothing is
                            // marked (Emacs dired-compress-file, the
                            // author's my/dired-compress-transient
                            // simplified to this platform's tools).
                            // Entries that already carry a compression
                            // suffix are decompressed straight away;
                            // anything else opens the one-key format menu.
                            var idxs: std.ArrayList(usize) = .empty;
                            defer idxs.deinit(gpa);
                            diredOpIndices(gpa, d, &idxs);
                            if (idxs.items.len > 0) blk: {
                                for (dired_compress_opds.items) |p| gpa.free(p);
                                dired_compress_opds.clearRetainingCapacity();
                                var all_compressed = true;
                                for (idxs.items) |i| {
                                    const name = d.entries.items[i].name;
                                    if (compressedKindOf(name) == null) all_compressed = false;
                                    const full = std.fs.path.join(gpa, &.{ d.path.items, name }) catch break :blk;
                                    dired_compress_opds.append(gpa, full) catch {
                                        gpa.free(full);
                                        break :blk;
                                    };
                                }
                                if (dired_compress_opds.items.len < idxs.items.len) break :blk;
                                if (all_compressed) {
                                    var failed = false;
                                    for (dired_compress_opds.items) |p| {
                                        if (!diredDecompressRun(io, gpa, p)) failed = true;
                                    }
                                    refreshDired(gpa, io, &buffers, &direds, current);
                                    if (failed) {
                                        status_msg = "Decompression failed";
                                    } else {
                                        const n = std.fmt.bufPrint(&status_buf, "Decompressed {d} file{s}", .{ dired_compress_opds.items.len, if (dired_compress_opds.items.len == 1) "" else "s" }) catch unreachable;
                                        status_msg = status_buf[0..n.len];
                                    }
                                } else {
                                    // The menu's formats depend on the
                                    // target: a single plain file gets the
                                    // gzip-style tools, a directory or
                                    // several files the tar-style ones.
                                    const single_dir = idxs.items.len == 1 and d.entries.items[idxs.items[0]].is_dir;
                                    dired_compress_multi = idxs.items.len > 1;
                                    compressChoices(io, gpa, &dired_compress_choices, dired_compress_multi or single_dir);
                                    if (dired_compress_choices.items.len == 0) {
                                        status_msg = "No compression tools found";
                                    } else {
                                        var names: std.ArrayList(u8) = .empty;
                                        defer names.deinit(gpa);
                                        for (dired_compress_opds.items, 0..) |p, i| {
                                            if (i > 0) names.appendSlice(gpa, ", ") catch {};
                                            names.appendSlice(gpa, std.fs.path.basename(p)) catch {};
                                            if (names.items.len > 60) {
                                                names.appendSlice(gpa, "...") catch {};
                                                break;
                                            }
                                        }
                                        dired_compress_label = std.fmt.bufPrint(&dired_compress_label_buf, "Compress {s} as: ", .{names.items}) catch "";
                                        dired_compress_menu_text = compressMenuText(&dired_compress_menu_buf, dired_compress_choices.items);
                                        dired_compress_menu = true;
                                    }
                                }
                            }
                        } else if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true }) or key.matches('m', .{ .ctrl = true }) or key.matches('f', .{})) {
                            // Enter / C-j / C-m, or "f" (the dirlst-find-file
                            // key from the Jasspa setup): open the selected
                            // entry.
                            const choice = d.choose(gpa) catch Dired.Choice.none;
                            switch (choice) {
                                .none => {},
                                .open_file, .open_dir => |path| {
                                    defer gpa.free(path);
                                    recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                                    current = try openBufferOrDired(gpa, io, &buffers, &direds, &recent, path);
                                    focused.buf_idx = current;
                                },
                            }
                        }
                    }

                    if (key.matches('x', .{ .ctrl = true })) {
                        pending_ctrl_x = true;
                    } else if (key.matches('c', .{ .ctrl = true })) {
                        pending_ctrl_c = true;
                    } else if (key.matches('z', .{ .ctrl = true })) {
                        // C-z: the whitespace-marker prefix — C-z e
                        // toggles the current buffer's markers (see the
                        // pending_ctrl_z branch).
                        pending_ctrl_z = true;
                    } else if (key.matches('l', .{ .alt = true })) {
                        // M-l: the my-jump prefix (see the pending_alt_l
                        // branch above).
                        pending_alt_l = true;
                    } else if (key.matches('/', .{ .ctrl = true }) or key.matches(0x1F, .{})) {
                        if (pending_ctrl_g) {
                            // C-g C-/: redo (the author's Emacs habit);
                            // plain C-/ undoes.
                            pending_ctrl_g = false;
                            buf.redo(gpa);
                        } else {
                            buf.undo(gpa);
                        }
                    } else if (key.matches('/', .{ .alt = true })) {
                        // M-/: redo, the single-key alias of C-g C-/.
                        buf.redo(gpa);
                    } else if (key.matches(';', .{ .ctrl = true })) {
                        if (editing) try buf.toggleComment(gpa);
                    } else if (key.matches('s', .{ .ctrl = true })) {
                        // C-s: search forward. A last search string starts
                        // the search prefilled and jumps to the next match
                        // at once (Emacs isearch-repeat-forward: C-s with an
                        // empty query repeats the previous search).
                        isearch_active = true;
                        isearch_dir = .forward;
                        isearch_origin = if (direds.items[current]) |d|
                            .{ .row = d.selected, .col = 0 }
                        else
                            .{ .row = buf.cursor_row, .col = buf.cursor_col };
                        isearch_match = null;
                        isearch_failed = false;
                        isearch_query.clearRetainingCapacity();
                        isearch_prefill = isearch_last.items.len > 0;
                        if (isearch_prefill) {
                            isearch_query.appendSlice(gpa, isearch_last.items) catch {};
                            if (buf.findNext(isearch_query.items, isearch_origin, .forward)) |m| {
                                buf.cursor_row = m.row;
                                buf.cursor_col = m.col;
                                syncDiredSelection(direds.items, current, buf);
                                isearch_match = m;
                            } else {
                                isearch_failed = true;
                            }
                        }
                    } else if (key.matches('r', .{ .ctrl = true })) {
                        // C-r: search backward, remembered like C-s.
                        isearch_active = true;
                        isearch_dir = .backward;
                        isearch_origin = if (direds.items[current]) |d|
                            .{ .row = d.selected, .col = 0 }
                        else
                            .{ .row = buf.cursor_row, .col = buf.cursor_col };
                        isearch_match = null;
                        isearch_failed = false;
                        isearch_query.clearRetainingCapacity();
                        isearch_prefill = isearch_last.items.len > 0;
                        if (isearch_prefill) {
                            isearch_query.appendSlice(gpa, isearch_last.items) catch {};
                            if (buf.findNext(isearch_query.items, isearch_origin, .backward)) |m| {
                                buf.cursor_row = m.row;
                                buf.cursor_col = m.col;
                                syncDiredSelection(direds.items, current, buf);
                                isearch_match = m;
                            } else {
                                isearch_failed = true;
                            }
                        }
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
                        refreshBookmarksAfterSave(gpa, io, init.environ_map, &bookmarks, buf);
                    } else if (key.matches('w', .{ .alt = true })) {
                        // M-w: copy the region (point to mark), or — with no
                        // mark set — the current line, like Emacs's M-w on a
                        // line with no active region. Either way the text heads
                        // the kill ring (so C-y gets it back) and mirrors onto
                        // the system clipboard; a following kill appends, like
                        // C-k after M-w on a region. Direds are read-only, so
                        // the copy-line fallback is editing-only; with a mark
                        // the region copy still runs (same as before).
                        if (buf.mark != null) {
                            try buf.copyRegion(gpa, &kill_ring, was_kill);
                            buf.mark = null; // copy drops the mark, like C-c w
                        } else if (editing) {
                            try buf.copyLine(gpa, &kill_ring, was_kill);
                        }
                        syncClipboard(&vx, &tty, gpa, kill_ring.current() orelse "");
                        kill_active = true;
                    } else if (key.matches('c', .{ .alt = true })) {
                        // M-c: occur (the author's Emacs M-c) — every line
                        // of the current buffer matching a term lands in a
                        // *occur* buffer, exactly like *grep* but over the
                        // buffer itself. Editing buffers only: a results
                        // buffer or dired has no text to scan.
                        if (editing) {
                            occur_prompt = true;
                            occur_query.clearRetainingCapacity();
                            if (buf.lines.items.len > 0) {
                                const line = buf.lines.items[buf.cursor_row].items;
                                const col = @min(buf.cursor_col, line.len);
                                var s = col;
                                while (s > 0 and (std.ascii.isAlphanumeric(line[s - 1]) or line[s - 1] == '_')) s -= 1;
                                var e = col;
                                while (e < line.len and (std.ascii.isAlphanumeric(line[e]) or line[e] == '_')) e += 1;
                                if (e > s) occur_query.appendSlice(gpa, line[s..e]) catch {};
                                occur_prefill = e > s;
                            }
                        }
                    } else if (key.matches('%', .{ .alt = true })) {
                        // M-%: query-replace (Emacs query-replace) — prompt
                        // for the string to find (prefilled with the word at
                        // point), then its replacement, then walk the
                        // matches asking y / n / q / ! / . / ^, like Emacs.
                        // Editing buffers only: a results buffer or dired has
                        // no text to rewrite. Each session is one undo step.
                        if (editing) {
                            buf.undoBoundary();
                            replace_prompt = .query;
                            replace_query.clearRetainingCapacity();
                            replace_with.clearRetainingCapacity();
                            if (buf.lines.items.len > 0) {
                                const line = buf.lines.items[buf.cursor_row].items;
                                const col = @min(buf.cursor_col, line.len);
                                var s = col;
                                while (s > 0 and (std.ascii.isAlphanumeric(line[s - 1]) or line[s - 1] == '_')) s -= 1;
                                var e = col;
                                while (e < line.len and (std.ascii.isAlphanumeric(line[e]) or line[e] == '_')) e += 1;
                                if (e > s) replace_query.appendSlice(gpa, line[s..e]) catch {};
                                replace_prefill = e > s;
                            }
                        }
                    } else if (key.matches('y', .{ .ctrl = true })) {
                        if (editing) {
                            yank_clip: {
                                // Windows: consult the real clipboard on
                                // every C-y, not just when the kill ring is
                                // empty. An external copy made since the
                                // last yank must win over the (now-stale)
                                // kill-ring head — Emacs consults the
                                // interprogram clipboard the same way. Only
                                // content that merely repeats the current
                                // kill-ring head falls through to a normal
                                // yank; with no clipboard at all the empty
                                // kill ring is handled below.
                                if (comptime builtin.os.tag == .windows) {
                                    if (winClipboardGet(gpa)) |clip| {
                                        defer gpa.free(clip);
                                        const repeats_kill_ring = if (kill_ring.current()) |k|
                                            std.mem.eql(u8, k, clip)
                                        else
                                            false;
                                        if (!repeats_kill_ring) {
                                            buf.insertSlice(gpa, clip) catch {};
                                            // A clipboard paste is yankable
                                            // too, and heads the kill ring
                                            // like any fresh kill.
                                            kill_ring.remember(gpa, clip, false) catch {};
                                            yank_state = null;
                                            break :yank_clip;
                                        }
                                    }
                                } else if (comptime builtin.os.tag == .linux) {
                                    // The same clipboard-first rule as the
                                    // Windows branch above: the system
                                    // clipboard is consulted on every C-y, not
                                    // just when the kill ring is empty, so an
                                    // external copy made since the last yank
                                    // must win over the (now-stale) kill-ring
                                    // head. Many terminals (alacritty's osc52
                                    // setting defaults to OnlyCopy) never
                                    // answer an OSC 52 clipboard read, so the
                                    // platform's clipboard tool reads it
                                    // directly — wl-paste on Wayland, xsel /
                                    // xclip on X11. Content that merely
                                    // repeats the current kill-ring head falls
                                    // through to a normal yank; with no
                                    // clipboard at all the empty kill ring is
                                    // handled below.
                                    var clip: ?[]u8 = null;
                                    if (init.environ_map.get("WAYLAND_DISPLAY") != null) {
                                        clip = clipboardGet(io, gpa, &.{ "wl-paste", "--no-newline" });
                                    } else if (init.environ_map.get("DISPLAY") != null) {
                                        clip = clipboardGet(io, gpa, &.{ "xsel", "--clipboard", "--output" }) orelse
                                            clipboardGet(io, gpa, &.{ "xclip", "-selection", "clipboard", "-o" });
                                    }
                                    if (clip) |c| {
                                        defer gpa.free(c);
                                        const repeats_kill_ring = if (kill_ring.current()) |k|
                                            std.mem.eql(u8, k, c)
                                        else
                                            false;
                                        if (!repeats_kill_ring) {
                                            buf.insertSlice(gpa, c) catch {};
                                            // A clipboard paste is yankable
                                            // too, and heads the kill ring
                                            // like any fresh kill.
                                            kill_ring.remember(gpa, c, false) catch {};
                                            yank_state = null;
                                            break :yank_clip;
                                        }
                                    }
                                }
                                if (kill_ring.current()) |text| {
                                    const start: Buffer.Pos = .{ .row = buf.cursor_row, .col = buf.cursor_col };
                                    try buf.yank(gpa, text);
                                    yank_state = .{
                                        .buf_idx = current,
                                        .entry = kill_ring.head,
                                        .start = start,
                                        .end = .{ .row = buf.cursor_row, .col = buf.cursor_col },
                                    };
                                } else if (comptime builtin.os.tag != .windows) {
                                    // Nothing has been killed yet: yank the
                                    // system clipboard instead (Emacs
                                    // consults the interprogram clipboard
                                    // when the kill ring is empty). The
                                    // terminal answers the OSC 52 request
                                    // asynchronously with a .paste event.
                                    vx.requestSystemClipboard(tty.writer()) catch {};
                                }
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
                    } else if (key.matches('f', .{ .alt = true })) {
                        // M-f: forward word (Emacs forward-word) — skip a run
                        // of non-word chars then a run of word chars, landing
                        // at the end of the word. Editing-only: direds
                        // navigate with n/p, not word motion.
                        if (editing) buf.moveWordForward();
                    } else if (key.matches('b', .{ .alt = true })) {
                        // M-b: backward word (Emacs backward-word) — the
                        // mirror of M-f, landing at the start of the word.
                        if (editing) buf.moveWordBackward();
                    } else if (results_kind == null and (key.matches('n', .{ .ctrl = true }) or key.matches(vaxis.Key.down, .{}))) {
                        // C-n: down one visual (soft-wrapped) line, so a
                        // wrapped paragraph is stepped through line by
                        // line (Emacs visual-line-mode). The grep results
                        // buffer owns these keys (see the grep branch), so
                        // they don't double-move its selection.
                        moveDownVisual(buf, focused_text_width, vx.screen.width_method);
                    } else if (results_kind == null and (key.matches('p', .{ .ctrl = true }) or key.matches(vaxis.Key.up, .{}))) {
                        moveUpVisual(buf, focused_text_width, vx.screen.width_method);
                    } else if (key.matches('a', .{ .ctrl = true })) {
                        // C-a: the start of the visual line (the segment's
                        // wrap point on a soft-wrapped line).
                        moveStartVisual(buf, focused_text_width, vx.screen.width_method);
                    } else if (key.matches('e', .{ .ctrl = true })) {
                        // C-e: the end of the visual line — the wrap
                        // point, not the logical line's end.
                        moveEndVisual(buf, focused_text_width, vx.screen.width_method);
                    } else if (key.matches('l', .{ .ctrl = true })) {
                        // C-l: recenter the window on the cursor's visual
                        // line (recenter-top-bottom), within the focused
                        // pane.
                        recenterVisual(buf, focused_text_height, focused_text_width, vx.screen.width_method, last_was_recenter);
                        last_was_recenter = true;
                    } else if (key.matches('d', .{ .ctrl = true }) or key.matches(vaxis.Key.delete, .{})) {
                        try buf.deleteForward(gpa);
                    } else if (key.matches('d', .{ .alt = true }) or key.matches(vaxis.Key.delete, .{ .ctrl = true })) {
                        // M-d / C-Delete: kill one word forward (Emacs
                        // kill-word) — kill from point to the end of the
                        // word run forward, saving it to the kill ring (so
                        // C-y gets it back). Editing-only: direds are
                        // read-only. A following kill appends, like C-k.
                        if (editing) {
                            try buf.killWord(gpa, &kill_ring, was_kill);
                            syncClipboard(&vx, &tty, gpa, kill_ring.current() orelse "");
                            kill_active = true;
                        }
                    } else if (key.matches(vaxis.Key.backspace, .{ .alt = true })) {
                        // M-Backspace: kill one word backward (Emacs
                        // backward-kill-word) — the mirror of M-d, killing
                        // from point back to the start of the word run,
                        // saving it to the kill ring (so C-y gets it back).
                        // Editing-only: direds are read-only. A following
                        // kill appends, like C-k.
                        if (editing) {
                            try buf.killWordBackward(gpa, &kill_ring, was_kill);
                            syncClipboard(&vx, &tty, gpa, kill_ring.current() orelse "");
                            kill_active = true;
                        }
                    } else if (key.matches(vaxis.Key.backspace, .{})) {
                        // With a mark set, Backspace deletes the whole
                        // region (Emacs delete-active-region) — killRegion
                        // saves it to the kill ring (so C-y gets it back)
                        // and clears the mark, like C-x C-k. Without a mark
                        // it deletes one char backward as before. Direds are
                        // read-only, so the region path is editing-only.
                        if (editing and buf.mark != null) {
                            try buf.killRegion(gpa, &kill_ring, was_kill);
                            syncClipboard(&vx, &tty, gpa, kill_ring.current() orelse "");
                            kill_active = true;
                        } else {
                            try buf.deleteBackward(gpa);
                        }
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
                        current = try openBufferOrDired(gpa, io, &buffers, &direds, &recent, start);
                        focused.buf_idx = current;
                    } else if (key.matches('n', .{ .alt = true })) {
                        // M-n: move to the next window.
                        if (moveFocus(root, focused, 1)) |nf| {
                            focused = nf;
                            current = focused.buf_idx;
                        }
                    } else if (key.matches('p', .{ .alt = true })) {
                        // M-p: move to the previous window.
                        if (moveFocus(root, focused, -1)) |nf| {
                            focused = nf;
                            current = focused.buf_idx;
                        }
                    } else if (key.matches('o', .{ .alt = true })) {
                        // M-o: quick window jump (the author's
                        // my/quick-window-jump, ace-window style) — with
                        // two windows it jumps straight across; with more,
                        // each window gets a one-char corner label (j k l ;
                        // a s d f) and typing the label jumps to its
                        // window. C-g / Esc cancels the labels.
                        if (root.leafCount() <= 2) {
                            if (moveFocus(root, focused, 1)) |nf| {
                                focused = nf;
                                current = focused.buf_idx;
                            }
                        } else {
                            pending_alt_o = true;
                        }
                    } else if (key.matches('j', .{ .alt = true })) {
                        buf.moveLines(5);
                    } else if (key.matches('k', .{ .alt = true })) {
                        buf.moveLines(-5);
                    } else if (key.matches('J', .{ .alt = true })) {
                        // M-J: page down — the cursor moves a screenful
                        // (the focused window's text height, minus the
                        // modeline), like Emacs scroll-up.
                        buf.moveLines(@intCast(focused_text_height -| 1));
                    } else if (key.matches('K', .{ .alt = true })) {
                        // M-K: page up (Emacs scroll-down).
                        buf.moveLines(-@as(isize, @intCast(focused_text_height -| 1)));
                    } else if (key.matches('<', .{ .alt = true })) {
                        buf.moveBufStart();
                    } else if (key.matches('>', .{ .alt = true })) {
                        buf.moveBufEnd();
                    } else if (key.matches('g', .{ .alt = true })) {
                        // M-g: goto line — the modeline already shows the
                        // current line (L:C), so a numbered jump is the
                        // natural complement.
                        goto_prompt = true;
                        goto_query.clearRetainingCapacity();
                    } else if (key.matches('z', .{ .alt = true })) {
                        // M-z: toggle soft wrap (Emacs
                        // toggle-truncate-lines). On, long lines wrap at
                        // the window edge and movement steps visual
                        // lines; off, they truncate and movement steps
                        // logical lines — the modeline's [truncate] shows
                        // the state. The buffer remembers its own
                        // setting.
                        buf.soft_wrap = !buf.soft_wrap;
                    } else if (key.matches('h', .{ .alt = true })) {
                        // M-h: mark the whole paragraph (Emacs
                        // mark-paragraph): the region becomes the block
                        // around the cursor — mark at its start, cursor
                        // at its end — ready for M-w / C-w.
                        buf.markParagraph();
                    } else if (key.matches(0x08, .{ .alt = true }) or key.matches('h', .{ .alt = true, .ctrl = true })) {
                        // C-M-h: resize width, matching the author's
                        // Emacs my/adaptive-resize — a window on the left
                        // of a split shrinks, one on the right grows (the
                        // divider moves in the h direction). Terminals
                        // without the kitty keyboard protocol send the
                        // chord as ESC + the control byte (0x08 = C-h),
                        // which vaxis reports as alt + 0x08 — both
                        // encodings are bound here. The step is ~2 columns
                        // of the screen per press (see resizeStep).
                        recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                        root.resizeDivider(focused, .vertical, -resizeColsStep(if (last_winsize) |ws| ws.cols else 100));
                    } else if (key.matches(0x0C, .{ .alt = true }) or key.matches('l', .{ .alt = true, .ctrl = true })) {
                        // C-M-l: the mirror of C-M-h — a left window
                        // grows, a right one shrinks.
                        recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                        root.resizeDivider(focused, .vertical, resizeColsStep(if (last_winsize) |ws| ws.cols else 100));
                    } else if (key.matches(0x0A, .{ .alt = true }) or key.matches('j', .{ .alt = true, .ctrl = true })) {
                        // C-M-j: resize height, matching the author's
                        // Emacs — a top window shrinks, a bottom one
                        // grows.
                        recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                        root.resizeDivider(focused, .horizontal, -resizeRowsStep(if (last_winsize) |ws| ws.rows else 30));
                    } else if (key.matches(0x0B, .{ .alt = true }) or key.matches('k', .{ .alt = true, .ctrl = true })) {
                        // C-M-k: the mirror of C-M-j — a top window
                        // grows, a bottom one shrinks.
                        recordWindow(gpa, root, focused, current, &window_undo, &window_redo);
                        root.resizeDivider(focused, .horizontal, resizeRowsStep(if (last_winsize) |ws| ws.rows else 30));
                    } else if (key.matches(vaxis.Key.enter, .{}) or key.matches(0x0A, .{}) or key.matches('j', .{ .ctrl = true }) or key.matches('m', .{ .ctrl = true })) {
                        // A bare LF (0x0A) key event is a paste-delivered
                        // line break: Windows terminals that synthesize
                        // per-character key events for a paste send LF
                        // with no matching key code, and it would
                        // otherwise be dropped here.
                        if (editing) try buf.insertNewline(gpa);
                    } else if (key.text) |t| {
                        // Dired buffers are read-only: typing is ignored.
                        if (editing) try buf.insertSlice(gpa, t);
                    }
                }
            },
        };

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
        // The blinking block cursor is the position indicator; the line it
        // sits on is bold too (the dired selection the same), so where you
        // are is obvious even when the block cursor is hard to see.
        win.setCursorShape(.block_blink);

        // The tab bar (only when more than one tab exists) takes the top
        // row; everything else renders into the rows below it. The label
        // buffers live until the frame is drawn (vaxis keeps grapheme
        // slices into them), so they're scoped to this render pass.
        const body = if (tabs.items.len > 1) win.child(.{ .x_off = 0, .y_off = 1, .width = win.width, .height = win.height -| 1 }) else win;
        var tab_blocks: [MAX_TABS][16]u8 = undefined;
        if (tabs.items.len > 1) renderTabBar(win, &tab_blocks, tabs.items.len, active_tab);

        const text_height: usize = if (body.height > 1) body.height - 1 else body.height;
        // The focused pane's text area (the whole window when unsplit),
        // remembered for C-l and the visual-line navigation so they
        // recenter and wrap within the right window.
        focused_text_height = text_height;
        focused_text_width = body.width;
        // Dired, isearch and the picker are not modal: they render inside
        // whichever pane they apply to, leaving the window layout
        // untouched. Only the prompt-style modes take over the whole
        // screen.
        const is_modal = confirming_quit or confirming_kill;

        const search_view: ?IsearchView = if (isearch_active)
            .{ .failed = isearch_failed, .match = isearch_match, .query = isearch_query.items, .backward = isearch_dir == .backward, .count = isearch_count, .pos = isearch_pos }
        else if (replace_active)
            // The query-replace walk highlights the current candidate like
            // an isearch match.
            .{ .failed = false, .match = replace_match, .query = replace_query.items, .backward = false, .count = 0, .pos = 0 }
        else
            null;

        const replace_view: ?ReplaceView = if (replace_prompt) |phase|
            .{ .prompt = phase, .query = replace_query.items, .with = replace_with.items, .match = null }
        else if (replace_active)
            .{ .prompt = null, .query = replace_query.items, .with = replace_with.items, .match = replace_match }
        else
            null;

        const find_file_view: ?FindFileView = if (switching_buffer)
            .{ .query = switch_query.items }
        else
            null;

        const bookmark_prompt_view: ?BookmarkPromptView = if (bookmark_prompt) |mode|
            .{ .query = bookmark_query.items, .set = mode == .set }
        else
            null;

        const goto_prompt_view: ?GotoPromptView = if (goto_prompt)
            .{ .query = goto_query.items }
        else
            null;

        const grep_prompt_view: ?GrepPromptView = if (grep_prompt)
            .{ .query = grep_query.items, .label = "Grep: " }
        else if (occur_prompt)
            .{ .query = occur_query.items, .label = "Occur: " }
        else
            null;

        // The transient grep-match highlight, expired once GREP_HL_NS has
        // passed since the jump (it only redraws on events anyway, so the
        // highlight lingers until the next keypress at most).
        const grep_hl_view: ?GrepHl = if (grep_hl) |h| blk: {
            if (std.Io.Clock.now(.real, io).nanoseconds - h.set_at < GREP_HL_NS) break :blk h;
            break :blk null;
        } else null;

        // The results-buffer state for the modelines and highlights (see
        // GrepView / FilesView). The display-name checks keep a stale
        // index — a results buffer killed via C-x k — from matching.
        const grep_view: ?GrepView = blk: {
            const idx = grep_buf_idx orelse break :blk null;
            if (idx >= buffers.items.len) break :blk null;
            if (!std.mem.eql(u8, buffers.items[idx].display_name orelse "", "*grep*")) break :blk null;
            break :blk .{ .buf = buffers.items[idx], .count = grep_matches.items.len, .follow = results_follow, .hl = grep_hl_view };
        };
        const occur_view: ?GrepView = blk: {
            const idx = occur_buf_idx orelse break :blk null;
            if (idx >= buffers.items.len) break :blk null;
            if (!std.mem.eql(u8, buffers.items[idx].display_name orelse "", "*occur*")) break :blk null;
            break :blk .{ .buf = buffers.items[idx], .count = occur_matches.items.len, .follow = results_follow, .hl = grep_hl_view };
        };
        const files_view: ?FilesView = blk: {
            const idx = find_buf_idx orelse break :blk null;
            if (idx >= buffers.items.len) break :blk null;
            if (!std.mem.eql(u8, buffers.items[idx].display_name orelse "", "*files*")) break :blk null;
            break :blk .{ .buf = buffers.items[idx], .count = find_visible.items.len, .follow = results_follow, .filter = find_filter.items, .row_hl = find_hl.items };
        };

        const dired_prompt_view: ?DiredPromptView = if (dired_copy_prompt)
            .{ .kind = dired_copy_kind, .query = dired_copy_query.items }
        else if (confirming_delete)
            .{ .kind = .delete }
        else if (confirming_open)
            .{ .kind = .open, .detail = open_confirm_app orelse "the system default" }
        else
            null;

        const compress_menu_view: ?CompressMenuView = if (dired_compress_menu)
            .{ .label = dired_compress_label, .choices = dired_compress_menu_text }
        else
            null;
        const archive_query_view: ?[]const u8 = if (dired_archive_prompt) dired_archive_query.items else null;

        const picker_view: ?PickerView = if (picker_kind) |kind|
            .{ .kind = kind, .visible = picker_visible.items, .selected = picker_selected, .top = &picker_top, .query = picker_query.items, .hl = picker_hl.items }
        else
            null;

        if (!is_modal and !root.isLeaf()) {
            var modeline_bufs: [MAX_PANES][2048]u8 = undefined;
            var slot_counter: usize = 0;
            renderTree(body, &frame_allocs, root, 0, 0, body.width, body.height, &modeline_bufs, &slot_counter, buffers.items, direds.items, focused, io, picker_view, bookmarks.items, recent.items, pending_alt_o, find_file_view, bookmark_prompt_view, goto_prompt_view, grep_prompt_view, grep_view, files_view, occur_view, grep_hl_view, search_view, replace_view, compress_menu_view, archive_query_view, dired_prompt_view, status_msg, &focused_text_height, &focused_text_width);
            try vx.render(tty.writer());
            frame_allocs.reset();
            continue;
        }

        if (picker_kind) |_| {
            // The picker (buffers / bookmarks / recent files): one row per
            // entry, Enter opens the selection. Typing filters the rows
            // (see pickerFilter) — the block cursor marks the selection
            // among the visible ones. A lone window shows it full-screen;
            // a split keeps the layout visible (see renderTree).
            var picker_ml_buf: [2048]u8 = undefined;
            renderPicker(body, io, picker_view.?, buffers.items, bookmarks.items, recent.items, &picker_ml_buf, search_view);
            try vx.render(tty.writer());
            frame_allocs.reset();
            continue;
        }

        if (!is_modal) {
            if (direds.items[current]) |*d| {
                var modeline_buf: [2048]u8 = undefined;
                renderDiredPane(body, d, true, 0, body.height, &modeline_buf, find_file_view, bookmark_prompt_view, goto_prompt_view, grep_prompt_view, grep_view, files_view, occur_view, grep_hl_view, search_view, replace_view, compress_menu_view, archive_query_view, dired_prompt_view, status_msg);
                try vx.render(tty.writer());
                frame_allocs.reset();
                continue;
            }
        }
        // The prompt-style modal states (buffer switch, quit confirm)
        // render a dired through the normal buffer renderer instead: its
        // lines mirror the listing, so the prompt modeline works exactly as
        // it does in a file buffer. isearch is handled natively above.

        scrollToCursorVisual(buf, text_height, body.width, vx.screen.width_method);
        scrollToCursorHorizontal(buf, body.width, vx.screen.width_method);
        var row: u16 = 0;
        var i = buf.top_line;
        while (i < buf.lines.items.len and row < text_height) : (i += 1) {
            const raw = buf.lines.items[i].items;
            // Tabs render as spaces up to the next tab stop (see
            // renderPane); the whitespace markers (C-z e) render through
            // whitespaceLine instead.
            const ws_mode = buf.show_whitespace;
            const ws_text = if (ws_mode)
                whitespaceLine(&frame_allocs, raw, i + 1 < buf.lines.items.len, vx.screen.width_method)
            else
                null;
            const expanded = if (!ws_mode) expandTabs(&frame_allocs, raw, vx.screen.width_method) else null;
            const line = ws_text orelse expanded orelse raw;
            var h = highlightFor(buf, i, search_view != null, if (search_view) |s| (if (s.failed) null else s.match) else null, if (search_view) |s| s.query.len else 0);
            // The transient grep-match highlight (see GrepHl).
            if (h.hl == null) {
                if (grep_hl_view) |gh| {
                    if (i == gh.row) {
                        const line_len = buf.lines.items[i].items.len;
                        const start = @min(gh.col, line_len);
                        const end = @min(gh.col + gh.len, line_len);
                        if (end > start) h.hl = .{ .start = start, .end = end };
                    }
                }
            }
            if (h.hl) |hl| {
                if (ws_text != null) {
                    h.hl = .{ .start = whitespaceDispAt(raw, hl.start, vx.screen.width_method), .end = whitespaceDispAt(raw, hl.end, vx.screen.width_method) };
                } else if (expanded != null) {
                    h.hl = .{ .start = tabAwareWidth(raw, 0, hl.start, vx.screen.width_method), .end = tabAwareWidth(raw, 0, hl.end, vx.screen.width_method) };
                }
            }
            var seg_storage3: [3]vaxis.Segment = undefined;
            var seg_storage129: [129]vaxis.Segment = undefined;
            const row_hl: ?FuzzyHl = if (files_view) |fv| blk: {
                if (buf == fv.buf and fv.filter.len > 0 and i < fv.row_hl.len and fv.row_hl[i].len > 0) break :blk fv.row_hl[i];
                break :blk null;
            } else null;
            const segs = if (row_hl) |fh|
                fuzzySegments(line, fh, i == buf.cursor_row, &seg_storage129)
            else
                lineSegments(line, h.hl, h.empty_marker, &seg_storage3, i == buf.cursor_row);
            // Advance by the line's wrapped height (see renderPane).
            const wraps = wrapCount(raw, buf.soft_wrap, body.width, vx.screen.width_method);
            if (buf.soft_wrap) {
                _ = body.print(segs, .{ .row_offset = row });
            } else {
                // Soft wrap off (M-z): the line truncates at the window
                // edge, scrolled right with the cursor when it walks past
                // the edge (see renderPane).
                var col: u16 = 0;
                var seg_off: usize = 0;
                const skip = if (buf.hscroll > 0) byteAtColumn(line, buf.hscroll, vx.screen.width_method) else 0;
                for (segs) |seg| {
                    if (col >= body.width) break;
                    const rest = if (seg_off < skip)
                        seg.text[@min(skip - seg_off, seg.text.len)..]
                    else
                        seg.text;
                    seg_off += seg.text.len;
                    if (rest.len == 0) continue;
                    const clipped = clipToWidth(rest, body.width - col, vx.screen.width_method);
                    if (clipped.len == 0) continue;
                    _ = body.printSegment(.{ .text = clipped, .style = seg.style }, .{ .row_offset = row, .col_offset = col });
                    col += body.gwidth(clipped);
                }
            }
            row += @intCast(wraps);
        }

        // Fixed scratch space for the modeline text: it's redrawn every
        // frame, so this avoids growing `init.arena` (which lives for the
        // whole process) by one small allocation per keystroke forever.
        var modeline_buf: [2048]u8 = undefined;
        var count_buf: [32]u8 = undefined;

        const ml: PromptModeline = if (confirming_quit)
            fillPromptModeline(&modeline_buf, "Save file {s} before exiting? (y / n / C-g cancels)", .{buf.filename orelse "?"}, "")
        else if (confirming_kill)
            fillPromptModeline(&modeline_buf, "Save file {s} before killing? (y / n / C-g cancels)", .{buf.filename orelse "?"}, "")
        else if (status_msg) |m| blk: {
            const n = std.fmt.bufPrint(&modeline_buf, "{s}", .{m}) catch break :blk .{ .len = 0, .label_len = 0 };
            break :blk .{ .len = n.len, .label_len = 0 };
        } else if (switching_buffer)
            fillPromptModeline(&modeline_buf, "Find file: ", .{}, switch_query.items)
        else if (bookmark_prompt) |mode| blk: {
            if (mode == .set) break :blk fillPromptModeline(&modeline_buf, "Bookmark name (C-g cancels): ", .{}, bookmark_query.items);
            break :blk fillPromptModeline(&modeline_buf, "Jump to bookmark (C-g cancels): ", .{}, bookmark_query.items);
        } else if (goto_prompt) blk: {
            break :blk fillPromptModeline(&modeline_buf, "Goto line (C-g cancels): ", .{}, goto_query.items);
        } else if (grep_prompt) blk: {
            break :blk fillPromptModeline(&modeline_buf, "Grep: ", .{}, grep_query.items);
        } else if (occur_prompt) blk: {
            break :blk fillPromptModeline(&modeline_buf, "Occur: ", .{}, occur_query.items);
        } else if (replace_prompt) |phase| blk: {
            switch (phase) {
                .query => break :blk fillPromptModeline(&modeline_buf, "Query replace: ", .{}, replace_query.items),
                .with => break :blk fillPromptModeline(&modeline_buf, "Query replace {s} with: ", .{replace_query.items}, replace_with.items),
            }
        } else if (replace_active) blk: {
            const n = std.fmt.bufPrint(&modeline_buf, "Replace {s} with {s}? (y / n / q / ! / . / ^)", .{ replace_query.items, replace_with.items }) catch break :blk .{ .len = 0, .label_len = 0 };
            break :blk .{ .len = n.len, .label_len = n.len };
        } else if (isearch_active) blk: {
            const label = if (isearch_failed)
                (if (isearch_dir == .backward) "Failing I-search backward" else "Failing I-search")
            else
                (if (isearch_dir == .backward) "I-search backward" else "I-search");
            // The lazy count ("I-search: term (3/12)", like Emacs) trails
            // the query in the same plain style.
            const suffix = isearchCountSuffix(&count_buf, isearch_query.items, isearch_pos, isearch_count);
            var query_buf: [2048]u8 = undefined;
            const query_with_count = if (suffix.len > 0)
                (std.fmt.bufPrint(&query_buf, "{s}{s}", .{ isearch_query.items, suffix }) catch isearch_query.items)
            else
                isearch_query.items;
            break :blk fillPromptModeline(&modeline_buf, "{s}: ", .{label}, query_with_count);
        } else blk: {
            // The results buffers show their position and keys in the
            // modeline instead of the L:C readout.
            if (grep_view) |gv| {
                if (buf == gv.buf) {
                    const n = std.fmt.bufPrint(&modeline_buf, "-- {s}{s} {d}/{d}{s}{s}   (n/p move, Enter opens, F follows, g rerun, q close) --", .{
                        gv.buf.display_name orelse "?",
                        if (gv.follow) " [follow]" else "",
                        buf.cursor_row + 1,
                        gv.count,
                        if (!buf.soft_wrap) " [truncate]" else "",
                    if (buf.scroll_lock) " [scroll-lock]" else "",
                    }) catch break :blk .{ .len = 0, .label_len = 0 };
                    break :blk .{ .len = n.len, .label_len = 0 };
                }
            }
            if (files_view) |fv| {
                if (buf == fv.buf) {
                    const n = if (fv.filter.len > 0)
                        std.fmt.bufPrint(&modeline_buf, "-- {s}{s} {d}/{d}{s}{s}   filter: {s}   (C-g/Esc clears, Enter opens, F follows, g rerun) --", .{
                            fv.buf.display_name orelse "?",
                            if (fv.follow) " [follow]" else "",
                            buf.cursor_row + 1,
                            fv.count,
                            if (!buf.soft_wrap) " [truncate]" else "",
                            if (buf.scroll_lock) " [scroll-lock]" else "",
                            fv.filter,
                        }) catch break :blk .{ .len = 0, .label_len = 0 }
                    else
                        std.fmt.bufPrint(&modeline_buf, "-- {s}{s} {d}/{d}{s}{s}   (type to filter, C-s searches, Enter opens, F follows, g rerun, C-g/Esc closes) --", .{
                            fv.buf.display_name orelse "?",
                            if (fv.follow) " [follow]" else "",
                            buf.cursor_row + 1,
                            fv.count,
                            if (!buf.soft_wrap) " [truncate]" else "",
                            if (buf.scroll_lock) " [scroll-lock]" else "",
                        }) catch break :blk .{ .len = 0, .label_len = 0 };
                    break :blk .{ .len = n.len, .label_len = 0 };
                }
            }
            if (occur_view) |ov| {
                if (buf == ov.buf) {
                    const n = std.fmt.bufPrint(&modeline_buf, "-- {s}{s} {d}/{d}{s}{s}   (n/p move, Enter jumps, F follows, g rerun, q close) --", .{
                        ov.buf.display_name orelse "?",
                        if (ov.follow) " [follow]" else "",
                        buf.cursor_row + 1,
                        ov.count,
                        if (!buf.soft_wrap) " [truncate]" else "",
                    if (buf.scroll_lock) " [scroll-lock]" else "",
                    }) catch break :blk .{ .len = 0, .label_len = 0 };
                    break :blk .{ .len = n.len, .label_len = 0 };
                }
            }
            const buf_count = if (buffers.items.len > 1)
                (std.fmt.bufPrint(&count_buf, "  ({d}/{d})", .{ current + 1, buffers.items.len }) catch "")
            else
                "";
            const n = std.fmt.bufPrint(&modeline_buf, "{s}-- {s}{s}{s}{s}{s}{s}{s}  L{d}:C{d} --", .{
                // Emacs-style modified marker in the bottom-left corner of
                // the modeline.
                if (buf.dirty) "*" else "",
                buf.display_name orelse buf.filename orelse "?",
                if (buf.dirty) " [modified]" else "",
                if (buf.mark != null) " [mark set]" else "",
                // M-z: soft wrap off (truncated lines) shows like Emacs's
                // Truncate mode-line marker; its absence means wrap is on.
                if (!buf.soft_wrap) " [truncate]" else "",
                // C-x l: scroll lock shows like Emacs's Scroll-Lock
                // mode-line marker; its absence means the cursor scrolls
                // with the text.
                if (buf.scroll_lock) " [scroll-lock]" else "",
                // C-z e: whitespace markers show like Emacs's
                // whitespace-mode "WS" mode-line lighter.
                if (buf.show_whitespace) " [whitespace]" else "",
                buf_count,
                buf.cursor_row + 1,
                buf.cursor_col + 1,
            }) catch break :blk .{ .len = 0, .label_len = 0 };
            break :blk .{ .len = n.len, .label_len = 0 };
        };
        // Same full-width bar as the pane modelines: the whole row lives
        // in `modeline_buf`, kept alive until after the render. An active
        // prompt's label is bold too, so it stands out.
        printModeline(body, &modeline_buf, ml, highlight_style, body.height -| 1);

        const cv = cursorVisual(buf, body.width, vx.screen.width_method);
        body.showCursor(
            @intCast(if (buf.soft_wrap) cv.col else cv.col -| buf.hscroll),
            @intCast(visualRowOfCursor(buf, buf.top_line, body.width, vx.screen.width_method)),
        );

        try vx.render(tty.writer());
        frame_allocs.reset();
    }
}
