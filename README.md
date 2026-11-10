# Windows GPU Unlock Starter Kit

**v0.4.0 desktop preview, build 11** includes **Windows GPU Unlock Setup.exe** for one or two GeForce RTX 30- or RTX 40-series GPUs, including mixed pairs. Extract the whole ZIP, open Setup and approve the Windows administrator prompt. Use one dedicated, backed-up USB drive. Setup guides Windows prerequisites, USB preparation and boot verification. Setup can install a private CUDA PyTorch environment on a fresh Windows install, then run and compare the stock and unlocked tensor tests. Once Setup verifies the boot, it clears its sign-in shortcut. If a step fails, Setup opens a diagnostic text file you can review and attach to a support report. [Download the desktop preview](https://github.com/twranieri/windows-gpu-unlock-starter-kit/releases/tag/v0.4.0-preview.11)

The preview includes verified prebuilt EFI tools, the asset generator and the corresponding engine source. It generates firmware assets locally from verified inputs. Git and compilers are unnecessary for desktop setup. Physical validation of this workflow is pending.

[Desktop setup and offline inputs](docs/RTX30-40.md#desktop-setup-preview-v040) · [Upstream comparison and hardware reports](docs/COMPARISON.md)

**v0.3.0 experimental prerelease** remains available as a source-only kit. It builds the bootloader and firmware assets on your PC and includes before/after tensor benchmarks for each card.

[Download the v0.3.0 kit](https://github.com/twranieri/windows-gpu-unlock-starter-kit/releases/download/v0.3.0/gpu-unlock-starter-kit-v0.3.0.zip) · [SHA-256](https://github.com/twranieri/windows-gpu-unlock-starter-kit/releases/download/v0.3.0/gpu-unlock-starter-kit-v0.3.0.zip.sha256) · [GitHub release](https://github.com/twranieri/windows-gpu-unlock-starter-kit/releases/tag/v0.3.0)

[v0.3.0 source setup](#set-up-v030) · [GPU compatibility](#gpu-compatibility) · [Benchmarks and results](#measure-each-physical-card) · [Recovery and driver updates](#recovery-and-driver-updates) · [Validation and source](#validation-and-source)

## GPU compatibility

The RTX 30/40 workflows accept **48 RTX 30-branded PCI device IDs** and **25 RTX 40 IDs** from the pinned NVIDIA driver table. This includes the RTX 3080 **10 GB**, **10 GB LHR** and **12 GB**, plus desktop and laptop entries. The loader reads each card's live memory layout. The Ada-based RTX 3050 A Laptop uses the Ada firmware path. Both cards in a two-GPU setup must match the inventory and probe.

These are **candidates for physical testing**. Physical results depend on the exact card, VBIOS, power state, UEFI graphics initialization, motherboard and display ownership. [Upstream hardware reports](https://github.com/physicsdolphin/nv-uefi-unlocker/blob/37327d53dfae1f475638cdb8897b56d3edd4eb20/docs/compatibility.en.md) · [RTX 30 catalog](rtx30-pci.json) · [RTX 40 catalog](rtx40-pci.json)

<details>
<summary>All 73 catalog PCI device IDs</summary>

All IDs below use NVIDIA vendor ID `10de`. Some laptop IDs cover more than one model depending on the subsystem.

### RTX 30-branded cards

| Model | PCI device IDs |
|---|---|
| RTX 3090 Ti | `2203` |
| RTX 3090 | `2204` |
| RTX 3080 10GB | `2206` |
| RTX 3070 Ti | `2207`, `2482` |
| RTX 3080 Ti | `2208` |
| RTX 3080 12GB | `220A` |
| RTX 3080 10GB LHR | `2216` |
| RTX 3060 Ti | `2414`, `2486`, `2489`, `24C9` |
| RTX 3080 Ti Laptop GPU | `2420`, `2460` |
| RTX 3070 | `2484`, `2488` |
| RTX 3060 | `2487`, `24C7`, `2503`, `2504`, `2544` |
| RTX 3080 Laptop GPU / RTX 3060 Laptop GPU | `249C` |
| RTX 3070 Laptop GPU | `249D`, `24DD` |
| RTX 3070 Ti Laptop GPU / RTX 3060 Laptop GPU | `24A0` |
| RTX 3080 Laptop GPU | `24DC` |
| RTX 3070 Ti Laptop GPU | `24E0` |
| RTX 3050 | `2507`, `2582`, `2584` |
| RTX 3050 OEM | `2508` |
| RTX 3060 Laptop GPU | `2520`, `2521`, `2560` |
| RTX 3050 Ti Laptop GPU | `2523`, `2563`, `25E0` |
| RTX 3050 Ti Laptop GPU / RTX 3060 Laptop GPU | `25A0` |
| RTX 3050 Laptop GPU / RTX 3050 Ti Laptop GPU / RTX 3060 Laptop GPU | `25A2` |
| RTX 3050 Laptop GPU | `25A5`, `25E2`, `25E5` |
| RTX 3050 4GB Laptop GPU | `25AB` |
| RTX 3050 6GB Laptop GPU | `25AC`, `25EC` |
| RTX 3050 A Laptop GPU | `2822`, `28A3`, `28E3` |

### RTX 40-branded cards

| Model | PCI device IDs |
|---|---|
| RTX 4090 | `2684` |
| RTX 4090 D | `2685` |
| RTX 4070 Ti SUPER | `2689`, `2705` |
| RTX 4080 SUPER | `2702` |
| RTX 4080 | `2704` |
| RTX 4070 | `2709`, `2786` |
| RTX 4090 Laptop GPU | `2717`, `2757` |
| RTX 4070 Ti | `2782` |
| RTX 4070 SUPER | `2783` |
| RTX 4060 Ti | `2788`, `2803`, `2805` |
| RTX 4080 Laptop GPU | `27A0`, `27E0` |
| RTX 4060 | `2808`, `2882` |
| RTX 4070 Laptop GPU | `2820`, `2860` |
| RTX 4060 Laptop GPU | `28A0`, `28E0` |
| RTX 4050 Laptop GPU | `28A1`, `28E1` |

</details>

## Set up v0.3.0

Use x64 Windows with native UEFI, CSM off, Secure Boot off, a GPT Windows boot disk, BitLocker fully decrypted and off on the Windows volume, and Windows Fast Startup off. Save any recovery key before changing firmware settings. Use **one dedicated, backed-up FAT32 USB drive** and a keyboard. An 8 GB drive is ample.

Install Git, the NVIDIA Windows driver with `nvidia-smi`, Rustup, and Visual Studio C++ Build Tools with the Windows SDK. Extract the kit and open an x64 Visual Studio Developer PowerShell in that folder.

1. Install the pinned toolchain, check the detected cards, and save a stock tensor benchmark per card.

   ```powershell
   rustup toolchain install 1.95.0-x86_64-pc-windows-msvc --profile minimal --target x86_64-unknown-uefi
   $env:RUSTUP_TOOLCHAIN = '1.95.0-x86_64-pc-windows-msvc'
   .\RTX.ps1 -Action Check
   ```

2. Build the probe and unlock EFI applications plus the firmware assets. The first build needs internet access.

   ```powershell
   .\RTX.ps1 -Action Build -Execute
   ```

3. In administrator PowerShell, stage the read-only probe. Replace `E` with the actual USB letter. Fully power off, boot the USB from the one-time UEFI boot menu, and let it hand off to Windows. Keep the same GPU layout and USB.

   ```powershell
   .\RTX.ps1 -Action Probe -Drive E -Execute
   ```

4. After Windows returns, stage the unlock. This requires the matching probe log. Fully power off and boot the USB again. Press **Space** or **Enter** to confirm, then wait for Windows.

   ```powershell
   .\RTX.ps1 -Action StageUnlock -Drive E -Execute
   ```

5. Inspect `loader.log` for each PCI address and run the same tensor benchmark per card. Keep the raw boot log private.

The default local work folder is `.local/rtx`. If the installed GPU set changes, build in a fresh `-WorkDirectory` and pass that directory to the subsequent commands. Commands without `-Execute` preview their actions. [Full RTX 30/40 guide](docs/RTX30-40.md)

## Measure each physical card

In the desktop preview, leave automatic tensor testing enabled and open
Setup after starting Windows Boot Manager for the stock boot. Setup can
find a compatible CUDA PyTorch environment or let you select its
`python.exe`. After the unlock boot, keep the USB connected so Setup can
match the boot log. The comparison appears in the tensor benchmark window.
Keep the driver and GPU settings the same, and close other GPU workloads.

For the command-line workflow, run the scripts directly.

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

### Historical RTX 3090 result

The originating 24 GB RTX 3090 used the earlier capture-based workflow on an MSI MAG B550 Tomahawk with Windows 10 Pro, NVIDIA driver **617.42** and a matched **350 W** limit. Two successful cold unlock boots were recorded. This comparison used three trials per state and 720 CUDA-event samples total. The complete output matched the expected value in all 24 checks.

| Mode | Stock TFLOPS | Unlocked TFLOPS | Change |
|---|---:|---:|---:|
| FP32 IEEE | 25.9513 | 25.7616 | −0.73% |
| FP16 | 70.3660 | 126.9367 | +80.39% |
| BF16 | 70.4411 | 130.0559 | +84.63% |
| TF32 | 35.8296 | 66.9827 | +86.95% |

These are synthetic matrix-throughput measurements from one system and one driver. [Full report, method and findings](docs/ORIGINATING-RESULTS.md) · [Sanitized benchmark data and reproduction script](research/originating-rtx3090/)

## Recovery and driver updates

If a USB boot hangs or the unlock fails, fully power off, remove the USB, and boot **Windows Boot Manager** directly. Check the fresh log for each card's result. The engine handles each card separately, so a two-card session can succeed on one and fail on the other. [Recovery and verification details](docs/RTX30-40.md#4-stage-and-confirm-the-unlock)

A driver update changes the comparison conditions. Collect a new stock baseline and verify the new unlocked session on that driver before comparing results. On the originating PC, driver 621.01 cleared high idle clocks. Its unlocked throughput was not retested. [Driver and clock observations](docs/ORIGINATING-RESULTS.md#later-observations)

## Validation and source

- The Windows entry point built a single-card package for the installed RTX 3090. A mixed RTX 3090 and RTX 4070 Super package built with simulated card identities and produced both EFI applications and 13 verified assets.
- Host tests covered all 73 catalog IDs, VRAM inputs, exact one- and two-card matching, mixed-family assets, probe-log gating and interrupted staging. Physical unlock and recovery through `RTX.ps1` remain pending.
- The published v0.3.0 ZIP is source-only. It obtains the engine, pinned dependencies and NVIDIA inputs during the local build. The v0.4.0 desktop preview also includes verified prebuilt tools and complete corresponding engine source. Each route generates the NVIDIA assets locally.

[Validation report](VALIDATION.txt) · [Change history](CHANGELOG.md) · [Pinned source manifest](pinned-source.json) · [Notices](NOTICES.txt) · [GPL-2.0-only license](LICENSE)

The v0.3.0 workflow builds on **physicsdolphin/nv-uefi-unlocker**. The capture-based route builds on **Windows GPU UNLOCK**, **jingx8885's dual-GPU contribution**, **Zagitta/gpu-unlock**, and earlier port work. [Pinned v0.3.0 engine](https://github.com/physicsdolphin/nv-uefi-unlocker/blob/37327d53dfae1f475638cdb8897b56d3edd4eb20)

## Capture-based RTX 30 workflow

<details>
<summary>Earlier Start.ps1 route and its separate compatibility list</summary>

[Step-by-step setup](docs/QUICKSTART.md) · [Compatibility](docs/COMPATIBILITY.md) · [One/two-card implementation](experimental/dual-gpu/README.md) · [Originating results](docs/ORIGINATING-RESULTS.md)

The existing `Start.ps1` workflow prepares a separate LOCAL profile from complete captures on selected RTX 30 configurations. Its candidate list follows below. Build and staging are separate explicit actions. Physical validation of both kit workflows is limited to their documented results.

The unlock path requires every installed NVIDIA display controller to be an admitted candidate. These device IDs all use vendor `10DE`.

| Card | Candidate device ID |
|---|---|
| RTX 3060 12GB, selected variants | `2487`, `2504` |
| RTX 3060 Ti 8GB, selected variant | `24C9` |
| RTX 3070 8GB, selected variant | `2484` |
| MSI RTX 3070 Ti 8GB | `2482` with subsystem `1462:5052` |
| Maxsun RTX 3080 10GB LHR | `2216` with subsystem `7377:2000` and the reviewed PROM and GOP |
| RTX 3080 12GB | `220A` |
| RTX 3090 24GB | `2204` |
| RTX 3090 Ti 24GB | `2203` |

Identical or different candidates can form a two-card set. The kit checks exact chip and VRAM, PCI resources, UEFI driver code, console ownership and both cold captures before an unlock build. Physical two-card validation is pending.

`Check` displays driver-reported memory by PCI address when NVIDIA's driver tool is available. The unlock profile uses the separate cold-boot VRAM reading. The original RTX 3080 10GB `2206` and selected other LHR boards can collect deeper read-only evidence. For those configurations and other inventory-only IDs in this workflow, `Check` shows `OBSERVE`. Build and StageUnlock require a qualified candidate on every card.

### Prepare the capture-based workflow

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

</details>

## Support the project

[Venmo @twranieri](https://venmo.com/u/twranieri)
