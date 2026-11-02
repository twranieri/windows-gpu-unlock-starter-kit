"""Compare two matched tensor benchmarks; operator labels are not unlock proof.

GPL-2.0-only. Reads JSON only; no Torch, GPU, browser or backend access.
Schema 3 requires matched physical GPU UUID and full PCI BDF. Schema 2 remains
readable only as a legacy schema-2 pair without UUID identity assurance; mixed
schema pairs are refused. Each report compares one card, never aggregate GPUs.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import statistics
import sys

MODES = {
    "fp32_ieee": ("float32", "ieee"),
    "fp16_fp32_accumulate": ("float16", "ieee"),
    "bf16_fp32_accumulate": ("bfloat16", "ieee"),
    "tf32_fp32_accumulate": ("float32", "tf32"),
}
SETTINGS = ("name", "pci.bus_id", "driver_version", "vbios_version", "memory.total",
            "power.limit", "power.default_limit", "clocks.max.sm", "clocks.max.memory")
TELEMETRY = ("utilization.gpu", "memory.used", "temperature.gpu", "power.draw", "clocks.sm")
ENVIRONMENT = ("NVIDIA_TF32_OVERRIDE", "TORCH_ALLOW_TF32_CUBLAS_OVERRIDE",
               "CUDA_VISIBLE_DEVICES", "CUBLAS_WORKSPACE_CONFIG")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def numeric(value, label, minimum=None, maximum=None, integer=False):
    require(type(value) in ((int,) if integer else (int, float)), label + " must be numeric")
    require(math.isfinite(value), label + " is nonfinite")
    require(minimum is None or value >= minimum, label + " is below range")
    require(maximum is None or value <= maximum, label + " exceeds range")
    return value


def string(value, label):
    require(isinstance(value, str) and bool(value.strip()), label + " is missing/empty")
    return value


def identity(value, label):
    require(isinstance(value, dict), label + " identity is missing")
    require(set(value) == {"name", "bytes", "sha256"}, label + " identity must contain only name/bytes/sha256")
    name = string(value["name"], label + " name")
    require(not any(c in name for c in ("/", "\\", ":")), label + " contains a local path")
    numeric(value["bytes"], label + " bytes", minimum=1, integer=True)
    require(isinstance(value["sha256"], str) and re.fullmatch(r"[0-9a-f]{64}", value["sha256"]), label + " SHA-256 is invalid")


def reject_bad_values(value):
    if isinstance(value, dict):
        for key, item in value.items():
            require(key not in ("error", "errors"), "Result contains an error field")
            reject_bad_values(item)
    elif isinstance(value, list):
        for item in value:
            reject_bad_values(item)
    elif isinstance(value, float):
        require(math.isfinite(value), "Result contains nonfinite data")


def load_result(path):
    require(path.stat().st_size <= 32 * 1024 * 1024, "Result exceeds 32 MiB")

    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "Duplicate JSON key: " + key)
            result[key] = value
        return result

    def constant(value):
        raise ValueError("Nonfinite JSON constant: " + value)

    result = json.loads(path.read_text(encoding="utf-8-sig"), object_pairs_hook=unique, parse_constant=constant)
    reject_bad_values(result)
    return result


def physical_uuid(value):
    require(isinstance(value, str) and
            re.fullmatch(r"GPU-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", value),
            "Missing/invalid canonical physical GPU UUID")
    require(set(value[4:].replace("-", "")) != {"0"}, "Zero GPU UUID is invalid")
    return value


def gpu_settings(snapshot, label, idle=False, schema=2):
    require(isinstance(snapshot, dict), label + " GPU snapshot is missing")
    for key in SETTINGS:
        string(snapshot.get(key), label + "." + key)
    require(re.fullmatch(r"[0-9A-Fa-f]{1,8}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-7]", snapshot["pci.bus_id"]), label + " BDF invalid")
    if schema == 3:
        require(re.fullmatch(r"[0-9a-f]{8}:[0-9a-f]{2}:[01][0-9a-f]\.[0-7]", snapshot["pci.bus_id"]),
                label + " requires a canonical full PCI BDF")
        physical_uuid(snapshot.get("uuid"))
    for key in SETTINGS[4:] + TELEMETRY:
        try:
            value = float(snapshot[key])
        except (KeyError, TypeError, ValueError) as exc:
            raise ValueError(label + "." + key + " is unavailable") from exc
        numeric(value, label + "." + key, minimum=0)
        if key in SETTINGS[4:]:
            require(value > 0, label + "." + key + " must be positive")
    if idle:
        require(float(snapshot["utilization.gpu"]) <= 5, label + " idle utilization gate failed")
        require(float(snapshot["memory.used"]) <= 2048, label + " idle VRAM gate failed")
        require(float(snapshot["temperature.gpu"]) <= 65, label + " idle temperature gate failed")
    return {key: snapshot[key] for key in SETTINGS + (("uuid",) if schema == 3 else ())}


def check_derived(actual, expected, label):
    numeric(actual, label, minimum=0)
    require(math.isclose(actual, expected, rel_tol=1e-10, abs_tol=1e-12), label + " disagrees with CUDA event timings")


def validate(result, label):
    require(isinstance(result, dict), "Result must be a JSON object")
    reject_bad_values(result)
    require(type(result.get("schema_version")) is int and result["schema_version"] in (2, 3),
            "Only portable benchmark schemas 2 (legacy pair) and 3 (UUID-bound pair) are accepted")
    schema = result["schema_version"]
    require(result.get("label") == label, "Expected operator label " + label)
    require(result.get("status") == "complete", label + " benchmark is not complete")
    require(result.get("data_kind", "measured") in ("measured", "synthetic"), "Unknown data kind")
    identity(result.get("script"), "script")
    python = result.get("python")
    require(isinstance(python, dict), "Python metadata is missing")
    identity(python.get("executable"), "Python executable")
    for key in ("version", "platform"):
        string(python.get(key), "Python " + key)
    torch = result.get("torch")
    require(isinstance(torch, dict), "Torch metadata is missing")
    for key in ("version", "cuda_build", "git_version", "build_configuration", "file"):
        string(torch.get(key), "Torch " + key)
    identity(torch.get("module"), "Torch module")
    require(not any(c in torch["file"] for c in ("/", "\\", ":")), "Torch file contains a local path")
    require(isinstance(torch.get("build_configuration_sha256"), str) and
            re.fullmatch(r"[0-9a-f]{64}", torch["build_configuration_sha256"]), "Missing Torch build configuration hash")
    dlls = torch.get("cublas_dlls")
    require(isinstance(dlls, list) and bool(dlls), "cuBLAS DLL identities are missing")
    names = set()
    for dll in dlls:
        identity(dll, "cuBLAS DLL")
        require(dll["name"].lower().startswith("cublas") and dll["name"].lower().endswith(".dll"), "Unexpected cuBLAS DLL name")
        require(dll["name"].lower() not in names, "Duplicate cuBLAS DLL identity")
        names.add(dll["name"].lower())
    require(any(name.startswith("cublas64_") for name in names) and
            any(name.startswith("cublaslt64_") for name in names), "Both cuBLAS and cuBLASLt identities are required")
    props = torch.get("gpu_properties")
    require(isinstance(props, dict), "Torch GPU properties are missing")
    string(props.get("name"), "Torch GPU name")
    for key in ("total_memory_bytes", "multiprocessor_count"):
        numeric(props.get(key), "Torch GPU " + key, minimum=1, integer=True)
    capability = props.get("compute_capability")
    require(isinstance(capability, list) and len(capability) == 2 and
            all(type(v) is int and 0 <= v <= 99 for v in capability) and capability >= [8, 0],
            "Expected Ampere-or-newer tensor capability")
    protocol = result.get("protocol")
    require(isinstance(protocol, dict), "Protocol is missing")
    n = numeric(protocol.get("n"), "n", 128, 8192, integer=True)
    samples = numeric(protocol.get("samples"), "samples", 1, 1000, integer=True)
    trials = numeric(protocol.get("trials"), "trials", 1, 20, integer=True)
    warmup = numeric(protocol.get("warmup_seconds"), "warmup", 0, 60)
    require(warmup > 0, "Warmup must be positive")
    require(protocol.get("modes") == list(MODES), "Protocol modes/order must contain exactly the four required modes")
    env = result.get("environment")
    require(isinstance(env, dict) and set(env) == set(ENVIRONMENT), "Precision environment is incomplete")
    require(all(v is None or isinstance(v, str) for v in env.values()), "Invalid precision environment value")
    require(not env["NVIDIA_TF32_OVERRIDE"] and not env["TORCH_ALLOW_TF32_CUBLAS_OVERRIDE"], "External TF32 override invalidates precision control")
    hashes = result.get("environment_sha256")
    require(isinstance(hashes, dict) and set(hashes) == set(ENVIRONMENT), "Raw precision environment hashes are missing")
    for key in ENVIRONMENT:
        if env[key] is None:
            require(hashes[key] is None, "Unset precision environment hash is inconsistent")
        else:
            require(isinstance(hashes[key], str) and re.fullmatch(r"[0-9a-f]{64}", hashes[key]),
                    "Raw precision environment hash is invalid")
            if env[key] != "<path redacted>":
                require(hashes[key] == hashlib.sha256(env[key].encode()).hexdigest(),
                        "Precision environment value/hash disagree")
    settings = gpu_settings(result.get("gpu_before"), label + " initial", idle=True, schema=schema)
    require(props["name"] == settings["name"], "Torch/driver GPU identity differs")
    if schema == 3:
        require(physical_uuid(props.get("uuid")) == settings["uuid"], "Torch/driver physical GPU UUID differs")
        selected = result.get("selected_device")
        require(isinstance(selected, dict) and set(selected) == {"pci_bus_id", "uuid", "cuda_ordinal", "identity_method"},
                "Selected-device UUID/BDF binding is missing or malformed")
        require(selected["pci_bus_id"] == settings["pci.bus_id"] and
                physical_uuid(selected["uuid"]) == settings["uuid"] and
                selected["identity_method"] == "physical GPU UUID", "Selected-device identity differs")
        numeric(selected["cuda_ordinal"], "Selected CUDA ordinal", 0, 1, integer=True)
    require(gpu_settings(result.get("gpu_pre_measurement"), label + " premeasurement", idle=True, schema=schema) == settings,
            "GPU settings changed before measurement")
    records = result.get("trials")
    require(isinstance(records, list) and len(records) == trials, "Trial count is missing/incorrect")
    derived = {mode: [] for mode in MODES}
    for index, record in enumerate(records, 1):
        require(isinstance(record, dict) and type(record.get("trial")) is int and record["trial"] == index,
                "Missing, duplicate or reordered trial")
        require(gpu_settings(record.get("gpu_after"), f"{label} trial {index}", schema=schema) == settings,
                "GPU settings changed during a trial")
        measurements = record.get("measurements")
        require(isinstance(measurements, list) and len(measurements) == 4 and
                [m.get("mode") if isinstance(m, dict) else None for m in measurements] == list(MODES),
                "Missing, duplicate or reordered measurement mode")
        for measurement in measurements:
            mode = measurement["mode"]
            require(measurement.get("n") == n and type(measurement.get("n")) is int and
                    measurement.get("samples") == samples and type(measurement.get("samples")) is int and
                    type(measurement.get("warmup_seconds")) in (int, float) and
                    measurement.get("warmup_seconds") == warmup, "Measurement protocol drift")
            dtype, precision = MODES[mode]
            require(measurement.get("input_dtype") == dtype and measurement.get("output_dtype") == "float32", "Unexpected input/output dtype")
            flags = {"fp32_precision": precision, "allow_fp16_reduced_precision_reduction": False,
                     "allow_bf16_reduced_precision_reduction": False, "allow_fp16_accumulation": False}
            require(measurement.get("precision_settings") == flags and
                    all(measurement["precision_settings"][k] is False for k in flags if k != "fp32_precision"),
                    "Precision/FP32 accumulation flags differ from requested protocol")
            correctness = measurement.get("correctness")
            require(isinstance(correctness, dict) and correctness.get("passed") is True and
                    correctness.get("method") == "all output elements equal n" and
                    type(correctness.get("elements_checked")) is int and correctness["elements_checked"] == n * n and
                    type(correctness.get("mismatches")) is int and correctness["mismatches"] == 0,
                    "Missing/failed full-output correctness check")
            timings = measurement.get("sample_ms")
            require(isinstance(timings, list) and len(timings) == samples, "CUDA event timing count is incorrect")
            for value in timings:
                numeric(value, "CUDA event milliseconds", minimum=0)
                require(value > 0, "CUDA event milliseconds must be positive")
            median = statistics.median(timings)
            rate = 2 * n ** 3 / (median * 1e9)
            require(math.isfinite(rate) and rate > 0, "Derived throughput is invalid")
            for key, expected in (("median_ms", median), ("min_ms", min(timings)),
                                  ("max_ms", max(timings)), ("tflops", rate)):
                check_derived(measurement.get(key), expected, mode + "." + key)
            derived[mode].append(rate)
    summary = result.get("summary")
    require(isinstance(summary, dict) and set(summary) == set(MODES), "Four-mode summary is incomplete")
    for mode in MODES:
        require(isinstance(summary[mode], dict), "Invalid summary mode")
        check_derived(summary[mode].get("median_tflops"), statistics.median(derived[mode]), mode + " summary")
    return derived, settings


def compare(before, after):
    try:
        stock, stock_settings = validate(before, "stock")
        unlocked, unlocked_settings = validate(after, "unlocked")
        require(before["schema_version"] == after["schema_version"],
                "Cannot compare legacy schema 2 with UUID-bound schema 3; rerun both states with the same script")
        for key in ("script", "python", "torch", "protocol", "environment", "environment_sha256"):
            require(before[key] == after[key], "Comparison metadata mismatch: " + key)
        require(stock_settings == unlocked_settings, "Comparison GPU/driver/power/clock settings differ")
        kind = before.get("data_kind", "measured")
        require(kind == after.get("data_kind", "measured"), "Cannot mix synthetic and measured data")
        modes = {}
        for mode in MODES:
            a, b = statistics.median(stock[mode]), statistics.median(unlocked[mode])
            ratio = b / a
            require(math.isfinite(ratio) and math.isfinite((ratio - 1) * 100), "Derived comparison ratio is nonfinite")
            modes[mode] = {"before_median_tflops": a, "after_median_tflops": b,
                           "speed_ratio": ratio, "percent_gain": (ratio - 1) * 100,
                           "before_trial_tflops": stock[mode], "after_trial_tflops": unlocked[mode],
                           "before_trial_range_tflops": [min(stock[mode]), max(stock[mode])],
                           "after_trial_range_tflops": [min(unlocked[mode]), max(unlocked[mode])]}
        return {"schema_version": 2, "benchmark_schema_version": before["schema_version"],
                "status": "comparison_complete", "data_kind": kind,
                "purpose": "Matched GEMM performance comparison; not proof of unlocked state or application speed",
                "operator_labels": {"before": "stock", "after": "unlocked", "verified": False},
                "validation": "All required metadata, event timings, precision flags and full-output checks passed",
                "identity_validation": ("Matched physical GPU UUID and canonical PCI BDF" if before["schema_version"] == 3
                                        else "Legacy schema 2: PCI/settings match only; physical UUID was not recorded"),
                "gpu_settings": stock_settings, "protocol": before["protocol"],
                "script": before["script"], "modes": modes}
    except (KeyError, TypeError, OverflowError, AttributeError) as exc:
        raise ValueError("Missing or malformed benchmark data: " + str(exc)) from exc


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", required=True, type=Path)
    parser.add_argument("--after", required=True, type=Path)
    parser.add_argument("--output", type=Path, help="Optional new JSON report; existing files are never overwritten")
    args = parser.parse_args(argv)
    try:
        if args.output is not None:
            require(not args.output.exists(), "Output already exists; choose a new report path")
        report = compare(load_result(args.before), load_result(args.after))
        rendered = json.dumps(report, indent=2, allow_nan=False) + "\n"
        if args.output is not None:
            with args.output.open("x", encoding="utf-8") as stream:
                stream.write(rendered)
        print(rendered, end="")
        return 0
    except (ValueError, OSError) as exc:
        print("Comparison refused: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
