# Windows GPU Unlock Starter Kit

**Version 0.2.1 test build.** Read-only inventory for NVIDIA-listed RTX 30-series cards and an experimental unlock path for selected configurations.

[Step-by-step setup](docs/QUICKSTART.md) · [Compatibility](docs/COMPATIBILITY.md) · [One/two-card implementation](experimental/dual-gpu/README.md) · [Originating results](docs/ORIGINATING-RESULTS.md)

The helper detects one or two installed candidate NVIDIA cards, prepares a read-only USB probe, generates a profile from that PC's own complete captures, runs the required host jobs and builds the exact local USB unlock package. Build and staging are separate explicit actions. The guarded one/two-card path is implemented; passing its host tests does not establish physical two-card qualification.

The unlock path requires every installed NVIDIA display controller to be an admitted candidate. These device IDs all use vendor `10DE`.

| Card | Candidate device ID |
|---|---|
| RTX 3060 12GB, selected variants | `2487`, `2504` |
| RTX 3060 Ti 8GB, selected variant | `24C9` |
| RTX 3070 8GB, selected variant | `2484` |
| MSI RTX 3070 Ti 8GB | `2482` with subsystem `1462:5052` |
| RTX 3080 12GB | `220A` |
| RTX 3090 24GB | `2204` |
| RTX 3090 Ti 24GB | `2203` |

Identical or different candidates can form a two-card set. The kit checks exact chip and VRAM, PCI resources, UEFI driver code, console ownership and both cold captures before an unlock build. Physical two-card validation is pending.

For other IDs in the [RTX 30-series catalog](rtx30-pci.json), including the RTX 3050, RTX 3080 10GB and laptop variants, `Check` shows `OBSERVE`. `Probe` can collect a read-only UEFI inventory for review. Build and StageUnlock require a qualified candidate on every card.

## Start here

Use one existing FAT32 USB stick; 8 GB is ample. Install Git, Python 3.14+, LLVM 20.1.8 and Visual Studio C++ Build Tools with the Windows SDK. UEFI boot, Secure Boot off, the Windows volume fully decrypted with BitLocker protection off, and Fast Startup off are prerequisites. The helper reads these settings and changes none of them.

Extract the kit and open administrator PowerShell in its folder:

```powershell
.\Get-Source.ps1 -DualGpu -Execute
.\Start.ps1 -Action Check
py -3.14 .\prepare-assets.py --firmware-repo .\gpu-unlock-firmware-source --windows-repo .\Windows-GPU-UNLOCK-dual-dev --work-dir .\asset-work --download --execute
.\Start.ps1 -Action Check
```

The explicit `-DualGpu` selects the reviewed one/two-card source in a separate `Windows-GPU-UNLOCK-dual-dev` folder. `Start.ps1` selects that checkout automatically when present. Existing legacy checkouts are retained. Source and patch hashes are bound by [source.json](experimental/dual-gpu/source.json). Unknown readiness states block execution.

**Replace `E` with your actual FAT32 USB letter.** Save a stock benchmark before the first unlock boot, then:

```powershell
.\Start.ps1 -Action Probe -Drive E -Execute
# Fully shut down -> boot UEFI USB -> return to Windows. Repeat from another full shutdown.
.\Start.ps1 -Action Build -Drive E -Execute
.\Start.ps1 -Action StageUnlock -Drive E -Execute
```

Follow the [full quickstart](docs/QUICKSTART.md) for cold boots, current-boot log checks and recovery. Commands without `-Execute` show the plan. Check is read-only. The kit does not format, change boot priority, update a driver or reboot.

Both captures must contain the entire unchanged installed set. The write build requires each card's actual PROM/firmware jobs, the actual console's host jobs and whole-pair graph replay. Generated profiles, captures and driver images stay private. Unreviewed peer display-driver ownership is refused rather than bypassed.

## Measure each physical card

Use the same CUDA-enabled PyTorch interpreter before and after, with driver, power limit, voltage curve and offsets unchanged. Close GPU applications. Find each physical address:

```powershell
nvidia-smi --query-gpu=name,pci.bus_id --format=csv
$tensorPython = 'C:\Path\To\TorchEnvironment\python.exe'
& $tensorPython .\benchmark-tensors.py --gpu 00000000:01:00.0 --label stock --output .\stock-card-a.json
# After a verified unlock boot, use the same physical address and interpreter:
& $tensorPython .\benchmark-tensors.py --gpu 00000000:01:00.0 --label unlocked --output .\unlocked-card-a.json
& $tensorPython .\compare-tensors.py --before .\stock-card-a.json --after .\unlocked-card-a.json --output .\comparison-card-a.json
```

Replace the example address. With two GPUs, `--gpu` is required. Run cards sequentially with separate filenames; results bind UUID and BDF, including identical models. The benchmark uses 4096-square matrices, three trials and 30 timed samples per mode, checking every output element for its all-ones input. It measures FP32, FP16, BF16 and TF32; it is not an application speed guarantee.

The historical originating RTX 3090 at 350 W on driver 617.42 measured FP16 +80.4%, BF16 +84.6%, TF32 +86.9%, FP32 -0.7%. These are single-card matrix results, not a dual-card or Stable Diffusion measurement. [Historical data](research/originating-rtx3090/).

## Recovery and sharing

If a boot fails, fully power off and select Windows Boot Manager directly, bypassing the USB. Removing the USB during a Windows session does not revert that session. A failure after one card is mutated is not a proven rollback. Supervise the first boot; inspect fresh per-card transaction/cleanup and final Windows-handoff logs.

Share this source-only kit, not a prepared USB or private working directory. It contains no EFI, firmware, VBIOS/PROM, driver binary or generated machine profile. See [validation](VALIDATION.txt), [notices](NOTICES.txt) and [license](LICENSE).

This helper builds on Windows GPU UNLOCK and contributors, jingx8885's PR #82, Zagitta/gpu-unlock and earlier port work. It claims neither authorship of their core nor upstream endorsement. The donor PR is unmerged work; this patched path remains experimental.
