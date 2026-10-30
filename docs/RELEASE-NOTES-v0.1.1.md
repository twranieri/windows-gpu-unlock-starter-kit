# Windows GPU Unlock Starter Kit v0.1.1

Experimental, source-only preparation helper for selected RTX 30-series configurations. Includes the Windows workflow, step-by-step guide, portable FP32/FP16/BF16/TF32 before-and-after tests, strict comparator and originating RTX 3090 measurements.

The downloadable kit ZIP contains no EFI executables, GPU firmware, PROM/VBIOS, Windows drivers, raw captures or generated profiles. Each recipient obtains the pinned upstream source, generates verified assets locally, collects two cold captures, passes all required host jobs and validates their own supervised USB boot.

Validation: 39 offline Python tests and 17 mocked PowerShell checks passed; local Windows asset generation matched all five expected hashes. The new helper and portable benchmark have not received a new physical unlock/recovery or GPU benchmark qualification.

The historical one-machine result at 350 W on driver 617.42 was FP16 +80.4%, BF16 +84.6%, TF32 +86.9%, FP32 −0.7%. These are matrix-throughput measurements, not promised application gains or results on driver 621.01.

RTX 20-series, RTX 40-series and arbitrary RTX 30-series cards are not supported by this pinned kit. Follow the repository's exact compatibility and recovery instructions. Credit and licenses are in NOTICES.txt and LICENSE.
