# Experimental one/two-GPU development

**Development branch, not a supported dual-GPU unlock release.** The normal
`Start.ps1` workflow remains single-NVIDIA-GPU. This directory contains the
separate source experiment and its reproducible patch; it does not bypass that
production gate or automatically stage an unlock.

The intended target is one or two admitted GPUs, including different models or
two identical models. The candidate PCI IDs remain `2204`, `2203`, `2487`,
`2504`, `2484`, and `24C9` with vendor `10DE`. Exact chip/VRAM/firmware/platform
checks still apply. Third or unrecognized NVIDIA display controllers are refused.

## Implemented

- Explicit read-only one/two-card probe. Both candidate resource/identity
  checks finish before deep capture, targets are ordered by full PCI address,
  and each card gets a separate `PROM00.BIN` / `PROM01.BIN`.
- Offline two-capture reviewer verifies each complete card record, PROM hash,
  cold state, resources and full-graph PCI identity. It never authorizes a write
  build and refuses changes in the installed set between captures.
- Hardening of the upstream PR #82 runtime: exact immutable subsystem matching,
  bounded target discovery, isolated per-card contexts and all-target preflight
  before sequential attempts. See the patch and validation record for limits.
- Per-GPU tensor tests select a physical PCI address and match CUDA by UUID.
  Two identical models and reversed CUDA ordering are covered by mock tests.

## Prepare the isolated source

From the kit root:

```powershell
.\experimental\dual-gpu\Get-Source.ps1
.\experimental\dual-gpu\Get-Source.ps1 -Execute
```

This obtains the pinned contributor source and applies the SHA-256-bound patch
in a separate `Windows-GPU-UNLOCK-dual-dev` directory. It does not install a
driver, change settings, build, stage a USB or boot anything. Existing production
checkouts and unknown destinations are not overwritten.

The experimental probe builder is
`Windows-GPU-UNLOCK-dual-dev/research/dual/build-probe.ps1`. It requires both
`-ExperimentalDual -MaxTargets 2`, the recipient's own Windows ESP GUID and the
normal LLVM 20.1.8/Python tool paths. Its output is a diagnostic EFI only, with a
separate non-unlock manifest. No EFI/firmware/driver binaries are distributed.
The existing single-card build/staging route does not accept its manifest.

Keep both installed cards and their slots unchanged across two full-shutdown
captures. Keep the full logs, per-card PROM files and driver-image dumps private.
The offline reviewer is:

```powershell
python .\Windows-GPU-UNLOCK-dual-dev\research\dual\analyze_pair.py --first C:\PrivateCaptures\DIAG00.TXT --second C:\PrivateCaptures\DIAG01.TXT --output C:\PrivateCaptures\pair-review.json
```

The reviewer intentionally reports `can_unlock: false` and
`can_build_write_efi: false`. Two files alone do not prove separate cold boots.

## Measure each card separately

Find the actual addresses with:

```powershell
nvidia-smi --query-gpu=name,pci.bus_id --format=csv
```

Example using a CUDA-enabled Python environment; replace the address with the
actual card's address and use different result filenames for the other card:

```powershell
python .\benchmark-tensors.py --gpu 00000000:2b:00.0 --label stock --output stock-card-a.json
python .\benchmark-tensors.py --gpu 00000000:2b:00.0 --label unlocked --output unlocked-card-a.json
python .\compare-tensors.py --before stock-card-a.json --after unlocked-card-a.json --output comparison-card-a.json
```

Only use the `unlocked` label after independently verifying that card's boot
transaction. Measurements and labels are not proof of unlock state. Schema-3
results bind both physical UUID and BDF. Legacy schema-2 pairs remain readable
with weaker identity assurance; mixed schemas are refused. The matrix timing
and precision protocol is unchanged. Run one card at a time.

## Still required before this becomes a usable dual-GPU unlock kit

The donor implementation is for specific B660M systems; it is not an ASUS
X570-Pro / EVGA 3090 / ASUS 3060 profile. Do not select its B660M profile for a
different machine.

Generic two-card LOCAL profile generation and per-machine evidence must bind
both captured identities, resources, firmware images and the actual console
route. Whole-pair driver-release/shared-agent replay and final wrapper handoff
verification must be completed. Actual-PROM transaction jobs and a supervised
physical two-card boot remain required. A failure after the first card is
mutated cannot be described as a proven rollback.

The connected development PC has one RTX 3090, so two-card tests here are mocks.
No physical dual-card unlock, recovery or performance gain is claimed. Production
hardware support has not been expanded by publishing this branch.

## Credits

Based on [Windows GPU UNLOCK](https://github.com/windows-GPU-UNLOCK/Windows-GPU-UNLOCK),
[jingx8885's PR #82](https://github.com/windows-GPU-UNLOCK/Windows-GPU-UNLOCK/pull/82)
at `e27d200aaaee8de67a12bce4ab48eba58c0c8551`, and
[Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock). The donor runtime is
unmerged upstream work. GPL-2.0-only and upstream notices continue to apply.
