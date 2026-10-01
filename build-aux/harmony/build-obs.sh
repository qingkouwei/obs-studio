#!/usr/bin/env bash
# build-obs.sh — one command from a clean checkout to an installable HAP.
#
#   deps (cross-compile) -> CMake configure -> ninja -> stage -> hvigor assembleHap
#
# Usage:
#   ./build-obs.sh                      # full build
#   ./build-obs.sh --skip-deps          # reuse an existing .deps-harmony
#   ./build-obs.sh --skip-native        # only rebuild the ArkUI/HAP layer
#   ./build-obs.sh --build-type Debug
#
# Signing is NOT handled here. A debug-signed HAP requires DevEco Studio to
# generate a profile for this bundle name and register the target device UDID:
#   DevEco Studio -> open harmony/ -> File > Project Structure > Project
#   -> Signing Configs -> tick "Automatically generate signature"
# (needs a logged-in Huawei account). After that, hvigor emits a signed HAP
# alongside the unsigned one and `hdc install` will accept it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- locate the SDK ---------------------------------------------------------
if [ -n "${DEVECO_SDK_HOME:-}" ] && [ -d "$DEVECO_SDK_HOME" ]; then
    SDK_BASE="$DEVECO_SDK_HOME"
else
    SDK_BASE="/Applications/DevEco-Studio.app/Contents/sdk"
fi
[ -d "$SDK_BASE" ] || { echo "ERROR: DevEco SDK not found; set DEVECO_SDK_HOME" >&2; exit 1; }
# DEVECO_SDK_HOME may point at <sdk> or <sdk>/default; normalise to <sdk>.
case "$SDK_BASE" in
    */default) SDK_BASE="${SDK_BASE%/default}" ;;
esac
NATIVE="$SDK_BASE/default/openharmony/native"
TOOLCHAIN="$NATIVE/build/cmake/ohos.toolchain.cmake"
[ -f "$TOOLCHAIN" ] || { echo "ERROR: no ohos.toolchain.cmake under $NATIVE" >&2; exit 1; }

DEVECO_TOOLS="/Applications/DevEco-Studio.app/Contents/tools"

# --- options ----------------------------------------------------------------
ARCH="arm64-v8a"
BUILD_TYPE="Release"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 8)"
DEPS_PREFIX="$REPO_ROOT/.deps-harmony"
STAGE_PREFIX="$REPO_ROOT/.ohos-stage"
NATIVE_BUILD="$REPO_ROOT/build-ohos"
SKIP_DEPS=0
SKIP_NATIVE=0
# The repo carries no git tags, so versionconfig.cmake's `git describe` yields
# something like "1bf1379fa-modified", which project(VERSION) rejects.
OBS_VERSION="${OBS_VERSION:-32.2.2}"

while [ $# -gt 0 ]; do
    case "$1" in
        --arch)        ARCH="$2"; shift 2 ;;
        --build-type)  BUILD_TYPE="$2"; shift 2 ;;
        --jobs)        JOBS="$2"; shift 2 ;;
        --deps-prefix) DEPS_PREFIX="$2"; shift 2 ;;
        --obs-version) OBS_VERSION="$2"; shift 2 ;;
        --skip-deps)   SKIP_DEPS=1; shift ;;
        --skip-native) SKIP_NATIVE=1; shift ;;
        -h|--help)     grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Cross-compile third-party dependencies
# ---------------------------------------------------------------------------
if [ "$SKIP_DEPS" -eq 0 ]; then
    step "1/5 Cross-compiling dependencies -> $DEPS_PREFIX"
    "$SCRIPT_DIR/build-deps.sh" --prefix "$DEPS_PREFIX" --arch "$ARCH" --jobs "$JOBS"
    "$SCRIPT_DIR/verify-deps.sh" --prefix "$DEPS_PREFIX" --arch "$ARCH"
else
    step "1/5 Skipping dependencies (--skip-deps)"
    if [ -z "$(find "$DEPS_PREFIX/lib" -maxdepth 1 -name 'libavcodec.so*' -print -quit 2>/dev/null)" ]; then
        echo "ERROR: --skip-deps but $DEPS_PREFIX has no FFmpeg" >&2; exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 2. Configure the native build
