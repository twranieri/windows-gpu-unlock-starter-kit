# SPDX-License-Identifier: GPL-2.0-only
"""Portable Windows PyTorch tensor GEMM comparison; no unlock or GPU tuning.

Use the identical script and Python/CUDA-enabled Torch environment before and
after a separately performed boot experiment. --label is operator-supplied and
does not prove an unlock. --help imports no Torch and does not query the GPU.
"""

import argparse
import csv
from datetime import datetime, timezone
import hashlib
import importlib
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


GPU_FIELDS = ("name", "pci.bus_id", "driver_version", "vbios_version", "memory.total",
              "power.limit", "power.default_limit", "clocks.max.sm", "clocks.max.memory",
              "utilization.gpu", "memory.used", "temperature.gpu", "power.draw", "clocks.sm")
SETTINGS_FIELDS = GPU_FIELDS[:9]
MODES = (("fp32_ieee", "float32", "ieee"),
         ("fp16_fp32_accumulate", "float16", "ieee"),
         ("bf16_fp32_accumulate", "bfloat16", "ieee"),
         ("tf32_fp32_accumulate", "float32", "tf32"))
ENVIRONMENT_FIELDS = ("NVIDIA_TF32_OVERRIDE", "TORCH_ALLOW_TF32_CUBLAS_OVERRIDE",
                      "CUDA_VISIBLE_DEVICES", "CUBLAS_WORKSPACE_CONFIG")
PATH_LIKE = re.compile(r"(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\|/(?:home|Users|tmp|opt|usr)/)")


class BenchmarkError(RuntimeError):
    pass


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def file_identity(path):
    path = Path(path).resolve()
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"name": path.name, "bytes": path.stat().st_size, "sha256": digest.hexdigest()}


def environment_metadata():
    raw = {key: os.environ.get(key) for key in ENVIRONMENT_FIELDS}
    public = {key: "<path redacted>" if value and PATH_LIKE.search(value) else value
              for key, value in raw.items()}
    hashes = {key: None if value is None else hashlib.sha256(value.encode()).hexdigest()
              for key, value in raw.items()}
    return raw, public, hashes


def number(gpu, field):
    try:
        value = float(gpu[field])
    except (KeyError, TypeError, ValueError) as error:
        raise BenchmarkError("Unavailable numeric GPU field: " + field) from error
    if not math.isfinite(value):
        raise BenchmarkError("Non-finite GPU field: " + field)
    return value


def gpu_snapshot():
    completed = subprocess.run(["nvidia-smi", "--query-gpu=" + ",".join(GPU_FIELDS),
                                "--format=csv,noheader,nounits"], check=True,
                               capture_output=True, text=True, timeout=15)
    rows = list(csv.reader(completed.stdout.strip().splitlines()))
    if len(rows) != 1 or len(rows[0]) != len(GPU_FIELDS):
        raise BenchmarkError("Expected exactly one NVIDIA GPU and complete telemetry")
    gpu = dict(zip(GPU_FIELDS, (value.strip() for value in rows[0])))
    if not re.fullmatch(r"[0-9a-fA-F]{1,8}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]", gpu["pci.bus_id"]):
        raise BenchmarkError("Unavailable or invalid GPU PCI location")
    for field in ("name", "driver_version", "vbios_version"):
        if not gpu[field] or gpu[field] in ("N/A", "[N/A]", "Unknown") or PATH_LIKE.search(gpu[field]):
            raise BenchmarkError("Unavailable GPU identity field: " + field)
    for field in GPU_FIELDS[4:]:
        number(gpu, field)
    for field in ("memory.total", "power.limit", "power.default_limit", "clocks.max.sm", "clocks.max.memory"):
        if number(gpu, field) <= 0:
            raise BenchmarkError("Positive GPU comparison setting unavailable: " + field)
    if not 0 <= number(gpu, "utilization.gpu") <= 100 or number(gpu, "memory.used") < 0 or number(gpu, "power.draw") < 0:
        raise BenchmarkError("Invalid GPU utilization/memory/power telemetry")
    return gpu


