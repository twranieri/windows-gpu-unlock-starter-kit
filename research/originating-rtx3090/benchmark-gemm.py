"""Ordinary PyTorch GEMM measurements for this RTX 3090; no unlock or tuning.

Run this identical file/interpreter before and after a separately performed boot
experiment. Results describe current performance, not an unlocked-state verdict.
"""

import argparse
import csv
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import sys
import time


GPU_FIELDS = (
    "name", "pci.bus_id", "driver_version", "vbios_version", "memory.total",
    "power.limit", "power.default_limit", "clocks.max.sm", "clocks.max.memory",
    "utilization.gpu", "memory.used", "temperature.gpu", "power.draw", "clocks.sm",
)
SETTINGS_FIELDS = GPU_FIELDS[:9]
MODES = (
    ("fp32_ieee", "float32", "ieee"),
    ("fp16_fp32_accumulate", "float16", "ieee"),
    ("bf16_fp32_accumulate", "bfloat16", "ieee"),
    ("tf32_fp32_accumulate", "float32", "tf32"),
)


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def file_identity(path):
    path = Path(path).resolve()
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"path": str(path), "bytes": path.stat().st_size,
            "sha256": digest.hexdigest()}


def gpu_snapshot():
    command = ["nvidia-smi", "--query-gpu=" + ",".join(GPU_FIELDS),
               "--format=csv,noheader,nounits"]
    completed = subprocess.run(command, check=True, capture_output=True,
                               text=True, timeout=15)
    rows = list(csv.reader(completed.stdout.strip().splitlines()))
    if len(rows) != 1 or len(rows[0]) != len(GPU_FIELDS):
        raise RuntimeError("Expected exactly one NVIDIA GPU and complete telemetry")
    gpu = dict(zip(GPU_FIELDS, (value.strip() for value in rows[0])))
    location = re.fullmatch(r"([0-9a-fA-F]{1,8}):([0-9a-fA-F]{2}):"
                            r"([0-9a-fA-F]{2})\.([0-7])", gpu["pci.bus_id"])
    if (gpu["name"] != "NVIDIA GeForce RTX 3090" or not location or
            tuple(int(value, 16) for value in location.groups()) != (0, 0x2B, 0, 0)):
        raise RuntimeError("Expected the sole RTX 3090 at 0000:2b:00.0")
    return gpu


def number(gpu, field):
    try:
        value = float(gpu[field])
    except (KeyError, ValueError) as error:
        raise RuntimeError("Unavailable GPU field: " + field) from error
    if not math.isfinite(value):
        raise RuntimeError("Non-finite GPU field: " + field)
    return value


def assert_idle(gpu):
    if number(gpu, "utilization.gpu") > 5:
        raise RuntimeError("GPU utilization exceeds 5%; finish other GPU jobs first")
    if number(gpu, "memory.used") > 2048:
        raise RuntimeError("GPU memory use exceeds 2048 MiB; release other workloads first")
    if number(gpu, "temperature.gpu") > 65:
        raise RuntimeError("GPU temperature exceeds 65 C; allow it to cool first")
    for field in ("power.limit", "clocks.max.sm", "clocks.max.memory"):
        if number(gpu, field) <= 0:
            raise RuntimeError("Positive comparison setting unavailable: " + field)


def wait_for_idle(timeout_seconds=30):
    """Require three idle samples, allowing CUDA startup activity to settle."""
    deadline = time.monotonic() + timeout_seconds
    consecutive = 0
    last_error = None
    while True:
        snapshot = gpu_snapshot()
        try:
            assert_idle(snapshot)
        except RuntimeError as error:
            consecutive = 0
            last_error = error
        else:
            consecutive += 1
            if consecutive == 3:
                return snapshot
        if time.monotonic() >= deadline:
            raise RuntimeError("GPU did not settle to three idle samples: " +
                               str(last_error or "intermittent activity"))
        time.sleep(1)


