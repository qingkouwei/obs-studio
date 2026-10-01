# OBS Studio — HarmonyOS ArkUI frontend (scaffold)

Native ArkUI/ArkTS rewrite of the OBS frontend for **HarmonyOS PC (2in1)**, API 26 /
platformVersion 26.0.0, bundle `com.obsproject.studio.harmony`. The ~85.5 kLOC Qt6 Widgets
frontend in `../frontend/` is **not** ported; instead this ArkUI shell drives the existing C
core (`libobs`) through a Node-API (NAPI) bridge.

## Architecture

```
ArkTS UI (ets/)  ──NAPI──>  libobs_bridge.so (C++)  ──>  libobs.so + plugins
                                    │
                     XComponent(SURFACE) ──> NativeWindow ──> EGL surface
                                    │        (program/preview canvas; libobs's
                                    │         graphics subsystem renders into it)
                     AVScreenCapture  (display + window capture sources)
                     OH_AudioCapturer (desktop loopback "内录" + microphone)
                     OH_VideoEncoder  (hardware H.264/H.265 encode)
                     librtmp          (vendored in ../plugins/obs-outputs/librtmp)
```

Layout: `pages/Index.ets` (desktop grid: preview · scenes · sources · mixer · transport),
`components/*` (`@ComponentV2` structs), `model/ObsModel.ets` (`@ObservedV2` state +
`ObsController`), `napi/obsBridge.ets` (defensive typed wrapper), `common/Logger.ets`.
Native: `cpp/napi_init.cpp`, `cpp/obs_bridge.cpp`, `cpp/xcomponent_surface.cpp`,
`cpp/CMakeLists.txt`.

## Two build modes (HAVE_LIBOBS)

The bridge **always compiles**, with or without libobs:

