const std = @import("std");
const vaxis = @import("vaxis");
const Buffer = @import("Buffer.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // First non-program argument is the file to open.
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();
    _ = args_it.next();
    const path = args_it.next() orelse {
        std.debug.print("usage: zemacs <file>\n", .{});
        return;
    };

    var buf = try Buffer.loadFile(gpa, io, path);
    defer buf.deinit(gpa);

    var tty_buf: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();

    var vx = try vaxis.init(io, gpa, init.environ_map, .{});
    // Passing null here (rather than gpa) skips freeing internal state, which
    // is fine because the process is about to exit anyway.
    defer vx.deinit(null, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    var pending_ctrl_x = false;

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .winsize => |ws| try vx.resize(gpa, tty.writer(), ws),
            .key_press => |key| {
                if (pending_ctrl_x) {
                    pending_ctrl_x = false;
                    if (key.matches('s', .{ .ctrl = true })) {
                        buf.save(gpa, io) catch {};
                    } else if (key.matches('c', .{ .ctrl = true })) {
                        return;
                    }
                    continue;
                }

                const was_kill = buf.kill_active;
                buf.kill_active = false;

                if (key.matches('x', .{ .ctrl = true })) {
                    pending_ctrl_x = true;
                } else if (key.matches(' ', .{ .ctrl = true }) or key.matches('@', .{ .ctrl = true })) {
                    buf.setMark();
                } else if (key.matches('k', .{ .ctrl = true })) {
                    try buf.killLine(gpa, was_kill);
                    buf.kill_active = true;
                } else if (key.matches('w', .{ .ctrl = true })) {
                    try buf.killRegion(gpa, was_kill);
                    buf.kill_active = true;
                } else if (key.matches('w', .{ .alt = true })) {
                    try buf.copyRegion(gpa, was_kill);
                    buf.kill_active = true;
                } else if (key.matches('y', .{ .ctrl = true })) {
                    try buf.yank(gpa);
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
                    buf.deleteForward(gpa);
                } else if (key.matches(vaxis.Key.backspace, .{})) {
                    buf.deleteBackward(gpa);
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    try buf.insertNewline(gpa);
                } else if (key.text) |t| {
                    try buf.insertSlice(gpa, t);
                }
            },
        }

        const win = vx.window();
        win.clear();

        const text_height: usize = if (win.height > 1) win.height - 1 else win.height;
        buf.scrollToCursor(text_height);

        var row: u16 = 0;
        var i = buf.top_line;
        while (i < buf.lines.items.len and row < text_height) : (i += 1) {
            _ = win.printSegment(.{ .text = buf.lines.items[i].items }, .{ .row_offset = row });
            row += 1;
        }

        const modeline = try std.fmt.allocPrint(init.arena.allocator(), "-- {s}{s}{s}  L{d}:C{d} --", .{
            path,
            if (buf.dirty) " [modified]" else "",
            if (buf.mark != null) " [mark set]" else "",
            buf.cursor_row + 1,
            buf.cursor_col + 1,
        });
        _ = win.printSegment(.{ .text = modeline }, .{ .row_offset = win.height -| 1 });

        win.showCursor(
            @intCast(buf.cursor_col),
            @intCast(buf.cursor_row - buf.top_line),
        );

        try vx.render(tty.writer());
    }
}
