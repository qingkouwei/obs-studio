#!/usr/bin/env bash
#
# build-deps.sh — cross-compile OBS Studio's third-party dependencies for
# HarmonyOS (OHOS). Build order: mbedTLS -> curl -> x264 -> FFmpeg.
#
# zlib is NOT built here: it ships in the OHOS sysroot (shared libz.so) and we
# link against the system one.
#
# Usage: ./build-deps.sh [--prefix DIR] [--arch ARCH] [--jobs N] [--only LIST]
# Run with --help for the full option list.

# Constants below are consumed by the sourced deps/*.sh build functions.
# shellcheck disable=SC2034

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ---------------------------------------------------------------------------
# Pinned sources. Checksums below were computed from downloads off the official
# distribution sites (mbedtls hash additionally cross-checked against the
# GitHub release metadata). x264 is pinned to a git commit on the `stable`
# branch; its GitLab archive tarball is a convenience mirror that is not
# guaranteed byte-stable, so a checksum failure there falls back to fetching
# the exact commit over git (the commit id itself is the integrity proof).
# ---------------------------------------------------------------------------
MBEDTLS_VERSION="3.6.2"
MBEDTLS_URL="https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-${MBEDTLS_VERSION}/mbedtls-${MBEDTLS_VERSION}.tar.bz2"
MBEDTLS_SHA256="8b54fb9bcf4d5a7078028e0520acddefb7900b3e66fec7f7175bb5b7d85ccdca"

CURL_VERSION="8.11.1"
CURL_URL="https://curl.se/download/curl-${CURL_VERSION}.tar.xz"
CURL_SHA256="c7ca7db48b0909743eaef34250da02c19bc61d4f1dcedd6603f109409536ab56"

X264_COMMIT="b35605ace3ddf7c1a5d67a2eb553f034aef41d55"  # x264 `stable`, 2025-09
X264_GIT_URL="https://code.videolan.org/videolan/x264.git"
X264_URL="https://code.videolan.org/videolan/x264/-/archive/${X264_COMMIT}/x264-${X264_COMMIT}.tar.bz2"
X264_SHA256="6eeb82934e69fd51e043bd8c5b0d152839638d1ce7aa4eea65a3fedcf83ff224"

FFMPEG_VERSION="7.1"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
FFMPEG_SHA256="40973d44970dbc83ef302b0609f2e74982be2d85916dd2ee7472d30678a7abe6"

# libobs's own dependencies. jansson backs obs_data_t; SIMDe emulates the x86
# SSE intrinsics libobs uses (which is what makes the arm64 port viable without
# rewriting the SIMD paths); uthash backs the lookup tables in obs-internal.h.
# ZLIB is deliberately absent from this list: it is already in the OHOS sysroot.
JANSSON_VERSION="2.14"
JANSSON_URL="https://github.com/akheron/jansson/releases/download/v${JANSSON_VERSION}/jansson-${JANSSON_VERSION}.tar.gz"
JANSSON_SHA256="5798d010e41cf8d76b66236cfb2f2543c8d082181d16bc3085ab49538d4b9929"

SIMDE_VERSION="0.8.2"
# The "amalgamated" release asset does not exist for this tag (returns a 9-byte
# "Not Found" body); the plain source archive does and contains simde/.
SIMDE_URL="https://github.com/simd-everywhere/simde/archive/refs/tags/v${SIMDE_VERSION}.tar.gz"
SIMDE_SHA256="ed2a3268658f2f2a9b5367628a85ccd4cf9516460ed8604eed369653d49b25fb"

UTHASH_VERSION="2.3.0"
UTHASH_URL="https://github.com/troydhanson/uthash/archive/refs/tags/v${UTHASH_VERSION}.tar.gz"
UTHASH_SHA256="e10382ab75518bad8319eb922ad04f907cb20cccb451a3aa980c9d005e661acc"

