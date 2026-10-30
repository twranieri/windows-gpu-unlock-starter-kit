# Originating RTX 3090 measurements

These are historical measurements from one PC using the underlying pinned workflow. They establish that experiment's synthetic matrix throughput; they do not establish compatibility or gains for another system.

## Hardware and software

- NVIDIA GeForce RTX 3090, 24 GB; VBIOS `94.02.4b.00.0b`.
- MSI MAG B550 Tomahawk, BIOS A.80; AMD Ryzen 9 5900X; Windows 10 Pro build 19045.
- Driver **617.42**, with the same **350 W** limit for stock and unlocked runs.
- Python 3.12.14; PyTorch 2.14.1+cu130; CUDA build 13.0.
- Windows source `75071aa134616c3d65ad315e0cf2810bf34b191b`; firmware source `0ebdb1c6308b6a2072be5bf04513472942541956`.

The procedure used two agreeing diagnostic cold captures, a generated local profile, all 22 required host jobs and a headless USB wrapper that started Windows directly. Two successful unlock cold boots were recorded. Firmware logs reported successful transaction/cleanup and Windows handoff; the matrix comparison below concerns the initial matched pair, not a long-term reliability campaign. USB-first automatic boot was requested but was not physically verified.

## Matched benchmark

The original script used 4096×4096 all-ones matrices, three trials per state, two seconds of warmup per mode and 30 CUDA-event samples per mode/trial. FP16/BF16 inputs produced FP32 outputs with FP32 accumulation controls. The complete final output of each mode/trial was checked against 4096.

There were **720 recorded timing samples** and **24 complete-output checks** across the two states. Each output check covered 16,777,216 elements. This validates that specific matrix pattern; random inputs, other shapes and extended numerical workloads were not established by this comparison.

| Mode | Stock TFLOPS | Unlocked TFLOPS | Throughput change |
|---|---:|---:|---:|
| FP32 IEEE | 25.9513 | 25.7616 | −0.73% |
| FP16 / FP32 accumulation | 70.3660 | 126.9367 | +80.39% |
| BF16 / FP32 accumulation | 70.4411 | 130.0559 | +84.63% |
| TF32 / FP32 accumulation | 35.8296 | 66.9827 | +86.95% |

Values are medians across trial throughputs. These are synthetic GEMM gains, not image-generation, gaming, video or LLM performance percentages. There was no matched end-to-end application timing comparison. [Historical report and sanitized data](../research/originating-rtx3090/) preserve the original evidence; its machine-pinned benchmark script is a reproduction record, not the portable kit's entry point.

## Later observations

Trying to hold 1980 MHz during image generation was unsuccessful. The unlocked workload approached the configured software power cap even though its sustained core clock was lower. A global +150 MHz attempt and a later 900 mV curve attempt were followed by driver/application errors; lower-voltage testing stopped and the card returned to tuning defaults. Those settings are not part of this kit and should not be treated as a stable profile.

Later, the operator updated the driver to **621.01** and reported that a high idle-clock problem cleared. Readings after the update showed **P8, 210 MHz core, 405 MHz memory and approximately 28 W**. This was not a new matched tensor benchmark or proof that the unlock remained active after driver recovery/update. It also did not isolate the driver update from all other setting changes.

## What the portable kit has established

The new tensor script retains the original default timing/matrix protocol while removing that PC's hard-coded GPU address and software-version restrictions. Its metadata/capability checks and strict comparator were host-tested with synthetic services, including a benchmark-to-comparator round trip. It has not yet received a new physical GPU benchmark run or an additional physical unlock/recovery qualification.

A recipient must establish their own stock baseline, obtain fresh successful boot evidence, and measure on the same driver/software/settings. Performance measurements and operator labels do not independently prove the live firmware state.
