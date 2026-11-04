# Step-by-step: one or two candidate GPUs

**Experimental 0.2.2 test build.** Check the [candidate configurations and inventory coverage](COMPATIBILITY.md) first. Physical two-GPU boot, recovery and performance remain unverified.

## 1. Prepare the PC and tools

Use an existing FAT32 USB with its contents backed up; 8 GB is ample and a second USB is unnecessary. Install Git, Python 3.14+, LLVM 20.1.8, and Visual Studio C++ Build Tools with the Windows SDK. Use a PowerShell environment permitted to run these scripts; host execution was tested with PowerShell 7.

Finish driver updates first. Save your BitLocker recovery key before firmware changes. The procedure requires UEFI boot, Secure Boot off, Windows fully decrypted with BitLocker protection off, and Fast Startup off. The helper checks these and changes none of them. Leave NVIDIA Automatic Tuning off and keep driver, power limit, voltage curve and offsets fixed for measurement.

## 2. Extract and acquire the reviewed source

Extract this version into a fresh folder and open administrator PowerShell there. Reopen it there after every boot. Source receipts are bound to the kit version's patch.

```powershell
.\Get-Source.ps1 -DualGpu -Execute
.\Start.ps1 -Action Check
```

This obtains the reviewed source plus SHA-bound patch in `Windows-GPU-UNLOCK-dual-dev`, and the independently pinned firmware source. Existing production checkouts remain intact. Start selects the patched checkout automatically. `-Repo .\Windows-GPU-UNLOCK-dual-dev` can select it explicitly. Missing assets are expected until step 3; resolve other BLOCKED/UNKNOWN rows.

If `Check` reports `OBSERVE`, go to step 5, boot the probe once after a full shutdown, and keep its diagnostic for review. Inventory collection needs the probe tools and a FAT32 USB. Steps 3–4 and 6–8 apply to the unlock path for a `CANDIDATE` setup.

`Check` also shows the amount of GPU memory reported by the Windows driver when available. The probe measures usable VRAM again before the driver loads. An RTX 3080 capture marked `probe-capture-only=1` can be reviewed as research evidence and stays out of the build count.

## 3. Prepare firmware locally

```powershell
py -3.14 .\prepare-assets.py --firmware-repo .\gpu-unlock-firmware-source --windows-repo .\Windows-GPU-UNLOCK-dual-dev --work-dir .\asset-work --download --execute
.\Start.ps1 -Action Check
```

Use a local work folder, not the USB. This runs the pinned generators and verifies all five output hashes; retain their licenses locally. It installs no GPU driver. Explicit `-Python`, `-Clang`, `-LldLink`, `-VcVars` and `-Assets` can select nonstandard locations.

## 4. Save stock measurements

Fully shut down and boot **Windows Boot Manager directly**, bypassing any unlock USB. Close GPU applications. Use a Python interpreter containing CUDA-enabled PyTorch:

```powershell
nvidia-smi --query-gpu=name,pci.bus_id --format=csv
$tensorPython = 'C:\Path\To\TorchEnvironment\python.exe'
& $tensorPython .\benchmark-tensors.py --gpu 00000000:01:00.0 --label stock --output .\stock-card-a.json
```

Replace the example address with the actual card's full PCI address. For two cards repeat sequentially with its other address and `stock-card-b.json`. `--gpu` is mandatory with two installed cards, including identical models. Save these files. The benchmark waits for idle and refuses more than 2 GiB of existing GPU-memory use.

## 5. Stage read-only diagnostics

**Replace `E` with your actual FAT32 USB letter in every command.**

```powershell
.\Start.ps1 -Action Probe -Drive E -Execute
```

This builds and stages a read-only probe, preserving the previous USB bootloader. It does not format or unlock the GPU. Without `-Execute` the action only previews its plan.

## 6. Collect two whole-set cold captures

Fully shut down, power on and choose the UEFI USB in the motherboard's one-time boot menu. The key varies by motherboard; F11 is not universal. Let diagnostics return to Windows. Repeat from **another full shutdown**. A restart does not replace these cold captures.

Keep both cards, slots and displays unchanged. Each complete capture must include the entire installed set, separate BDF-ordered `PROM00.BIN`/`PROM01.BIN`, driver dumps and the full shared graph. Two files do not prove the operator performed two full shutdowns. Keep all evidence private.

If the count remains 0/2 or an incomplete/refused capture appears, inspect its reason before another boot. An unsupported ID/resource/layout needs review, not repeated power cycles. [Troubleshooting](COMPATIBILITY.md#why-the-capture-count-can-stay-at-02).

## 7. Build and run required host jobs

```powershell
.\Start.ps1 -Action Build -Drive E -Execute
```

This validates both captures, generates this PC's exact one/two-card profile, runs applicable actual-PROM/firmware tests for every card plus whole-pair release/handoff replay, and builds the package. The console has 22 required jobs; a nonconsole peer has 11 applicable jobs; three pair jobs bind the complete set. Host tests simulate EFI services in RAM and do not unlock a GPU. A refusal stops the build; there is no compatibility override. This action stops before staging the unlock.

## 8. Stage the locally built unlock

```powershell
.\Start.ps1 -Action StageUnlock -Drive E -Execute
```

Only proceed after the build succeeds. This rechecks exact source/profile/fixture evidence and stages the wrapper, child and verified assets. It does not reboot or change boot priority.

## 9. Supervise the unlock boot

Fully shut down and select the UEFI USB. Wait without pressing T, U or Enter. The display can go black during headless handoff. Do not reset between unlock and Windows.

After Windows returns, inspect the **fresh current-boot** `RTX3090-UNLOCK\HLSnnnnnn.TXT` and `AUTOnnnnnn\REPORT.TXT` records. Require success and cleanup (`clean=1`) for every targeted card and a successful final Windows handoff with a working display. Old successful logs or one card succeeding cannot establish the whole boot succeeded. The two-card path has not yet received a physical validation here.

## 10. Measure and compare each card

Close GPU applications; assign the same interpreter after reboot:

```powershell
$tensorPython = 'C:\Path\To\TorchEnvironment\python.exe'
& $tensorPython .\benchmark-tensors.py --gpu 00000000:01:00.0 --label unlocked --output .\unlocked-card-a.json
& $tensorPython .\compare-tensors.py --before .\stock-card-a.json --after .\unlocked-card-a.json --output .\comparison-card-a.json
```

Use the actual matching address. Repeat sequentially for card B with separate filenames. The comparator binds physical UUID/BDF and matching software/settings, checks complete outputs and reports FP32/FP16/BF16/TF32 changes. It does not prove live unlock state or Stable Diffusion speedup. Driver updates require a new matched stock/unlocked pair on the new driver.

## Recovery

If anything fails, fully power off and boot **Windows Boot Manager directly**, bypassing the USB. Removing a USB from running Windows does not revert that session. A failure after one GPU was mutated is not a demonstrated automatic rollback. Keep the USB out of automatic boot priority until supervised testing succeeds. Share the starter kit, never a prepared USB or private capture/profile directory.
