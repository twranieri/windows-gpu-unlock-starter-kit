# Changes

## 0.1.1 — 2026-10-30

- Publish the source-only Windows preparation kit, step-by-step guide and historical RTX 3090 report/data.
- Include portable before/after FP32, FP16, BF16 and TF32 benchmarks with complete-output checks and strict matched-result comparison.
- Keep the unlock implementation pinned to upstream revision `75071aa134616c3d65ad315e0cf2810bf34b191b` and its existing capture, profile, staging and 22-host-job gates.
- Exclude firmware/EFI binaries, private captures, generated profiles and application-generation comparison tools.

This preparation/measurement helper has host validation and local asset-generation evidence. It is not an additional physical boot or cross-system qualification.
