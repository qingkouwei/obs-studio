#!/usr/bin/env bash
# on-device-verify.sh — one-shot: unlock → clear log → launch → walk the
# first-run dialogs → add a Display capture source → confirm the share picker
# → sleep N → dump the app's own logs.
#
# Usage:
#   ./build-aux/harmony/on-device-verify.sh [--install <hap>] [seconds]
#
# Coordinates are re-discovered at run time with dumpLayout (the window moves
# every launch), so the script survives UI layout changes.
set -uo pipefail

HAP=""; WAIT=6; RECORD=0; STREAM=0
while [ $# -gt 0 ]; do
    case "$1" in
        --install) HAP="$2"; shift 2 ;;
        --record)  RECORD=1; shift ;;
        --stream)  STREAM=1; shift ;;
        *)         WAIT="$1"; shift ;;
    esac
done

DEV="${OBS_HARMONY_DEVICE:-192.168.31.75:40183}"
HDC="${HDC:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc}"
BUNDLE="com.obsproject.studio.harmony"

tconn() { "$HDC" tconn "$DEV" >/dev/null 2>&1; }
shell() { tconn; "$HDC" shell "$@" 2>/dev/null | tr -d '\r'; }

# Centre of the first node whose text equals $1; echoes "x y" or nothing.
find_text() {
    shell "uitest dumpLayout -p /data/local/tmp/_v.json >/dev/null; cat /data/local/tmp/_v.json" \
    | python3 -c "
import json,re,sys
raw=sys.stdin.read()
i=raw.find('{')
if i<0: sys.exit()
try: d=json.loads(raw[i:])
except Exception: sys.exit()
out=[]
def walk(n):
    a=n.get('attributes',{})
    if a.get('text')=='$1':
        m=re.findall(r'-?\d+', a.get('bounds',''))
        if len(m)==4:
            x1,y1,x2,y2=map(int,m)
            out.append(((x1+x2)//2,(y1+y2)//2))
    for c in n.get('children',[]): walk(c)
walk(d)
if out:
    print(out[0][0], out[0][1])
" 2>/dev/null
}

tap_text() {
    local pair cx cy
    pair="$(find_text "$1")"
    cx=${pair%% *}
    cy=$(echo "$pair" | awk '{print $2}')
    if [ -n "$cx" ] && [ -n "$cy" ]; then
        echo "  tap '$1' @ $cx,$cy"
        shell "uitest uiInput click $cx $cy" >/dev/null
        return 0
    fi
    echo "  '$1' not on screen"
    return 1
}

# wait_tap <text> <attempts> — dialogs appear asynchronously; keep looking.
wait_tap() {
    local text="$1" tries="${2:-6}" i
    for ((i = 0; i < tries; i++)); do
        tap_text "$text" && return 0
        sleep 2
    done
    return 1
}

# wait_tap_any <text1> [text2 ...] — try several labels (i18n: zh default, en fallback)
wait_tap_any() {
    local tries="${TRIES:-6}" i t
    for ((i = 0; i < tries; i++)); do
        for t in "$@"; do
            tap_text "$t" && return 0
        done
        sleep 2
    done
    return 1
}

if [ -n "$HAP" ]; then
    echo "[install] $HAP"
    tconn; "$HDC" install -r "$HAP" 2>&1 | tr -d '\r' | tail -1
fi

echo "[1] wake + unlock"
shell "power-shell wakeup" >/dev/null
sleep 1
# Two swipes: the first dismisses the always-on-display page, the second
# actually unlocks (no PIN set on this test device).
shell "uitest uiInput swipe 1560 1800 1560 400 200" >/dev/null
sleep 1
shell "uitest uiInput swipe 1560 1800 1560 400 200" >/dev/null
sleep 1

echo "[2] clear log, restart app"
shell "hilog -r; aa force-stop $BUNDLE" >/dev/null
sleep 1
shell "aa start -a EntryAbility -b $BUNDLE" | head -1
sleep 7

echo "[3] walk dialogs (允许; popups arrive staggered)"
miss=0
while [ $miss -lt 3 ]; do
    if wait_tap "允许" 2; then miss=0; sleep 2
    else miss=$((miss+1)); fi
done

echo "[4] add Display capture source"
wait_tap_any "捕获屏幕" "Display"
sleep 4

echo "[5] confirm share picker (开始共享)"
tap_text "开始共享"
sleep "$WAIT"

if [ "$STREAM" = "1" ]; then
    echo "[5a] streaming: start → ${STREAM_SECS:-10}s → stop"
    wait_tap_any "开始直播" "Start Streaming"
    sleep "${STREAM_SECS:-10}"
    shell "hilog -x | grep -iE 'streaming started|rtmp|connect' | grep obs_bridge | tail -6"
    wait_tap_any "停止直播" "Stop Streaming"
    sleep 3
fi

if [ "$RECORD" = "1" ]; then
    echo "[5b] recording: start → ${RECORD_SECS:-8}s → stop"
    wait_tap_any "开始录制" "Start Recording"
    sleep "${RECORD_SECS:-8}"
    shell "hilog -x | grep -E 'recording started|encoder|mp4|mux' | tail -6"
    wait_tap_any "停止录制" "Stop Recording"
    sleep 4
fi

echo "[6] app log tail"
shell "hilog -x | grep -E 'obs_bridge|ObsHarmony' | grep -viE 'Processor|Memory|Kernel|Operating|RawFile|is a directory' | tail -25"

echo "[7] screenshot -> /tmp/obs-verify.jpeg"
shell "snapshot_display -f /data/local/tmp/_v.jpeg" >/dev/null
tconn; "$HDC" file recv /data/local/tmp/_v.jpeg /tmp/obs-verify.jpeg 2>&1 | tail -1
echo "done"
