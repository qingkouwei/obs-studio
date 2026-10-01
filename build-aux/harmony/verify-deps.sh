#!/usr/bin/env bash
#
# verify-deps.sh — fast validator for a HarmonyOS dependency prefix produced
# by build-deps.sh. Checks artifact presence, ELF architecture, dynamic
# linkage sanity, and key exported symbols. Exits non-zero on any failure.
#
# Usage: ./verify-deps.sh [--prefix DIR] [--arch arm64-v8a] [--sdk DIR]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PREFIX="$REPO_ROOT/.deps-harmony"
OHOS_ARCH="arm64-v8a"
SDK_HOME="${DEVECO_SDK_HOME:-}"
TOOLCHAIN_VARIANT="openharmony"

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --arch)   OHOS_ARCH="$2"; shift 2 ;;
        --sdk)    SDK_HOME="$2"; shift 2 ;;
        --toolchain) TOOLCHAIN_VARIANT="$2"; shift 2 ;;
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

case "$OHOS_ARCH" in
    arm64-v8a)   TRIPLE="aarch64-linux-ohos";       EXPECTED_FILE="ARM aarch64"; EXPECTED_MACHINE="AArch64" ;;
    armeabi-v7a) TRIPLE="armv7-unknown-linux-ohos"; EXPECTED_FILE="ARM,";        EXPECTED_MACHINE="ARM" ;;
    x86_64)      TRIPLE="x86_64-linux-ohos";        EXPECTED_FILE="x86-64";      EXPECTED_MACHINE="X86-64" ;;
    *) echo "Unknown --arch: $OHOS_ARCH" >&2; exit 2 ;;
esac

# Locate SDK llvm-nm/llvm-readelf (same discovery as build-deps.sh).
case "$TOOLCHAIN_VARIANT" in
    openharmony) VARIANT_DIR="openharmony" ;;
    hmos)        VARIANT_DIR="hms" ;;
    *) echo "Unknown --toolchain: $TOOLCHAIN_VARIANT" >&2; exit 2 ;;
esac
LLVM_BIN=""
_sdk_candidates=()
if [ -n "$SDK_HOME" ]; then
    _sdk_candidates+=("$SDK_HOME" "$SDK_HOME/default")
fi
_sdk_candidates+=("/Applications/DevEco-Studio.app/Contents/sdk" \
                  "/Applications/DevEco-Studio.app/Contents/sdk/default")
for _base in "${_sdk_candidates[@]}"; do
    if [ -x "$_base/$VARIANT_DIR/native/llvm/bin/llvm-nm" ]; then
        LLVM_BIN="$_base/$VARIANT_DIR/native/llvm/bin"
        break
    fi
    if [ -x "$_base/$VARIANT_DIR/native/BiSheng/bin/llvm-nm" ]; then
        LLVM_BIN="$_base/$VARIANT_DIR/native/BiSheng/bin"
        break
    fi
done
[ -n "$LLVM_BIN" ] || { echo "ERROR: SDK llvm tools not found; set DEVECO_SDK_HOME or --sdk" >&2; exit 2; }
NM="$LLVM_BIN/llvm-nm"
READELF="$LLVM_BIN/llvm-readelf"

FAILURES=0
CHECKS=0

pass() { CHECKS=$((CHECKS+1)); printf 'PASS  %s\n' "$1"; }
fail() { CHECKS=$((CHECKS+1)); FAILURES=$((FAILURES+1)); printf 'FAIL  %s\n' "$1"; }

check_file() {
    if [ -e "$1" ]; then pass "exists: ${1#"$PREFIX"/}"; else fail "missing: ${1#"$PREFIX"/}"; fi
}

# check_elf <path> — confirm `file` reports the expected target architecture.
check_elf() {
    local f="$1" desc
    if [ ! -e "$f" ]; then fail "missing: ${f#"$PREFIX"/}"; return; fi
    desc="$(file -b "$f")"
    case "$desc" in
        *"$EXPECTED_FILE"*) pass "arch ok (${EXPECTED_FILE}): $(basename "$f")" ;;
        *) fail "wrong arch: $(basename "$f") -> $desc" ;;
    esac
}

