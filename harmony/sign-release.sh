#!/bin/bash
# 轻录直录播软件 — 发布签名打包（AGC 上架包）。
# 用法（在 harmony/ 目录下）：
#   source /Users/shen/code/HarmonyOS/qinglu-signing/env.sh   # 注入密码与签名材料路径
#   ./sign-release.sh
#
# 签名材料（p12 私钥 / AGC 发布证书链 / release Profile）不在本仓库：
# 本仓库是 public fork，材料单独放在私有仓库 qinglu-signing（本机 ~/code/HarmonyOS/）。
set -e
JBR=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home/bin
TOOL=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar
NODE=/Users/shen/.workbuddy/binaries/node/versions/22.22.2-6/bin/node
HVIGOR=/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js
SR="${QINGLU_SIGNING_DIR:-/Users/shen/code/HarmonyOS/qinglu-signing}"
OUT="$(cd "$(dirname "$0")" && pwd)/build/outputs/default"

# 私钥密码不入库：从环境变量注入（仓库是 public fork）。
#   export QINGLU_KEYSTORE_PWD='<keystore 密码>'
# 可选：QINGLU_KEY_ALIAS（默认 qinglvrelease）、QINGLU_SIGNING_DIR（默认私有签名仓库路径）
: "${QINGLU_KEYSTORE_PWD:?未设置 QINGLU_KEYSTORE_PWD —— 先 source ~/code/HarmonyOS/qinglu-signing/env.sh 再运行}"
KEY_ALIAS="${QINGLU_KEY_ALIAS:-qinglvrelease}"
if [ ! -f "$SR/qinglu_release_keystore.p12" ]; then
  echo "错误：签名材料目录无效：$SR" >&2
  echo "     请设置 QINGLU_SIGNING_DIR 指向私有签名仓库（含 qinglu_release_keystore.p12）" >&2
  exit 1
fi

echo "[1/3] hvigor assembleApp (release 编译，签名走 debug 配置或跳过)"
env -u WORKBUDDY_BROKER_SOCK -u NODE_OPTIONS \
  DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
  JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr \
  PATH="/Applications/DevEco-Studio.app/Contents/jbr/bin:$PATH" \
  "$NODE" "$HVIGOR" --mode project -p product=default -p buildMode=release \
  assembleApp --no-daemon

echo "[2/3] hap-sign-tool 发布签名"
"$JBR/java" -jar "$TOOL" sign-app -mode localSign \
  -keyAlias "$KEY_ALIAS" -keyPwd "$QINGLU_KEYSTORE_PWD" \
  -keystoreFile "$SR/qinglu_release_keystore.p12" -keystorePwd "$QINGLU_KEYSTORE_PWD" \
  -appCertFile "$SR/qingstudio.cer" -profileFile "$SR/qingluRelease.p7b" \
  -inFile "$OUT/harmony-default-unsigned.app" \
  -outFile "$OUT/qinglu-release.app" \
  -signAlg SHA256withECDSA -compatibleVersion 26

echo "[3/3] verify-app 校验"
"$JBR/java" -jar "$TOOL" verify-app -inFile "$OUT/qinglu-release.app" \
  -outCertChain /tmp/_vc.cer -outProfile /tmp/_vp.p7b | grep -iE "verify|success|error" | head -2
echo "→ 上架包：$OUT/qinglu-release.app"