- **Shell-only (default, what builds today).** `OBS_HARMONY_PREFIX` is unset, `HAVE_LIBOBS`
  is undefined. Every libobs-dependent NAPI call returns a `napi` error ("libobs core is not
  linked"); `ets/napi/obsBridge.ets` catches it and logs, so the UI stays up. What is REAL in
  this mode: the XComponent→NativeWindow→EGL surface seam (`xcomponent_surface.cpp` creates a
  live EGL window surface and clears it), the OHAudio desktop-loopback + microphone capturers,
  and the per-track peak/RMS metering fed to the mixer. So the window renders and the audio
  meters move before the core port lands.
- **Linked core (`-DHAVE_LIBOBS`).** The genuine calls compile in: `obs_startup`,
  `obs_reset_video`/`obs_reset_audio`, `obs_scene_create`, `obs_source_create`, `obs_scene_add`,
  `obs_sceneitem_set_visible`, `obs_service_create("rtmp_custom")`, `obs_output_create`
  (`rtmp_output` / `ffmpeg_muxer`), `obs_video_encoder_create`/`obs_audio_encoder_create`,
  `obs_output_start`, `obs_get_video`/`obs_get_audio`, `obs_output_get_total_bytes` /
  `..._frames_dropped` / `..._total_frames`, and `obs_display_create` on the XComponent surface.

To link the core, stage a cross-compiled libobs (headers + `lib/libobs.so` + deps) and point
the cache var at it:

```
export OBS_HARMONY_PREFIX=/path/to/staging   # or -DOBS_HARMONY_PREFIX=... in entry/build-profile.json5
# staging layout: include/obs/obs.h (or include/obs.h) and lib/libobs.so
```

`CMakeLists.txt` auto-detects the staging dir, defines `HAVE_LIBOBS`, adds both
`<prefix>/include/obs` and `<prefix>/include` (for simde & other dependency headers — the
repo's `.deps-harmony/include` already has them), and links any of {jansson, mbed*, z, lzma,
speexdsp, curl} it finds. Note this repo already contains an in-progress core port:
`libobs/obs-harmony.c`, `libobs-opengl/gl-harmony-egl.c`, `cmake/harmony/`, and staged deps in
`.deps-harmony/`. The bridge matches that port's window contract exactly: the XComponent's
`OHNativeWindow*` is passed through `gs_init_data.window.display` (read back by
`gs_window_native_window()` in `gl-harmony-egl.h`). Two integration details the bridge also
handles: libobs's `LOG_*` enum collides with hilog's (renamed via macros around the includes),
and libobs headers need a generated `obsconfig.h` + `OBS_INSTALL_PREFIX` from the outer build.

## Verified / not verified

- VERIFIED (this machine, DevEco SDK API 26, hvigor 6.26.4): full `assembleHap` in shell-only
  mode — **BUILD SUCCESSFUL**; `libobs_bridge.so` compiles + links for arm64-v8a; all ArkTS
  compiles under the real ArkTS compiler; HAP packages with `deviceTypes:["2in1"]`,
  `minWindowWidth/Height 1024x640`, `supportWindowMode`, and all six permissions.
- VERIFIED (syntax only): the `HAVE_LIBOBS` branch of all three .cpp files passes
  `clang++ -fsyntax-only` against the repo's real `libobs/` headers + `.deps-harmony/include`
  (simde) with a stub `obsconfig.h`. Not link-verified — no cross-compiled `libobs.so` exists yet.
- NOT VERIFIED: signing (no cert), install/run on a device (`hdc install`), actual loopback
  audio behavior on 2in1 hardware, and anything requiring the linked core.

## Build & run

```bash
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export PATH=/Applications/DevEco-Studio.app/Contents/tools/node/bin:$PATH
cd harmony
/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin/ohpm install --all
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap
# -> entry/build/default/outputs/default/entry-default-unsigned.hap

# sign (DevEco auto-sign, or a release profile), then:
hdc install entry-default-signed.hap
hdc shell aa start -a EntryAbility -b com.obsproject.studio.harmony
```

Signing is skipped without a cert (`hvigor WARN: Will skip sign 'hos_hap'`); the produced
`entry-default-unsigned.hap` must be signed before `hdc install` accepts it.

## Permissions (module.json5)

| Permission | Level | Notes / degradation without it |
|---|---|---|
| `INTERNET` | normal | RTMP push. No streaming without it. |
| `MICROPHONE` | user_grant | Requested at runtime. Mic track reports "permission denied". |
| `KEEP_BACKGROUND_RUNNING` | normal | Long broadcasts survive backgrounding. Continuous task not yet wired. |
| `CUSTOM_SCREEN_CAPTURE` | user_grant (PC/2in1 ≥ API 14) | Requested at runtime. Display/window capture unavailable without it. |
| `CUSTOM_SCREEN_RECORDING` | **RESTRICTED — needs AGC approval** | Suppresses the recording privacy dialog. Without it recording still works; the user just sees the system prompt. Debug auto-signing rejects it. |
| `INPUT_MONITORING` | **RESTRICTED (system_basic) — needs AGC review ~3 days** | Global hotkeys while unfocused. Without it, hotkeys are in-app only (not implemented here). |

The two RESTRICTED permissions only take effect in a release build signed with an AGC-approved
profile; the app must (and does) degrade gracefully when they are absent.

## Desktop audio loopback ("内录") — probed, not assumed

`SystemCapability.Multimedia.Audio.PlaybackCapture` is documented for **Phone/Tablet/TV**;
PC/2in1 support is **unverified**, so it is probed at runtime two ways and the result is shown
in the mixer header: ArkTS `canIUse(...)` AND native `dlsym` of the API-23 async entry point +
`OH_GetSdkApiVersion() >= 23`. Loopback start is **asynchronous**: `RequestPlaybackCaptureStart`
returning success only means "submitted"; the real outcome (including privacy-dialog approval)
arrives in `OnPlaybackCaptureStartResult` as `SUCCESS` / `NOT_AUTHORIZED` / `FAILED`, which the
track state machine surfaces honestly (never faked as Running).

## What is stubbed / not implemented (honest list)

- **libobs itself** is not yet cross-compiled to a `libobs.so`; shell-only mode is what builds
  and links today. The port is in progress in-repo (`obs-harmony.c`, `gl-harmony-egl.c`).
- **Frame compositing**: the XComponent→NativeWindow→EGL seam is real (shell mode creates a
  live EGL surface and clears it), and the bridge passes the window via `gs_init_data.window.display`
  exactly as `gl-harmony-egl.c` expects — but until `libobs.so` is staged, `obs_reset_video`
  can't run, so no libobs frame is composited onto the canvas yet.
- **Hardware encoder**: `OH_VideoEncoder` is linked but no libobs encoder plugin wraps it;
  `WireOutputEncoders` falls back to `obs_x264`/`ffmpeg_aac` and reports honestly if unstaged.
- **Screen-capture source**: `libnative_avscreen_capture.so` is linked, but no
  `harmony_screen_capture` libobs source plugin feeds `OH_AVScreenCapture` frames into scenes.
- **Recording helper**: `ffmpeg_muxer` spawns `obs-ffmpeg-mux`; shipping that ELF via API-24
  `executableBinaryPaths` + `extractNativeLibs` is documented in `module.json5` but not enabled.
- **Continuous task** for background streaming (`KEEP_BACKGROUND_RUNNING`) is declared, not wired.
- **Desktop Extension Kit** (status-bar/quickbar dock): HarmonyOS 6.0.2(22)+, China-mainland
  only — a guarded no-op stub (`common/DesktopExtensionStub.ets`), not implemented.
- **Global hotkeys** (`INPUT_MONITORING`), settings/profile dialogs, and full source
  property editing are out of scope for this scaffold (transport has inline RTMP inputs only).
- Icons under `resources/base/media/` are generated placeholders, not final OBS artwork.
