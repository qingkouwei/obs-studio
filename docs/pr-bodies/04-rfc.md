# RFC draft — HarmonyOS NEXT as a supported platform (for dev forum / Discord #dev)

Subject: RFC: HarmonyOS NEXT port — landing shape for a third platform family

Hi all —

I've been porting OBS 32.2.2 to HarmonyOS NEXT (arm64, API 26) and have the full chain working on real hardware: libobs boot, EGL/GLES 3.2 backend, plugin loading, screen capture, live preview, MP4 recording, and RTMP streaming — all verified on a MatePad Edge running in PC/2in1 mode.

Before any large PR, this RFC asks: **what shape would a mergeable HarmonyOS contribution take?** My assumptions to confirm or tear down:

1. **Graphics**: HarmonyOS exposes OpenGL ES only (no desktop GL, no Vulkan path in scope). I'd like to upstream the GLES-compat fixes first as standalone PRs (shader parser emission, effect literal cleanups) since they're target-neutral. Would a "GLES target" capability flag in the shader pipeline be a reviewable abstraction, vs. OS-macro branches?

2. **Backends**: capture = AVScreenCapture NDK, encode = OH_VideoEncoder (surface input, shared EGL context), mux = existing in-process mp4_output (ffmpeg muxer's fork/exec model doesn't fit the app sandbox). Each would be a new plugin under `plugins/`. Acceptable placement?

3. **Host app**: the ArkTS/ArkUI shell + napi bridge is inherently out-of-tree-shaped; I plan to keep it in a separate repo unless maintainers want it under `harmony/`.

4. **Process**: I'm running the whole port as a public ledger branch with small slices PR'd independently (three are up now: effect float-literal typos, redundant zero texel-offsets, `float(lod)` in textureLod emission). Happy to rebase/reshape per whatever review cadence works.

Full per-bug journey writeup available; happy to answer specifics.

— qingkouwei
