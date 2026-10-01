# shellcheck shell=bash
# deps/speexdsp.sh — SpeexDSP 1.2.0 (autoconf), static.
#
# libobs's audio resampler and obs-filters' noise-suppression filter both link
# this. Built static so it is absorbed into the consuming .so rather than adding
# another entry to the HAP's libs/{abi}/ directory.
#
# The GitHub release asset for this tag does not exist (returns a 9-byte
# "Not Found" body); the canonical Xiph download does.
#
# Uses $CONFIG_HOST (a gnu triple) for --host because config.sub does not know
# "ohos" — see build-deps.sh for the full rationale.

build_speexdsp() {
    local tarball="speexdsp-${SPEEXDSP_VERSION}.tar.gz"
    local topdir="speexdsp-${SPEEXDSP_VERSION}"
    local src="$WORK_DIR/$topdir"

    fetch_tarball "$tarball" "$SPEEXDSP_URL" "$SPEEXDSP_SHA256"
    extract_tarball "$tarball" "$topdir"
    apply_patches "$src" speexdsp

    ( cd "$src" || exit 1
      ./configure \
        --host="$CONFIG_HOST" \
        --prefix="$PREFIX" \
        --enable-static \
        --disable-shared \
        --disable-examples \
        --with-pic \
      && make -j "$JOBS" \
      && make install )
}
