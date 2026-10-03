#!/usr/bin/env bash
# C5 live-window verification — robust against the device dropping its
# wireless session mid-run. Each step re-establishes the hdc connection.
DEV="192.168.0.100:35565"
BUNDLE="com.obsproject.studio.harmony"
HAP="/Users/shen/Documents/commission/OBS/obs-studio/harmony/entry/build/default/outputs/default/entry-default-signed.hap"
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc

conn(){ timeout 12 $HDC tconn $DEV >/dev/null 2>&1; }
shell(){ conn; timeout 15 $HDC shell "$@" 2>/dev/null | tr -d '\r'; }
dump(){ conn; timeout 20 $HDC shell "uitest dumpLayout -p /data/local/tmp/_v.json >/dev/null; cat /data/local/tmp/_v.json" 2>/dev/null | tr -d '\r'; }

# tap a button by exact text; retries across a reconnect
tapbtn(){
  local want="$1" p x y
  p=$(dump | WANT="$want" python3 -c "
import json,re,sys,os
raw=sys.stdin.read(); i=raw.find('{')
if i<0: sys.exit()
d=json.loads(raw[i:])
w=os.environ['WANT']; out=[]
def walk(n):
    a=n.get('attributes',{})
    if a.get('text','')==w:
        m=re.findall(r'-?\d+',a.get('bounds',''))
        if len(m)==4: x1,y1,x2,y2=map(int,m); out.append(((x1+x2)//2,(y1+y2)//2))
    for c in n.get('children',[]): walk(c)
walk(d)
if out: print(out[0][0],out[0][1])" 2>/dev/null)
  if [ -n "$p" ]; then
    x=${p%% *}; y=${p##* }
    shell "uitest uiInput click $x $y" >/dev/null
    echo "  tap '$want' @ $x,$y"; return 0
  fi
  echo "  MISS '$want'"; return 1
}

echo "=== [install] ==="
conn; timeout 60 $HDC install -r "$HAP" 2>&1 | tail -1

echo "=== [boot] ==="
shell "power-shell wakeup" >/dev/null; sleep 1
shell "uitest uiInput swipe 1560 1800 1560 400 200" >/dev/null; sleep 1
shell "hilog -r; aa force-stop $BUNDLE" >/dev/null; sleep 1
shell "aa start -a EntryAbility -b $BUNDLE" >/dev/null; sleep 9
echo "  pid: $(shell "pidof $BUNDLE")"

echo "=== [setup sources] ==="
# multiple privacy dialogs can stack (mic/camera/screen); loop until gone
miss=0; while [ $miss -lt 3 ]; do if tapbtn "允许"; then miss=0; sleep 2; else miss=$((miss+1)); fi; done
tapbtn "捕获屏幕" && sleep 3
tapbtn "开始共享" && sleep 3

echo "=== [record -> C5 start] ==="
shell "hilog -r" >/dev/null
tapbtn "开始录制" && sleep 7
echo "--- LiveView log (start) ---"
shell "hilog -x | grep -iE 'LiveView|live_view' | grep -vE 'AppKit|pc 0'" | tail -8

echo "--- screenshot mid-recording ---"
shell "snapshot_display -f /data/local/tmp/_c5.jpeg" >/dev/null
conn; timeout 30 $HDC file recv /data/local/tmp/_c5.jpeg /tmp/c5-mid.jpeg 2>&1 | tail -1

echo "=== [stop -> start -> stop: entitlement-classify + disable-once] ==="
tapbtn "停止录制" && sleep 3
tapbtn "开始录制" && sleep 4
# after start succeeds the same button reads 停止录制 — re-find each time
tapbtn "停止录制" || tapbtn "开始录制" && sleep 2
echo "PARAMETER-error count: $(shell "hilog -x | grep -c 'PARAMETER error'")"
echo "capsule-started count: $(shell "hilog -x | grep -c 'capsule started'")"
echo "live-disabled count:   $(shell "hilog -x | grep -c 'live window disabled'")"
echo "--- any new layer-401 field ---"
shell "hilog -x | grep -iE 'must be|mandatory' | grep -i live_view" | tail -3

echo "=== DONE ==="
