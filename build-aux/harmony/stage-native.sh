#!/usr/bin/env bash
# stage-native.sh — assemble the cross-compiled OBS native stack into the two
# layouts that consume it:
#
#   1. <prefix>/{include/obs,lib}   — what harmony/entry/src/main/cpp/CMakeLists.txt
#      looks for via OBS_HARMONY_PREFIX. Finding lib/libobs.so there is what flips
#      HAVE_LIBOBS on, so the bridge compiles against the real core instead of the
#      shell-only stubs.
#
#   2. harmony/entry/libs/<abi>/    — what hvigor packs into the HAP. Every .so
#      libobs needs at runtime must be here or the app fails to load at startup.
#
# Usage: ./stage-native.sh --build-dir <cmake-build> --deps <deps-prefix> [--prefix <stage>] [--abi arm64-v8a]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BUILD_DIR=""
DEPS_PREFIX="$REPO_ROOT/.deps-harmony"
PREFIX="$REPO_ROOT/.ohos-stage"
ABI="arm64-v8a"

while [ $# -gt 0 ]; do
    case "$1" in
        --build-dir) BUILD_DIR="$2"; shift 2 ;;
        --deps)      DEPS_PREFIX="$2"; shift 2 ;;
        --prefix)    PREFIX="$2"; shift 2 ;;
        --abi)       ABI="$2"; shift 2 ;;
        -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'ERROR: unknown argument %s\n' "$1" >&2; exit 2 ;;
    esac
done

[ -n "$BUILD_DIR" ] || { printf 'ERROR: --build-dir is required\n' >&2; exit 2; }
[ -d "$BUILD_DIR" ] || { printf 'ERROR: build dir not found: %s\n' "$BUILD_DIR" >&2; exit 2; }

