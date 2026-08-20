#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="1.3.0"

usage() {
    cat <<'USAGE'
Usage: ./build.sh [OPTIONS] [-- <editor-args>]

Build and optionally run james with cross-compilation support.

Targets:
  (none)          Native build (ReleaseSmall, stripped)      (default, -> zig-out/bin)
  release         Native release build                       (ReleaseSmall, stripped, -> zig-out/bin)
  windows         Cross-compile for x86_64-windows           (ReleaseSmall, -> zig-out/windows)
  windows32       Cross-compile for x86-windows (32-bit)     (ReleaseSmall, -> zig-out/windows32)
  macos           Cross-compile for aarch64-macos            (ReleaseSmall, -> zig-out/macos)
  intel-macos     Cross-compile for x86_64-macos             (ReleaseSmall, -> zig-out/intel-macos)
  linux           Cross-compile for x86_64-linux-musl        (ReleaseSmall, -> zig-out/linux)
  linux32         Cross-compile for x86-linux-musl (32-bit)  (ReleaseSmall, -> zig-out/linux32)
  aarch64-linux   Cross-compile for aarch64-linux-musl       (ReleaseSmall, -> zig-out/aarch64-linux)
  freebsd         Cross-compile for x86_64-freebsd           (ReleaseSmall, -> zig-out/freebsd)
  freebsd32       Cross-compile for x86-freebsd (32-bit)     (ReleaseSmall, -> zig-out/freebsd32)
  all             Build every target into zig-out/<target>/
  dist            Build the full portable set into dist/: one archive per
                  (OS, arch) — tarballs for the unix targets, a zip for Windows
                  — plus a SHA256SUMS file. macOS binaries are ad-hoc codesigned
                  when the build host is macOS. =--keep= keeps the staged build
                  folders too.

Options:
  -t, --target NAME   Select target (above, or a raw Zig triple)
  -r, --run           Build and run (native targets only)
  -k, --keep          Keep the staged build folders inside dist/ when making a
                      dist set (default: only the archives + SHA256SUMS survive)
  -h, --help          Show this message

Examples:
  ./build.sh                    # native (ReleaseSmall, stripped)
  ./build.sh -t release         # native release (same as default)
  ./build.sh -t windows         # cross-compile for Windows
  ./build.sh -t windows32       # cross-compile for 32-bit Windows (XP and later)
  ./build.sh -t macos           # cross-compile for macOS (Apple Silicon)
  ./build.sh -t intel-macos     # cross-compile for macOS (Intel)
  ./build.sh -t linux           # cross-compile for Linux x86_64 (musl)
  ./build.sh -t linux32         # cross-compile for 32-bit Linux (musl, old distros)
  ./build.sh -t aarch64-linux   # cross-compile for Linux aarch64 (musl)
  ./build.sh -t freebsd         # cross-compile for FreeBSD x86_64
  ./build.sh -t freebsd32       # cross-compile for 32-bit FreeBSD
  ./build.sh -t all             # all of the above
./build.sh -t dist             # portable release set into dist/ (archives only)
  ./build.sh -t dist -k          # same, but keep the staged build folders
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
KEEP_STAGED=false

EDITOR_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t | --target) TARGET="$2"; shift 2 ;;
        -r | --run) RUN=true; shift ;;
        -k | --keep) KEEP_STAGED=true; shift ;;
        -h | --help) usage ;;
        --) shift; EDITOR_ARGS=("$@"); break ;;
        *)
            EDITOR_ARGS=("$@")
            break
            ;;
    esac
done

# Preset name -> Zig target triple. An empty triple is a native build.
declare -A PRESETS
PRESETS[release]=""
PRESETS[windows]="x86_64-windows"
PRESETS[windows32]="x86-windows"
PRESETS[macos]="aarch64-macos"
PRESETS[intel-macos]="x86_64-macos"
PRESETS[linux]="x86_64-linux-musl"
PRESETS[linux32]="x86-linux-musl"
PRESETS[aarch64-linux]="aarch64-linux-musl"
PRESETS[freebsd]="x86_64-freebsd"
PRESETS[freebsd32]="x86-freebsd"

