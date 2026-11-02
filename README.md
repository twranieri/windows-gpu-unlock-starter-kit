# Windows GPU Unlock Starter Kit

**Version 0.2.0 experimental: one or two selected RTX 30-series GPUs. Physical two-card boot/recovery and performance remain unverified.**

[Download source-only kit](dist/gpu-unlock-starter-kit-v0.2.0.zip) · [Step-by-step setup](docs/QUICKSTART.md) · [Compatibility](docs/COMPATIBILITY.md) · [One/two-card implementation](experimental/dual-gpu/README.md) · [Originating results](docs/ORIGINATING-RESULTS.md)

The helper detects one or two installed candidate NVIDIA cards, prepares a read-only USB probe, generates a profile from that PC's own complete captures, runs the required host jobs and builds the exact local USB unlock package. Build and staging are separate explicit actions. The guarded one/two-card path is implemented; passing its host tests does not establish physical two-card qualification.

Every installed NVIDIA display controller must be admitted. All entries use vendor `10DE`:

| Card | Candidate device ID |
|---|---|
| RTX 3060 12GB, selected variants | `2487`, `2504` |
| RTX 3060 Ti 8GB, selected variant | `24C9` |
| RTX 3070 8GB, selected variant | `2484` |
| RTX 3090 24GB | `2204` |
| RTX 3090 Ti 24GB | `2203` |

Identical or different admitted models can form the two-card set. An ID match is preliminary: exact chip/VRAM, PCI resources, UEFI driver code and console ownership still have to pass. Third, unsupported, unknown or ambiguous NVIDIA controllers are refused. RTX 3080 `2206`, RTX 3070 Ti, other unlisted variants, laptop variants and RTX 20/40/50 cards are outside this kit.

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
