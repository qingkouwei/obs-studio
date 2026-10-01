# shellcheck shell=bash
# deps/mbedtls.sh — mbedTLS 3.6.2 (CMake). Consumed statically by curl and
# FFmpeg (RTMPS/TLS), so only the static libs are built; -fPIC is required
# because they get linked into FFmpeg's shared libraries.
#
# Expects globals from build-deps.sh: WORK_DIR, PREFIX, JOBS, OHOS_ARCH,
# OHOS_STL, TOOLCHAIN_FILE, fetch_tarball, extract_tarball, apply_patches.

build_mbedtls() {
    local tarball="mbedtls-${MBEDTLS_VERSION}.tar.bz2"
    local topdir="mbedtls-${MBEDTLS_VERSION}"
    local src="$WORK_DIR/$topdir"
    local build="$src/build-$OHOS_ARCH"

    fetch_tarball "$tarball" "$MBEDTLS_URL" "$MBEDTLS_SHA256"
    extract_tarball "$tarball" "$topdir"
    apply_patches "$src" mbedtls

    rm -rf "$build"
    # ohos.toolchain.cmake injects --gcc-toolchain= into every compile line.
    # clang 15 considers it unused here and emits -Wunused-command-line-argument,
    # which mbedTLS's default -Werror turns into a hard failure on every single
    # translation unit. -Qunused-arguments suppresses that class of warning;
    # MBEDTLS_FATAL_WARNINGS=OFF is belt-and-braces for the same reason.
    cmake -S "$src" -B "$build" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
        -DOHOS_ARCH="$OHOS_ARCH" \
        -DOHOS_STL="$OHOS_STL" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_C_FLAGS="-Qunused-arguments" \
        -DCMAKE_CXX_FLAGS="-Qunused-arguments" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DENABLE_TESTING=OFF \
        -DENABLE_PROGRAMS=OFF \
        -DMBEDTLS_FATAL_WARNINGS=OFF \
        -DUSE_STATIC_MBEDTLS_LIBRARY=ON \
        -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
        && cmake --build "$build" --parallel "$JOBS" \
        && cmake --install "$build"
}
