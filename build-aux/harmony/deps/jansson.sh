# shellcheck shell=bash
# deps/jansson.sh — jansson 2.14 (CMake), the JSON library libobs uses for
# obs_data_t. Built static so it is absorbed into libobs.so and does not add
# another .so to the HAP's libs/{abi}/ directory.

build_jansson() {
    local tarball="jansson-${JANSSON_VERSION}.tar.gz"
    local topdir="jansson-${JANSSON_VERSION}"
    local src="$WORK_DIR/$topdir"
    local build="$src/build-$OHOS_ARCH"

    fetch_tarball "$tarball" "$JANSSON_URL" "$JANSSON_SHA256"
    extract_tarball "$tarball" "$topdir"
    apply_patches "$src" jansson

    rm -rf "$build"

    # See deps/mbedtls.sh for why -Qunused-arguments is required here.
    cmake -S "$src" -B "$build" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
        -DOHOS_ARCH="$OHOS_ARCH" \
        -DOHOS_STL="$OHOS_STL" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_C_FLAGS="-Qunused-arguments" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DJANSSON_BUILD_SHARED_LIBS=OFF \
        -DJANSSON_WITHOUT_TESTS=ON \
        -DJANSSON_EXAMPLES=OFF \
        -DJANSSON_BUILD_DOCS=OFF \
        && cmake --build "$build" --parallel "$JOBS" \
        && cmake --install "$build"
}
