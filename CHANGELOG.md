# Changes

## 0.1.2 — 2026-10-30

- Put the exact candidate PCI IDs and excluded RTX 30-series models in the README and quickstart; add a compatibility and diagnostic guide.
- Explain that every recipient generates their own LOCAL profile and that the upstream RTX3090-UNLOCK folder name does not bind the kit to one card.
- Add a read-only preliminary GPU check against the pinned admission data before preparing the USB. An admitted PCI ID is a candidate, not full compatibility approval.
- Report failed diagnostic reasons rather than presenting an unsupported capture as a repeated 0/2 cold-boot task.
- Keep both upstream source revisions, firmware assets and all per-machine validation gates unchanged. This release adds no GPU support and no new physical qualification.

## 0.1.1 — 2026-10-30

- Publish the source-only Windows preparation kit, step-by-step guide and historical RTX 3090 report/data.
- Include portable before/after FP32, FP16, BF16 and TF32 benchmarks with complete-output checks and strict matched-result comparison.
- Keep the unlock implementation pinned to upstream revision `75071aa134616c3d65ad315e0cf2810bf34b191b` and its existing capture, profile, staging and 22-host-job gates.
- Exclude firmware/EFI binaries, private captures, generated profiles and application-generation comparison tools.

This preparation/measurement helper has host validation and local asset-generation evidence. It is not an additional physical boot or cross-system qualification.
