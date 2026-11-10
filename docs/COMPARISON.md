# What the kit adds

The desktop preview guides Windows users through the same pre-OS unlock engine
used by the RTX 30/40 command-line route. It discovers one or two cards, selects
the required firmware families, verifies the prebuilt tools, and prepares one
dedicated FAT32 USB. It requires a matching read-only probe before staging the
transaction loader. You still choose the USB at boot and confirm the unlock
there. The USB log reports each card separately. [Desktop and source workflows](RTX30-40.md)

| Step | Upstream v2.1.10 Windows release | Kit desktop preview |
|---|---|---|
| Get started | Extract the prebuilt release and run its PowerShell asset maker | Open Setup to check GPUs, motherboard, Windows settings and USB choices |
| Prepare the USB | Choose the output or copy the generated USB files | Confirm the selected volume and let Setup write and verify the layout |
| First boot | Boot the transaction loader and confirm at its prompt | Boot a read-only probe, then return to Windows before staging the transaction loader |
| Retry and check results | Read the EFI log and follow upstream recovery steps | Resume from the matching USB receipt, restore a verified probe, and run the same tensor test per GPU |
| Scope | Upstream provides a separate RTX 20 GSP path and other operating systems | One or two cataloged GeForce RTX 30/40 cards under Windows |

