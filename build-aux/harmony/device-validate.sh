#!/usr/bin/env bash
# device-validate.sh — install, launch and assert against a real HarmonyOS
# device or emulator, then print a per-subsystem PASS/FAIL report.
#
# Turns an open-ended debugging session into one command. Designed to be run
# twice: once against a phone (available now, same arm64-v8a ABI and API 26) and
# once against the PC/2in1 target.
#
# Usage:
#   ./device-validate.sh                     # auto-pick the unsigned/signed HAP
#   ./device-validate.sh --hap path/to.hap
#   ./device-validate.sh --keep-open 60      # leave the app in foreground 60s
#   ./device-validate.sh --skip-install
#
# Requires a debug-signed HAP for a physical device (code 9568320
# "no signature file" otherwise). Emulators accept unsigned HAPs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BUNDLE="com.obsproject.studio.harmony"
ABILITY="EntryAbility"
DOMAIN_HEX="b50"
KEEP_OPEN=25

SDK_BASE="${DEVECO_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk}"
case "$SDK_BASE" in */default) SDK_BASE="${SDK_BASE%/default}" ;; esac
HDC="$SDK_BASE/default/openharmony/toolchains/hdc"

HAP=""
SKIP_INSTALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --hap)          HAP="$2"; shift 2 ;;
        --keep-open)    KEEP_OPEN="$2"; shift 2 ;;
        --skip-install) SKIP_INSTALL=1; shift ;;
        -h|--help)      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

[ -x "$HDC" ] || { echo "ERROR: hdc not found at $HDC" >&2; exit 1; }

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; WARN=$((WARN+1)); }
head_(){ printf '\n\033[1m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
head_ "1. Device"
# ---------------------------------------------------------------------------
TARGET="$("$HDC" list targets 2>/dev/null | head -1 | tr -d '\r' | sed 's/[[:space:]]*$//')"
if [ -z "$TARGET" ] || [ "$TARGET" = "[Empty]" ]; then
    bad "no device/emulator connected (hdc list targets is empty)"
    echo
    echo "Plug in the device with USB debugging enabled and the screen UNLOCKED,"
    echo "then confirm it is visible before re-running:"
    echo "    hdc list targets        # must print a serial, not [Empty]"
    echo
    echo "Note: hdc returns exit 0 even with no device attached and prints"
    echo "'[Fail]ExecuteCommand need connect-key' on stdout, so do not trust the"
    echo "exit code of an hdc command on its own."
    exit 1
fi
ok "target: $TARGET"

DTYPE="$("$HDC" shell param get const.product.devicetype 2>/dev/null | tr -d '\r\n ')"
API="$("$HDC" shell param get const.ohos.apiversion 2>/dev/null | tr -d '\r\n ')"
MODEL="$("$HDC" shell param get const.product.model 2>/dev/null | tr -d '\r\n ')"
ABI="$("$HDC" shell param get const.product.cpu.abilist 2>/dev/null | tr -d '\r\n ')"
printf '        model=%s  deviceType=%s  api=%s  abi=%s\n' "$MODEL" "$DTYPE" "$API" "$ABI"

case "$DTYPE" in
    2in1|pc) ok "device is a PC/2in1 — the real migration target" ;;
    phone|tablet) warn "device is '$DTYPE', not the PC/2in1 target. Validates the native
        stack (ABI $ABI, API $API) but not PC windowing or Desktop Extension Kit." ;;
    *) warn "unrecognised deviceType '$DTYPE'" ;;
esac

case "$ABI" in
    *arm64-v8a*) ok "ABI arm64-v8a matches the built libraries" ;;
    *) bad "ABI '$ABI' does not include arm64-v8a — the bundled .so cannot load" ;;
esac

if [ "$API" != "26" ] && [ -n "$API" ]; then
    warn "device API is $API but the SDK builds against 26; API-26-only features
        (notably audio playback capture) may be unavailable"
fi