ALL_PRESETS=(release windows windows32 macos intel-macos linux linux32 aarch64-linux freebsd freebsd32)
DIST_PRESETS=(windows windows32 macos intel-macos linux linux32 aarch64-linux freebsd freebsd32)

# What the dist folders and archives are called on the stick / in the wild.
declare -A DIST_LABELS
DIST_LABELS[windows]="windows-x86_64"
DIST_LABELS[windows32]="windows-x86"
DIST_LABELS[macos]="macos-aarch64"
DIST_LABELS[intel-macos]="macos-x86_64"
DIST_LABELS[linux]="linux-x86_64"
DIST_LABELS[linux32]="linux-x86"
DIST_LABELS[aarch64-linux]="linux-aarch64"
DIST_LABELS[freebsd]="freebsd-x86_64"
DIST_LABELS[freebsd32]="freebsd-x86"

declare -A BIN_SUFFIX
BIN_SUFFIX[windows]=".exe"
BIN_SUFFIX[windows32]=".exe"
BIN_SUFFIX[macos]=""
BIN_SUFFIX[intel-macos]=""
BIN_SUFFIX[linux]=""
BIN_SUFFIX[linux32]=""
BIN_SUFFIX[aarch64-linux]=""
BIN_SUFFIX[freebsd]=""
BIN_SUFFIX[freebsd32]=""

resolve_target() {
    if [[ -n "${PRESETS[$1]+x}" ]]; then
        echo "${PRESETS[$1]}"
    else
        # A raw Zig triple ("x86_64-linux-gnu", ...) passes straight through.
        echo "$1"
    fi
}

# The newest CHANGELOG.org release heading's version ("** 0.82.0 — <date>"
# -> "0.82.0"), used to name the dist folders. Empty when none is found.
latest_version() {
    local line
    line=$(grep -m1 '^\*\* ' CHANGELOG.org) || return 0
    line="${line#*\*\* }"   # drop the leading "** "
    line="${line%%<*}"      # cut the trailing " — <date>"
    echo "${line%%[[:space:]]*}"
}

build_one() {
    local name="$1"
    local prefix="${2:-}"
    local triple
    triple=$(resolve_target "$name")
    local triple_label="${triple:-native}"

    # Cross-compile presets default to their own subdirectory so they
    # never clobber the native binary in zig-out/bin (running a Windows
    # PE or macOS Mach-O on Linux fails with "exec format error").
    if [[ -z "$prefix" ]] && [[ -n "$triple" ]]; then
        prefix="zig-out/$name"
    fi

    echo "=== Building james for $name ($triple_label, ReleaseSmall) ==="

    local args=()
    if [[ -n "$triple" ]]; then
        args+=("-Dtarget=$triple")
    fi
    args+=("-Doptimize=ReleaseSmall")
    if [[ -n "$prefix" ]]; then
        args+=("-p" "$prefix")
    fi

    zig build --summary all "${args[@]}"

    # Derive Windows-ness from the triple, not the preset name, so a raw
    # triple (=-t x86-windows=) behaves like the =windows= preset.
    local is_windows=no
    local is_macos=no
    if [[ "$triple" == *windows* ]]; then is_windows=yes; fi
    if [[ "$triple" == *macos* ]]; then is_macos=yes; fi

    local bin_name="james"
    [[ "$is_windows" == yes ]] && bin_name="james.exe"
    local bin_path="${prefix:-zig-out}/bin/$bin_name"
    if [[ ! -f "$bin_path" ]]; then
        echo "Error: $bin_path missing after build."
        exit 1
    fi
    echo "  -> $bin_path"

    # Generate a .lnk shortcut with the matching AppUserModelID baked
    # in, so Windows groups the running button with the pinned shortcut
    # (Super+N activates it). The .lnk uses a relative target path, so
    # it works wherever james.exe + james.lnk are copied together.
    if [[ "$is_windows" == yes ]]; then
        zig run tools/make-lnk.zig -- "${prefix:-zig-out}/bin/james.lnk" "james.exe" "james.exe" "JamesDyer.James"
        echo "  -> ${prefix:-zig-out}/bin/james.lnk"
    fi

    # Ad-hoc sign macOS binaries when the build host is macOS (only macOS
    # has codesign), so Gatekeeper is quieter when the binary is shared.
    if [[ "$is_macos" == yes ]]; then
        if command -v codesign &>/dev/null && [[ "$(uname -s)" == "Darwin" ]]; then
            codesign --force --deep -s - "$bin_path" && echo "  -> ad-hoc signed (codesign)"
        fi
    fi

    echo ""
}

