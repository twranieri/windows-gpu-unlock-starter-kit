# Card compatibility

Version 0.2.0 provides the guarded one/two-card Windows LOCAL flow for selected
RTX 30-series configurations. Physical two-card boot, recovery and performance
remain unverified. It is not a universal RTX 30-series unlock.

## Check the PCI device ID first

All candidate entries have NVIDIA PCI vendor ID `10DE`. The accepted device IDs
in this kit's reviewed [source and patch](../experimental/dual-gpu/source.json) are:

| Card | Device ID | VRAM |
|---|---|---|
| RTX 3060, selected variants | `2487` or `2504` | 12GB |
| RTX 3060 Ti, selected variant | `24C9` | 8GB |
| RTX 3070, selected variant | `2484` | 8GB |
| RTX 3090 | `2204` | 24GB |
| RTX 3090 Ti | `2203` | 24GB |

The model name alone is insufficient. For example, another RTX 3060 Ti or RTX
3070 device ID is not admitted merely because it shares the same marketing name.
In Device Manager, open the NVIDIA display adapter's Properties, select Details,
then Hardware Ids. `VEN_10DE&DEV_2206` means vendor `10DE`, device `2206`.

These IDs are not admitted by this kit's pinned LOCAL route:

- RTX 3050 and RTX 3060 8GB.
- RTX 3060 Ti and RTX 3070 variants whose device IDs are absent from the table.
- RTX 3070 Ti, RTX 3080 and RTX 3080 Ti, including RTX 3080 device `2206`.
- Laptop variants and RTX 20-, RTX 40- and RTX 50-series cards.

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

One or two admitted NVIDIA controllers are allowed, including identical models.
Third, unsupported, unknown or ambiguous NVIDIA controllers are refused. The
whole installed set remains fixed across both cold captures.

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
[the implementation guide](../experimental/dual-gpu/README.md). The kit keeps
its six-device scope even where the donor source contains additional IDs.

## Why the capture count can stay at 0/2

The number counts accepted complete capture files, not the number of times a
person powered the PC off. An incomplete diagnostic cannot satisfy either of the
two required captures.

For example, an RTX 3080 `10DE:2206` diagnostic can contain:

```text
incomplete reason=probe-unreviewed-envelope status=0x8000000000000003
capture-complete=0
```

That PCI ID is absent from this kit's admitted set. Repeating cold boots will
not add hardware support. Stop at diagnostics, retain the files privately and
boot Windows Boot Manager directly. There is no unlock attempt in this
diagnostic-only step.

`probe-unreviewed-envelope` can also indicate another unreviewed resource
condition. For an admitted PCI ID, inspect the actual refusal before deciding
what needs to change. Missing files, write failures or incomplete capture markers
must not be treated as a successful cold capture. Keep raw diagnostic images and
machine-specific reports local; this repository does not collect or publish them.

Broader support needs reviewed upstream implementation and hardware evidence.
Preparation automation and a new card name in a list cannot supply that evidence.