# check_symbol <lib-path> <symbol-prefix> [nm-args...] — look for a defined
# (T/D/B/W) symbol. Static libs use plain nm, shared libs use nm -D.
check_symbol() {
    local lib="$1" sym="$2"; shift 2
    if [ ! -e "$lib" ]; then fail "missing lib for symbol $sym: ${lib#"$PREFIX"/}"; return; fi
    # No grep -q here: it exits on first match and closes the pipe, which kills
    # llvm-nm with SIGPIPE. Under `set -o pipefail` that non-zero status would
    # override grep's success and report every symbol as missing.
    if "$NM" "$@" "$lib" 2>/dev/null | grep -E "[TDBW] _?${sym}" >/dev/null; then
        pass "symbol $sym in $(basename "$lib")"
    else
        fail "symbol $sym NOT found in $(basename "$lib")"
    fi
}

# check_archive_arch <path> — `file` reports "current ar archive" for a static
# library, so the ELF architecture has to come from the members instead. Fails if
# any member targets something other than $EXPECTED_MACHINE, which is how a
# host-architecture object sneaking into the archive would show up.
check_archive_arch() {
    local f="$1" bad
    if [ ! -e "$f" ]; then fail "missing: ${f#"$PREFIX"/}"; return; fi
    bad="$("$READELF" -h "$f" 2>/dev/null | awk '/^[ \t]*Machine:/ { if ($2 != m) { m = $2; print m } }' | grep -vx "$EXPECTED_MACHINE")"
    if [ -z "$bad" ]; then
        pass "arch ok (${EXPECTED_MACHINE}): $(basename "$f")"
    else
        fail "wrong arch member(s) in $(basename "$f"): $(echo "$bad" | tr '\n' ' ')"
    fi
}

# check_no_undefined <lib> <regex> — assert that no undefined symbol in the
# archive matches <regex>. Guards the "self-contained static library" invariant:
# a .a carries no dependency information, so an external reference to a library
# OBS's find module does not know about only surfaces later as a hard link
# failure under -Wl,--no-undefined.
check_no_undefined() {
    local lib="$1" pattern="$2" hits
    if [ ! -e "$lib" ]; then fail "missing lib for undefined-symbol scan: ${lib#"$PREFIX"/}"; return; fi
    hits="$("$NM" -u "$lib" 2>/dev/null | sed 's/^[[:space:]]*U[[:space:]]*//' | grep -E "$pattern" | sort -u | tr '\n' ' ')"
    if [ -z "$hits" ]; then
        pass "no undefined ${pattern} in $(basename "$lib")"
    else
        fail "undefined ${pattern} in $(basename "$lib"): $hits"
    fi
}

echo "Verifying HarmonyOS deps prefix: $PREFIX (arch: $OHOS_ARCH / $TRIPLE)"
echo "Using SDK binutils: $LLVM_BIN"
echo

if [ ! -d "$PREFIX" ]; then
    echo "ERROR: prefix does not exist: $PREFIX" >&2
    exit 1
fi

# --- artifacts -------------------------------------------------------------
check_file "$PREFIX/include/mbedtls/ssl.h"
check_file "$PREFIX/include/curl/curl.h"
check_file "$PREFIX/include/x264.h"
check_file "$PREFIX/include/libavcodec/avcodec.h"
check_file "$PREFIX/include/libavformat/avformat.h"
# FreeType installs under include/freetype2/ (ft2build.h alongside freetype/),
# which is the layout CMake's built-in FindFreetype.cmake expects via its
# PATH_SUFFIXES include/freetype2.
check_file "$PREFIX/include/freetype2/ft2build.h"
check_file "$PREFIX/include/freetype2/freetype/freetype.h"
check_file "$PREFIX/include/freetype2/freetype/config/ftoption.h"

check_file "$PREFIX/lib/pkgconfig/libcurl.pc"
check_file "$PREFIX/lib/pkgconfig/x264.pc"
check_file "$PREFIX/lib/pkgconfig/libavcodec.pc"
check_file "$PREFIX/lib/pkgconfig/freetype2.pc"

# Static: mbedtls (3 libs), curl, x264, freetype
check_file "$PREFIX/lib/libmbedtls.a"
check_file "$PREFIX/lib/libmbedx509.a"
check_file "$PREFIX/lib/libmbedcrypto.a"
check_file "$PREFIX/lib/libcurl.a"
check_file "$PREFIX/lib/libx264.a"
check_file "$PREFIX/lib/libfreetype.a"

