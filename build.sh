#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="1.0.0"

usage() {
    cat <<'USAGE'
Usage: ./build.sh [OPTIONS] [-- <editor-args>]

Build and optionally run james with cross-compilation support.

Targets:
  (none)    Native build (ReleaseSmall, stripped)     (default, -> zig-out/bin)
  release   Native release build                      (ReleaseSmall, stripped, -> zig-out/bin)
  windows   Cross-compile for x86_64-windows          (ReleaseSmall, -> zig-out/windows)
  macos     Cross-compile for aarch64-macos           (ReleaseSmall, -> zig-out/macos)
  linux     Cross-compile for x86_64-linux-musl       (ReleaseSmall, -> zig-out/linux)
  all       Build all of the above into zig-out/<target>/

Options:
  -t, --target NAME   Select target (above, or a raw Zig triple)
  -r, --run           Build and run (native targets only)
  -h, --help          Show this message

Examples:
  ./build.sh                    # native (ReleaseSmall, stripped)
  ./build.sh -t release         # native release (same as default)
  ./build.sh -t windows         # cross-compile for Windows
  ./build.sh -t macos           # cross-compile for macOS
  ./build.sh -t linux           # cross-compile for Linux musl
  ./build.sh -t all             # all cross-compile targets
  ./build.sh -r                 # build & run (debug)
  ./build.sh -r -- file.txt     # build & run with a file
  ./build.sh -t release -r      # build & run release
USAGE
    exit 0
}

if ! command -v zig &>/dev/null; then
    echo "Error: 'zig' not found in PATH. Install Zig 0.16.0 first."
    exit 1
fi

TARGET="native"
RUN=false

EDITOR_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t | --target) TARGET="$2"; shift 2 ;;
        -r | --run) RUN=true; shift ;;
        -h | --help) usage ;;
        --) shift; EDITOR_ARGS=("$@"); break ;;
        *)
            EDITOR_ARGS=("$@")
            break
            ;;
    esac
done

resolve_target() {
    case "$1" in
        native | release) echo "" ;;
        windows) echo "x86_64-windows" ;;
        macos) echo "aarch64-macos" ;;
        linux) echo "x86_64-linux-musl" ;;
        *) echo "$1" ;;
    esac
}

resolve_optimize() {
    case "$1" in
        native | release | windows | macos | linux) echo "ReleaseSmall" ;;
        *) echo "ReleaseSmall" ;;
    esac
}

build_one() {
    local name="$1"
    local triple
    triple=$(resolve_target "$name")
    local optimize
    optimize=$(resolve_optimize "$name")
    local prefix="${2:-}"
    local triple_label

    # Cross-compile presets default to their own subdirectory so they
    # never clobber the native binary in zig-out/bin (running a Windows
    # PE or macOS Mach-O on Linux fails with "exec format error").
    if [[ -z "$prefix" ]] && [[ "$name" == windows || "$name" == macos || "$name" == linux ]]; then
        prefix="zig-out/$name"
    fi

    if [[ -z "$triple" ]]; then
        triple_label="native"
    else
        triple_label="$triple"
    fi

    echo "=== Building james for $name ($triple_label, optimize=$optimize) ==="

    local args=()
    if [[ -n "$triple" ]]; then
        args+=("-Dtarget=$triple")
    fi
    args+=("-Doptimize=$optimize")
    if [[ -n "$prefix" ]]; then
        args+=("-p" "$prefix")
    fi

    zig build --summary all "${args[@]}"
    local bin_name="james"
    [[ "$name" == "windows" ]] && bin_name="james.exe"
    if [[ -n "$prefix" ]]; then
        echo "  -> $prefix/bin/$bin_name"
    else
        echo "  -> zig-out/bin/$bin_name"
    fi

    # Generate a .lnk shortcut with the matching AppUserModelID baked
    # in, so Windows groups the running button with the pinned shortcut
    # (Super+N activates it). The .lnk uses a relative target path, so
    # it works wherever james.exe + james.lnk are copied together.
    if [[ "$name" == "windows" ]]; then
        local lnk_path="${prefix:-zig-out}/bin/james.lnk"
        zig run tools/make-lnk.zig -- "$lnk_path" "james.exe" "james.exe" "JamesDyer.James"
        echo "  -> $lnk_path"
    fi

    echo ""
}

case "$TARGET" in
    all)
        for t in release windows macos linux; do
            build_one "$t" "zig-out/$t"
        done
        echo "=== All targets built ==="
        for t in release windows macos linux; do
            bin="zig-out/$t/bin/james"
            [[ "$t" == "windows" ]] && bin="$bin.exe"
            if [[ -f "$bin" ]]; then
                ls -lh "$bin" | awk -v t="$t" '{printf "  %-8s %s %s\n", t, $5, $9}'
            else
                printf "  %-8s (missing)\n" "$t"
            fi
            if [[ "$t" == "windows" ]] && [[ -f "zig-out/$t/bin/james.lnk" ]]; then
                ls -lh "zig-out/$t/bin/james.lnk" | awk '{printf "  %-8s %s %s\n", "lnk", $5, $9}'
            fi
        done
        ;;
    *)
        build_one "$TARGET"
        if $RUN; then
            triple=$(resolve_target "$TARGET")
            if [[ -n "$triple" ]]; then
                echo "Warning: --run with target '$TARGET' ($triple) — can't run a cross-compiled binary on this host."
                local bin="zig-out/bin/james"
                if [[ "$TARGET" == windows || "$TARGET" == macos || "$TARGET" == linux ]]; then
                    bin="zig-out/$TARGET/bin/james"
                    [[ "$TARGET" == windows ]] && bin="$bin.exe"
                fi
                echo "Binary is in $bin"
            else
                echo "=== Running james ==="
                if [[ ${#EDITOR_ARGS[@]} -gt 0 ]]; then
                    zig build run -- "${EDITOR_ARGS[@]}"
                else
                    zig build run
                fi
            fi
        fi
        ;;
esac