# Backs libobs's audio resampler and obs-filters' noise suppression. The GitHub
# release asset for this tag returns a 9-byte "Not Found"; use the Xiph mirror.
SPEEXDSP_VERSION="1.2.0"
SPEEXDSP_URL="https://downloads.xiph.org/releases/speex/speexdsp-${SPEEXDSP_VERSION}.tar.gz"
SPEEXDSP_SHA256="682042fc6f9bee6294ec453f470dadc26c6ff29b9c9e9ad2ffc1f4312fd64771"

# Backs plugins/text-freetype2. The canonical savannah URL and the SourceForge
# release asset are byte-identical (both verified to produce the checksum below,
# which also appears on the freetype2 2.13.3 SourceForge release page), so no
# mirror substitution was needed here. FreeType is configured with every
# optional back end disabled — see deps/freetype.sh for the reasoning — so it
# pulls in no other library: no harfbuzz, no fontconfig, no expat, no libpng and
# not even the sysroot's libz (it compiles the zlib sources it bundles instead).
FREETYPE_VERSION="2.13.3"
FREETYPE_URL="https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.xz"
FREETYPE_SHA256="0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289"

# freetype has no dependency on anything else in this list, so it goes last;
# everything before it keeps its existing position and is never rebuilt.
BUILD_ORDER="headers jansson speexdsp mbedtls curl x264 ffmpeg freetype"

# ---------------------------------------------------------------------------
# Defaults & CLI
# ---------------------------------------------------------------------------
PREFIX="${PREFIX:-$REPO_ROOT/.deps-harmony}"
OHOS_ARCH="arm64-v8a"
OHOS_STL="c++_shared"
TOOLCHAIN_VARIANT="openharmony"   # "openharmony" | "hmos" (commercial HarmonyOS)
SDK_HOME="${DEVECO_SDK_HOME:-}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$REPO_ROOT/.deps-harmony-src}"
WORK_DIR=""
JOBS=""
ONLY=""
FRESH=0
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

  --prefix DIR       Install prefix (default: <repo>/.deps-harmony)
  --arch ARCH        arm64-v8a (default), armeabi-v7a, x86_64.
                     Only arm64-v8a is verified; others are best-effort.
  --stl STL          c++_shared (default) or c++_static. Every native lib in
                     one HAP must use the same STL choice.
  --jobs N           Parallel jobs (default: ncpu)
  --only LIST        Comma-separated subset of: $BUILD_ORDER
  --download-dir DIR Source tarball cache (default: <repo>/.deps-harmony-src)
  --work-dir DIR     Extraction/build dir (default: <repo>/.deps-harmony-build-<arch>)
  --sdk DIR          SDK root (default: \$DEVECO_SDK_HOME, then DevEco-Studio.app)
  --toolchain NAME   openharmony (default) or hmos (commercial HarmonyOS PC,
                     uses <SDK>/hms/native + hmos.toolchain.cmake)
  --fresh            Delete the work dir and rebuild sources from scratch
  --dry-run          Print the resolved configuration and exit (builds nothing)
  -h, --help         This help

Sources are cached in --download-dir, so reruns are offline-capable.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)       PREFIX="$(cd "$2" 2>/dev/null && pwd || echo "$2")"; shift 2 ;;
        --arch)         OHOS_ARCH="$2"; shift 2 ;;
        --stl)          OHOS_STL="$2"; shift 2 ;;
        --jobs|-j)      JOBS="$2"; shift 2 ;;
        --only)         ONLY="${ONLY:+$ONLY,}$2"; shift 2 ;;
        --download-dir) DOWNLOAD_DIR="$2"; shift 2 ;;
        --work-dir)     WORK_DIR="$2"; shift 2 ;;
        --sdk)          SDK_HOME="$2"; shift 2 ;;
        --toolchain)    TOOLCHAIN_VARIANT="$2"; shift 2 ;;
        --fresh)        FRESH=1; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

