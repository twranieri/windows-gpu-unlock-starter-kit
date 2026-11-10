"""Offline comparison checks. Every result below is explicitly synthetic data."""
import copy
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import statistics
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "compare-tensors.py"
SPEC = importlib.util.spec_from_file_location("starter_kit_compare_tensors", SCRIPT)
compare_tensors = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = compare_tensors
SPEC.loader.exec_module(compare_tensors)

MODES = ("fp32_ieee", "fp16_fp32_accumulate", "bf16_fp32_accumulate", "tf32_fp32_accumulate")
DTYPES = ("float32", "float16", "bfloat16", "float32")


def identity(name, size=100):
    return {"name": name, "bytes": size, "sha256": hashlib.sha256(name.encode()).hexdigest()}


def synthetic_result(label, factor=1.0):
    """Invented timings and identities; never load or reuse machine benchmark results."""
    gpu = {"name": "Synthetic CUDA GPU", "pci.bus_id": "00000000:01:00.0",
           "driver_version": "synthetic-driver", "vbios_version": "synthetic-vbios",
           "memory.total": "8192", "power.limit": "200.00", "power.default_limit": "200.00",
           "clocks.max.sm": "1800", "clocks.max.memory": "7000",
           "utilization.gpu": "0", "memory.used": "256", "temperature.gpu": "35",
           "power.draw": "25", "clocks.sm": "210"}
    configuration = "synthetic build configuration"
    result = {"schema_version": 2, "data_kind": "synthetic", "label": label,
              "status": "complete", "started_utc": "2000-01-01T00:00:00+00:00",
              "finished_utc": "2000-01-01T00:01:00+00:00",
              "purpose": "Synthetic offline unit-test fixture; no measured hardware results",
              "script": identity("benchmark-gemm.py"),
              "python": {"executable": identity("python.exe", 200),
                         "version": "3.14.0 synthetic fixture", "platform": "synthetic-windows",
                         "implementation": "CPython"},
              "torch": {"version": "2.14.1+cu130", "cuda_build": "13.0",
                        "git_version": "synthetic-git-revision", "file": "__init__.py",
                        "module": identity("__init__.py", 300),
                        "build_configuration": configuration,
                        "build_configuration_sha256": hashlib.sha256(configuration.encode()).hexdigest(),
                        "cublas_dlls": [identity("cublas64_13.dll", 400),
                                        identity("cublasLt64_13.dll", 500)],
                        "gpu_properties": {"name": gpu["name"], "compute_capability": [8, 6],
                                           "total_memory_bytes": 8192 * 1024 * 1024,
                                           "multiprocessor_count": 20}},
              "protocol": {"n": 128, "samples": 3, "trials": 2, "warmup_seconds": 0.1,
                           "modes": list(MODES)},
              "environment": {"NVIDIA_TF32_OVERRIDE": None, "TORCH_ALLOW_TF32_CUBLAS_OVERRIDE": None,
                              "CUDA_VISIBLE_DEVICES": None, "CUBLAS_WORKSPACE_CONFIG": None},
              "gpu_before": copy.deepcopy(gpu), "gpu_pre_measurement": copy.deepcopy(gpu),
              "trials": []}
    result["environment_sha256"] = {key: None for key in result["environment"]}
    for index in range(2):
        snapshot = copy.deepcopy(gpu)
        snapshot.update({"utilization.gpu": "99", "memory.used": "384", "temperature.gpu": "50",
                         "power.draw": "190", "clocks.sm": "1500"})
        trial = {"trial": index + 1, "gpu_after": snapshot, "measurements": []}
        for mode_index, (mode, dtype) in enumerate(zip(MODES, DTYPES)):
            median = (10.0 + mode_index * 2 + index) * factor
            timings = [median * 0.9, median, median * 1.1]
            trial["measurements"].append({
                "mode": mode, "input_dtype": dtype, "output_dtype": "float32",
                "precision_settings": {"fp32_precision": "tf32" if mode_index == 3 else "ieee",
                                       "allow_fp16_reduced_precision_reduction": False,
                                       "allow_bf16_reduced_precision_reduction": False,
                                       "allow_fp16_accumulation": False},
                "n": 128, "warmup_seconds": 0.1, "samples": 3, "sample_ms": timings,
                "median_ms": median, "min_ms": min(timings), "max_ms": max(timings),
                "tflops": 2 * 128 ** 3 / (median * 1e9),
                "correctness": {"passed": True, "method": "all output elements equal n",
                                "elements_checked": 128 ** 2, "mismatches": 0}})
        result["trials"].append(trial)
    result["summary"] = {
        mode: {"median_tflops": statistics.median(trial["measurements"][i]["tflops"]
                                                 for trial in result["trials"])}
        for i, mode in enumerate(MODES)}
    return result


