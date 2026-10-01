# shellcheck shell=bash
# deps/x264.sh — x264 `stable` @ $X264_COMMIT (autoconf), static + PIC.
# Consumed by FFmpeg (--enable-libx264) and by plugins/obs-x264.
#
# arm64 assembly retry: x264's configure probes the assembler and the arm64
# .S files may fail to assemble under the OHOS clang 15 (integrated as,
# musl headers, vendor patches). If the first attempt fails for any reason,
# we retry once with --disable-asm so the port is unblocked. C-implementation
# x264 is roughly 2-4x slower to encode on arm64 — acceptable to get a
# working bundle, unacceptable for production streaming. Remove the fallback
# once the asm issue is root-caused.

# Source acquisition: prefer the pinned-commit archive tarball (with sha256);
# GitLab archives are not guaranteed byte-stable, so on checksum failure fall
# back to a git fetch of the exact commit — the commit id is the integrity
# proof in that path.
ensure_x264_source() {
    local src="$WORK_DIR/x264-$X264_COMMIT"
    local out="$DOWNLOAD_DIR/x264-$X264_COMMIT.tar.bz2"

    if [ -f "$src/configure" ]; then
        return 0
    fi
    local have_tarball=0
    if [ ! -f "$out" ]; then
        log "Downloading x264 archive for commit ${X264_COMMIT:0:12}"
        if curl -fL --retry 3 --connect-timeout 20 -o "$out.part" "$X264_URL"; then
            mv "$out.part" "$out"
        else
            rm -f "$out.part"
        fi
    fi
    if [ -f "$out" ]; then
        local got
        got="$(sha256_of "$out")"
        if [ "$got" = "$X264_SHA256" ]; then
            have_tarball=1
        else
            rm -f "$out"
            warn "x264 archive checksum mismatch (GitLab archives are not byte-stable);"
            warn "falling back to git fetch of pinned commit $X264_COMMIT"
        fi
    fi

    if [ "$have_tarball" = "1" ]; then
        log "Extracting x264 archive"
        tar -xf "$out" -C "$WORK_DIR"
        [ -f "$src/configure" ] || die "x264 archive did not extract to x264-$X264_COMMIT/"
        return 0
    fi

    rm -rf "$src"
    git init -q "$src"
    git -C "$src" remote add origin "$X264_GIT_URL"
    git -C "$src" fetch -q --depth 1 origin "$X264_COMMIT" \
        || die "git fetch of x264 commit $X264_COMMIT failed"
    git -C "$src" checkout -q FETCH_HEAD
    local head
    head="$(git -C "$src" rev-parse HEAD)"
    [ "$head" = "$X264_COMMIT" ] || die "x264 checkout is $head, expected $X264_COMMIT"
}

x264_attempt() { # <srcdir> [extra configure args...]
    local src="$1"; shift
    ( cd "$src" || exit 1
      make distclean >/dev/null 2>&1 || true
      ./configure \
          --prefix="$PREFIX" \
          --host="$CONFIG_HOST" \
          --cross-prefix= \
          --enable-static \
          --enable-pic \
          --disable-cli \
          --disable-opencl \
          --disable-lto \
          "$@" \
      && make -j "$JOBS" \
      && make install )
}

build_x264() {
    local src="$WORK_DIR/x264-$X264_COMMIT"

    ensure_x264_source
    apply_patches "$src" x264

    if x264_attempt "$src"; then
        return 0
    fi

    warn "**************************************************************"
    warn "x264 build FAILED with arm64 assembly enabled. Retrying once"
    warn "with --disable-asm. WARNING: without asm, x264 encodes roughly"
    warn "2-4x slower on arm64 — fine to unblock the port, not fine for"
    warn "production. Root-cause the assembler failure (see the log)."
    warn "**************************************************************"

    x264_attempt "$src" --disable-asm \
        || die "x264 build failed even with --disable-asm"
}