log()  { printf '== %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Validate selectors
# ---------------------------------------------------------------------------
case "$OHOS_ARCH" in
    arm64-v8a)   TRIPLE="aarch64-linux-ohos";       LIB_TRIPLE="aarch64-linux-ohos"; FFMPEG_ARCH="aarch64" ;;
    armeabi-v7a) TRIPLE="armv7-unknown-linux-ohos"; LIB_TRIPLE="arm-linux-ohos";     FFMPEG_ARCH="arm";
                 warn "armeabi-v7a is unverified; only arm64-v8a has been smoke-tested" ;;
    x86_64)      TRIPLE="x86_64-linux-ohos";        LIB_TRIPLE="x86_64-linux-ohos";  FFMPEG_ARCH="x86_64";
                 warn "x86_64 is unverified (emulator arch)" ;;
    *) die "Invalid --arch '$OHOS_ARCH' (expected arm64-v8a, armeabi-v7a or x86_64)" ;;
esac
# autoconf --host value. Deliberately NOT $TRIPLE: config.sub does not know
# "ohos" as an OS (verified against curl 8.11.1's bundled 2022-vintage copy and
# automake 1.17's), so configure aborts with
#   Invalid configuration `aarch64-linux-ohos': OS `ohos' not recognized
# A gnu triple validates cleanly and yields host_os=linux-gnu, which activates
# the Linux code paths these projects need. The real target is still enforced
# through CC/CXX (--target=$TRIPLE --sysroot=...), and every capability check
# autoconf runs is a compile test against the OHOS sysroot, so feature detection
# stays honest even though the host name is approximate.
case "$OHOS_ARCH" in
    arm64-v8a)   CONFIG_HOST="aarch64-linux-gnu" ;;
    armeabi-v7a) CONFIG_HOST="armv7-linux-gnueabi" ;;
    x86_64)      CONFIG_HOST="x86_64-linux-gnu" ;;
esac

case "$OHOS_STL" in
    c++_shared|c++_static) ;;
    *) die "Invalid --stl '$OHOS_STL' (expected c++_shared or c++_static)" ;;
esac

if [ -n "$ONLY" ]; then
    IFS=',' read -r -a _only_arr <<< "$ONLY"
    for lib in "${_only_arr[@]}"; do
        case " $BUILD_ORDER " in
            *" $lib "*) ;;
            *) die "Unknown --only library '$lib' (expected: $BUILD_ORDER)" ;;
        esac
    done
fi

# ---------------------------------------------------------------------------
# Locate the SDK. DEVECO_SDK_HOME may point at <...>/sdk or <...>/sdk/default;
# handle both, then fall back to the stock DevEco-Studio.app location.
# ---------------------------------------------------------------------------
case "$TOOLCHAIN_VARIANT" in
    openharmony) VARIANT_DIR="openharmony"; TOOLCHAIN_CMAKE="ohos.toolchain.cmake" ;;
    hmos)        VARIANT_DIR="hms";         TOOLCHAIN_CMAKE="hmos.toolchain.cmake" ;;
    *) die "Invalid --toolchain '$TOOLCHAIN_VARIANT' (expected openharmony or hmos)" ;;
esac

SDK_NATIVE=""
_sdk_candidates=()
if [ -n "$SDK_HOME" ]; then
    _sdk_candidates+=("$SDK_HOME" "$SDK_HOME/default")
fi
_sdk_candidates+=("/Applications/DevEco-Studio.app/Contents/sdk" \
                  "/Applications/DevEco-Studio.app/Contents/sdk/default")
for _base in "${_sdk_candidates[@]}"; do
    _nat="$_base/$VARIANT_DIR/native"
    if [ -f "$_nat/build/cmake/$TOOLCHAIN_CMAKE" ]; then
        SDK_NATIVE="$(cd "$_nat" && pwd)"
        break
    fi
done
[ -n "$SDK_NATIVE" ] || die "Could not find the HarmonyOS SDK ($VARIANT_DIR/native with $TOOLCHAIN_CMAKE).
Install DevEco Studio, or set DEVECO_SDK_HOME, or pass --sdk <dir>.
Searched: ${_sdk_candidates[*]}"

