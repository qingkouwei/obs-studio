# shellcheck shell=bash
# deps/curl.sh — curl 8.11.1, built with CMake (not autoconf).
#
# Two reasons this uses CMake rather than ./configure:
#
#  1. autoconf's config.sub does not recognise "ohos", so ./configure aborts.
#     Working around that needs a gnu-triple lie for --host. CMake has no such
#     gate — the OHOS toolchain file is enough.
#
#  2. This is the one that actually matters. autoconf installs only libcurl.pc;
#     it does NOT install a CMake package. OBS calls find_package(CURL REQUIRED),
#     which then falls back to module mode and resolves CURL::libcurl to the bare
#     libcurl.a with no transitive dependencies. Because we build curl static,
#     every consumer (rtmp-services, frontend) then fails to link with
#     "undefined symbol: inflateInit_" and "undefined symbol: mbedtls_des_init".
#     curl's CMake build runs install(EXPORT CURLTargets), which records
#     ZLIB::ZLIB and the mbedTLS libraries in INTERFACE_LINK_LIBRARIES, so
#     consumers get them automatically.
#
# Static is kept despite the extra .so it would cost: it avoids shipping a
# libcurl.so whose version must stay in lockstep with the app.

build_curl() {
    local tarball="curl-${CURL_VERSION}.tar.xz"
    local topdir="curl-${CURL_VERSION}"
    local src="$WORK_DIR/$topdir"
    local build="$src/build-$OHOS_ARCH"

    fetch_tarball "$tarball" "$CURL_URL" "$CURL_SHA256"
    extract_tarball "$tarball" "$topdir"
    apply_patches "$src" curl

    rm -rf "$build"

    # CURL_USE_PKGCONFIG=OFF is deliberate: with it on, curl would happily
    # discover libidn2/libpsl/brotli from the *host* prefix. Everything curl
    # needs is listed explicitly below.
    #
    # CMAKE_FIND_ROOT_PATH is not redundant with CMAKE_PREFIX_PATH. The OHOS
    # toolchain sets CMAKE_FIND_ROOT_PATH_MODE_{LIBRARY,INCLUDE,PACKAGE} to ONLY
    # and seeds FIND_ROOT_PATH with the SDK, so every find_path()/find_library()
    # is re-rooted there. Without adding $PREFIX, curl's bundled
    # FindMbedTLS.cmake searches only the sysroot and fails with
    # "Could NOT find MbedTLS" even though we staged it. The toolchain appends
    # the SDK path after whatever we pass, so sysroot isolation is preserved.
    cmake -S "$src" -B "$build" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
        -DOHOS_ARCH="$OHOS_ARCH" \
        -DOHOS_STL="$OHOS_STL" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_C_FLAGS="-Qunused-arguments" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_PREFIX_PATH="$PREFIX" \
        -DCMAKE_FIND_ROOT_PATH="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_CURL_EXE=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTING=OFF \
        -DBUILD_STATIC_CURL=OFF \
        -DBUILD_LIBCURL_DOCS=OFF \
        -DBUILD_MISC_DOCS=OFF \
        -DENABLE_CURL_MANUAL=OFF \
        -DCURL_USE_PKGCONFIG=OFF \
        -DCURL_ENABLE_EXPORT_TARGET=ON \
        -DCURL_ENABLE_SSL=ON \
        -DCURL_USE_MBEDTLS=ON \
        -DCURL_USE_OPENSSL=OFF \
        -DCURL_USE_LIBSSH2=OFF \
        -DCURL_USE_LIBSSH=OFF \
        -DCURL_USE_LIBPSL=OFF \
        -DCURL_USE_GSSAPI=OFF \
        -DUSE_LIBIDN2=OFF \
        -DUSE_NGHTTP2=OFF \
        -DCURL_BROTLI=OFF \
        -DCURL_ZSTD=OFF \
        -DCURL_ZLIB=ON \
        -DENABLE_IPV6=ON \
        -DENABLE_THREADED_RESOLVER=ON \
        -DCURL_DISABLE_LDAP=ON \
        -DCURL_DISABLE_LDAPS=ON \
        -DCURL_DISABLE_DICT=ON \
        -DCURL_DISABLE_TELNET=ON \
        -DCURL_DISABLE_TFTP=ON \
        -DCURL_DISABLE_POP3=ON \
        -DCURL_DISABLE_IMAP=ON \
        -DCURL_DISABLE_SMTP=ON \
        -DCURL_DISABLE_GOPHER=ON \
        -DCURL_DISABLE_MQTT=ON \
        -DCURL_DISABLE_RTSP=ON \
        -DCURL_DISABLE_SMB=ON \
        -DCURL_DISABLE_FTP=ON \
        && cmake --build "$build" --parallel "$JOBS" \
        && cmake --install "$build"

    if [ ! -d "$PREFIX/lib/cmake/CURL" ]; then
        die "curl did not install a CMake package at $PREFIX/lib/cmake/CURL.
Without it, find_package(CURL) resolves to a bare libcurl.a and every consumer
fails to link zlib and mbedTLS symbols. Check CURL_ENABLE_EXPORT_TARGET."
    fi
}
