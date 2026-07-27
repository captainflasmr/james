#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="1.0.0"

usage() {
    cat <<'USAGE'
Usage: ./build.sh [OPTIONS] [-- <editor-args>]

Build and optionally run james with cross-compilation support.

Targets:
  (none)    Native debug build                        (default)
  release   Native release build                      (ReleaseSmall)
  windows   Cross-compile for x86_64-windows          (ReleaseSmall)
  macos     Cross-compile for aarch64-macos           (ReleaseSmall)
  linux     Cross-compile for x86_64-linux-musl       (ReleaseSmall)
  all       Build all of the above into zig-out/<target>/

Options:
  -t, --target NAME   Select target (above, or a raw Zig triple)
  -r, --run           Build and run (native targets only)
  -h, --help          Show this message

Examples:
  ./build.sh                    # native debug
  ./build.sh -t release         # native release
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
        native) echo "Debug" ;;
        release | windows | macos | linux) echo "ReleaseSmall" ;;
        *) echo "Debug" ;;
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
        done
        ;;
    *)
        build_one "$TARGET"
        if $RUN; then
            triple=$(resolve_target "$TARGET")
            if [[ -n "$triple" ]]; then
                echo "Warning: --run with target '$TARGET' ($triple) — can't run a cross-compiled binary on this host."
                echo "Binary is in zig-out/bin/james"
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