SYSROOT="$SDK_NATIVE/sysroot"
LLVM_BIN="$SDK_NATIVE/llvm/bin"
if [ ! -x "$LLVM_BIN/clang" ] && [ -x "$SDK_NATIVE/BiSheng/bin/clang" ]; then
    # The commercial (hmos) SDK ships the BiSheng clang instead of llvm/bin.
    LLVM_BIN="$SDK_NATIVE/BiSheng/bin"
fi
TOOLCHAIN_FILE="$SDK_NATIVE/build/cmake/$TOOLCHAIN_CMAKE"
SYSROOT_LIBDIR="$SYSROOT/usr/lib/$LIB_TRIPLE"

[ -x "$LLVM_BIN/clang" ] || die "clang not found under $SDK_NATIVE (looked in llvm/bin and BiSheng/bin)"
[ -d "$SYSROOT_LIBDIR" ] || die "sysroot lib dir not found: $SYSROOT_LIBDIR (wrong SDK arch layout?)"
[ -f "$SYSROOT_LIBDIR/libz.so" ] || warn "libz.so not found in sysroot; curl/ffmpeg will be built without zlib"

if [ -z "$JOBS" ]; then
    JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
fi
if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$REPO_ROOT/.deps-harmony-build-$OHOS_ARCH"
fi
LOG_DIR="$WORK_DIR/logs"
PATCH_DIR="$SCRIPT_DIR/patches"

if [ "$FRESH" = "1" ] && [ -d "$WORK_DIR" ]; then
    log "--fresh: removing $WORK_DIR"
    rm -rf "$WORK_DIR"
fi
mkdir -p "$PREFIX" "$WORK_DIR" "$LOG_DIR" "$DOWNLOAD_DIR"

for tool in cmake ninja make tar git patch pkg-config; do
    command -v "$tool" >/dev/null 2>&1 || die "required host tool not found: $tool"
done

# ---------------------------------------------------------------------------
# Cross-compile environment for the autoconf projects (curl, x264, FFmpeg).
#
# PKG_CONFIG_LIBDIR points ONLY at the staging prefix: if the host pkg-config
# search path leaks in, configure happily picks up Homebrew's x86/arm-mac
# libraries and the link fails later (or worse, silently succeeds with host
# code). PKG_CONFIG_PATH is forced empty for the same reason.
#
# CC/CXX carry --target/--sysroot as part of the command string, which
# autoconf handles fine. The CMake-based mbedTLS build ignores these and uses
# the OHOS toolchain file instead.
# ---------------------------------------------------------------------------
export CC="$LLVM_BIN/clang --target=$TRIPLE --sysroot=$SYSROOT"
export CXX="$LLVM_BIN/clang++ --target=$TRIPLE --sysroot=$SYSROOT"
export AR="$LLVM_BIN/llvm-ar"
export RANLIB="$LLVM_BIN/llvm-ranlib"
export STRIP="$LLVM_BIN/llvm-strip"
export NM="$LLVM_BIN/llvm-nm"
# -Qunused-arguments: the OHOS toolchain passes --gcc-toolchain= on every
# compile line, clang 15 reports it as unused, and any upstream project building
# with -Werror (mbedTLS does by default) turns that into a hard failure. Apply
# it globally so the autoconf projects get the same protection as the CMake ones.
export CFLAGS="-O2 -fPIC -Qunused-arguments"
export CXXFLAGS="-O2 -fPIC -Qunused-arguments"
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH=""
export PATH="$LLVM_BIN:$PATH"

# ---------------------------------------------------------------------------
# Download / extract / patch helpers
# ---------------------------------------------------------------------------
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# fetch_tarball <filename> <url> <expected-sha256> — caches in DOWNLOAD_DIR.
# Never proceeds on a checksum mismatch: the poisoned file is deleted.
fetch_tarball() {
    local name="$1" url="$2" want="$3"
    local out="$DOWNLOAD_DIR/$name"
    if [ ! -f "$out" ]; then
        log "Downloading $name"
        curl -fL --retry 3 --connect-timeout 20 -o "$out.part" "$url" \
            || die "download failed: $url"
        mv "$out.part" "$out"
    else
        log "Using cached $name"
    fi
    local got
    got="$(sha256_of "$out")"
    if [ "$got" != "$want" ]; then
        rm -f "$out"
        die "Checksum mismatch for $name
  expected: $want
  actual:   $got
The cached file was deleted. Re-run to download again; if it fails again the
upstream artifact changed and the pin in this script must be reviewed."
    fi
}

