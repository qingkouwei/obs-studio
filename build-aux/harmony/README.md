# HarmonyOS dependency bundle for OBS Studio

Builds the third-party dependencies OBS requires (mbedTLS, curl, x264, FFmpeg,
FreeType) for HarmonyOS `arm64-v8a`, staged into a single prefix that OBS's
CMake can consume via `CMAKE_PREFIX_PATH`. zlib is *not* built — the OHOS
sysroot's `libz.so` is linked instead.

Verified against: HarmonyOS SDK API 26 (clang 15.0.4, musl libc, `ld.lld`).

## Prerequisites

- macOS with DevEco Studio installed (or set `DEVECO_SDK_HOME` to an SDK root).
  The stock path `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native`
  is auto-detected. A commercial HarmonyOS variant exists at
  `<SDK>/../hms/native` (`hmos.toolchain.cmake`); select it with `--toolchain hmos`.
- Host tools: `cmake` (>= 3.20), `ninja`, `make`, `git`, `tar`, `patch`,
  `pkg-config`, `curl`, `sha256sum`/`shasum`.
- Network access on the first run (sources are cached afterwards).

## One-command build

```sh
cd obs-studio
./build-aux/harmony/build-deps.sh                 # default prefix: .deps-harmony
./build-aux/harmony/build-deps.sh --only ffmpeg   # rebuild just FFmpeg
./build-aux/harmony/build-deps.sh --prefix /tmp/ohos-deps --jobs 8
```

Options: `--prefix`, `--arch {arm64-v8a,armeabi-v7a,x86_64}`, `--stl
{c++_shared,c++_static}`, `--jobs`,
`--only <headers,jansson,speexdsp,mbedtls,curl,x264,ffmpeg,freetype>`,
`--download-dir`, `--work-dir`, `--sdk`, `--toolchain`, `--fresh`.

Sources are pinned by version + SHA-256 (x264 by git commit; if the GitLab
archive tarball's checksum drifts, the script falls back to fetching the exact
commit over git). A checksum mismatch is always a hard failure. Build logs
land in `<work-dir>/logs/`; on failure the last 50 lines are printed.

## What lands in the prefix

```
include/          mbedtls/ curl/ x264.h libav*/ libsw*/
                  freetype2/{ft2build.h,freetype/,dlg/}
lib/              libmbedtls.a libmbedx509.a libmbedcrypto.a
                  libcurl.a (static on purpose — fewer .so files in the HAP)
                  libx264.a
                  libfreetype.a (static, PIC, every optional back end disabled —
                                 it is absorbed into text-freetype2.so)
                  libavcodec.so.* libavformat.so.* libavutil.so.*
                  libswscale.so.* libswresample.so.* libavfilter.so.* libavdevice.so.*
lib/pkgconfig/    libcurl.pc x264.pc libav*.pc libsw*.pc freetype2.pc
lib/cmake/        MbedTLS package configs, freetype/ package configs
```

## Pointing OBS at the bundle

```sh
cmake -B build -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$SDK/native/build/cmake/ohos.toolchain.cmake" \
  -DOHOS_ARCH=arm64-v8a -DOHOS_STL=c++_shared \
  -DCMAKE_PREFIX_PATH="$PWD/.deps-harmony" \
  -DPKG_CONFIG_PATH="$PWD/.deps-harmony/lib/pkgconfig" \
  -DCMAKE_BUILD_TYPE=Release
```

OBS's own `find_package(FFmpeg/CURL/Libx264)` calls resolve through the
pkg-config files and CMake search paths in the prefix. All native libraries
packaged into one HAP must share the same `OHOS_STL` choice (default
`c++_shared`).

## Validation

```sh
./build-aux/harmony/verify-deps.sh --prefix .deps-harmony
```

It checks presence, architecture, SONAME/dynamic-section sanity (including
host-path contamination), and key symbols. Manual spot checks:

