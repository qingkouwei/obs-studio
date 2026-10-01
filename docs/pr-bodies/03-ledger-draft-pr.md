# [Draft] HarmonyOS NEXT port — progress ledger (do not merge yet)

<!-- base: obsproject/obs-studio master ← qingkouwei:harmonyos-port -->
<!-- one-click: https://github.com/obsproject/obs-studio/compare/master...qingkouwei:obs-studio:harmonyos-port?expand=1 -->

**Draft on purpose.** This branch is a public working ledger for the HarmonyOS NEXT (arm64, API 26) port of OBS Studio 32.2.2, run per the maintainer-friendly process discussed upstream: small independently-reviewable slices go out as separate PRs; this one tracks the whole and gives reviewers a single place to see where the port stands.

## Status (verified on real hardware, MatePad Edge in PC/2in1 mode)

| Capability | State |
|---|---|
| libobs boot (obs_startup, module search, config) | ✅ |
| Graphics backend (EGL + GLES 3.2, all stock effects compile) | ✅ |
| Plugin loading (12 modules under OHOS linker-namespace constraints) | ✅ |
| Screen capture (AVScreenCapture NDK, PC-mode share picker) | ✅ |
| Live preview | ✅ |
| Recording → playable MP4 (h264 1080p60 + aac, surface-input encoder on shared EGL context) | ✅ |
| RTMP streaming (verified via mediamtx ingest + HLS pull-back) | ✅ |
| Background recording (app switched away, 221 s file, no ANR) | ✅ |

## What is in this branch

- `libobs`, `libobs-opengl`: `__OHOS__` branches for GLES/EGL (shader parser, texture formats, effect header)
- `plugins/harmony-capture`: screen capture source (AVScreenCapture)
- `plugins/harmony-vcodec`: surface-input H.264 encoder (OH_VideoEncoder) + NV12→RGB BT.709 blit
- `harmony/`: ArkTS/ArkUI host app (XComponent surface, napi bridge, plugin manifest)
- `build-aux/harmony/`: toolchain scripts + one-shot on-device verification script
- `docs/harmonyos-*.md`: migration design, session log, and a per-bug port journey writeup

## Independently valuable slices (separate PRs)

1. `pr/effect-format-fixes` — format_conversion.effect literal/LOD cleanups (pure bugfix)
2. `pr/glsl-es-compat` — GLSL ES 3.0 emission fixes in gl-shaderparser.c

More slices to follow (BGRA texture-combo fallbacks, mipmap-filter clamp for single-level textures) as they can be expressed target-neutrally.

## Before any mergeable port PR

RFC on the dev forum first (draft text kept in `docs/pr-bodies/04-rfc.md` here). Open design questions for maintainers: GLES-only backend shape, effect `#version` selection, plugin discovery under sandboxed filesystems.