extract_tarball() { # <filename-in-download-dir> <expected-top-dir>
    local tarball="$DOWNLOAD_DIR/$1" topdir="$2"
    if [ -d "$WORK_DIR/$topdir" ]; then
        return 0
    fi
    log "Extracting $1"
    tar -xf "$tarball" -C "$WORK_DIR"
    [ -d "$WORK_DIR/$topdir" ] || die "$tarball did not extract to $topdir/"
}

# apply_patches <srcdir> <libname> — applies every patches/<libname>-*.patch
# that actually contains diff content. Placeholder patches (comments only,
# e.g. the documented ffmpeg-ohos.patch stub) are detected and skipped.
apply_patches() {
    local srcdir="$1" lib="$2" p
    for p in "$PATCH_DIR"/"$lib"-*.patch "$PATCH_DIR"/"$lib"-*.diff; do
        [ -e "$p" ] || continue
        if ! grep -qE '^(diff -|--- )' "$p"; then
            log "Skipping placeholder patch (no diff content): $(basename "$p")"
            continue
        fi
        log "Applying patch: $(basename "$p")"
        ( cd "$srcdir" && patch -p1 --forward -i "$p" ) \
            || die "failed to apply patch: $p"
    done
}

# build_one <lib> — runs build_<lib> with tracing into a per-library log;
# on failure prints the last 50 lines plus the full log path.
build_one() {
    local lib="$1"
    local logfile="$LOG_DIR/$lib.log"
    : > "$logfile"
    log "Building $lib  (log: $logfile)"
    if ( set -x; "build_$lib" ) >> "$logfile" 2>&1; then
        log "$lib: OK"
    else
        printf '\nERROR: %s FAILED. Last 50 lines of %s:\n\n' "$lib" "$logfile" >&2
        tail -n 50 "$logfile" >&2 || true
        printf '\nFull log: %s\n' "$logfile" >&2
        exit 1
    fi
}

should_build() {
    [ -z "$ONLY" ] && return 0
    case ",$ONLY," in
        *",$1,"*) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Per-library build functions
# ---------------------------------------------------------------------------
for f in "$SCRIPT_DIR"/deps/*.sh; do
    # shellcheck source=/dev/null
    . "$f"
done

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log "SDK:        $SDK_NATIVE (toolchain: $TOOLCHAIN_VARIANT)"
log "Arch:       $OHOS_ARCH ($TRIPLE)"
log "Prefix:     $PREFIX"
log "Work dir:   $WORK_DIR"
log "Downloads:  $DOWNLOAD_DIR"
log "Jobs:       $JOBS"

if [ "$DRY_RUN" = "1" ]; then
    log "dry-run: resolved environment"
    printf '  CC=%s\n  CXX=%s\n  AR=%s\n  PKG_CONFIG_LIBDIR=%s\n  TOOLCHAIN_FILE=%s\n  SYSROOT=%s\n  TRIPLE=%s\n  FFMPEG_ARCH=%s\n' \
        "$CC" "$CXX" "$AR" "$PKG_CONFIG_LIBDIR" "$TOOLCHAIN_FILE" "$SYSROOT" "$TRIPLE" "$FFMPEG_ARCH"
    log "dry-run: would build: $(for lib in $BUILD_ORDER; do if should_build "$lib"; then printf '%s ' "$lib"; fi; done)"
    exit 0
fi

for lib in $BUILD_ORDER; do
    if should_build "$lib"; then
        build_one "$lib"
    else
        log "Skipping $lib (not in --only list)"
    fi
done

log "All requested dependencies installed into: $PREFIX"
log "Validate with: $SCRIPT_DIR/verify-deps.sh --prefix $PREFIX --arch $OHOS_ARCH"
