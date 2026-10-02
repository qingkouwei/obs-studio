#!/usr/bin/env bash
# anr-repro.sh — 复现并取证"坏态 obs_reset_video 阻塞 51s"专项（任务20）
#
# 已确诊现场：反复"采集会话启停 + 应用焦点切换"后，libobs 启动路径的
# obs_reset_video 主线程阻塞（THREAD_BLOCK_3S durationTime:51168）被系统杀。
# 本脚本自动化搓坏态 + 抓 faultlogger 完整栈，产出归因所需数据：
#   - 主线程卡在哪个调用（faultlog 栈顶帧）
#   - AVScreenCapture 会话销毁/重建时序（hilog）
#   - 阻塞期间 system_server/graphic 侧有无对应报错
#
# Usage: ./anr-repro.sh [rounds=6]
set -uo pipefail
HDC="${HDC:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc}"
DEV="${OBS_HARMONY_DEVICE:-192.168.0.101:46729}"
BUNDLE=com.obsproject.studio.harmony
ROUNDS="${1:-6}"

shell(){ "$HDC" tconn "$DEV" >/dev/null 2>&1; "$HDC" shell "$@" 2>/dev/null | tr -d '\r'; }
tap(){ shell "uitest uiInput click $1 $2" >/dev/null; }
find_text(){
    shell "uitest dumpLayout -p /data/local/tmp/_a.json >/dev/null; cat /data/local/tmp/_a.json" | WANT="$1" python3 -c "
import json,re,sys,os
raw=sys.stdin.read(); i=raw.find('{')
d=json.loads(raw[i:]) if i>=0 else {}
w=os.environ['WANT']; out=[]
def walk(n):
    a=n.get('attributes',{})
    if a.get('text','')==w:
        m=re.findall(r'-?\d+',a.get('bounds',''))
        if len(m)==4: x1,y1,x2,y2=map(int,m); out.append(((x1+x2)//2,(y1+y2)//2))
    for c in n.get('children',[]): walk(c)
walk(d)
if out: print(out[0][0],out[0][1])
" 2>/dev/null; }
tap_text(){ local p; p="$(find_text "$1")"; [ -n "$p" ] && { tap $p; return 0; }; return 1; }

echo "[0] 唤醒设备并清日志基线"
shell "power-shell wakeup" >/dev/null
shell "hilog -r" >/dev/null
shell "aa force-stop $BUNDLE" >/dev/null

for ((r=1; r<=ROUNDS; r++)); do
    echo "[round $r/$ROUNDS] start → share → stop → background → foreground"
    shell "aa start -a EntryAbility -b $BUNDLE" >/dev/null
    sleep 6
    tap_text "允许" >/dev/null 2>&1 || true
    sleep 1
    tap_text "捕获屏幕" >/dev/null 2>&1 || tap_text "Display" >/dev/null 2>&1 || true
    sleep 3
    tap_text "开始共享" >/dev/null 2>&1 || true
    sleep 2
    # 焦点切换：按 home 再拉回
    shell "uitest uiInput keyEvent Home" >/dev/null
    sleep 1
    shell "aa start -a EntryAbility -b $BUNDLE" >/dev/null
    sleep 2
    # 停会话（若还在）+ 杀应用快速重开 = 会话销毁重建压力
    tap_text "停止共享" >/dev/null 2>&1 || true
    sleep 1
    shell "aa force-stop $BUNDLE" >/dev/null
    sleep 1
done

echo "[F] 抓取 faultlog 与关键日志"
shell "ls -lt /data/log/faultlog/faultlogger/ 2>/dev/null | head -6"
NEWEST=$(shell "ls -t /data/log/faultlog/faultlogger/*${BUNDLE}* /data/log/faultlog/temp/*${BUNDLE}* 2>/dev/null | head -1")
if [ -n "$NEWEST" ]; then
    echo "=== newest faultlog: $NEWEST ==="
    shell "cat $NEWEST" | head -120
    "$HDC" tconn "$DEV" >/dev/null 2>&1
    "$HDC" file recv "$NEWEST" /tmp/anr-faultlog.txt 2>/dev/null | tail -1
fi
echo "=== obs_bridge timeline ==="
shell "hilog -x | grep -E 'obs_bridge' | grep -iE 'begin|coreOk|end|reset_video|encoder|capture' | tail -30"
echo "=== THREAD_BLOCK events ==="
shell "hilog -x | grep -iE 'THREAD_BLOCK|AppDfr|freeze' | tail -8"
echo done
