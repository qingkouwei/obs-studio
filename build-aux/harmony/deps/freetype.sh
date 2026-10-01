# shellcheck shell=bash
# deps/freetype.sh — FreeType 2.13.3 (CMake), the glyph rasteriser behind OBS's
# text-freetype2 source plugin.
#
# Dependency set, deliberately minimal
# ------------------------------------
# Built static with PIC so it is absorbed into text-freetype2.so and does not
# add another .so to the HAP's libs/{abi}/ directory (and so stage-native.sh has
# no extra DT_NEEDED soname to resolve).
#
# Every optional FreeType back end is switched OFF, which keeps the whole chain
# at exactly one library:
#
#   harfbuzz  text-freetype2 never calls the shaping API; it maps wchar_t to a
#             glyph index with FT_Get_Char_Index and rasterises glyph by glyph
#             (see cache_glyphs() in text-functionality.c). Nothing in
#             plugins/text-freetype2/ references hb_* at all, so building
#             harfbuzz would buy nothing and would drag in its own C++ runtime,
#             glib-free but still ~2 MB of code.
#   brotli    WOFF2 decompression. HarmonyOS ships no .woff2 system fonts.
#   bzip2     PCF/bzip2-compressed fonts. None on HarmonyOS.
#   png       CBDT/sbix colour bitmap strikes need libpng, which is absent from
#             the OHOS sysroot. Without it FreeType still rasterises the
#             monochrome outlines of the same faces, so text renders.
#   zlib      NOT a typo — see the note below.
#
# fontconfig / expat are not built either. plugins/text-freetype2 only reaches
# fontconfig through find-font-unix.c, which the plugin's CMakeLists compiles
# for $<PLATFORM_ID:Linux,FreeBSD,OpenBSD>. The OHOS toolchain sets
# CMAKE_SYSTEM_NAME=OHOS, so PLATFORM_ID is "OHOS" and that file is never part
# of the target; find-font-ohos.c replaces it with a direct scan of the
# HarmonyOS font directories.
#
# Why FT_DISABLE_ZLIB=TRUE even though the sysroot has libz.so
# ------------------------------------------------------------
# CMake's built-in FindFreetype.cmake (there is no cmake/finders/FindFreetype.cmake
# in this tree) creates an UNKNOWN IMPORTED target carrying only
# IMPORTED_LOCATION and INTERFACE_INCLUDE_DIRECTORIES — no interface link
# libraries. If FreeType were configured against the sysroot zlib,
# FT_CONFIG_OPTION_SYSTEM_ZLIB would be defined, libfreetype.a would reference
# inflate/deflate/crc32, and nothing would tell OBS to add -lz. Under the OHOS
# linker's -Wl,--no-undefined -Wl,--fatal-warnings that is a hard link failure
# in text-freetype2.so. Disabling system zlib makes FreeType compile the zlib
# 1.2.13 sources it bundles in src/gzip/ (pulled in by src/gzip/ftgzip.c)
# instead, so libfreetype.a is fully self-contained.
#
# Expects globals from build-deps.sh: WORK_DIR, PREFIX, JOBS, OHOS_ARCH,
# OHOS_STL, TOOLCHAIN_FILE, fetch_tarball, extract_tarball, apply_patches.

build_freetype() {
    local tarball="freetype-${FREETYPE_VERSION}.tar.xz"
    local topdir="freetype-${FREETYPE_VERSION}"
    local src="$WORK_DIR/$topdir"
    local build="$src/build-$OHOS_ARCH"

    fetch_tarball "$tarball" "$FREETYPE_URL" "$FREETYPE_SHA256"
    extract_tarball "$tarball" "$topdir"
    apply_patches "$src" freetype

    rm -rf "$build"

    # -Qunused-arguments: ohos.toolchain.cmake injects --gcc-toolchain= on every
    # compile line and clang 15 reports it unused. FreeType does not default to
    # -Werror, but the flag is applied for consistency with every other CMake
    # dep here and so a future FreeType that does enable -Werror keeps building.
    #
    # Both CMAKE_PREFIX_PATH and CMAKE_FIND_ROOT_PATH point at the staging
    # prefix: the toolchain sets CMAKE_FIND_ROOT_PATH_MODE_{LIBRARY,INCLUDE,
    # PACKAGE} to ONLY, so a prefix path alone would still be re-rooted and
    # find_package/find_library would report "Could NOT find" for anything we
    # staged. FreeType itself needs no staged dep in this configuration, but
    # passing both keeps this file consistent with the rest of the pipeline and
    # stops a stray host harfbuzz/png/brotli from being picked up.
    cmake -S "$src" -B "$build" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
        -DOHOS_ARCH="$OHOS_ARCH" \
        -DOHOS_STL="$OHOS_STL" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_C_FLAGS="-Qunused-arguments" \
        -DCMAKE_PREFIX_PATH="$PREFIX" \
        -DCMAKE_FIND_ROOT_PATH="$PREFIX" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DFT_DISABLE_HARFBUZZ=TRUE \
        -DFT_DISABLE_BROTLI=TRUE \
        -DFT_DISABLE_BZIP2=TRUE \
        -DFT_DISABLE_PNG=TRUE \
        -DFT_DISABLE_ZLIB=TRUE \
        && cmake --build "$build" --parallel "$JOBS" \
        && cmake --install "$build"
}
