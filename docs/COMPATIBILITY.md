# Card compatibility

Version 0.2.2 adds a guarded Maxsun RTX 3080 10GB LHR candidate and deeper
read-only capture for other RTX 3080 10GB boards.
Physical two-card boot, recovery and performance remain unverified.

## Check the PCI device ID first

All candidate entries have NVIDIA PCI vendor ID `10DE`. The accepted device IDs
in this kit's reviewed [source and patch](../experimental/dual-gpu/source.json) are:

| Card | Device ID | VRAM |
|---|---|---|
| RTX 3060, selected variants | `2487` or `2504` | 12GB |
| RTX 3060 Ti, selected variant | `24C9` | 8GB |
| RTX 3070, selected variant | `2484` | 8GB |
| MSI RTX 3070 Ti, subsystem `1462:5052` | `2482` | 8GB |
| Maxsun RTX 3080 LHR, subsystem `7377:2000` | `2216` | 10GB |
| RTX 3080 12GB | `220A` | 12GB |
| RTX 3090 | `2204` | 24GB |
| RTX 3090 Ti | `2203` | 24GB |

The model name alone is insufficient. For example, another RTX 3060 Ti or RTX
3070 device ID is not admitted merely because it shares the same marketing name.
In Device Manager, open the NVIDIA display adapter's Properties, select Details,
then Hardware Ids. `VEN_10DE&DEV_2206` means vendor `10DE`, device `2206`.

All other variants in the [NVIDIA PCI catalog](../rtx30-pci.json) use the
read-only `OBSERVE` route. That includes the RTX 3050, RTX 3060 8GB, the original
RTX 3080 10GB, other RTX 3080 LHR variants, RTX 3080 Ti, and laptop models. The catalog covers
45 Ampere IDs plus three RTX 3050 A Laptop IDs branded as RTX 30 series by
NVIDIA and built on Ada. RTX 20, 40 and 50 families outside that branding and
unrecognized IDs are blocked.