def uuid_result(label, factor=1.0, uuid="GPU-11111111-1111-4111-8111-111111111111",
                bdf="00000000:01:00.0", ordinal=0):
    result = synthetic_result(label, factor)
    result["schema_version"] = 3
    for snapshot in [result["gpu_before"], result["gpu_pre_measurement"], *[t["gpu_after"] for t in result["trials"]]]:
        snapshot["uuid"] = uuid
        snapshot["pci.bus_id"] = bdf
    result["torch"]["gpu_properties"]["uuid"] = uuid
    result["selected_device"] = {"pci_bus_id": bdf, "uuid": uuid, "cuda_ordinal": ordinal,
                                 "identity_method": "physical GPU UUID"}
    return result


class CompareTensorsTests(unittest.TestCase):
    def setUp(self):
        self.before = synthetic_result("stock")
        self.after = synthetic_result("unlocked", factor=0.5)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def assert_rejected(self, mutate, side="after"):
        before, after = copy.deepcopy(self.before), copy.deepcopy(self.after)
        mutate(after if side == "after" else before)
        with self.assertRaises(ValueError):
            compare_tensors.compare(before, after)

    def test_valid_synthetic_comparison_derives_ratios_and_trial_ranges(self):
        before, after = copy.deepcopy(self.before), copy.deepcopy(self.after)
        report = compare_tensors.compare(before, after)
        self.assertEqual(report["status"], "comparison_complete")
        self.assertEqual(report["data_kind"], "synthetic")
        self.assertEqual(report["operator_labels"], {"before": "stock", "after": "unlocked", "verified": False})
        self.assertEqual(set(report["modes"]), set(MODES))
        for i, mode in enumerate(MODES):
            values = report["modes"][mode]
            stock_rates = [t["measurements"][i]["tflops"] for t in before["trials"]]
            unlocked_rates = [t["measurements"][i]["tflops"] for t in after["trials"]]
            self.assertAlmostEqual(values["speed_ratio"], 2.0)
            self.assertAlmostEqual(values["percent_gain"], 100.0)
            self.assertEqual(values["before_trial_tflops"], stock_rates)
            self.assertEqual(values["after_trial_tflops"], unlocked_rates)
            self.assertEqual(values["before_trial_range_tflops"], [min(stock_rates), max(stock_rates)])
            self.assertEqual(values["after_trial_range_tflops"], [min(unlocked_rates), max(unlocked_rates)])
        self.assertEqual(before, self.before)
        self.assertEqual(after, self.after)

    def test_legacy_pair_is_explicitly_labeled_without_uuid_assurance(self):
        report = compare_tensors.compare(self.before, self.after)
        self.assertEqual(report["benchmark_schema_version"], 2)
        self.assertIn("physical UUID was not recorded", report["identity_validation"])

    def test_uuid_pair_accepts_changed_cuda_ordinal_but_same_physical_card(self):
        before = uuid_result("stock", ordinal=0)
        after = uuid_result("unlocked", factor=0.5, ordinal=1)
        report = compare_tensors.compare(before, after)
        self.assertEqual(report["benchmark_schema_version"], 3)
        self.assertEqual(report["gpu_settings"]["uuid"], before["selected_device"]["uuid"])
        self.assertIn("Matched physical GPU UUID", report["identity_validation"])
        self.assertEqual(report["modes"][MODES[0]]["speed_ratio"], 2.0)

    def test_uuid_pair_treats_nvidia_memory_total_as_optional_telemetry(self):
        before, after = uuid_result("stock"), uuid_result("unlocked")
        before["gpu_before"]["memory.total"] = "[N/A]"
        before["gpu_pre_measurement"]["memory.total"] = "0"
        before["trials"][0]["gpu_after"].pop("memory.total")
        after["gpu_before"]["memory.total"] = "23028"
        after["trials"][0]["gpu_after"]["memory.total"] = "24564"
        report = compare_tensors.compare(before, after)
        self.assertNotIn("memory.total", report["gpu_settings"])
        self.assertEqual(report["nvidia_memory_total"],
                         {"stock": {"raw": "[N/A]", "mib": None},
                          "unlocked": {"raw": "23028", "mib": 23028}})

    def test_uuid_pair_omits_invalid_total_text_from_portable_report(self):
        before, after = uuid_result("stock"), uuid_result("unlocked")
        before["gpu_before"]["memory.total"] = r"C:\Users\Private"
        after["gpu_before"]["memory.total"] = "9" * 100
        report = compare_tensors.compare(before, after)
        self.assertEqual(report["nvidia_memory_total"],
                         {"stock": {"raw": None, "mib": None},
                          "unlocked": {"raw": None, "mib": None}})

    def test_uuid_pair_still_refuses_changed_torch_capacity(self):
        before, after = uuid_result("stock"), uuid_result("unlocked")
        after["torch"]["gpu_properties"]["total_memory_bytes"] += 1024 ** 2
        with self.assertRaisesRegex(ValueError, "Comparison metadata mismatch: torch"):
            compare_tensors.compare(before, after)

    def test_legacy_pair_requires_stable_positive_nvidia_memory_total(self):
        for value in ("N/A", "0", "23028"):
            with self.subTest(value=value):
                after = copy.deepcopy(self.after)
                for snapshot in [after["gpu_before"], after["gpu_pre_measurement"],
                                 *(trial["gpu_after"] for trial in after["trials"])]:
                    snapshot["memory.total"] = value
                with self.assertRaises(ValueError):
                    compare_tensors.compare(self.before, after)

    def test_mixed_schema_pair_is_refused(self):
        with self.assertRaisesRegex(ValueError, "Cannot compare legacy"):
            compare_tensors.compare(self.before, uuid_result("unlocked"))
        with self.assertRaisesRegex(ValueError, "Cannot compare legacy"):
            compare_tensors.compare(uuid_result("stock"), self.after)

    def test_identical_model_cross_card_comparisons_are_refused(self):
        for bdf in ("00000000:01:00.0", "00000000:02:00.0"):
            with self.subTest(bdf=bdf), self.assertRaises(ValueError):
                compare_tensors.compare(uuid_result("stock"), uuid_result(
                    "unlocked", uuid="GPU-22222222-2222-4222-8222-222222222222", bdf=bdf))
        with self.assertRaises(ValueError):
            compare_tensors.compare(uuid_result("stock"), uuid_result("unlocked", bdf="00000000:02:00.0"))

    def test_uuid_required_and_stable_at_every_checkpoint(self):
        for checkpoint in ("gpu_before", "gpu_pre_measurement", "gpu_after", "props", "selected"):
            for value in (None, "GPU-22222222-2222-4222-8222-222222222222", "GPU-00000000-0000-0000-0000-000000000000"):
                before, after = uuid_result("stock"), uuid_result("unlocked")
                target = (after["torch"]["gpu_properties"] if checkpoint == "props" else
                          after["selected_device"] if checkpoint == "selected" else
                          after["trials"][0]["gpu_after"] if checkpoint == "gpu_after" else after[checkpoint])
                if value is None:
                    target.pop("uuid")
                else:
                    target["uuid"] = value
                with self.subTest(checkpoint=checkpoint, value=value), self.assertRaises(ValueError):
                    compare_tensors.compare(before, after)

    def test_selected_device_mapping_and_canonical_bdf_are_validated(self):
        for changes in ({"cuda_ordinal": 2}, {"cuda_ordinal": True}, {"pci_bus_id": "00000000:02:00.0"},
                        {"identity_method": "matched model name"}):
            before, after = uuid_result("stock"), uuid_result("unlocked")
            after["selected_device"].update(changes)
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                compare_tensors.compare(before, after)
        for bdf in ("0000:01:00.0", "00000000:01:20.0", "00000000:01:0A.0"):
            with self.subTest(bdf=bdf), self.assertRaises(ValueError):
                compare_tensors.compare(uuid_result("stock", bdf=bdf), uuid_result("unlocked", bdf=bdf))

    def test_rejects_driver_power_and_hardware_setting_drift_at_any_checkpoint(self):
        for checkpoint in ("gpu_before", "gpu_pre_measurement", "gpu_after"):
            for field, value in (("driver_version", "different-driver"), ("power.limit", "225.00"),
                                 ("clocks.max.sm", "1900"), ("pci.bus_id", "00000000:02:00.0")):
                with self.subTest(checkpoint=checkpoint, field=field):
                    def mutate(result, checkpoint=checkpoint, field=field, value=value):
                        target = result["trials"][1]["gpu_after"] if checkpoint == "gpu_after" else result[checkpoint]
                        target[field] = value
                    self.assert_rejected(mutate)

    def test_rejects_script_python_torch_and_cublas_identity_changes(self):
        changes = [lambda r: r["script"].update(sha256="0" * 64),
                   lambda r: r["python"]["executable"].update(sha256="1" * 64),
                   lambda r: r["python"].update(version="different-python"),
                   lambda r: r["torch"].update(version="different-torch"),
                   lambda r: r["torch"]["module"].update(sha256="2" * 64),
                   lambda r: r["torch"]["cublas_dlls"][0].update(sha256="3" * 64),
                   lambda r: r["torch"].update(build_configuration_sha256="4" * 64)]
        for index, mutate in enumerate(changes):
            with self.subTest(change=index):
                self.assert_rejected(mutate)

    def test_rejects_different_raw_environment_hashes_behind_same_redaction(self):
        self.before["environment"]["CUDA_VISIBLE_DEVICES"] = "<path redacted>"
        self.after["environment"]["CUDA_VISIBLE_DEVICES"] = "<path redacted>"
        self.before["environment_sha256"]["CUDA_VISIBLE_DEVICES"] = "a" * 64
        self.after["environment_sha256"]["CUDA_VISIBLE_DEVICES"] = "b" * 64
        with self.assertRaises(ValueError):
            compare_tensors.compare(self.before, self.after)

    def test_rejects_protocol_mismatch_and_missing_or_duplicate_modes_trials(self):
        changes = [lambda r: r["protocol"].update(n=256),
                   lambda r: r["protocol"].update(samples=4),
                   lambda r: r["trials"].pop(),
                   lambda r: r["trials"][1].update(trial=1),
                   lambda r: r["trials"][0]["measurements"].pop(),
                   lambda r: r["trials"][0]["measurements"][1].update(mode="fp32_ieee"),
                   lambda r: r["protocol"]["modes"].pop(),
                   lambda r: r["protocol"]["modes"].append("fp32_ieee")]
        for index, mutate in enumerate(changes):
            with self.subTest(change=index):
                self.assert_rejected(mutate)

    def test_rejects_missing_failed_or_incomplete_numerical_checks(self):
        changes = [lambda m: m.pop("correctness"), lambda m: m["correctness"].update(passed=False),
                   lambda m: m["correctness"].update(mismatches=1),
                   lambda m: m["correctness"].update(elements_checked=1),
                   lambda m: m["correctness"].update(method="only checked first element")]
        for index, change in enumerate(changes):
            with self.subTest(change=index):
                self.assert_rejected(lambda r, change=change: change(r["trials"][0]["measurements"][0]))

    def test_rejects_reduced_precision_or_wrong_dtype(self):
        for field in ("allow_fp16_reduced_precision_reduction", "allow_bf16_reduced_precision_reduction",
                      "allow_fp16_accumulation"):
            with self.subTest(field=field):
                self.assert_rejected(lambda r, field=field: r["trials"][0]["measurements"][1]["precision_settings"].update({field: True}))
        self.assert_rejected(lambda r: r["trials"][0]["measurements"][1].update(output_dtype="float16"))
        self.assert_rejected(lambda r: r["trials"][0]["measurements"][3]["precision_settings"].update(fp32_precision="ieee"))

    def test_rejects_nonfinite_zero_short_or_inconsistent_event_statistics(self):
        changes = [lambda m: m["sample_ms"].__setitem__(0, float("nan")),
                   lambda m: m["sample_ms"].__setitem__(0, float("inf")),
                   lambda m: m["sample_ms"].__setitem__(0, 0), lambda m: m["sample_ms"].pop(),
                   lambda m: m.update(median_ms=m["median_ms"] + 1),
                   lambda m: m.update(min_ms=0), lambda m: m.update(max_ms=m["max_ms"] + 1),
                   lambda m: m.update(tflops=m["tflops"] * 2)]
        for index, change in enumerate(changes):
            with self.subTest(change=index):
                self.assert_rejected(lambda r, change=change: change(r["trials"][0]["measurements"][0]))

    def test_rejects_invalid_protocol_bounds_or_incomplete_result(self):
        for field, value in (("n", 0), ("samples", 0), ("trials", 0),
                             ("warmup_seconds", 0), ("warmup_seconds", float("inf"))):
            with self.subTest(field=field, value=value):
                self.assert_rejected(lambda r, field=field, value=value: r["protocol"].update({field: value}))
        self.assert_rejected(lambda r: r.update(status="failed"))

    def test_rejects_matched_protocols_outside_runner_bounds(self):
        # Keep both protocols and derived measurements internally consistent so
        # rejection must depend on bounds, rather than a before/after mismatch.
        for field, value in (("n", 64), ("n", 16384), ("samples", 1001),
                             ("trials", 21), ("warmup_seconds", 0), ("warmup_seconds", 61)):
            with self.subTest(field=field, value=value):
                before, after = copy.deepcopy(self.before), copy.deepcopy(self.after)
                for result in (before, after):
                    result["protocol"][field] = value
                    if field == "trials":
                        result["trials"] = [copy.deepcopy(result["trials"][0]) for _ in range(value)]
                        for index, trial in enumerate(result["trials"], 1):
                            trial["trial"] = index
                    for trial in result["trials"]:
                        for measurement in trial["measurements"]:
                            if field != "trials":
                                measurement[field] = value
                            if field == "n":
                                measurement["correctness"]["elements_checked"] = value ** 2
                            if field == "samples":
                                measurement["sample_ms"] = [measurement["median_ms"]] * value
                                measurement["min_ms"] = measurement["max_ms"] = measurement["median_ms"]
                            measurement["tflops"] = 2 * measurement["n"] ** 3 / (measurement["median_ms"] * 1e9)
                    for i, mode in enumerate(MODES):
                        result["summary"][mode]["median_tflops"] = statistics.median(
                            trial["measurements"][i]["tflops"] for trial in result["trials"])
                with self.assertRaises(ValueError):
                    compare_tensors.compare(before, after)

    def test_rejects_summary_not_derived_from_trial_timings(self):
        self.assert_rejected(lambda r: r["summary"]["fp16_fp32_accumulate"].update(median_tflops=1.0))

    def test_dynamic_boost_telemetry_changes_are_not_settings_drift(self):
        self.after["trials"][0]["gpu_after"].update({"clocks.sm": "1200", "power.draw": "175", "temperature.gpu": "55"})
        self.assertEqual(compare_tensors.compare(self.before, self.after)["status"], "comparison_complete")

    def test_load_result_rejects_duplicate_json_keys_and_nonfinite_tokens(self):
        path = self.root / "invalid.json"
        for raw in ('{"schema_version":2,"schema_version":2}', '{"value":NaN}', '{"value":Infinity}', '{"value":-Infinity}'):
            with self.subTest(raw=raw):
                path.write_text(raw, encoding="utf-8")
                with self.assertRaises(ValueError):
                    compare_tensors.load_result(path)

    def test_cli_writes_new_report_and_never_overwrites_existing_output(self):
        before_path, after_path, output = (self.root / name for name in ("before.json", "after.json", "comparison.json"))
        before_path.write_text(json.dumps(self.before, allow_nan=False), encoding="utf-8")
        after_path.write_text(json.dumps(self.after, allow_nan=False), encoding="utf-8")
        command = ["--before", str(before_path), "--after", str(after_path), "--output", str(output)]
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(compare_tensors.main(command), 0)
        original = output.read_bytes()
        self.assertEqual(json.loads(original)["data_kind"], "synthetic")
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertNotEqual(compare_tensors.main(command), 0)
        self.assertEqual(output.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
