# Changes

## 0.3.0 — 2026-11-04 (test build)

- Add an experimental RTX 30 and RTX 40 route using pinned `nv-uefi-unlocker` source with separate read-only and transaction builds.
- Bind staging and runtime to one or two exact PCI identities. Check the probe log and firmware files before replacing the USB loader. Require manual boot confirmation.
- Add NVIDIA's 25 listed RTX 40 IDs to the device catalog and select firmware family independently for each card.

## 0.2.2 — 2026-11-04 (test build)

- Add the exact Maxsun RTX 3080 10GB LHR candidate and bounded read-only evidence for the RTX 3080 `2206` and two other LHR subsystems.
- Show driver-reported VRAM by PCI address and keep the cold-probe measurement as the profile input.
- Exercise the reservation calculation at 4, 6, 8, 10, 12, 16 and 24 GiB in RAM.

## 0.2.1 — 2026-11-04 (test build)

- Add RTX 3080 12GB `220A` and the MSI RTX 3070 Ti `2482` / subsystem `1462:5052` as candidates for the guarded profile workflow.
- Add read-only inventory for the other NVIDIA-listed GeForce RTX 30-series IDs. An inventory-only result blocks unlock building and staging.
- Explain PCI decode and legacy BIOS video failures in `Check` using the diagnostic log.

## 0.2.0 — 2026-11-01 (experimental)

- Add the complete reviewed one/two-card capture, per-machine profile, applicable actual-input host-test, build and explicit staging pipeline in an isolated source checkout.
- Preserve full shared ownership graphs; bind each target's PCI identity/resources, PROM, driver code, paths and final state. Refuse third/unknown/unsupported cards and unreviewed peer ownership.
- Add physical UUID/BDF selection and separate measurements for each GPU, including identical models.
- Keep the exact six candidate device IDs; no universal RTX 30-series support is claimed. Physical two-card boot/recovery and performance remain unverified.

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