log() { printf '== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

RUNDIR="$BUILD_DIR/rundir/Release/libs/$ABI"
[ -d "$RUNDIR" ] || die "no build products at $RUNDIR — did the ninja build succeed?"

HAP_LIBS="$REPO_ROOT/harmony/entry/libs/$ABI"

# ---------------------------------------------------------------------------
# 1. OBS native libraries
# ---------------------------------------------------------------------------
log "Staging OBS libraries from $RUNDIR"
mkdir -p "$PREFIX/lib" "$PREFIX/include/obs" "$HAP_LIBS"

count=0
for so in "$RUNDIR"/*.so; do
    [ -e "$so" ] || continue
    cp -f "$so" "$PREFIX/lib/"
    cp -f "$so" "$HAP_LIBS/"
    count=$((count + 1))
done
[ "$count" -gt 0 ] || die "no .so found in $RUNDIR"
log "  $count OBS libraries"

# ---------------------------------------------------------------------------
# 2. Third-party shared libraries libobs links against at runtime.
#
#    libobs.so's DT_NEEDED entries are sonames such as "libavcodec.so.61", but
#    the deps prefix holds "libavcodec.so.61.19.100" plus a dev symlink
#    "libavcodec.so". The HAP loader resolves DT_NEEDED by exact filename, so the
#    file on disk must be named exactly what DT_NEEDED says. Copy the real file
#    under its soname rather than shipping the symlink.
# ---------------------------------------------------------------------------
log "Staging third-party runtime libraries from $DEPS_PREFIX/lib"

# Prefer the SDK's llvm-readelf; fall back to the host readelf.
readelf_tool=""
for cand in \
    "${DEVECO_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk}/default/openharmony/native/llvm/bin/llvm-readelf" \
    "$(command -v llvm-readelf 2>/dev/null || true)" \
    "$(command -v readelf 2>/dev/null || true)"; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then readelf_tool="$cand"; break; fi
done
[ -n "$readelf_tool" ] || die "no readelf/llvm-readelf found; cannot resolve DT_NEEDED"

llvm_readelf_sonames() {
    "$readelf_tool" -d "$1" 2>/dev/null \
        | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'
}

# Collect the sonames every OBS library actually needs, then satisfy each from
# the deps prefix. Anything the OHOS sysroot provides (libc, libz, libEGL, ...)
# is already on the device and must NOT be bundled.
needed="$(
    for so in "$PREFIX"/lib/*.so; do llvm_readelf_sonames "$so"; done | sort -u
)"

staged_deps=0
for name in $needed; do
    in_prefix=0
    in_hap=0
    # Check the two destinations independently. Testing them together would let
    # a stale copy in the HAP libs dir suppress the staging prefix copy, leaving
    # <prefix>/lib incomplete for anything that links against it.
    [ -e "$PREFIX/lib/$name" ] && in_prefix=1
    [ -e "$HAP_LIBS/$name" ] && in_hap=1
    [ "$in_prefix" -eq 1 ] && [ "$in_hap" -eq 1 ] && continue

    src=""
    # Exact soname match first (e.g. libavcodec.so.61 -> libavcodec.so.61.19.100).
    for cand in "$DEPS_PREFIX/lib/$name" "$DEPS_PREFIX/lib/$name."*; do
        if [ -f "$cand" ] && [ ! -L "$cand" ]; then src="$cand"; break; fi
    done
    # Resolve a dev symlink (libavcodec.so -> libavcodec.so.61.19.100).
    if [ -z "$src" ] && [ -L "$DEPS_PREFIX/lib/$name" ]; then
        resolved="$(readlink "$DEPS_PREFIX/lib/$name")"
        [ -f "$DEPS_PREFIX/lib/$resolved" ] && src="$DEPS_PREFIX/lib/$resolved"
    fi

    if [ -z "$src" ]; then
        # libc.so, libz.so, libEGL.so, libGLESv3.so, libhilog_ndk.z.so and the
        # rest of the NDK stubs live on the device. Only warn for names that do
        # not look like system libraries.
        case "$name" in
            lib*.so|lib*.so.*) : ;;
            *) log "  WARN: unresolved DT_NEEDED '$name'" ;;
        esac
        continue
    fi

    [ "$in_prefix" -eq 1 ] || cp -f "$src" "$PREFIX/lib/$name"
    [ "$in_hap" -eq 1 ] || cp -f "$src" "$HAP_LIBS/$name"
    staged_deps=$((staged_deps + 1))
done
log "  $staged_deps third-party libraries"

# ---------------------------------------------------------------------------
# 3. libobs public headers.
#
#    The install rules do not currently export them, and the bridge includes
#    <obs.h>, <obs-module.h>, <graphics/graphics.h>, <media-io/video-io.h> and
#    <media-io/audio-io.h>. Copy the libobs headers with their subdirectory
#    structure preserved so both <obs.h> and <graphics/graphics.h> resolve.
# ---------------------------------------------------------------------------
log "Staging libobs headers"
(
    cd "$REPO_ROOT/libobs"
    # Top-level public headers.
    for h in *.h; do
        [ -e "$h" ] && cp -f "$h" "$PREFIX/include/obs/"
    done
    # Subdirectory headers, preserving relative paths.
    for d in callback graphics media-io util; do
        [ -d "$d" ] || continue
        mkdir -p "$PREFIX/include/obs/$d"
        find "$d" -name '*.h' -exec cp -f {} "$PREFIX/include/obs/$d/" \;
    done
)
# The generated config header is required by obs.h consumers.
if [ -f "$BUILD_DIR/config/obsconfig.h" ]; then
    cp -f "$BUILD_DIR/config/obsconfig.h" "$PREFIX/include/obs/"
fi
# obs-config.h is generated into the build tree as well on some configurations.
find "$BUILD_DIR" -maxdepth 3 -name 'obs-config.h' -exec cp -f {} "$PREFIX/include/obs/" \; 2>/dev/null || true

hdr_count="$(find "$PREFIX/include/obs" -name '*.h' | wc -l | tr -d ' ')"
log "  $hdr_count libobs headers"

# libobs's public headers are not self-contained: graphics/vec4.h pulls in
# util/sse-intrin.h, which includes <simde/x86/sse2.h>. Stage the deps headers
# alongside them so a consumer only needs -I<prefix>/include.
if [ -d "$DEPS_PREFIX/include" ]; then
    log "Staging third-party headers required by the libobs headers"
    cp -R "$DEPS_PREFIX/include/." "$PREFIX/include/"
    log "  $(find "$PREFIX/include" -name '*.h' | wc -l | tr -d ' ') headers total"
fi

# ---------------------------------------------------------------------------
# 4. libobs runtime data (effect shaders, locale) into the HAP rawfile tree.
# ---------------------------------------------------------------------------
if [ -d "$BUILD_DIR/rundir/Release/share/obs" ]; then
    log "Staging libobs data into HAP rawfile"
    mkdir -p "$REPO_ROOT/harmony/entry/src/main/resources/rawfile"
    cp -R "$BUILD_DIR/rundir/Release/share/obs/." \
          "$REPO_ROOT/harmony/entry/src/main/resources/rawfile/"
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
printf '\n'
log "Staging prefix : $PREFIX"
log "HAP libs dir   : $HAP_LIBS"
printf '\n'
log "Bridge build with the core linked:"
printf '   export OBS_HARMONY_PREFIX=%s\n' "$PREFIX"
printf '   # or add to entry/build-profile.json5 externalNativeOptions.arguments:\n'
printf '   #   "-DOBS_HARMONY_PREFIX=%s"\n\n' "$PREFIX"

[ -f "$PREFIX/lib/libobs.so" ] || die "staging failed: $PREFIX/lib/libobs.so missing"
[ -f "$PREFIX/include/obs/obs.h" ] || die "staging failed: $PREFIX/include/obs/obs.h missing"

log "OK — libobs.so and obs.h are in place; HAVE_LIBOBS will be enabled."
printf '   HAP libs (%s): %s files, %s\n' "$ABI" \
    "$(find "$HAP_LIBS" -name '*.so*' | wc -l | tr -d ' ')" \
    "$(du -sh "$HAP_LIBS" | cut -f1)"
