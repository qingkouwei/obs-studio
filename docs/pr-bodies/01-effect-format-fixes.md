# libobs: fix format_conversion.effect literals and redundant explicit LOD

<!-- base: obsproject/obs-studio master ← qingkouwei:pr/effect-format-fixes -->
<!-- one-click: https://github.com/obsproject/obs-studio/compare/master...qingkouwei:obs-studio:pr/effect-format-fixes?expand=1 -->

## What

Two behaviour-neutral cleanups in `libobs/data/format_conversion.effect`, found while porting OBS to HarmonyOS (a GLES-only shader target whose parser is stricter than desktop):

1. **`65535. / 4095` → `65535. / 4095.`** — the divisor is written as an untyped int literal while every neighbouring constant uses a float literal. On the strict parser this is an implicit int/float mix in a scalar multiply chain.
2. **Drop explicit `, 0` LOD argument** on five `image.Sample(def_sampler, uv, 0)` call sites (PSUYVY/PSYUY2/PSYUY2_PQ/PSYUY2_HLG/PSYVYU `_Reverse`). The default LOD is already 0; the three-argument overload is what strict GLES-target parsers reject.

## Why it matters beyond HarmonyOS

These are latent correctness issues in the effect source itself — the intent of the code is unambiguous (float math, default LOD), and the current spelling only happens to work because desktop parsers are lenient.

## Verification

- Compiled and rendered on device (HarmonyOS NEXT, GLES 3.2): all stock effects compile, YUV conversion paths verified by recording + RTMP streaming with frame extraction (content matches source pixels).
- No change in emitted math on desktop targets (literal suffix and default argument only).
