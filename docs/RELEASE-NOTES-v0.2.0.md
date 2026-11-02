# v0.2.0 — experimental one-or-two-card workflow

The kit can prepare a locally generated profile for one or two installed candidate GPUs. With two cards, it captures both during each diagnostic boot, binds each card's PCI identity, subsystem, bus location, BAR, PROM and driver topology, and coordinates both unlock transactions before handing off to Windows. A changed, missing or unsupported card, failed transaction or failed cleanup blocks the handoff.

This is an experimental software implementation. Physical two-GPU boot validation has **not** been performed. The previously tested single RTX 3090 system does not establish that an RTX 3090 + RTX 3060 on an ASUS X570-Pro will pass its platform checks. Candidate device IDs remain `2204`, `2203`, `2487`, `2504`, `2484` and `24C9`; this does not add RTX 20/40-series support.

Source preparation downloads a pinned public upstream revision and applies the included, hash-checked GPL patch. No EFI binaries, firmware, generated profiles or private captures are redistributed. Existing legacy source checkouts are preserved. Read the quickstart and run the readiness check before preparing a USB.

Two complete agreeing cold-boot captures of the **whole installed set** are required. Host tests use the captured per-card inputs and full firmware graph; passing them is required before building or staging. Simulated tests cover one card, two cards with an unbound peer, two cards sharing an NVIDIA UEFI driver and a console GPU that is second in bus order. They are not physical boot tests.

Tensor benchmarks now select and compare each physical GPU independently by PCI bus address and UUID. CUDA enumeration changes cannot pair one card's baseline with the other card's result. There is no Stable Diffusion comparison tool in this kit.

Download `gpu-unlock-starter-kit-v0.2.0.zip`, extract to a new folder, and follow `docs/QUICKSTART.md`. Do not share your working directory or prepared USB. Return to stock by fully powering off and booting Windows Boot Manager directly, bypassing the unlock USB.
