# shellcheck shell=bash
# deps/ffmpeg.sh — FFmpeg 7.1 (autoconf), shared libs, linked against the
# staged x264/mbedtls and the sysroot zlib.
#
# --target-os=linux on a non-Linux target: FFmpeg has no ohos target. linux +
# musl is the closest working configuration (OHOS is a linux-abi ELF platform
# with musl libc), and the clang driver's --target=aarch64-linux-ohos plus
# -D__MUSL__ keep codegen and feature probes honest. This is the MOST LIKELY
# place to need source patching — if configure misdetects a glibc-ism or a
# compile fails on a missing libc symbol, put the fix in
# build-aux/harmony/patches/ffmpeg-ohos.patch (applied automatically).
#
# Network stays ENABLED: obs-outputs needs rtmp/rtmps/http/https/hls/tcp/udp.
#
# --enable-version3 is mandatory, not optional. FFmpeg classifies mbedTLS 3.x as
# a (L)GPLv3 component and configure aborts with
#   "mbedtls is version3 and --enable-version3 is not specified."
# That lifts the resulting libraries from LGPLv2.1 to LGPLv3; OBS Studio is
# licensed GPL-2.0-or-later, so the "or later" grant keeps the combination valid.
#
# NOTE for anyone editing the ./configure invocation below: it is one long
# backslash-continued command. A comment line placed between continued lines
# silently truncates the command at that point while still passing bash -n and
# the linter. Keep commentary in this header block, never inline.
#
# Component selection mirrors what OBS actually links:
#   libobs           -> avformat avutil swscale swresample (+avcodec)
#   frontend         -> avcodec avutil avformat
#   plugins/obs-ffmpeg -> avcodec avfilter avformat avdevice avutil swscale swresample
#   plugins/obs-outputs -> avformat muxers/protocols (flv, mpegts, hls, rtmp)
# Everything else is off (--disable-everything) to keep the .so set small.

FFMPEG_ENCODERS="aac,alac,flac,libx264,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,png"
FFMPEG_DECODERS="aac,aac_latm,alac,av1,bmp,flac,gif,h264,hevc,mjpeg,mp3,mpeg2video,mpeg4,opus,pcm_alaw,pcm_mulaw,pcm_f32le,pcm_f64le,pcm_s16be,pcm_s16le,pcm_s24le,pcm_s32le,png,vorbis,vp8,vp9,webp,wmav2"
FFMPEG_MUXERS="aac,adts,flac,flv,hls,image2,ipod,matroska,mov,mp3,mp4,mpegts,ogg,wav"
FFMPEG_DEMUXERS="aac,aiff,asf,avi,concat,flac,flv,gif,hls,image2,image2pipe,matroska,mov,mp3,mpegps,mpegts,mpegvideo,ogg,pcm_f32le,pcm_s16le,png_pipe,wav"
FFMPEG_PARSERS="aac,aac_latm,av1,flac,gif,h264,hevc,mjpeg,mpeg4video,mpegaudio,mpegvideo,opus,png,vorbis,vp8,vp9"
FFMPEG_PROTOCOLS="concat,crypto,data,file,hls,http,httpproxy,https,pipe,rtmp,rtmps,rtmpt,rtmpts,subfile,tcp,tls,udp"
FFMPEG_BSFS="aac_adtstoasc,extract_extradata,h264_mp4toannexb,hevc_mp4toannexb"
FFMPEG_FILTERS="aformat,anull,aresample,atempo,format,fps,null,scale,volume"

build_ffmpeg() {
    local tarball="ffmpeg-${FFMPEG_VERSION}.tar.xz"
    local topdir="ffmpeg-${FFMPEG_VERSION}"
    local src="$WORK_DIR/$topdir"

    fetch_tarball "$tarball" "$FFMPEG_URL" "$FFMPEG_SHA256"
    extract_tarball "$tarball" "$topdir"
    apply_patches "$src" ffmpeg

    # --disable-autodetect: configure must not "discover" optional external
    # libs (bzlib, iconv, ...) through host paths; only what we list is built
    # against (staged x264/mbedtls + sysroot zlib).
    # -Wl,--no-undefined mirrors the OHOS CMake toolchain's link policy: a
    # missing symbol is a build-time error, not a runtime surprise.
    ( cd "$src" || exit 1
      make distclean >/dev/null 2>&1 || true
      ./configure \
        --prefix="$PREFIX" \
        --enable-cross-compile \
        --arch="$FFMPEG_ARCH" \
        --target-os=linux \
        --cross-prefix= \
        --cc="$CC" \
        --cxx="$CXX" \
        --ar="$AR" \
        --nm="$NM" \
        --ranlib="$RANLIB" \
        --strip="$STRIP" \
        --sysroot="$SYSROOT" \
        --extra-cflags="--target=$TRIPLE --sysroot=$SYSROOT -D__MUSL__ -I$PREFIX/include" \
        --extra-ldflags="--target=$TRIPLE --sysroot=$SYSROOT -L$PREFIX/lib -Wl,--no-undefined" \
        --disable-everything \
        --disable-autodetect \
        --enable-shared \
        --disable-static \
        --enable-pic \
        --enable-gpl \
        --enable-version3 \
        --enable-libx264 \
        --enable-mbedtls \
        --enable-zlib \
        --enable-network \
        --enable-avcodec \
        --enable-avdevice \
        --enable-avfilter \
        --enable-avformat \
        --enable-swresample \
        --enable-swscale \
        --disable-doc \
        --disable-programs \
        --disable-linux-perf \
        --enable-encoder="$FFMPEG_ENCODERS" \
        --enable-decoder="$FFMPEG_DECODERS" \
        --enable-muxer="$FFMPEG_MUXERS" \
        --enable-demuxer="$FFMPEG_DEMUXERS" \
        --enable-parser="$FFMPEG_PARSERS" \
        --enable-protocol="$FFMPEG_PROTOCOLS" \
        --enable-bsf="$FFMPEG_BSFS" \
        --enable-filter="$FFMPEG_FILTERS" \
      && make -j "$JOBS" \
      && make install )
}
