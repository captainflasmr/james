# james

*Just Another Micro Emacs Subset*

A very minimal, Emacs/MicroEmacs-inspired text editor, written in Zig on top
of [libvaxis](https://github.com/rockorager/libvaxis). This is a starting
point, not a finished editor — see Roadmap below.

## Requirements

- Zig **0.16.0** exactly (pinned in `build.zig.zon`; libvaxis tracks this
  version closely and older/newer Zig will likely fail to compile it)

## Build & run

```sh
zig build run -- path/to/file.txt
```

First run will fetch libvaxis automatically. To fetch dependencies ahead of
time (e.g. for an offline build later): `zig build --fetch`.

## Cross-compiling

No extra toolchains, no Docker. Confirmed working targets:

```sh
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSmall
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSmall
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall
zig build -Doptimize=ReleaseSmall   # native
```

Binaries land in `zig-out/bin/`. Use `-p some/dir` to send each target to a
separate folder if you're building several at once.

## Current keybindings

| Keys | Action |
|---|---|
| `C-f` `C-b` `C-n` `C-p` / arrows | move right / left / down / up |
| `C-a` / `C-e` | start / end of line |
| `C-d` / Delete | delete forward |
| Backspace | delete backward |
| Enter | new line |
| `C-space` | set mark |
| `C-k` | kill to end of line (or kill the newline, at end of line) |
| `C-w` | kill region (point to mark) |
| `M-w` | copy region, without deleting |
| `C-y` | yank (insert most recent kill) |
| `C-x C-s` | save |
| `C-x C-c` | quit |

Consecutive `C-k`/`C-w`/`M-w` presses append to the same kill instead of
overwriting it, same as real Emacs — typing or moving the cursor in between
starts a fresh kill.

## Architecture

- `src/Buffer.zig` — all text state: lines, cursor, load/save, edit and
  movement operations. Knows nothing about the terminal.
- `src/main.zig` — the only platform-facing file: sets up the terminal via
  vaxis, runs the event loop, maps keys to `Buffer` calls, renders.

Keeping that split matters: it's the same portability discipline MicroEmacs
used in the 1980s to run unmodified across CP/M, MS-DOS, VMS and Unix.
Everything except `main.zig`'s terminal setup should port to any future
front end (a different TUI library, or eventually a GUI) unchanged.

## Known caveat

Quitting (`C-x C-c`) relies on libvaxis's normal shutdown path, which sends a
terminal status query to wake up its background input thread — real terminal
emulators answer this automatically. This worked correctly for every editing
and saving operation I tested through a real pseudo-terminal, but I could not
fully confirm the exit path from inside a sandboxed test harness that lacks a
real terminal emulator. If it ever seems to hang on quit in your actual
terminal (unexpected — flag it if so), closing the terminal window or `C-c`
from another shell will always work as a fallback.

## Roadmap

1. ~~**Kill ring + yank**~~ — done (`C-space`, `C-k`, `C-w`, `M-w`, `C-y`).
   `Buffer.mark` is a plain snapshot, not a self-adjusting marker, so it can
   go stale if you edit the buffer between setting mark and using the
   region — acceptable for now, worth revisiting if it bites you.
2. **Undo** (`C-x u` or `C-/`) — simplest correct approach for a line-array
   buffer: snapshot the affected lines + cursor before each coalesced edit
   (group consecutive typing into one undo step) and push onto an undo
   stack; restore on undo. A proper diff-based undo log is a later
   optimization, not a v1 requirement.
3. **Incremental search** (`C-s` / `C-r`) — the most invasive of the
   remaining items, because it introduces a real "mode": while searching,
   keystrokes go to the query instead of the buffer, with a prompt on the
   status line. Worth building this as a small generalized "minibuffer
   mode" since `M-x` will want the exact same plumbing later.
4. Unsaved-changes confirmation on `C-x C-c`.
5. Multiple buffers and `C-x b` to switch.
6. Config: start with a plain keymap-override file, consider embedded Lua
   later if you want real elisp-like programmability.

Happy to implement any of these next — undo is self-contained; incremental
search is the one I'd budget the most time for.