The RTX 3080 `220A` candidate uses the upstream GA102/12GB and NVIDIA GOP
`60010` envelope. One contributor reported a clean transaction and Windows
start with a DisplayPort replug for display recovery. The MSI RTX 3070 Ti
candidate uses the existing `b660m-3070ti` evidence for GA104/8GB with GOP
`60010`. The new kit paths still need a supervised physical run. [RTX 3080 12GB report](https://github.com/windows-GPU-UNLOCK/Windows-GPU-UNLOCK/issues/73) · [RTX 3070 Ti report](https://github.com/windows-GPU-UNLOCK/Windows-GPU-UNLOCK/issues/4)

## RTX 3080 10GB

The Maxsun `2216` candidate must match GA102 `b72000a1`, 10,240 MiB, the
published PROM hash, and NVIDIA GOP `6000a` with the exact reviewed code hash.
The contributor's Windows success used an exact motherboard profile with its
own console handling. This kit still applies its local console and ownership
checks, so that reported boot does not establish a pass on this kit. [Maxsun hardware and source evidence](https://github.com/windows-GPU-UNLOCK/Windows-GPU-UNLOCK/pull/72)

The original `2206` and LHR `2216` subsystems `1458:403f` and `1462:389b` can
collect read-only chip, usable VRAM, PROM and driver evidence after the PCI
resource and decode checks pass. Those captures are excluded from unlock build
eligibility. The original MSI `2206` has a Windows success report using a
separate display route on a specific machine. [MSI 2206 source and evidence](https://github.com/rough2515-hub/rtx3080-unlock-public/blob/a08254d269af30ace9e57237abd3d8e6c261e8f5/README.md) · [Gigabyte LHR capture proposal](https://github.com/windows-GPU-UNLOCK/Windows-GPU-UNLOCK/pull/118) · [MSI LHR capture report](https://github.com/windows-GPU-UNLOCK/Windows-GPU-UNLOCK/issues/236)

## Retail memory configurations

The catalog identifies the model family. The Windows driver reports capacity by
PCI address, and the build gates use the exact usable VRAM from the cold probe.
An OEM, reserved-memory or modified card can report a different value from the
retail capacity. [NVIDIA desktop specifications](https://www.nvidia.com/en-gb/geforce/graphics-cards/compare/) · [NVIDIA laptop specifications](https://www.nvidia.com/en-in/geforce/laptops/compare/30-series/)

| RTX 30 family | Desktop VRAM | Laptop VRAM |
|---|---:|---:|
| 3050 / 3050 Ti | 3050 6GB or 8GB | 3050 4GB or 6GB, 3050 Ti 4GB |
| 3060 / 3060 Ti | 3060 8GB or 12GB, 3060 Ti 8GB | 3060 6GB |
| 3070 / 3070 Ti | 8GB | 8GB |
| 3080 / 3080 Ti | 3080 10GB or 12GB, 3080 Ti 12GB | 3080 8GB or 16GB, 3080 Ti 16GB |
| 3090 / 3090 Ti | 24GB | — |

The shared layout arithmetic passes RAM tests at 4, 6, 8, 10, 12, 16 and 24 GiB.
Each unlock still depends on an admitted PCI ID, chip revision, usable VRAM,
PROM and firmware topology. The branded RTX 3050 A Laptop is a separate 4GB
Ada product and uses the inventory route.

Support in the original Linux project, another Windows port or a newer upstream
revision does not automatically apply to this pinned kit. Do not edit an ID list
or substitute another model's profile to make a refused card pass.

## The kit generates a profile for each PC

The kit does not distribute the originating PC's GPU profile, PCI bus address,
Windows boot-partition GUID, PROM or diagnostic images. It detects local paths
and the Windows boot partition, then the upstream workflow derives a new LOCAL
profile from that recipient's own captures.

`RTX3090-UNLOCK` is the upstream USB directory name. It is used by the broader
LOCAL workflow and does not bind the kit to the originating RTX 3090.

The kit handles one or two NVIDIA controllers, including identical models.
Every controller must qualify for an unlock build. The whole installed set
remains fixed across both cold captures.

An accepted PCI ID is only a preliminary candidate. The exact chip/VRAM tuple,
reviewed NVIDIA UEFI driver code, PCI resources, console ownership and other
firmware/platform checks must also pass. Two complete, agreeing whole-set captures from
separate full shutdowns remain required. The actual console has 22 required
host jobs; a nonconsole peer has 11 applicable jobs; three pair jobs bind the
entire configuration. These jobs use each card's actual PROM/firmware fixtures
and the complete shared ownership graph. Passing them is not physical boot
qualification.

The current peer route admits unbound peers or reviewed NVIDIA-only peer
ownership. Active unreviewed EDID/text/graphics/combo consumers on peer display
children are refused at profile generation. Adding a candidate ID does not
implement a new driver-release route. A failure after the first card is mutated
is not a demonstrated rollback.

The legacy single-card requirements are in the [pinned upstream new-machine
guide](https://github.com/impacifist/Windows-GPU-UNLOCK/blob/75071aa134616c3d65ad315e0cf2810bf34b191b/docs/NEW-MACHINE.en.md)
and [legacy admission data](https://github.com/impacifist/Windows-GPU-UNLOCK/blob/75071aa134616c3d65ad315e0cf2810bf34b191b/research/profile/proven.json).

The reviewed one/two-card additions and exact source hashes are described in
[the implementation guide](../experimental/dual-gpu/README.md).

## Why the capture count can stay at 0/2

The number counts accepted complete capture files, not the number of times a
person powered the PC off. An incomplete diagnostic cannot satisfy either of the
two required captures.

For example, an RTX 3080 `10DE:2206` diagnostic can contain:

```text
incomplete reason=probe-unreviewed-envelope status=0x8000000000000003
capture-complete=0
```

That PCI ID is covered by the inventory route. A single inventory boot is
enough to collect the graph. Retain the files privately and boot Windows Boot
Manager directly afterward.

`probe-unreviewed-envelope` can also indicate another unreviewed resource
condition. For an admitted PCI ID, inspect the actual refusal before deciding
what needs to change. Missing files, write failures or incomplete capture markers
must not be treated as a successful cold capture. Keep raw diagnostic images and
machine-specific reports local; this repository does not collect or publish them.

`dual-unreviewed-envelope` can occur even when both PCI IDs pass. The probe
requires memory decoding on and bus mastering off on each card. If the capture
shows the legacy BIOS video driver owns an NVIDIA GPU, first confirm **BIOS
Mode: UEFI** in `msinfo32`, then disable **Launch CSM** in firmware and take one
fresh capture after a full shutdown. The new capture shows whether the native
UEFI graphics path meets the remaining checks. On ASUS X570 the setting is
under **Advanced Mode → Boot → CSM**. [ASUS X570 BIOS manual](https://dlcdnets.asus.com/pub/ASUS/mb/SocketAM4/PRIME_X570-P/E15829_PRIME_PRO_TUF_GAMING_X570_Series_BIOS_EM_WEB.pdf#page=43)

Broader support needs reviewed upstream implementation and hardware evidence.
Preparation automation and a new card name in a list cannot supply that evidence.
