#!/usr/bin/env bash
# check-contracts.sh — host-side pre-flight for the class of bug that compiles
# cleanly and only fails on a device: a name that crosses a layer boundary and
# does not match on the other side.
#
# Everything here is checkable without hardware, so it belongs in the build
# rather than in the debugging session. Three real defects of exactly this shape
# were found in this port:
#   * ArkTS asked for source id 'harmony_screen_capture'; the plugin registered
#     'harmony_display_capture' — the Display button would have failed at tap.
#   * libobs's .effect shaders were staged into rawfile, which has no filesystem
#     path, so obs_reset_video() could never load them.
#   * libobs.so. (trailing dot) as a DT_NEEDED soname, which no loader resolves.
#
# Usage: ./check-contracts.sh [--hap path/to.hap] [--libs dir]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SDK_BASE="${DEVECO_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk}"
case "$SDK_BASE" in */default) SDK_BASE="${SDK_BASE%/default}" ;; esac
NATIVE="$SDK_BASE/default/openharmony/native"
NM="$NATIVE/llvm/bin/llvm-nm"
READELF="$NATIVE/llvm/bin/llvm-readelf"

ABI="arm64-v8a"
LIBS_DIR="$REPO_ROOT/harmony/entry/libs/$ABI"
HAP=""

while [ $# -gt 0 ]; do
    case "$1" in
        --hap)  HAP="$2"; shift 2 ;;
        --libs) LIBS_DIR="$2"; shift 2 ;;
        --abi)  ABI="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; WARN=$((WARN+1)); }
head_(){ printf '\n\033[1m%s\033[0m\n' "$*"; }

[ -x "$NM" ] || { echo "ERROR: llvm-nm not found at $NM" >&2; exit 1; }
[ -d "$LIBS_DIR" ] || { echo "ERROR: no libs dir at $LIBS_DIR (run build-obs.sh)" >&2; exit 1; }

# ---------------------------------------------------------------------------
head_ "1. Source / encoder / output ids referenced vs registered"
# ---------------------------------------------------------------------------
# Ids that libobs resolves by string at runtime. Collect what the ArkTS UI and
# the C++ bridge ask for, then what the built plugins actually register.
REFERENCED="$(
    {
        grep -rhoE "addSource\('[a-z0-9_]+'\)" "$REPO_ROOT/harmony/entry/src/main/ets" 2>/dev/null \
            | sed "s/addSource('//;s/')//"
        grep -rhoE "id: '[a-z0-9_]+'" "$REPO_ROOT/harmony/entry/src/main/ets" 2>/dev/null \
            | sed "s/id: '//;s/'//"
        grep -rhoE 'obs_video_encoder_create\("[a-z0-9_]+"|obs_audio_encoder_create\("[a-z0-9_]+"|obs_output_create\("[a-z0-9_]+"|obs_source_create(_private)?\("[a-z0-9_]+"' \
            "$REPO_ROOT/harmony/entry/src/main/cpp" 2>/dev/null \
            | sed 's/.*("//;s/"$//'
        # The encoder fallback list is written as a plain array of ids.
        grep -rhoE '\{"harmony_h264", "obs_x264"\}' "$REPO_ROOT/harmony/entry/src/main/cpp" 2>/dev/null \
            | tr -d '{}"' | tr ',' '\n' | tr -d ' '
    } | grep -vE '^$' | sort -u
)"