# ---------------------------------------------------------------------------
head_ "2. Install"
# ---------------------------------------------------------------------------
if [ -z "$HAP" ]; then
    HAP_DIR="$REPO_ROOT/harmony/entry/build/default/outputs/default"
    # Prefer a signed HAP; fall back to unsigned (emulators accept it).
    # `ls -t` is deliberate: we want the most recent build, and these filenames
    # are produced by hvigor so they contain no spaces or glob characters.
    # shellcheck disable=SC2012
    HAP="$(ls -t "$HAP_DIR"/entry-default-signed.hap 2>/dev/null | head -1)"
    # shellcheck disable=SC2012
    [ -n "$HAP" ] || HAP="$(ls -t "$HAP_DIR"/*.hap 2>/dev/null | head -1)"
fi

if [ "$SKIP_INSTALL" -eq 1 ]; then
    warn "skipping install (--skip-install)"
elif [ -z "$HAP" ] || [ ! -f "$HAP" ]; then
    bad "no HAP found; run ./build-obs.sh first"
else
    printf '        %s (%s)\n' "$(basename "$HAP")" "$(du -h "$HAP" | cut -f1)"
    INSTALL_OUT="$("$HDC" install -r "$HAP" 2>&1)"
    if printf '%s' "$INSTALL_OUT" | grep -q "no signature file"; then
        bad "HAP is unsigned — physical devices reject it (code 9568320)"
        echo "        Sign it in DevEco Studio: File > Project Structure > Signing"
        echo "        Configs > tick 'Automatically generate signature'."
    elif printf '%s' "$INSTALL_OUT" | grep -qiE "successfully|install bundle success"; then
        ok "installed"
    else
        bad "install failed:"
        printf '%s\n' "$INSTALL_OUT" | sed 's/^/        /' | head -5
    fi
fi

# ---------------------------------------------------------------------------
head_ "3. Native libraries extracted into the sandbox"
# ---------------------------------------------------------------------------
# extractNativeLibs must be true for libobs's os_dlopen() to reach the plugins.
SANDBOX="/data/app/el1/bundle/public/$BUNDLE/libs/arm64-v8a"
LS_OUT="$("$HDC" shell "ls $SANDBOX 2>/dev/null" 2>/dev/null | tr -d '\r')"
if [ -n "$LS_OUT" ]; then
    N_SO="$(printf '%s\n' "$LS_OUT" | grep -c '\.so' || true)"
    if [ "${N_SO:-0}" -gt 0 ]; then
        ok "$N_SO native libraries extracted to $SANDBOX"
    else
        bad "$SANDBOX exists but holds no .so — extractNativeLibs did not take effect"
    fi
    for expect in libobs.so libobs-opengl.so libobs_bridge.so obs-outputs.so obs-x264.so \
                  harmony-capture.so harmony-audio.so harmony-vcodec.so libavcodec.so.61; do
        if printf '%s\n' "$LS_OUT" | grep -qx "$expect"; then
            ok "  present: $expect"
        else
            bad "  MISSING: $expect"
        fi
    done
else
    warn "could not list $SANDBOX (may need root, or the bundle is not installed)"
fi

# ---------------------------------------------------------------------------
head_ "4. Launch and capture logs"
# ---------------------------------------------------------------------------
"$HDC" shell hilog -r >/dev/null 2>&1
"$HDC" shell "aa force-stop $BUNDLE" >/dev/null 2>&1

START_OUT="$("$HDC" shell "aa start -a $ABILITY -b $BUNDLE" 2>&1 | tr -d '\r')"
if printf '%s' "$START_OUT" | grep -qiE "error|fail"; then
    bad "aa start reported an error:"
    printf '%s\n' "$START_OUT" | sed 's/^/        /' | head -4
else
    ok "launched $BUNDLE/$ABILITY"
fi

printf '        collecting %ss of hilog...\n' "$KEEP_OPEN"
LOGFILE="$(mktemp -t obsvalidate.XXXXXX)"
"$HDC" shell "hilog -x" > "$LOGFILE" 2>&1 &
HILOG_PID=$!
sleep "$KEEP_OPEN"
kill "$HILOG_PID" 2>/dev/null
wait "$HILOG_PID" 2>/dev/null
printf '        captured %s lines\n' "$(wc -l < "$LOGFILE" | tr -d ' ')"

# Our own log lines (native tag obs_bridge, ArkTS tag ObsHarmony, domain 0xB50).
OBSLOG="$(grep -iE "obs_bridge|ObsHarmony|$DOMAIN_HEX" "$LOGFILE" 2>/dev/null || true)"

