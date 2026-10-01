# libobs-opengl: GLSL ES 3.0 compatibility in the shader parser

<!-- base: obsproject/obs-studio master ← qingkouwei:pr/glsl-es-compat -->
<!-- one-click: https://github.com/obsproject/obs-studio/compare/master...qingkouwei:obs-studio:pr/glsl-es-compat?expand=1 -->

## What

Three emission fixes in `gl-shaderparser.c` that make the parsed GLSL valid under `#version 300 es` — relevant to **any GLES-only target**, not just HarmonyOS:

1. **Skip the `out gl_PerVertex` interface block.** GLSL ES 3.0 declares `gl_PerVertex` implicitly and rejects a redeclaration carrying an explicit storage qualifier (`"Invalid qualifier 'out' for interface block"`). `gl_Position` is available without declaration.
2. **Explicit `vec2()`/`vec3()` wrap around `textureSize()`** in the emitted `obs_load_2d`/`obs_load_3d` helpers. ES has no implicit `ivec`→`vec` vector conversion.
3. **`float(lod)` argument to `textureLod()`.** ES forbids the implicit `int`→`float` argument conversion desktop GLSL still allows for legacy reasons.

## Gating

The `#version 300 es` header + default-precision block are currently emitted under `__OHOS__`. The three fixes above are written to be **harmless on desktop** (points 2 and 3 are valid desktop GLSL too; point 1 is behind the ES branch). If upstream prefers, the same emission can be gated on a "GLES target" capability flag instead of an OS macro — happy to rework.

## Verification

Porting OBS 32.2.2 to HarmonyOS NEXT (arm64, API 26, Maleoon 916B, GLES 3.2): all stock effects compile and render on device; end-to-end preview / recording (h264+aac mp4) / RTMP streaming verified with frame extraction.

Found while working on the HarmonyOS port (see also the draft ledger PR `harmonyos-port` on my fork).