def precision_settings(torch):
    matmul = torch.backends.cuda.matmul
    return {
        "fp32_precision": matmul.fp32_precision,
        "allow_fp16_reduced_precision_reduction": matmul.allow_fp16_reduced_precision_reduction,
        "allow_bf16_reduced_precision_reduction": matmul.allow_bf16_reduced_precision_reduction,
        "allow_fp16_accumulation": matmul.allow_fp16_accumulation,
    }


def measure(torch, name, dtype_name, precision, args):
    torch.backends.cuda.matmul.fp32_precision = precision
    flags = precision_settings(torch)
    if flags["fp32_precision"] != precision or any(
            flags[key] for key in flags if key != "fp32_precision"):
        raise RuntimeError("Requested precision/accumulation settings did not take effect")
    dtype = getattr(torch, dtype_name)
    a = torch.ones((args.n, args.n), dtype=dtype, device="cuda:0")
    b = torch.ones_like(a)
    out = torch.empty((args.n, args.n), dtype=torch.float32, device="cuda:0")

    def gemm():
        if dtype == torch.float32:
            torch.mm(a, b, out=out)
        else:
            torch.mm(a, b, out_dtype=torch.float32, out=out)

    torch.cuda.synchronize()
    deadline = time.perf_counter() + args.warmup_seconds
    while True:
        gemm()
        torch.cuda.synchronize()
        if time.perf_counter() >= deadline:
            break
    start = torch.cuda.Event(enable_timing=True)
    stop = torch.cuda.Event(enable_timing=True)
    timings = []
    for _ in range(args.samples):
        start.record()
        gemm()
        stop.record()
        stop.synchronize()
        timings.append(float(start.elapsed_time(stop)))
    if not all(math.isfinite(value) and value > 0 for value in timings):
        raise RuntimeError("Invalid CUDA event timings")
    # Every element of an all-ones matrix product is exactly the integer n.
    # Inspect the complete output, rather than only its first/last elements.
    mismatches = int(torch.count_nonzero(out != args.n).item())
    if mismatches:
        raise RuntimeError(f"{name}: {mismatches} output elements differ from {args.n}")
    median_ms = statistics.median(timings)
    return {"mode": name, "input_dtype": dtype_name, "output_dtype": "float32",
            "precision_settings": flags, "n": args.n,
            "warmup_seconds": args.warmup_seconds, "samples": args.samples,
            "sample_ms": timings, "median_ms": median_ms,
            "min_ms": min(timings), "max_ms": max(timings),
            "tflops": 2 * args.n ** 3 / (median_ms * 1e9),
            "correctness": {"passed": True, "method": "all output elements equal n",
                            "elements_checked": args.n ** 2, "mismatches": 0}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path,
                        help="New JSON result path; an existing file is never overwritten")
    parser.add_argument("--n", type=int, default=4096)
    parser.add_argument("--warmup-seconds", type=float, default=2.0)
    parser.add_argument("--samples", type=int, default=30)
    parser.add_argument("--trials", type=int, default=3)
    args = parser.parse_args()
    if not (128 <= args.n <= 8192 and 1 <= args.samples <= 1000 and
            1 <= args.trials <= 20 and math.isfinite(args.warmup_seconds) and
            0 < args.warmup_seconds <= 60):
        parser.error("Use n=128..8192, samples=1..1000, trials=1..20, warmup=(0,60]")
    output = args.output.resolve()
    if output.exists():
        parser.error("Output already exists; choose a new result path")
    result = {"schema_version": 1, "started_utc": utc_now(), "status": "incomplete",
              "purpose": "Current-state GEMM performance; no unlock-state determination",
              "script": file_identity(__file__), "python": {
                  "executable": file_identity(sys.executable), "version": sys.version,
                  "platform": platform.platform()},
              "protocol": {"n": args.n, "warmup_seconds": args.warmup_seconds,
                           "samples": args.samples, "trials": args.trials,
                           "modes": [mode[0] for mode in MODES]}, "trials": [],
              "environment": {key: os.environ.get(key) for key in (
                  "NVIDIA_TF32_OVERRIDE", "TORCH_ALLOW_TF32_CUBLAS_OVERRIDE",
                  "CUDA_VISIBLE_DEVICES", "CUBLAS_WORKSPACE_CONFIG")}}
    try:
        if any(result["environment"][key] for key in
               ("NVIDIA_TF32_OVERRIDE", "TORCH_ALLOW_TF32_CUBLAS_OVERRIDE")):
            raise RuntimeError("External TF32 override is set; no workload was started")
        initial = wait_for_idle()
        result["gpu_before"] = initial
        assert_idle(initial)
        # Import only after argument/identity/idle checks. --help imports no Torch.
        import torch

        torch_dir = Path(torch.__file__).resolve().parent
        result["torch"] = {"version": torch.__version__, "file": str(torch.__file__),
                           "cuda_build": torch.version.cuda,
                           "git_version": torch.version.git_version,
                           "build_configuration": torch.__config__.show(),
                           "cublas_dlls": [file_identity(path) for path in
                                           sorted((torch_dir / "lib").glob("cublas*64_*.dll"))]}
        if torch.__version__ != "2.14.1+cu130" or torch.version.cuda != "13.0":
            raise RuntimeError("Expected the prepared ComfyUI Torch 2.14.1+cu130 environment")
        if torch.cuda.device_count() != 1 or torch.cuda.get_device_name(0) != initial["name"]:
            raise RuntimeError("Torch and nvidia-smi disagree about the single GPU")
        props = torch.cuda.get_device_properties(0)
        result["torch"]["gpu_properties"] = {
            "name": props.name, "compute_capability": [props.major, props.minor],
            "total_memory_bytes": props.total_memory,
            "multiprocessor_count": props.multi_processor_count}
        matmul = torch.backends.cuda.matmul
        matmul.allow_fp16_reduced_precision_reduction = False
        matmul.allow_bf16_reduced_precision_reduction = False
        matmul.allow_fp16_accumulation = False
        # Recheck after imports/hashing, before allocating tensors or running GEMM.
        result["gpu_pre_measurement"] = wait_for_idle()
        expected_settings = {key: initial[key] for key in SETTINGS_FIELDS}
        with torch.inference_mode():
            for trial in range(1, args.trials + 1):
                record = {"trial": trial, "measurements": []}
                result["trials"].append(record)
                for mode in MODES:
                    measurement = measure(torch, *mode, args)
                    record["measurements"].append(measurement)
                    print(f"Trial {trial} {mode[0]}: {measurement['tflops']:.3f} TFLOPS; all elements correct",
                          flush=True)
                snapshot = gpu_snapshot()
                record["gpu_after"] = snapshot
                if {key: snapshot[key] for key in SETTINGS_FIELDS} != expected_settings:
                    raise RuntimeError("GPU/driver/power/clock comparison settings changed")
        result["summary"] = {
            mode[0]: {"median_tflops": statistics.median(
                next(item["tflops"] for item in trial["measurements"]
                     if item["mode"] == mode[0]) for trial in result["trials"])}
            for mode in MODES}
        result["status"] = "complete"
    except Exception as error:
        result["status"] = "failed"
        result["error"] = f"{type(error).__name__}: {error}"
        print(result["error"], file=sys.stderr, flush=True)
    finally:
        result["finished_utc"] = utc_now()
        output.parent.mkdir(parents=True, exist_ok=True)
        with output.open("x", encoding="utf-8") as stream:
            json.dump(result, stream, indent=2, allow_nan=False)
            stream.write("\n")
        print(f"Result JSON: {output}", flush=True)
    return 0 if result["status"] == "complete" else 1


if __name__ == "__main__":
    sys.exit(main())
