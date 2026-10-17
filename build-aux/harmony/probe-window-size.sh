#!/bin/bash
# HarmonyOS 窗口采集尺寸真机探测
# 用法：W=<hdc 路径> D=<ip:port> MODE=<auto|declared> $0
# 探测目标：OH_AVScreenCapture 窗口模式下 videoFrameWidth/Height 申报值与
#           返回帧实际尺寸的关系——决定"对齐桌面 OBS"的实现路线。
HDC=${W:-hdc}
DEV=${D:?需要 D=ip:port}
MODE=${MODE:-auto}   # auto = 申报 1920x1080；declared = 申报 1080x1080 非 16:9

$HDC tconn "$DEV" >/dev/null 2>&1

if [ "$MODE" = declared ]; then
  # 走设置面板不可行时备用：预先把默认值编译进包（见 window-capture.c 的改动注释）
  echo "declared 模式需要预配置包，当前脚本先走 picker 手选路线"
fi

# 1) 起 OBS，最大化
$HDC -t "$DEV" shell "power-shell wakeup; aa force-stop com.obsproject.studio.harmony; sleep 1; aa start -a EntryAbility -b com.obsproject.studio.harmony" >/dev/null 2>&1
sleep 9

# 2) 布局 dump 找"窗口采集"按钮（文字匹配，不写死坐标）
$HDC -t "$DEV" shell "uitest dumpLayout -p /data/local/tmp/wc.json" >/dev/null 2>&1
$HDC -t "$DEV" file recv /data/local/tmp/wc.json /tmp/wc.json >/dev/null 2>&1

# 布局 JSON 里窗口采集入口（不同版本按钮文字：窗口采集/捕获窗口/window）
BTN=$(python3 - << 'PY'
import json, re
try:
    d = json.load(open('/tmp/wc.json'))
except Exception:
    print('ERR'); raise SystemExit
hit = None
def walk(n):
    global hit
    a = n.get('attributes', {})
    t = a.get('text', '')
    if hit is None and ('窗口' in t or 'window' in t.lower()) and '采集' in t + a.get('description',''):
        hit = a.get('bounds')
    for c in n.get('children', []):
        walk(c)
walk(d)
if hit:
    nums = list(map(int, re.findall(r'-?\d+', hit)))
    if len(nums) == 4:
        print(f"{(nums[0]+nums[2])//2} {(nums[1]+nums[3])//2}")
    else:
        print('ERR')
else:
    print('NOTFOUND')
PY
)
echo "窗口采集按钮=[$BTN]"
[ "$BTN" = "ERR" ] || [ "$BTN" = "NOTFOUND" ] && exit 1

read -r BX BY <<< "$BTN"
$HDC -t "$DEV" shell "uitest uiInput click $BX $BY" >/dev/null 2>&1
sleep 4

# 3) 等 picker 出现再截（每 1.5s 截一次共 8 次 = 12s 覆盖延迟）
for i in $(seq 1 8); do
  $HDC -t "$DEV" shell "uitest screenCap -p /data/local/tmp/pk.png" >/dev/null 2>&1
  $HDC -t "$DEV" file recv /data/local/tmp/pk.png /tmp/pk_$i.png >/dev/null 2>&1
  sleep 1.5
done
echo "picker 截屏组=/tmp/pk_1..8.png"

# 4) 探测日志：采集启动申报值 vs 实际帧尺寸
$HDC -t "$DEV" shell "hilog -x | grep -iE 'window-capture|capture started|buffer|frame' | tail -10"