def comparison_settings(gpu):
    return {key: gpu[key] for key in SETTINGS_FIELDS}


def assert_idle(gpu):
    if number(gpu, "utilization.gpu") > 5:
        raise BenchmarkError("GPU utilization exceeds 5%; finish other GPU jobs first")
    if number(gpu, "memory.used") > 2048:
        raise BenchmarkError("GPU memory use exceeds 2048 MiB; release other workloads first")
    if number(gpu, "temperature.gpu") > 65:
        raise BenchmarkError("GPU temperature exceeds 65 C; allow it to cool first")
    for field in ("power.limit", "clocks.max.sm", "clocks.max.memory"):
        if number(gpu, field) <= 0:
            raise BenchmarkError("Positive comparison setting unavailable: " + field)


def wait_for_idle(timeout_seconds=30):
    deadline = time.monotonic() + timeout_seconds
    consecutive, last_error, identity = 0, None, None
    while True:
        snapshot = gpu_snapshot()
        settings = comparison_settings(snapshot)
        if identity is None:
            identity = settings
        elif settings != identity:
            raise BenchmarkError("GPU/driver/power/clock settings changed during idle checks")
        try:
            assert_idle(snapshot)
        except BenchmarkError as error:
            consecutive, last_error = 0, error
        else:
            consecutive += 1
            if consecutive == 3:
                return snapshot
        if time.monotonic() >= deadline:
            raise BenchmarkError("GPU did not settle to three consecutive idle samples: " +
                                 str(last_error or "intermittent activity"))
        time.sleep(1)


def precision_settings(torch):
    matmul = torch.backends.cuda.matmul
    return {"fp32_precision": matmul.fp32_precision,
            "allow_fp16_reduced_precision_reduction": matmul.allow_fp16_reduced_precision_reduction,
            "allow_bf16_reduced_precision_reduction": matmul.allow_bf16_reduced_precision_reduction,
            "allow_fp16_accumulation": matmul.allow_fp16_accumulation}


def validate_torch(torch, gpu):
    if not torch.version.cuda or not torch.cuda.is_available():
        raise BenchmarkError("A CUDA-enabled PyTorch installation and working NVIDIA CUDA device are required")
    if torch.cuda.device_count() != 1 or torch.cuda.get_device_name(0) != gpu["name"]:
        raise BenchmarkError("Torch and nvidia-smi disagree about the single GPU")
    props = torch.cuda.get_device_properties(0)
    if props.name != gpu["name"] or props.major < 8:
        raise BenchmarkError("This exact BF16/TF32 protocol requires the matched NVIDIA GPU with compute capability 8.0 or newer")
    physical_bytes = number(gpu, "memory.total") * 1024 ** 2
    if (not isinstance(props.total_memory, int) or props.total_memory <= 0 or
            abs(props.total_memory - physical_bytes) > max(64 * 1024 ** 2, physical_bytes * 0.01)):
        raise BenchmarkError("Torch and nvidia-smi GPU memory identities disagree")
    if not torch.cuda.is_bf16_supported():
        raise BenchmarkError("Native BF16 support is required; no emulation or dtype fallback is used")
    for target, names in ((torch, ("mm", "ones", "ones_like", "empty", "count_nonzero", "inference_mode")),
                          (torch.cuda, ("Event", "synchronize"))):
        if any(not callable(getattr(target, name, None)) for name in names):
            raise BenchmarkError("Required CUDA/PyTorch benchmark API is unavailable")
    if "out_dtype" not in (torch.mm.__doc__ or ""):
        raise BenchmarkError("Torch mm must support CUDA FP16/BF16 out_dtype=float32; no fallback is used")
    for dtype in ("float32", "float16", "bfloat16"):
        if not hasattr(torch, dtype):
            raise BenchmarkError("A required Torch dtype is unavailable")
    try:
        flags = precision_settings(torch)
    except AttributeError as error:
        raise BenchmarkError("Torch must expose fp32_precision and all three reduction/accumulation controls") from error
    matmul = torch.backends.cuda.matmul
    for flag in flags:
        if flag != "fp32_precision":
            setattr(matmul, flag, False)
    matmul.fp32_precision = "ieee"
    configured = precision_settings(torch)
    if configured["fp32_precision"] != "ieee" or any(configured[k] is not False for k in configured if k != "fp32_precision"):
        raise BenchmarkError("Required precision/accumulation controls did not take effect")
    return props