```sh
file .deps-harmony/lib/libavcodec.so.*     # -> ELF 64-bit LSB shared object, ARM aarch64
"$SDK/native/llvm/bin/llvm-readelf" -d .deps-harmony/lib/libavcodec.so.* | grep -E 'NEEDED|SONAME'
"$SDK/native/llvm/bin/llvm-nm" -D .deps-harmony/lib/libavcodec.so.* | grep avcodec_open2
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| **Every** translation unit fails with `argument unused during compilation: '--gcc-toolchain=...' [-Werror,-Wunused-command-line-argument]` | `ohos.toolchain.cmake` injects `--gcc-toolchain=` on every compile line; clang 15 reports it as unused, and any project building with `-Werror` (mbedTLS does by default) turns that into a hard error. Nothing compiles at all, and the visible symptom is misleading — e.g. a later `file INSTALL cannot find libeverest.a`. | **Already fixed here.** `-Qunused-arguments` is exported in `CFLAGS`/`CXXFLAGS` by `build-deps.sh`, and passed via `-DCMAKE_C_FLAGS`/`-DCMAKE_CXX_FLAGS` for the CMake build. mbedTLS additionally gets `-DMBEDTLS_FATAL_WARNINGS=OFF`. |
| autoconf dies with `Invalid configuration 'aarch64-linux-ohos': OS 'ohos' not recognized` | `config.sub` does not know `ohos`. Verified against curl 8.11.1's bundled 2022-vintage copy **and** automake 1.17's — upgrading autotools does not help. | **Already fixed here.** `build-deps.sh` sets `CONFIG_HOST` to a gnu triple (`aarch64-linux-gnu`) used only for autoconf `--host`, while the real target is still enforced through `CC`/`CXX` via `--target=aarch64-linux-ohos --sysroot=...`. Feature detection stays honest because every autoconf probe is a compile test against the OHOS sysroot. |
| FFmpeg configure aborts: `mbedtls is version3 and --enable-version3 is not specified.` | FFmpeg classifies mbedTLS 3.x as a (L)GPLv3 component and refuses to use it without the explicit licence opt-in. | **Already fixed here** via `--enable-version3`. This lifts the FFmpeg libraries from LGPLv2.1 to LGPLv3; OBS Studio is GPL-2.0-**or-later**, so the "or later" grant keeps the combination valid. Do not remove it. |
| `nm -D` on a built library shows no symbols from a dependency you know you linked | FFmpeg and x264 build with `-fvisibility=hidden`, so absorbed code never reaches the dynamic symbol table. A zero count here is **not** evidence of a failed link. | Verify with `strings -a <lib> \| grep <banner>` instead. Confirmed working: `libavcodec.so` contains `x264 - core %d - H.264/MPEG-4 AVC codec`, and `libavformat.so` contains `mbedtls_ssl_set_hostname` plus the `rtmp_*` option strings. |
| configure: "C compiler cannot create executables" / wrong-arch objects | host clang or brew paths leaking in | ensure you run through `build-deps.sh` (it isolates `PKG_CONFIG_LIBDIR`/`PKG_CONFIG_PATH` and forces `CC/CXX` with `--target=aarch64-linux-ohos --sysroot=...`) |
| undefined symbol at link (e.g. `malloc_trim`, `sysctl`, glibc-only API) | **musl, not glibc**: the toolchain injects `-D__MUSL__`; a configure probe misdetected a glibc-ism | for FFmpeg, put the fix in `patches/ffmpeg-ohos.patch` (placeholder with a documented debugging map ships in this directory and is applied automatically once it contains real hunks) |
| link fails with `-Wl,--no-undefined` | any missing symbol is a hard error on OHOS, underlinking never "just warns" | add the missing `-l<lib>` to the project's LDFLAGS/`--extra-ldflags`; never remove `--no-undefined` |
| x264 make fails in `common/aarch64/*.S` | arm64 asm rejected by OHOS clang | automatic: the script retries once with `--disable-asm` and prints a big warning (2-4x slower encodes) |
| FFmpeg configure: "ERROR: x264 not found using pkg-config" | staging prefix not on the pkg-config search path | re-run via the driver; check `PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig` |
| x264 tarball checksum mismatch | GitLab archive tarballs are not byte-stable | automatic git-clone fallback pins the exact commit; or pass `--fresh` |
| brew's ffmpeg/x264 picked up | host contamination | check `config.log`/`ffbuild/config.log` for `/opt/homebrew`; the driver already isolates pkg-config — don't export host `PKG_CONFIG_PATH` around it |
| `find_package(Freetype)` reports "Could NOT find Freetype" even though `libfreetype.a` is in the prefix | The OHOS toolchain sets `CMAKE_FIND_ROOT_PATH_MODE_{LIBRARY,INCLUDE,PACKAGE}` to `ONLY` and seeds `CMAKE_FIND_ROOT_PATH` with the SDK, so a bare `CMAKE_PREFIX_PATH` is re-rooted away from the deps prefix. | Pass **both** `-DCMAKE_PREFIX_PATH="$PWD/.deps-harmony"` and `-DCMAKE_FIND_ROOT_PATH="$PWD/.deps-harmony"` to the OBS configure. Verified: `-- Found Freetype: .../.deps-harmony/lib/libfreetype.a (found version "2.13.3")`. |
| `text-freetype2.so` fails to link with `undefined symbol: inflate` (or `hb_*`, `png_*`, `BZ2_*`) | CMake's built-in `FindFreetype.cmake` creates an `UNKNOWN IMPORTED` target carrying only `IMPORTED_LOCATION` and `INTERFACE_INCLUDE_DIRECTORIES` — no interface link libraries. A `.a` also records no dependencies, so anything FreeType was configured against is simply never added to the link line, and `-Wl,--no-undefined` makes that fatal. | **Already fixed here.** `deps/freetype.sh` passes `FT_DISABLE_ZLIB/BZIP2/PNG/HARFBUZZ/BROTLI=TRUE`, so FreeType compiles the zlib sources it bundles in `src/gzip/` and `libfreetype.a` is self-contained. `verify-deps.sh` guards this with a `check_no_undefined` scan — do not turn those options off without also adding the libraries to the plugin's link line. |
| `text-freetype2` links but calls `load_os_font_list`/`get_font_path` that no back end defines | Font back ends are selected by `$<PLATFORM_ID:...>` in the plugin's CMakeLists, and the OHOS toolchain sets `CMAKE_SYSTEM_NAME=OHOS` — so `PLATFORM_ID` is `OHOS`, which matches neither the `Windows,Darwin` (`find-font.c`) nor the `Linux,FreeBSD,OpenBSD` (`find-font-unix.c`) branch. Note `__linux__` **is** defined on OHOS, so a preprocessor-based selection would have compiled the fontconfig back end and failed on the missing header instead. | **Already fixed.** `OHOS` was added to the `find-font.c` branch and `plugins/text-freetype2/find-font-ohos.c` supplies the three back-end hooks by scanning `/system/fonts`. |
| `text-freetype2.so` loads but renders nothing and every property label is the raw key | On OHOS, module data is read from the HAP's rawfile assets, not a filesystem prefix (`libobs/obs-harmony.c` maps `%module%` to `<rawfile>/obs-plugins/%module%`), so `obs_module_file("text_default.effect")` misses and the draw effect is NULL. | Call `install_obs_data(text-freetype2 data "obs-plugins/text-freetype2")` from the plugin's CMakeLists, guarded by `if(OS_HARMONY)` — same as `libobs` and the `harmony-*` plugins do. |

## Notes

- FFmpeg is configured `--target-os=linux`: FFmpeg has no ohos target, and
  linux+musl (via `-D__MUSL__` and the ohos clang target) is the closest
  working configuration. This is the most likely place to need patching.
- Network support is deliberately ON in FFmpeg (rtmp/rtmps/http/https/hls/
  tcp/udp) — obs-outputs needs it.
- mbedTLS/curl/x264 are static (only consumed internally / by OBS libs);
  FFmpeg is shared because OBS links `FFmpeg::av*` shared targets.
- FreeType is static with PIC for the same reason mbedTLS is: only
  `text-freetype2.so` consumes it, so it is absorbed at link time and the HAP's
  `.so` count stays down (its `DT_NEEDED` ends up as just `libobs.so` +
  `libc.so`, which also means `stage-native.sh` has no extra soname to resolve).
- The FreeType chain stops at FreeType. harfbuzz is not built because
  `text-freetype2` never calls the shaping API — it maps `wchar_t` to a glyph
  index with `FT_Get_Char_Index` and rasterises glyph by glyph — and nothing in
  `plugins/text-freetype2/` references `hb_*`. fontconfig/expat are not built
  because the only file that includes `<fontconfig/fontconfig.h>`
  (`find-font-unix.c`) is not compiled on OHOS; `find-font-ohos.c` enumerates
  `/system/fonts` instead. `deps/freetype.sh` documents the reasoning per
  optional back end.
