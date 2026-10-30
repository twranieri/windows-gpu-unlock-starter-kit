# Step-by-step setup

**Check your card before installing tools or preparing a USB.** Candidate NVIDIA device IDs are RTX 3060 12GB `2487`/`2504`, RTX 3060 Ti 8GB `24C9`, RTX 3070 8GB `2484`, RTX 3090 `2204`, and RTX 3090 Ti `2203`. An exact ID match is preliminary; firmware and platform validation still apply.

RTX 3050, RTX 3070 Ti, RTX 3080/3080 Ti, other unlisted RTX 30 variants, laptop variants and RTX 20/40/50 cards are outside this pinned kit. See [compatibility and 0/2 troubleshooting](COMPATIBILITY.md). Each recipient generates their own profile; no originating-machine profile is reused.

## 1. Get the requirements

Use one existing **FAT32 USB**, with its contents backed up. An 8 GB stick is ample. Install Git, Python **3.14**, LLVM **20.1.8**, and Visual Studio C++ Build Tools with the Windows SDK. Use a PowerShell environment permitted to run these reviewed scripts; full host execution was tested with PowerShell 7.

The tensor benchmark needs a CUDA-enabled PyTorch environment with the required precision controls. An existing compatible application environment is suitable. Asset preparation uses Python 3.14; the benchmark can use a different Python, but its before/after runs must use the same one.

## 2. Prepare Windows and firmware settings

Finish driver updates first. Save the BitLocker recovery key before changing firmware settings. The upstream procedure requires UEFI boot, Secure Boot off, the Windows system volume fully decrypted with BitLocker protection off, and Fast Startup off. The kit reads these settings but does not change them.

Turn NVIDIA Automatic Tuning off. Keep driver, power limit, voltage curve and clock offsets unchanged between the two benchmarks.

## 3. Extract the kit and open PowerShell

Open an administrator PowerShell in the extracted kit folder. Reopen PowerShell in this same folder after each reboot. Download the pinned source:

```powershell
.\Get-Source.ps1 -Execute
```

## 4. Check readiness

```powershell
.\Start.ps1 -Action Check
```

Missing firmware assets are expected until the next step. Resolve other blocked or unknown requirements. Use `-Clang`, `-LldLink`, `-Python` or `-VcVars` if tools are outside their usual locations. No unknown security state is treated as a pass.

## 5. Prepare the firmware locally

```powershell
py -3.14 .\prepare-assets.py --firmware-repo .\gpu-unlock-firmware-source --windows-repo .\Windows-GPU-UNLOCK --work-dir .\asset-work --download --execute
.\Start.ps1 -Action Check
```

The first command downloads verified original inputs, runs the pinned generators and checks all five output hashes. It installs no GPU driver or kernel module. Keep these locally generated files and their licenses on the recipient's PC.

## 6. Save the stock benchmark

Fully shut down, then boot **Windows Boot Manager directly**, bypassing the unlock USB. Close GPU applications and release their GPU memory.

Set this to the actual Python executable containing CUDA-enabled PyTorch:

```powershell
$tensorPython = 'C:\Path\To\TorchEnvironment\python.exe'
& $tensorPython .\benchmark-tensors.py --label stock --output .\stock.json
```

Save `stock.json`. The benchmark waits for three idle readings and refuses existing GPU memory use above 2 GiB. It changes no clocks, power limits or boot settings.

## 7. Prepare the diagnostic USB

**Replace `E` with the actual USB drive letter in all commands below.**

```powershell
.\Start.ps1 -Action Probe -Drive E -Execute
```

This stages a read-only diagnostic probe. The upstream procedure preserves a previous USB bootloader. It does not format the USB.

## 8. Collect two separate cold captures

Fully shut down, power on, and select the **UEFI USB** from the motherboard's one-time boot menu. Let the probe return to Windows.

Repeat from **another full shutdown**. A Windows restart does not replace the two cold boots. Keep the raw capture files private and local.

If the count stays at 0/2, inspect the diagnostic refusal before repeating boots. `capture-complete=0` is not a valid capture; `probe-unreviewed-envelope` on an unlisted PCI ID requires hardware-support work, not more power cycles. See [the diagnostic explanation](COMPATIBILITY.md#why-the-capture-count-can-stay-at-02).

## 9. Build this PC's profile and run its tests

```powershell
.\Start.ps1 -Action Build -Drive E -Execute
```

Wait for capture validation and all 22 required host jobs to pass. If the workflow refuses the machine, stop and review the reason; there is no compatibility override.

## 10. Stage the unlock

Only after the build succeeds:

```powershell
.\Start.ps1 -Action StageUnlock -Drive E -Execute
```

This is the explicit step that stages the locally built unlock wrapper and child. It does not reboot or change boot priority.

## 11. Perform the supervised unlock boot

Read the [upstream headless USB instructions](https://github.com/impacifist/Windows-GPU-UNLOCK/blob/75071aa134616c3d65ad315e0cf2810bf34b191b/docs/HEADLESS-USB.en.md). Fully shut down and select the UEFI USB again.

Wait without pressing T, U or Enter. The display can go black during handoff. **Do not reset between the unlock and Windows.**

After Windows returns, inspect the fresh current-boot files:

```text
USB:\RTX3090-UNLOCK\HLSnnnnnn.TXT
USB:\RTX3090-UNLOCK\AUTOnnnnnn\REPORT.TXT
```

Require a successful transaction, cleanup (`clean=1`), successful Windows handoff and a working display. Old successful logs do not establish the current boot's result.

## 12. Run the unlocked benchmark and compare

Close GPU applications again. Reassign the same interpreter path after the reboot:

```powershell
$tensorPython = 'C:\Path\To\TorchEnvironment\python.exe'
& $tensorPython .\benchmark-tensors.py --label unlocked --output .\unlocked.json
& $tensorPython .\compare-tensors.py --before .\stock.json --after .\unlocked.json --output .\comparison.json
```

The report contains before/after FP32, FP16, BF16 and TF32 rates, correctness checks and percentage changes. Existing result files are never overwritten; use new filenames for another attempt. A driver update requires a new matched pair on the new driver.

## Recovery

If the unlock errors or Windows fails to return, fully power off and boot **Windows Boot Manager directly**, bypassing the USB. Removing a USB from a running Windows session does not revert that session's unlock. Share the starter ZIP, not a prepared USB or private capture directory.
