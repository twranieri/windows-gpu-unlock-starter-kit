# Windows GPU Unlock Starter Kit v0.1.2

Experimental compatibility and diagnostic usability update. This release adds no new GPU support.

- The README, quickstart and compatibility guide list the exact candidate NVIDIA PCI IDs: RTX 3060 12GB `2487`/`2504`, RTX 3060 Ti 8GB `24C9`, RTX 3070 8GB `2484`, RTX 3090 `2204`, and RTX 3090 Ti `2203`.
- RTX 3050, RTX 3070 Ti, RTX 3080/3080 Ti, unlisted RTX 30 variants, laptop variants, and RTX 20/40/50-series cards remain outside this pinned workflow.
- Preparation checks the recipient's NVIDIA PCI ID against pinned admission data. An ID match is a preliminary candidate; firmware and platform compatibility still require that PC's captures and all upstream checks.
- Incomplete diagnostics show their refusal reason instead of presenting an unsupported card as an unexplained 0/2 capture count.
- Each PC generates its own LOCAL profile. No originating-machine profile is distributed or reused.

Both upstream source pins, verified firmware hashes, per-machine capture/profile gates and 22 actual-input host jobs remain unchanged. No EFI executables, firmware, PROM/VBIOS, drivers, private captures or generated profiles are bundled. No Stable Diffusion comparison tool is included.

See VALIDATION.txt for host-only tests and their limits. This update is not an additional physical unlock/recovery qualification or evidence for other GPU models.