case "$TARGET" in
    all)
        for t in "${ALL_PRESETS[@]}"; do
            build_one "$t" "zig-out/$t"
        done
        echo "=== All targets built ==="
        for t in "${ALL_PRESETS[@]}"; do
            bin="zig-out/$t/bin/james${BIN_SUFFIX[$t]}"
            if [[ -f "$bin" ]]; then
                ls -lh "$bin" | awk -v t="$t" '{printf "  %-14s %s %s\n", t, $5, $9}'
            else
                printf "  %-14s (missing)\n" "$t"
            fi
            if [[ "${PRESETS[$t]}" == *windows* ]] && [[ -f "zig-out/$t/bin/james.lnk" ]]; then
                ls -lh "zig-out/$t/bin/james.lnk" | awk '{printf "  %-14s %s %s\n", "lnk", $5, $9}'
            fi
        done
        ;;
    dist)
        dist_ver="$(latest_version)"
        if [[ -z "$dist_ver" ]]; then
            echo "Error: couldn't read the version from CHANGELOG.org — expected a '** <version> — <date>' heading."
            exit 1
        fi
        echo "=== Building portable set james-$dist_ver -> dist/ ==="
        rm -rf dist
        mkdir -p dist
        for t in "${DIST_PRESETS[@]}"; do
            build_one "$t" "dist/james-$dist_ver-${DIST_LABELS[$t]}"
        done
        echo "=== Packaging ==="
        for t in "${DIST_PRESETS[@]}"; do
            dist_folder="dist/james-$dist_ver-${DIST_LABELS[$t]}"
            if [[ "${PRESETS[$t]}" == *windows* ]]; then
                (cd dist && zip -qr "james-$dist_ver-${DIST_LABELS[$t]}.zip" "james-$dist_ver-${DIST_LABELS[$t]}")
                dist_archive="dist/james-$dist_ver-${DIST_LABELS[$t]}.zip"
            else
                tar -C dist -czf "dist/james-$dist_ver-${DIST_LABELS[$t]}.tar.gz" "james-$dist_ver-${DIST_LABELS[$t]}"
                dist_archive="dist/james-$dist_ver-${DIST_LABELS[$t]}.tar.gz"
            fi
            ls -lh "$dist_archive"
        done
        (cd dist && sha256sum *.tar.gz *.zip > SHA256SUMS)
        if [[ "$KEEP_STAGED" != true ]]; then
            rm -rf dist/james-*/
        fi
        echo "=== dist complete ==="
        if [[ "$KEEP_STAGED" == true ]]; then
            echo "  staged folders kept: dist/james-$dist_ver-*/"
        fi
        echo "  archives + SHA256SUMS at dist/"
        ;;
    *)
        build_one "$TARGET"
        if $RUN; then
            triple=$(resolve_target "$TARGET")
            if [[ -n "$triple" ]]; then
                echo "Warning: --run with target '$TARGET' ($triple) — can't run a cross-compiled binary on this host."
                echo "Binary is in zig-out/$TARGET/bin/james${BIN_SUFFIX[$TARGET]-}"
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