# ---------------------------------------------------------------------------
head_ "5. Process health"
# ---------------------------------------------------------------------------
PID="$("$HDC" shell "pidof $BUNDLE" 2>/dev/null | tr -d '\r\n ' | awk '{print $1}')"
if [ -n "$PID" ] && [ "$PID" != "0" ]; then
    ok "process alive (pid $PID) after ${KEEP_OPEN}s — no startup crash"
else
    bad "process is NOT running — the app crashed or failed to start"
fi

# Native crash / appfreeze records written since we launched.
FAULTS="$("$HDC" shell "ls -t /data/log/faultlog/faultlogger/ 2>/dev/null | head -5" 2>/dev/null | tr -d '\r')"
if printf '%s' "$FAULTS" | grep -qi "$BUNDLE"; then
    bad "a fault log exists for this bundle:"
    printf '%s\n' "$FAULTS" | grep -i "$BUNDLE" | head -3 | sed 's/^/        /'
    echo "        pull it with: hdc file recv /data/log/faultlog/faultlogger/<name> ."
else
    ok "no faultlog entry for $BUNDLE"
fi

if grep -qiE "dlopen.*failed|cannot locate symbol|CANNOT LINK EXECUTABLE" "$LOGFILE" 2>/dev/null; then
    bad "dynamic linker error detected:"
    grep -iE "dlopen.*failed|cannot locate symbol|CANNOT LINK EXECUTABLE" "$LOGFILE" \
        | head -4 | sed 's/^/        /'
else
    ok "no dlopen / symbol resolution failures"
fi

# ---------------------------------------------------------------------------
head_ "6. Subsystem assertions (from app logs)"
# ---------------------------------------------------------------------------
assert_log() { # <label> <regex>
    if printf '%s' "$OBSLOG" | grep -qiE "$2"; then ok "$1"; else bad "$1 (no log match for /$2/)"; fi
}
note_log() { # <label> <regex> — informational, counts as WARN when absent
    if printf '%s' "$OBSLOG" | grep -qiE "$2"; then ok "$1"; else warn "$1 — not observed"; fi
}

if [ -z "$OBSLOG" ]; then
    warn "no obs_bridge/ObsHarmony log lines captured at all.
        Either the app did not reach its native init, or hilog needs
        'hdc shell hilog -b D' to lower the level. Raw tail:"
    tail -15 "$LOGFILE" | sed 's/^/        /'
else
    assert_log "libobs core started (obs_startup)"        "obs_startup|libobs|OBS core"
    note_log   "graphics module loaded"                   "libobs-opengl|graphics module|gs_create"
    note_log   "EGL initialised"                          "EGL|eglInitialize|HarmonyOS EGL"
    note_log   "GLES renderer string reported"            "GL_RENDERER|GLES|Adreno|Maleoon|renderer"
    note_log   "XComponent surface attached"              "surface|NativeWindow|XComponent"
    note_log   "plugin(s) registered"                     "obs_register|module load|plugin"
    # This is the open question from docs/harmonyos-migration.md §7.4: whether
    # SystemCapability.Multimedia.Audio.PlaybackCapture exists on this device.
    note_log   "system-audio loopback (内录) probe result" "PlaybackCapture|canCaptureSystemAudio|loopback|内录"
    note_log   "AVScreenCapture available"                "AVScreenCapture|screen capture|display capture"
    note_log   "hardware encoder probed"                  "VideoEncoder|AVCodec|h264|hevc"
fi

# ---------------------------------------------------------------------------
head_ "7. Device capability probe (independent of the app)"
# ---------------------------------------------------------------------------
# hdc returns exit 0 even when no device is attached — it prints
# "[Fail]ExecuteCommand need connect-key ..." on stdout instead. Test the output,
# not the status.
_probe="$("$HDC" shell "param get const.ohos.apiversion" 2>&1 | tr -d '\r')"
if ! printf '%s' "$_probe" | grep -qE '^[0-9]+$'; then
    bad "device became unreachable (hdc says: $(printf '%s' "$_probe" | head -c 80))."
    echo "        Reconnect / re-authorise USB debugging (or unlock the screen),"
    echo "        confirm with: hdc list targets"
    printf '\n  PASS %d   FAIL %d   WARN %d\n' "$PASS" "$FAIL" "$WARN"
    exit 1
