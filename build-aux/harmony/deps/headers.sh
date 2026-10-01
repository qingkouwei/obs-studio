# shellcheck shell=bash
# deps/headers.sh — header-only dependencies libobs needs: SIMDe and uthash.
#
# Neither produces a library, so this "build" is a download-verify-install of
# headers into $PREFIX/include. FindSIMDe.cmake looks for
# <prefix>/include/simde/simde-common.h and FindUthash.cmake for
# <prefix>/include/uthash.h.
#
# SIMDe emulates the x86 SSE intrinsics libobs uses, which is exactly what makes
# the arm64 port possible without rewriting the SIMD paths.

build_headers() {
    # --- uthash -----------------------------------------------------------
    local uthash_tarball="uthash-${UTHASH_VERSION}.tar.gz"
    local uthash_topdir="uthash-${UTHASH_VERSION}"

    fetch_tarball "$uthash_tarball" "$UTHASH_URL" "$UTHASH_SHA256"
    extract_tarball "$uthash_tarball" "$uthash_topdir"

    mkdir -p "$PREFIX/include"
    install -m 0644 "$WORK_DIR/$uthash_topdir/src/"*.h "$PREFIX/include/"
    log "installed uthash headers from $uthash_topdir/src"

    # --- SIMDe ------------------------------------------------------------
    local simde_tarball="simde-${SIMDE_VERSION}.tar.gz"
    local simde_topdir="simde-${SIMDE_VERSION}"

    fetch_tarball "$simde_tarball" "$SIMDE_URL" "$SIMDE_SHA256"
    extract_tarball "$simde_tarball" "$simde_topdir"

    if [ ! -f "$WORK_DIR/$simde_topdir/simde/simde-common.h" ]; then
        die "SIMDe tarball did not contain simde/simde-common.h; FindSIMDe.cmake would not detect it"
    fi

    rm -rf "$PREFIX/include/simde"
    mkdir -p "$PREFIX/include"
    cp -R "$WORK_DIR/$simde_topdir/simde" "$PREFIX/include/simde"
    log "installed SIMDe headers ($(du -sh "$PREFIX/include/simde" | cut -f1))"
}
