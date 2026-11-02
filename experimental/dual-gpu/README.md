# Experimental one/two-GPU flow

Version 0.2.0 implements the guarded capture -> local profile -> actual-input host tests -> build -> explicit staging path for **one or two** candidate NVIDIA cards. Physical two-card boot/recovery and performance remain unverified. Use the [step-by-step guide](../../docs/QUICKSTART.md).

The exact preliminary IDs are vendor `10DE` with device `2204`, `2203`, `2487`, `2504`, `2484` or `24C9`. Identical or different admitted models are allowed. Third, unsupported, ambiguous or unknown NVIDIA controllers are refused; matching IDs still need exact chip/VRAM, firmware-code, resources and ownership checks. [Compatibility](../../docs/COMPATIBILITY.md).

From the kit root:

```powershell
.\Get-Source.ps1 -DualGpu -Execute
.\Start.ps1 -Action Check
py -3.14 .\prepare-assets.py --firmware-repo .\gpu-unlock-firmware-source --windows-repo .\Windows-GPU-UNLOCK-dual-dev --work-dir .\asset-work --download --execute
.\Start.ps1 -Action Check
# Replace E with the actual existing FAT32 USB:
.\Start.ps1 -Action Probe -Drive E -Execute
# Two separate full shutdown -> UEFI USB -> Windows boots, with cards/slots unchanged.
.\Start.ps1 -Action Build -Drive E -Execute
.\Start.ps1 -Action StageUnlock -Drive E -Execute
```

Save stock measurements before the first unlock boot. The [quickstart](../../docs/QUICKSTART.md) includes exact per-card benchmark selection, fresh-log verification and Windows Boot Manager recovery. No command above changes security settings, formats a USB, promotes boot priority or reboots.

## What the source binds

The acquisition helper applies the reviewed hash-bound patch to the pinned PR #82 source in a separate `Windows-GPU-UNLOCK-dual-dev` folder. See [source.json](source.json). Start selects it automatically when present; the legacy source remains available separately.

The read-only probe orders targets by full physical PCI address, validates both candidate resource envelopes before deep capture and stores separate `PROM00.BIN`/`PROM01.BIN` files. Each boot records the complete shared ownership graph. Two whole-set agreeing cold captures are required, never one capture per card.

The generator derives the actual console route, immutable per-card identity/configuration/PROM/driver fingerprints and full child paths. The console's 22 host jobs, a peer's 11 applicable jobs and three pair jobs must pass against the exact source, headers and private fixture bytes before a write build. Whole-graph replay preserves peer and unrelated handles/ownership. An unbound peer or reviewed NVIDIA-only peer ownership is admitted; active unreviewed EDID/text/graphics/combo peer consumers are refused. No originating PC profile or donor fixed motherboard profile is substituted.

The offline `analyze_pair.py` is an observation reviewer and deliberately returns `can_unlock: false`. The complete pipeline uses separate exact-input test/build evidence; an observation report is not a build permit. Firmware transactions run sequentially. Final wrapper handoff requires every target's completed state; a partial failure does not establish rollback of an earlier card.

Private captures, driver images, PROMs, generated headers and test evidence remain local. Only source and reproducible source patches are distributed.

## Validation limits

RAM-only controls cover one card, two unbound/bound peers, shared NVIDIA agents and the console appearing second in BDF order. Per-GPU benchmark selection binds UUID/BDF, including identical models. These controls do not supply physical dual-card qualification. The connected development PC has one RTX 3090; no physical dual-card gain or recovery result is claimed.

## Credits

Based on Windows GPU UNLOCK and contributors, [jingx8885's PR #82](https://github.com/windows-GPU-UNLOCK/Windows-GPU-UNLOCK/pull/82) at `e27d200aaaee8de67a12bce4ab48eba58c0c8551`, and [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock). The donor runtime is unmerged upstream work. GPL-2.0-only and upstream notices apply; no endorsement is claimed.