fi
# Syscaps are exposed as system parameters named const.SystemCapability.<X>.
# There is no `canIUse` shell command — that is an ArkTS API — so query param
# directly. This answers the capability questions without needing the app to
# install, which matters because an unsigned HAP cannot be installed on a
# physical device at all.
probe_syscap() { # <SystemCapability.X.Y>
    local cap="$1" out
    out="$("$HDC" shell "param get const.SystemCapability.$cap" 2>/dev/null | tr -d '\r\n ')"
    case "$out" in
        true)  ok "$cap" ;;
        false) bad "$cap = false on this device" ;;
        *)     warn "$cap — not declared by this device" ;;
    esac
}

echo "        graphics (the GLES/EGL backend depends on all of these):"
probe_syscap "Graphic.Graphic2D.EGL"
probe_syscap "Graphic.Graphic2D.GLES3"
probe_syscap "Graphic.Graphic2D.NativeWindow"
probe_syscap "Graphic.Graphic2D.NativeBuffer"
# NativeImage is the zero-copy capture->GL-texture path deferred in §7 of the
# migration doc. If this is true it is worth implementing.
probe_syscap "Graphic.Graphic2D.NativeImage"

echo "        capture / encode:"
probe_syscap "Multimedia.Media.AVScreenCapture"
probe_syscap "Multimedia.Media.VideoEncoder"
probe_syscap "Multimedia.Audio.Core"
probe_syscap "Multimedia.Camera.Core"

# The open question from docs/harmonyos-migration.md §7.4: official docs list
# PlaybackCapture (system-audio loopback, "内录") for Phone/Tablet/TV only and
# say PC/2in1 must be probed at runtime. This is that probe.
echo "        desktop-audio loopback (the §7.4 open question):"
probe_syscap "Multimedia.Audio.PlaybackCapture"

echo "        windowing:"
probe_syscap "Window.SessionManager"

# text-freetype2's OHOS font back end (plugins/text-freetype2/find-font-ohos.c)
# enumerates faces by scanning these directories. If the HAP sandbox cannot read
# them, load_os_font_list() finds nothing and every text source renders blank —
# with no error at startup, only a "no fonts found" log line. This is the single
# point of failure for the text source, so probe it explicitly.
echo "        font discovery for text-freetype2:"
for d in /system/fonts /system/font /data/service/el1/public/fonts; do
    out="$("$HDC" shell "ls $d 2>/dev/null" 2>/dev/null | tr -d '\r')"
    # An hdc transport failure prints "[Fail]ExecuteCommand ..." on stdout, which
    # a bare non-empty test would mistake for a directory listing. Only count it
    # as readable when the listing actually contains font files.
    fonts="$(printf '%s\n' "$out" | grep -icE '\.(ttf|ttc|otf)$' || true)"
    if [ "${fonts:-0}" -gt 0 ]; then
        ok "$d readable ($fonts font file(s))"
    elif printf '%s' "$out" | grep -qiE '^\[Fail\]|need connect|connect-key'; then
        bad "$d — hdc transport error, device not reachable"
    else
        warn "$d is empty or unreadable from the shell"
    fi
done
# A shell ls proves the path exists, but the app runs in a restricted sandbox, so
# also confirm at least one usable font file is present by name.
if "$HDC" shell "ls /system/fonts 2>/dev/null" 2>/dev/null | tr -d '\r' | grep -qiE '\.(ttf|ttc|otf)$'; then
    ok "font files (.ttf/.ttc/.otf) present in /system/fonts"
else
    bad "no .ttf/.ttc/.otf found in /system/fonts — text sources will render blank"
fi

# ---------------------------------------------------------------------------
head_ "Result"
# ---------------------------------------------------------------------------
printf '  PASS %d   FAIL %d   WARN %d\n\n' "$PASS" "$FAIL" "$WARN"
echo "  Full hilog: $LOGFILE"
echo "  App-only lines:"
printf '%s\n' "$OBSLOG" | tail -25 | sed 's/^/    /'
echo
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
