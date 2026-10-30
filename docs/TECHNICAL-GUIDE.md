# Windows GPU Unlock Starter Kit

A guided preparation helper for the **pinned, experimental Windows GPU UNLOCK USB workflow**. Version 0.1.2.

The helper finds your tools, Windows boot partition and eligible USB, checks readiness, and resumes the existing capture/build/test pipeline. Each PC gets its own locally generated profile. It does not turn an arbitrary RTX card into a supported configuration.

**Check [the exact candidate PCI IDs and exclusions](COMPATIBILITY.md) before starting.** This kit is reusable across admitted machines and is not tied to the originating RTX 3090. It does not support every RTX 30-series card. RTX 3080 `2206`, for example, is outside the pinned LOCAL workflow.

## What you need

- Windows x64 with UEFI boot, Git, Python **3.14+**, LLVM **20.1.8** (`clang` and `lld-link`), and Visual Studio C++ Build Tools with the Windows SDK.
- **One FAT32 USB stick.** An existing 8 GB stick is ample; no second USB is required by this workflow. Use an existing FAT32 volume and keep a backup of its contents. This kit does not format it.
- Secure Boot off, Windows system volume fully decrypted with BitLocker protection off, and Fast Startup off, as required by the upstream procedure. The readiness check reads these settings; it does not change them.
- A machine accepted by the pinned [local-profile requirements](https://github.com/impacifist/Windows-GPU-UNLOCK/blob/75071aa134616c3d65ad315e0cf2810bf34b191b/docs/NEW-MACHINE.en.md). The card name alone cannot establish this.

Python 3.14 is needed for this kit's native Windows firmware preparation. LLVM and C++ Build Tools can be large downloads. There is no guaranteed 15-minute first setup.

## 1. Get the pinned source

Extract this kit to a normal local folder, then open PowerShell there. These commands use the installed tools; the kit does not install software or change PowerShell policy.

```powershell
# Preview the source downloads, then perform them.
.\Get-Source.ps1
.\Get-Source.ps1 -Execute
```

This obtains the exact Windows and firmware source revisions in `pinned-source.json`. Existing checkouts at another revision are left untouched. It does not run their build or unlock code.

## 2. Check readiness

```powershell
.\Start.ps1 -Action Check
```

Resolve the listed missing tools or settings. If Windows cannot read encryption or Secure Boot state without elevation, run this check from an administrator PowerShell. **UNKNOWN is not treated as a pass.** A passing preparation check still needs the later cold-boot capture checks.

The GPU row is a preliminary PCI-ID check against the pinned admission data. A **CANDIDATE** result does not prove firmware compatibility. Existing incomplete diagnostics show their refusal reason; investigate that reason before collecting more captures.

Tools outside the usual locations can be supplied explicitly with `-Clang`, `-LldLink`, `-Python` and `-VcVars`. `-Repo` selects an existing checkout at the required revision. `-Drive E` selects a USB when more than one is attached; use your actual letter.

## 3. Prepare the firmware files in Windows

```powershell
# Preview, then download the pinned original inputs and generate the five files.
py -3.14 .\prepare-assets.py --firmware-repo .\gpu-unlock-firmware-source --windows-repo .\Windows-GPU-UNLOCK --work-dir .\asset-work
py -3.14 .\prepare-assets.py --firmware-repo .\gpu-unlock-firmware-source --windows-repo .\Windows-GPU-UNLOCK --work-dir .\asset-work --download --execute
```

Use a local work folder, not the USB. This runs the original pinned firmware generators, verifies their inputs and all five output sizes/hashes, and retains the NVIDIA license and notice. It does not install a Linux GPU module or Windows driver. Generated firmware stays on the recipient's PC; it is not part of this ZIP.

## 4. Prepare the diagnostic USB

```powershell
.\Start.ps1 -Action Probe -Drive E
.\Start.ps1 -Action Probe -Drive E -Execute
```

The first command shows the plan. The second builds and stages the upstream **read-only diagnostic probe**. The recipient's current Windows boot-partition GUID is detected locally. Any previous USB bootloader is preserved by the upstream staging procedure.

Save your work, fully shut down, and use the motherboard's boot menu to select the UEFI USB. Let the probe return to Windows. Repeat from **another full shutdown** so there are two complete agreeing cold captures. A restart is not the required cold capture. The USB now contains private hardware evidence; keep it local.

## 5. Build and test this PC's profile

```powershell
.\Start.ps1 -Action Build -Drive E
.\Start.ps1 -Action Build -Drive E -Execute
```

The unchanged upstream pipeline validates the captures, generates this PC's local profile, runs its **22 required host jobs**, and builds the USB unlock package. This action stops before staging the unlock. A refusal needs review; the helper provides no override for the upstream evidence checks.

## 6. Stage and test the unlock

Save the stock tensor benchmark below before your first unlock boot. Read the pinned [headless USB procedure and recovery instructions](https://github.com/impacifist/Windows-GPU-UNLOCK/blob/75071aa134616c3d65ad315e0cf2810bf34b191b/docs/HEADLESS-USB.en.md), then:

```powershell
.\Start.ps1 -Action StageUnlock -Drive E
.\Start.ps1 -Action StageUnlock -Drive E -Execute
```

This explicitly stages the locally built wrapper, child and verified assets. It does not reboot or change boot priority. After a full shutdown, select the USB and follow the headless procedure. Inspect fresh successful transaction/cleanup and Windows-handoff logs and check performance. Passing host tests alone does not establish a successful physical boot.

For recovery, fully power off and boot **Windows Boot Manager directly**, bypassing the USB. Removing the USB from a running Windows session does not revert that session's unlock.

After one supervised successful boot, automatic USB-first boot can be considered in the motherboard firmware, retaining Windows Boot Manager as fallback. This kit does not promote boot priority. A generated LOCAL profile uses the USB path; do not run the fixed-profile internal installer for it.

## Before-and-after tensor-core testing

Use the same CUDA-enabled PyTorch environment for both runs. An existing application environment can be used; run its Python interpreter in place of `python` below. If needed, obtain a CUDA-enabled build through the [official PyTorch installer](https://pytorch.org/get-started/locally/). The script checks the required precision APIs and stops if the environment cannot perform the specified test.

The default protocol matches our original comparison: **4096×4096 matrices, three trials, two seconds of warmup per mode, and 30 CUDA-event samples per trial/mode**. It measures:

| Mode | Purpose |
|---|---|
| FP32 IEEE | Ordinary full-precision reference |
| FP16 → FP32 accumulation | Tensor-core throughput |
| BF16 → FP32 accumulation | Tensor-core throughput |
| TF32 → FP32 accumulation | Tensor-core throughput |

Each mode checks all 16,777,216 output elements against the exact all-ones product. This checks that specific matrix pattern, not every possible input or long-term stability.

### Save the stock baseline before the first unlock boot

Fully shut down and boot Windows Boot Manager directly, bypassing the unlock USB. Close GPU workloads and release their GPU memory. Keep the card at the same power limit and clock offsets for both measurements; leave automatic tuning off during the comparison.

```powershell
python .\benchmark-tensors.py --label stock --output .\stock.json
```

The benchmark waits for three idle samples before starting. It refuses a busy GPU or more than 2 GiB of existing GPU memory use. It changes no clocks, power limits, drivers or boot settings.

### Measure after the verified unlock boot

Use the supervised cold-boot USB procedure above. Check the fresh transaction, cleanup and Windows-handoff logs, then run the identical script and Python environment:

```powershell
python .\benchmark-tensors.py --label unlocked --output .\unlocked.json
python .\compare-tensors.py --before .\stock.json --after .\unlocked.json --output .\comparison.json
```

The comparator checks the same GPU, driver, VBIOS, power limit, maximum-clock metadata, Python/PyTorch/CUDA libraries, precision controls, script and timing protocol. It rejects incomplete runs, failed output checks and mismatched conditions. Keep power/clock tuning unchanged yourself; ordinary telemetry does not expose every voltage-curve setting.

It reports median TFLOPS before and after, speedup and percentage change for all four modes. The `stock`/`unlocked` labels describe the operator's boot choice; performance results alone do not prove the live firmware state. A driver update requires a new matched baseline and unlocked run on that driver.

For reference, the originating RTX 3090 comparison at 350 W on driver 617.42 measured FP16 **+80.4%**, BF16 **+84.6%**, TF32 **+86.9%**, and FP32 **−0.7%**. These are that machine's synthetic matrix results, not promised gains for another PC or application. Both result files keep raw timing samples and full-output correctness records.

See [PyTorch's CUDA precision notes](https://docs.pytorch.org/docs/stable/notes/cuda.html) for the precision controls used by the test.
## Sharing and testing status

Share the **starter ZIP**, not your working directory or prepared USB. Source downloads include upstream's historical files; the helper never stages its legacy `release/EFI` executable. The public ZIP contains no EFI executables, firmware, private captures, partition GUIDs or generated profiles.

This new helper is host-tested with mocked preparation/staging and synthetic comparison fixtures. Native Windows firmware generation was also exercised using the original verified local inputs: all five outputs matched their expected hashes. The helper has not received an additional physical boot validation. The underlying pinned pipeline was physically exercised on one RTX 3090/MSI B550 system. Other machines still require their own validation. See `VALIDATION.txt`, `NOTICES.txt` and `LICENSE`.