# Shared: ffmpeg libs (follow the SONAME symlink). Collected into an array so
# prefixes containing spaces keep working.
FFMPEG_SOS=()
for name in avcodec avformat avutil swscale swresample avfilter avdevice; do
    so=""
    for cand in "$PREFIX"/lib/lib"$name".so*; do
        [ -e "$cand" ] || continue
        so="$cand"
        [ ! -L "$cand" ] && break   # prefer the real versioned file over symlinks
    done
    if [ -z "$so" ]; then
        fail "missing shared lib: lib$name.so.*"
        continue
    fi
    FFMPEG_SOS+=("$so")
    pass "exists: lib$name ($(basename "$so"))"
done
echo

# --- ELF architecture ------------------------------------------------------
if [ ${#FFMPEG_SOS[@]} -gt 0 ]; then
    for so in "${FFMPEG_SOS[@]}"; do check_elf "$so"; done
    echo

    # --- dynamic section sanity (SONAME present, no host-path pollution) ---
    for so in "${FFMPEG_SOS[@]}"; do
        dyn="$("$READELF" -d "$so" 2>/dev/null)"
        if echo "$dyn" | grep -q 'SONAME'; then
            pass "SONAME: $(basename "$so")"
        else
            fail "no SONAME: $(basename "$so")"
        fi
        if echo "$dyn" | grep -E 'NEEDED|RPATH|RUNPATH' | grep -qE 'homebrew|/usr/local|/opt/'; then
            fail "host contamination in dynamic section of $(basename "$so"):"
            echo "$dyn" | grep -E 'NEEDED|RPATH|RUNPATH' | grep -E 'homebrew|/usr/local|/opt/'
        else
            pass "no host paths in dynamic section: $(basename "$so")"
        fi
    done
    echo
fi

# --- key symbols ------------------------------------------------------------
# shared ffmpeg: dynamic symbol table (-D). x264_encoder_open is versioned by
# API build number (x264_encoder_open_164), hence the prefix match.
realpath_first() { # <basename-pattern> -> first matching real file, or ""
    local cand
    for cand in "$PREFIX"/lib/"$1"*; do
        [ -e "$cand" ] && { printf '%s' "$cand"; return 0; }
    done
    printf ''
}
check_symbol "$(realpath_first libavcodec.so.)"  "avcodec_open2" -D
check_symbol "$(realpath_first libavformat.so.)" "avformat_write_header" -D
check_symbol "$PREFIX/lib/libx264.a"    "x264_encoder_open"
check_symbol "$PREFIX/lib/libcurl.a"    "curl_easy_init"
check_symbol "$PREFIX/lib/libmbedtls.a" "mbedtls_ssl_init"
# The API surface plugins/text-freetype2 actually calls.
check_symbol "$PREFIX/lib/libfreetype.a" "FT_Init_FreeType"
check_symbol "$PREFIX/lib/libfreetype.a" "FT_New_Face"
check_symbol "$PREFIX/lib/libfreetype.a" "FT_Set_Pixel_Sizes"
check_symbol "$PREFIX/lib/libfreetype.a" "FT_Get_Char_Index"
check_symbol "$PREFIX/lib/libfreetype.a" "FT_Load_Glyph"
check_symbol "$PREFIX/lib/libfreetype.a" "FT_Get_Sfnt_Name"
check_symbol "$PREFIX/lib/libfreetype.a" "FT_Get_Sfnt_Name_Count"
check_archive_arch "$PREFIX/lib/libfreetype.a"
# deps/freetype.sh builds FreeType with every optional back end disabled so that
# libfreetype.a is self-contained. CMake's FindFreetype creates an UNKNOWN
# IMPORTED target with no interface link libraries, so a stray external
# reference here would only appear later as a hard link failure in
# text-freetype2.so under -Wl,--no-undefined. FreeType compiles the zlib sources
# it bundles in src/gzip/, hence `inflate` must NOT be undefined.
check_no_undefined "$PREFIX/lib/libfreetype.a" "^(inflate|inflateEnd|deflate|uncompress|compress2|adler32|crc32|hb_[a-z]|png_[a-z]|BZ2_[a-z]|BrotliDec)"
echo

if [ "$FAILURES" -ne 0 ]; then
    echo "RESULT: $FAILURES of $CHECKS checks FAILED (prefix: $PREFIX)"
    exit 1
fi
echo "RESULT: all $CHECKS checks passed (prefix: $PREFIX)"