The extra probe boot checks the machine's GPU roster and Windows handoff before
the user stages any transaction. The actual unlock uses the same pinned engine.
[Upstream setup guide](https://github.com/physicsdolphin/nv-uefi-unlocker/blob/v2.1.10/README.en.md)

## How other unlocks handle boot

| Project | What its approach or tests show |
|---|---|
| Zagitta's original Linux module | Runs from Linux's initial boot environment before NVIDIA binds the card. Its resume hook can reapply the unlock when the card lost power. That hook is specific to Linux. [Boot and resume design](https://github.com/Zagitta/gpu-unlock/blob/main/README.md#boot-flow-and-opt-in) |
| JustAResearcher's Ada fork | A Windows 4090 Laptop report measured gains after a targeted runtime power change. Treat retained Windows performance as a separate check after EFI succeeds. [Laptop measurements](https://github.com/JustAResearcher/gpu-unlock-ada/issues/117) |
| LightEssence's Windows port | Uses UEFI and an optional display reconnect. Its logs distinguish a Windows loader path bug from an RTX 3060 ROM size rejection. The changes for those cases need separate hardware confirmation. [Loader path](https://github.com/LightEssence/universal-windows-unlock-gpu/issues/7) · [ROM parsing](https://github.com/LightEssence/universal-windows-unlock-gpu/issues/8) |
| ZeroHackz's Ada port | The author verified two Gigabyte RTX 4060 Ti 16GB cards. New boards require their own capture and rebuild. [Verified pair and porting steps](https://github.com/ZeroHackz/gpu-unlock-windows#capturing-your-own-card) |
| Zihao-Wu06's Windows GUI | Writes a firmware boot entry and offers a single unlock trial for cards other than the 4090. An RTX 4080 trial reached the unlock but hung on display handoff. Setting a mode after reconnect fixed it in three trials on that PC. [Installer design](https://github.com/Zihao-Wu06/gpu-unlock-for-windows) · [RTX 4080 trials](https://github.com/Zihao-Wu06/gpu-unlock-for-windows/issues/9) |

## Upstream engine and hardware evidence

Upstream v2.1.10 changed the default display handoff to rebuild the console with
the card's native UEFI graphics driver. The kit pins v2.1.11-diag2 at `37327d5`
and applies its reviewed patch. Diag2 releases the firmware asset pool before
handing control to Windows, addressing one documented low-memory boot failure.
Its release notes leave the Code 12 and driver relock diagnostics in place.
[Upstream v2.1.10](https://github.com/physicsdolphin/nv-uefi-unlocker/releases/tag/v2.1.10) ·
[Pinned v2.1.11-diag2](https://github.com/physicsdolphin/nv-uefi-unlocker/releases/tag/v2.1.11-diag2) ·
[Engine pin and patched files](../rtx/engine.json)

Build 3 binds transaction results to the expected PCI addresses and device
IDs. If a transaction fails and recovery cannot be verified, the kit records
the failure, closes the log, attempts an emergency reset and waits for a
full power-off. The Lenovo reset-and-handoff case and the MSI laptop that
loses GPU power still need their own hardware validation.
[Lenovo handoff report](https://github.com/physicsdolphin/nv-uefi-unlocker/issues/198) ·
[MSI power-state report](https://github.com/physicsdolphin/nv-uefi-unlocker/issues/208)

| Public report | What it establishes on that system |
|---|---|
| Two RTX 3060s on Windows 10 | An unlocked card hit Windows Device Manager Code 12, a PCI resource conflict. The other card could remain available. [Upstream #165](https://github.com/physicsdolphin/nv-uefi-unlocker/issues/165) |
| RTX 3070 on Windows | EFI verified the transaction, but Windows reported the card locked after driver initialization. [Upstream #164](https://github.com/physicsdolphin/nv-uefi-unlocker/issues/164) |
| Lenovo Legion with RTX 4090 Laptop GPU | The read-only path reached Windows. Boots that performed the reset and scrub sequence hung during handoff on that machine. [Upstream #198](https://github.com/physicsdolphin/nv-uefi-unlocker/issues/198) |
| RTX 3090 and RTX 3060 on ASRock B550 Taichi | Upstream v2.1.10 logged both cards completing the transaction and Windows booted. The report includes matched ComfyUI measurements and leaves direct Windows register readback unverified. [Upstream #206](https://github.com/physicsdolphin/nv-uefi-unlocker/issues/206) |
| RTX 4090 with the wrong USB layout | The reporter confirmed that moving the required assets from a nested folder to the USB root let the transaction run. Setup writes and checks this layout. [Upstream #139](https://github.com/physicsdolphin/nv-uefi-unlocker/issues/139#issuecomment-6596605976) |
| RTX 3090 with a frozen screen and an empty log | USB recovery found records from stages beyond the frozen screen. An empty file can leave the outcome unknown. [Upstream #170](https://github.com/physicsdolphin/nv-uefi-unlocker/issues/170) · [Diagnostic release findings](https://github.com/physicsdolphin/nv-uefi-unlocker/releases/tag/v2.1.11-diag5) |
| RTX 3070 Laptop with a Windows BCD error | Returning to the firmware boot manager got past that error on the reported PC. The platform then powered down the GPU before the Windows driver could retain the unlock. [Upstream #208](https://github.com/physicsdolphin/nv-uefi-unlocker/issues/208) |

An OCuLink RTX 3080 Ti was visible on the PCI bus while memory decoding was
disabled. The maintainer noted that a workaround changed the original PCI
command state. The kit keeps its first boot read-only and checks each card's D0
power state before accepting the probe. The app reports Device Manager errors
such as Code 12 separately from a missing NVIDIA inventory row.
[OCuLink test and maintainer review](https://github.com/windows-GPU-UNLOCK/Windows-GPU-UNLOCK/issues/164#issuecomment-6590753759) ·
[Code 12 enumeration caveat](https://github.com/physicsdolphin/nv-uefi-unlocker/issues/165#issuecomment-6625705557)

A Windows laptop test recorded a loss of tensor throughput after standby. A
separate RTX 4070 Ti SUPER report measured roughly 1.48× matrix throughput and a
5.3% reduction in one matched image-generation run. Setup labels its EFI
result as the latest USB boot log. Check performance again in the current
session after boot, sleep or driver reset.
[Standby test](https://github.com/JustAResearcher/gpu-unlock-ada/pull/64) ·
[Matched workload report](https://github.com/JustAResearcher/gpu-unlock-ada/issues/92)

Those reports describe individual upstream builds and machines. The kit's
73 catalog entries are candidates for testing. Build and host checks cover
inventory, package generation and staging logic. Physical qualification of the
desktop workflow is pending. The earlier capture-based RTX 3090 result measured
synthetic tensor throughput on one PC with a matched driver and power limit.
[Kit validation](../VALIDATION.txt) · [Originating RTX 3090 data](ORIGINATING-RESULTS.md)

## Discord field reports

- An older read-only run on an RTX 3080 10GB stopped with zero accepted
  captures because PCI ID `2206` was outside that probe's allowlist. The desktop
  preview recognizes that ID and uses the Ampere path.
- An older two-card run reached EFI after passing the Windows checks. The probe
  logged legacy BIOS video ownership on the RTX 3090 and disabled PCI memory
  decoding on the RTX 3060. It refused to finish the capture. The preview
  includes both IDs and requires a new native-UEFI probe with both cards awake.
- A separate posted RTX 3090 and RTX 3060 benchmark pair showed about 1.9×
  FP16 and BF16 matrix throughput per card, with FP32 essentially flat.
  The posted comparisons establish results for those matrix tests.

## Questions the setup addresses

- **What belongs on the USB?** Setup stages the EFI file and its matching
  inputs on a dedicated drive. Keep unrelated files and older unlock packages on
  separate media.
- **When is the unlock active?** It applies to the current USB-booted session.
  Start each test from a full power-off, and check Windows after the EFI handoff.
- **Will a particular motherboard or pair work?** Community questions about
  RTX 3070 on B550-F and dual RTX 3090 configurations establish interest.
  An exact-board result requires evidence for the card, motherboard and boot
  configuration. For a pair, check both PCI addresses.
- **Does a successful boot make an app faster?** Community feedback included an
  apparent unlock with no video-rendering improvement. Use a matched before and
  after test of the actual workload to measure its change. Tensor benchmarks
  isolate matrix throughput. [Per-card tensor test](../README.md#measure-each-physical-card)