# Ids a plugin registers appear as plain strings in its .so. Checking the binary
# rather than the source means a plugin that failed to build is caught here.
REGISTERED="$(
    for so in "$LIBS_DIR"/*.so; do
        strings -a "$so" 2>/dev/null
    done | grep -E '^[a-z][a-z0-9_]*$' | sort -u
)"

missing=0
for id in $REFERENCED; do
    if printf '%s\n' "$REGISTERED" | grep -x "$id" >/dev/null; then
        ok "id '$id' is registered by a built library"
    else
        bad "id '$id' is referenced but NOT registered by any library in $LIBS_DIR"
        missing=$((missing+1))
    fi
done
[ "$missing" -eq 0 ] || echo "        (an unregistered id makes obs_source_create/obs_*_encoder_create return NULL at runtime)"

# ---------------------------------------------------------------------------
head_ "2. Every plugin exports obs_module_load"
# ---------------------------------------------------------------------------
for so in "$LIBS_DIR"/*.so; do
    base="$(basename "$so")"
    # Core libraries and third-party runtime libs are not OBS plugins; only
    # check the ones libobs will dlopen as modules.
    case "$base" in
        libobs.so|libobs-opengl.so|libobs_bridge.so|libc++_shared.so) continue ;;
        libav*.so*|libsw*.so*) continue ;;
    esac
    if "$NM" -D --defined-only "$so" 2>/dev/null | grep -E " obs_module_load$" >/dev/null; then
        ok "$base"
    else
        bad "$base has no obs_module_load — libobs will reject it (MODULE_MISSING_EXPORTS)"
    fi
done

# ---------------------------------------------------------------------------
head_ "3. libobs data files the core loads at obs_reset_video()"
# ---------------------------------------------------------------------------
RAWFILE="$REPO_ROOT/harmony/entry/src/main/resources/rawfile"
# obs.c requests these by name through obs_find_data_file(); if any is missing
# the video subsystem fails to initialise and the app renders nothing.
EFFECTS="$(grep -rhoE 'obs_find_data_file\("[a-z_0-9]+\.effect"\)' "$REPO_ROOT/libobs/obs.c" 2>/dev/null \
            | sed 's/.*("//;s/")//' | sort -u)"
if [ -z "$EFFECTS" ]; then
    warn "could not extract the .effect list from libobs/obs.c"
else
    for e in $EFFECTS; do
        if [ -f "$RAWFILE/libobs/$e" ]; then
            ok "rawfile/libobs/$e"
        else
            bad "rawfile/libobs/$e MISSING — obs_reset_video() will fail and nothing renders"
        fi
    done
fi

# ---------------------------------------------------------------------------
head_ "4. DT_NEEDED closure resolves"
# ---------------------------------------------------------------------------
SYSROOT_LIB="$NATIVE/sysroot/usr/lib/$ABI"
case "$ABI" in
    arm64-v8a)   SYSROOT_LIB="$NATIVE/sysroot/usr/lib/aarch64-linux-ohos" ;;
    armeabi-v7a) SYSROOT_LIB="$NATIVE/sysroot/usr/lib/arm-linux-ohos" ;;
    x86_64)      SYSROOT_LIB="$NATIVE/sysroot/usr/lib/x86_64-linux-ohos" ;;
esac

unresolved=0
for so in "$LIBS_DIR"/*.so*; do
    for need in $("$READELF" -d "$so" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'); do
        case "$need" in
            *.) bad "$(basename "$so") needs '$need' — a soname with a trailing dot never resolves"; unresolved=$((unresolved+1)); continue ;;
        esac
        if [ -e "$LIBS_DIR/$need" ] || [ -e "$SYSROOT_LIB/$need" ]; then
            :
        else
            bad "$(basename "$so") needs '$need' — not bundled and not in the device sysroot"
            unresolved=$((unresolved+1))
        fi
    done
done
[ "$unresolved" -eq 0 ] && ok "every DT_NEEDED is either bundled or provided by the device"

# ---------------------------------------------------------------------------
head_ "5. HAP contents (skipped if no HAP given)"
# ---------------------------------------------------------------------------
if [ -z "$HAP" ]; then
    HAP="$(find "$REPO_ROOT/harmony/entry/build" -name '*.hap' 2>/dev/null | head -1)"
fi
if [ -n "$HAP" ] && [ -f "$HAP" ]; then
    printf '        %s (%s)\n' "$(basename "$HAP")" "$(du -h "$HAP" | cut -f1)"
    HAPLIST="$(unzip -l "$HAP" 2>/dev/null)"

    for so in "$LIBS_DIR"/*.so; do
        base="$(basename "$so")"
        if printf '%s' "$HAPLIST" | grep "libs/$ABI/$base" >/dev/null; then
            :
        else
            bad "$base is staged but NOT inside the HAP"
        fi
    done
    ok "all staged libraries are present in the HAP"

    n_eff="$(printf '%s' "$HAPLIST" | grep -c '\.effect' || true)"
    if [ "$n_eff" -gt 0 ]; then ok "$n_eff .effect shaders packed"; else bad "no .effect shaders in the HAP"; fi

    # extractNativeLibs must be true or libobs cannot dlopen its plugins by path.
    if unzip -p "$HAP" module.json 2>/dev/null | grep '"extractNativeLibs"[[:space:]]*:[[:space:]]*true' >/dev/null 2>&1; then
        ok "extractNativeLibs is true (required for os_dlopen of plugins)"
    else
        bad "extractNativeLibs is not true — plugins stay inside the HAP and os_dlopen cannot reach them"
    fi
else
    warn "no HAP found; run build-obs.sh first"
fi

# ---------------------------------------------------------------------------
head_ "Result"
# ---------------------------------------------------------------------------
printf '  PASS %d   FAIL %d   WARN %d\n' "$PASS" "$FAIL" "$WARN"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