def torch_metadata(torch, props):
    torch_file = Path(torch.__file__).resolve()
    dlls = sorted((torch_file.parent / "lib").glob("cublas*64_*.dll"))
    if not any(p.name.lower().startswith("cublas64_") for p in dlls) or not any(p.name.lower().startswith("cublaslt64_") for p in dlls):
        raise BenchmarkError("Cannot locate both bundled Windows cuBLAS DLLs for reproducibility hashing")
    build = torch.__config__.show()
    return {"version": str(torch.__version__), "file": torch_file.name,
            "module": file_identity(torch_file), "cuda_build": str(torch.version.cuda),
            "git_version": str(torch.version.git_version),
            "build_configuration": "Content omitted to avoid disclosing build paths; full text SHA-256 recorded.",
            "build_configuration_sha256": hashlib.sha256(build.encode()).hexdigest(),
            "cublas_dlls": [file_identity(path) for path in dlls],
            "gpu_properties": {"name": props.name, "compute_capability": [props.major, props.minor],
                               "total_memory_bytes": props.total_memory,
                               "multiprocessor_count": props.multi_processor_count}}


def measure(torch, name, dtype_name, precision, args):
    torch.backends.cuda.matmul.fp32_precision = precision
    flags = precision_settings(torch)
    if flags["fp32_precision"] != precision or any(flags[k] is not False for k in flags if k != "fp32_precision"):
        raise BenchmarkError("Requested precision/accumulation settings did not take effect")
    dtype = getattr(torch, dtype_name)
    a = torch.ones((args.n, args.n), dtype=dtype, device="cuda:0")
    b = torch.ones_like(a)
    out = torch.empty((args.n, args.n), dtype=torch.float32, device="cuda:0")
    if out.dtype != torch.float32 or out.device.type != "cuda":
        raise BenchmarkError("FP32 CUDA output allocation did not take effect")

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
    start, stop = torch.cuda.Event(enable_timing=True), torch.cuda.Event(enable_timing=True)
    timings = []
    for _ in range(args.samples):
        start.record()
        gemm()
        stop.record()
        stop.synchronize()
        timings.append(float(start.elapsed_time(stop)))
    if not all(math.isfinite(value) and value > 0 for value in timings):
        raise BenchmarkError("Invalid CUDA event timings")
    mismatches = int(torch.count_nonzero(out != args.n).item())
    if mismatches:
        raise BenchmarkError(name + ": output elements differ from the exact expected integer n")
    median_ms = statistics.median(timings)
    if not math.isfinite(median_ms) or median_ms <= 0:
        raise BenchmarkError("Invalid CUDA event median")
    tflops = 2 * args.n ** 3 / (median_ms * 1e9)
    if not math.isfinite(tflops) or tflops <= 0:
        raise BenchmarkError("Invalid throughput derived from CUDA event timings")
    return {"mode": name, "input_dtype": dtype_name, "output_dtype": "float32",
            "precision_settings": flags, "n": args.n, "warmup_seconds": args.warmup_seconds,
            "samples": args.samples, "sample_ms": timings, "median_ms": median_ms,
            "min_ms": min(timings), "max_ms": max(timings),
            "tflops": tflops,
            "correctness": {"passed": True, "method": "all output elements equal n",
                            "elements_checked": args.n ** 2, "mismatches": 0}}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", required=True, choices=("stock", "unlocked"), help="Operator label, not unlock proof")
    parser.add_argument("--output", required=True, type=Path, help="New result JSON; existing files are never overwritten")
    parser.add_argument("--n", type=int, default=4096)
    parser.add_argument("--warmup-seconds", type=float, default=2.0)
    parser.add_argument("--samples", type=int, default=30)
    parser.add_argument("--trials", type=int, default=3)
    args = parser.parse_args(argv)
    if not (128 <= args.n <= 8192 and 1 <= args.samples <= 1000 and 1 <= args.trials <= 20 and
            math.isfinite(args.warmup_seconds) and 0 < args.warmup_seconds <= 60):
        parser.error("Use n=128..8192, samples=1..1000, trials=1..20, warmup=(0,60]")
    output = args.output.resolve()
    if output.exists():
        parser.error("Output already exists; choose a new result path")
    # Reserve the path before any GPU query/import; a race cannot overwrite data.
    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        stream = output.open("x", encoding="utf-8")
    except FileExistsError:
        parser.error("Output already exists; choose a new result path")
    raw_env, public_env, env_hashes = environment_metadata()
    result = {"schema_version": 2, "label": args.label, "started_utc": utc_now(), "status": "incomplete",
              "purpose": "Current-state GEMM performance; operator label is not an unlock-state determination",
              "protocol": {"n": args.n, "warmup_seconds": args.warmup_seconds,
                           "samples": args.samples, "trials": args.trials, "modes": [m[0] for m in MODES]},
              "environment": public_env, "environment_sha256": env_hashes, "trials": []}
    try:
        result["script"] = file_identity(__file__)
        result["python"] = {"executable": file_identity(sys.executable), "version": platform.python_version(),
                            "implementation": platform.python_implementation(), "platform": platform.platform()}
        if any(raw_env[key] for key in ENVIRONMENT_FIELDS[:2]):
            raise BenchmarkError("External TF32 override is set; no workload was started")
        initial = wait_for_idle()
        result["gpu_before"] = initial
        torch = importlib.import_module("torch")
        props = validate_torch(torch, initial)
        result["torch"] = torch_metadata(torch, props)
        expected = comparison_settings(initial)
        result["gpu_pre_measurement"] = wait_for_idle()
        if comparison_settings(result["gpu_pre_measurement"]) != expected:
            raise BenchmarkError("GPU/driver/power/clock settings changed before the first measurement")
        with torch.inference_mode():
            for trial in range(1, args.trials + 1):
                record = {"trial": trial, "measurements": []}
                result["trials"].append(record)
                for mode in MODES:
                    item = measure(torch, *mode, args)
                    record["measurements"].append(item)
                    print("Trial " + str(trial) + " " + mode[0] + ": " + format(item["tflops"], ".3f") +
                          " TFLOPS; all elements correct", flush=True)
                record["gpu_after"] = gpu_snapshot()
                if comparison_settings(record["gpu_after"]) != expected:
                    raise BenchmarkError("GPU/driver/power/clock comparison settings changed")
        result["summary"] = {mode[0]: {"median_tflops": statistics.median(
            next(item["tflops"] for item in trial["measurements"] if item["mode"] == mode[0])
            for trial in result["trials"])} for mode in MODES}
        result["status"] = "complete"
    except Exception as error:
        result["status"] = "failed"
        # Library/OS errors may contain local paths. Keep those out of shareable JSON.
        result["error"] = str(error) if isinstance(error, BenchmarkError) else type(error).__name__ + ": external operation failed; see local terminal"
        print(type(error).__name__ + ": " + str(error), file=sys.stderr, flush=True)
    finally:
        result["finished_utc"] = utc_now()
        with stream:
            json.dump(result, stream, indent=2, allow_nan=False)
            stream.write("\n")
        print("Result JSON: " + output.name, flush=True)
    return 0 if result["status"] == "complete" else 1


if __name__ == "__main__":
    raise SystemExit(main())