# ---------------------------------------------------------------------------
if [ "$SKIP_NATIVE" -eq 0 ]; then
    step "2/5 Configuring OBS native build ($ARCH, $BUILD_TYPE)"
    cmake -S "$REPO_ROOT" -B "$NATIVE_BUILD" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
        -DOHOS_ARCH="$ARCH" \
        -DOHOS_STL=c++_shared \
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
        -DOBS_VERSION_OVERRIDE="$OBS_VERSION" \
        -DCMAKE_PREFIX_PATH="$DEPS_PREFIX" \
        -DCMAKE_FIND_ROOT_PATH="$DEPS_PREFIX"

    # -----------------------------------------------------------------------
    # 3. Build
    # -----------------------------------------------------------------------
    step "3/5 Building native libraries"
    cmake --build "$NATIVE_BUILD" --parallel "$JOBS"
else
    step "2/5 Skipping native configure (--skip-native)"
    step "3/5 Skipping native build (--skip-native)"
    [ -d "$NATIVE_BUILD/rundir" ] || { echo "ERROR: no prior native build in $NATIVE_BUILD" >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# 4. Stage into the prefix the NAPI bridge reads, and into the HAP libs dir
# ---------------------------------------------------------------------------
step "4/5 Staging native artifacts"
"$SCRIPT_DIR/stage-native.sh" \
    --build-dir "$NATIVE_BUILD" \
    --deps "$DEPS_PREFIX" \
    --prefix "$STAGE_PREFIX" \
    --abi "$ARCH"

# ---------------------------------------------------------------------------
# 5. Build the HAP
# ---------------------------------------------------------------------------
step "5/5 Building the ArkUI HAP"
export DEVECO_SDK_HOME="$SDK_BASE"
export NODE_HOME="$DEVECO_TOOLS/node"
export JAVA_HOME="/Applications/DevEco-Studio.app/Contents/jbr"
export PATH="$NODE_HOME/bin:$JAVA_HOME/bin:$PATH"

(
    cd "$REPO_ROOT/harmony"
    "$DEVECO_TOOLS/hvigor/bin/hvigorw" \
        --mode module -p module=entry@default -p product=default \
        -p buildMode=debug assembleHap
)

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
HAP_DIR="$REPO_ROOT/harmony/entry/build/default/outputs/default"
printf '\n'
step "Done"
for h in "$HAP_DIR"/*.hap; do
    [ -e "$h" ] || continue
    printf '   %-46s %s\n' "$(basename "$h")" "$(du -h "$h" | cut -f1)"
done
echo
echo "   Native libs : $(find "$REPO_ROOT/harmony/entry/libs/$ARCH" -name '*.so*' 2>/dev/null | wc -l | tr -d ' ') files in harmony/entry/libs/$ARCH"
BR="$REPO_ROOT/harmony/entry/build/default/intermediates/libs/default/$ARCH/libobs_bridge.so"
if [ -f "$BR" ]; then
    NM="$NATIVE/llvm/bin/llvm-nm"
    n=$("$NM" -D --undefined-only "$BR" 2>/dev/null | grep -cE " (obs_|gs_)" || true)
    if [ "$n" -gt 0 ]; then
        echo "   Bridge      : HAVE_LIBOBS enabled ($n live libobs symbol references)"
    else
        echo "   Bridge      : *** shell-only — NOT linked against libobs ***"
    fi
else
    echo "   Bridge      : *** libobs_bridge.so not found at $BR ***"
fi
echo
step "Cross-layer contract pre-flight"
if "$SCRIPT_DIR/check-contracts.sh" --hap "$(find "$HAP_DIR" -maxdepth 1 -name '*.hap' 2>/dev/null | head -1)"; then
    echo "   All contract checks passed."
else
    echo "   *** contract checks FAILED — see above. These are the defects that"
    echo "       compile cleanly and only surface on a device; fix before flashing."
fi

echo
echo "   Next: sign in DevEco Studio (see the header of this script), then"
echo "         ./device-validate.sh --hap <signed.hap>"
