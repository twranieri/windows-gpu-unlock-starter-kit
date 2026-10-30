"""Control-flow and arithmetic tests with fake CUDA/Torch; no GPU work."""

from contextlib import nullcontext, redirect_stderr, redirect_stdout
import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).resolve().parents[1] / "benchmark-tensors.py"
SPEC = importlib.util.spec_from_file_location("benchmark_tensors", SCRIPT)
B = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(B)


def gpu(**changes):
    values = ["NVIDIA Synthetic GPU", "00000000:01:00.0", "1.00", "synthetic-vbios", "24576",
              "350.00", "350.00", "2100", "9751", "0", "100", "35", "25", "210"]
    result = dict(zip(B.GPU_FIELDS, values))
    result.update(changes)
    return result


class Tensor:
    def __init__(self, dtype):
        self.dtype = dtype
        self.device = SimpleNamespace(type="cuda")

    def __ne__(self, value):
        return ("complete-output-comparison", value)


class Event:
    def record(self):
        pass

    def synchronize(self):
        pass

    def elapsed_time(self, other):
        return 1.0


def fake_torch():
    def mm(a, b, **kwargs):
        """Fake mm supports out_dtype; performs no arithmetic."""
        calls.append(kwargs)
    calls = []
    props = SimpleNamespace(name=gpu()["name"], major=8, minor=6,
                            total_memory=24576 * 1024 ** 2, multi_processor_count=82)
    flags = SimpleNamespace(fp32_precision="ieee", allow_fp16_reduced_precision_reduction=False,
                            allow_bf16_reduced_precision_reduction=False, allow_fp16_accumulation=False)
    cuda = SimpleNamespace(is_available=lambda: True, device_count=lambda: 1,
                           get_device_name=lambda index: props.name, get_device_properties=lambda index: props,
                           is_bf16_supported=lambda: True, synchronize=lambda: None,
                           Event=lambda **kwargs: Event())
    return SimpleNamespace(version=SimpleNamespace(cuda="SYNTHETIC", git_version="synthetic"),
                           cuda=cuda, backends=SimpleNamespace(cuda=SimpleNamespace(matmul=flags)),
                           float32="float32", float16="float16", bfloat16="bfloat16", mm=mm,
                           ones=lambda shape, dtype, device: Tensor(dtype), ones_like=lambda a: Tensor(a.dtype),
                           empty=lambda shape, dtype, device: Tensor(dtype),
                           count_nonzero=lambda value: SimpleNamespace(item=lambda: 0),
                           inference_mode=lambda: nullcontext(), calls=calls, props=props)


class TensorBenchmarkTests(unittest.TestCase):
    def quiet_main(self, argv):
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            return B.main(argv)

    def test_help_does_not_import_torch_or_query_gpu(self):
        with patch.object(B.importlib, "import_module") as load, patch.object(B, "gpu_snapshot") as query:
            with self.assertRaises(SystemExit) as done:
                self.quiet_main(["--help"])
            self.assertEqual(done.exception.code, 0)
            load.assert_not_called()
            query.assert_not_called()

    def test_existing_output_is_preserved_before_gpu_access(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "result.json"
            output.write_text("keep me", encoding="utf-8")
            with patch.object(B, "gpu_snapshot") as query, patch.object(B.importlib, "import_module") as load:
                with self.assertRaises(SystemExit):
                    self.quiet_main(["--label", "stock", "--output", str(output)])
            self.assertEqual(output.read_text(), "keep me")
            query.assert_not_called()
            load.assert_not_called()

    def test_empty_multiple_and_incomplete_gpu_output_rejected(self):
        line = ",".join(gpu()[key] for key in B.GPU_FIELDS)
        for output in ("", line + "\n" + line, "too,few,columns"):
            with self.subTest(output=output), patch.object(B.subprocess, "run", return_value=SimpleNamespace(stdout=output)):
                with self.assertRaises(B.BenchmarkError):
                    B.gpu_snapshot()

    def test_any_single_valid_nvidia_identity_is_accepted(self):
        line = ",".join(gpu()[key] for key in B.GPU_FIELDS)
        with patch.object(B.subprocess, "run", return_value=SimpleNamespace(stdout=line)):
            self.assertEqual(B.gpu_snapshot()["name"], "NVIDIA Synthetic GPU")

    def test_nonfinite_gpu_telemetry_rejected(self):
        data = gpu(**{"power.draw": "nan"})
        line = ",".join(data[key] for key in B.GPU_FIELDS)
        with patch.object(B.subprocess, "run", return_value=SimpleNamespace(stdout=line)):
            with self.assertRaises(B.BenchmarkError):
                B.gpu_snapshot()

    def test_idle_requires_three_consecutive_samples(self):
        readings = [gpu(), gpu(**{"memory.used": "18000"}), gpu(), gpu(), gpu()]
        with patch.object(B, "gpu_snapshot", side_effect=readings) as query, patch.object(B.time, "sleep"):
            B.wait_for_idle()
            self.assertEqual(query.call_count, 5)

    def test_busy_gpu_fails_before_torch_import(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "busy.json"
            with patch.object(B, "gpu_snapshot", return_value=gpu(**{"memory.used": "18000"})), \
                    patch.object(B.time, "monotonic", side_effect=[0, 31]), \
                    patch.object(B.importlib, "import_module") as load:
                self.assertEqual(self.quiet_main(["--label", "stock", "--output", str(output)]), 1)
            self.assertEqual(json.loads(output.read_text())["status"], "failed")
            load.assert_not_called()

    def test_torch_gpu_mismatch_and_missing_capabilities_fail(self):
        for change in ("name", "memory", "old_gpu", "missing_flag", "missing_out_dtype"):
            with self.subTest(change=change):
                torch = fake_torch()
                if change == "name":
                    torch.cuda.get_device_name = lambda index: "different GPU"
                elif change == "memory":
                    torch.props.total_memory = 12 * 1024 ** 3
                elif change == "old_gpu":
                    torch.props.major = 7
                elif change == "missing_flag":
                    del torch.backends.cuda.matmul.allow_fp16_accumulation
                else:
                    torch.mm = lambda *args, **kwargs: None
                with self.assertRaises(B.BenchmarkError):
                    B.validate_torch(torch, gpu())

    def test_measurement_uses_fp32_out_dtype_and_checks_complete_output(self):
        args = SimpleNamespace(n=4096, warmup_seconds=2, samples=30)
        for mode in B.MODES:
            with self.subTest(mode=mode[0]):
                torch = fake_torch()
                checked = Mock(return_value=SimpleNamespace(item=lambda: 0))
                torch.count_nonzero = checked
                with patch.object(B.time, "perf_counter", side_effect=[0, 2]):
                    result = B.measure(torch, *mode, args)
                self.assertEqual(len(result["sample_ms"]), 30)
                self.assertEqual(result["correctness"]["elements_checked"], 4096 ** 2)
                self.assertAlmostEqual(result["tflops"], 2 * 4096 ** 3 / 1e9)
                checked.assert_called_once_with(("complete-output-comparison", 4096))
                for call in torch.calls:
                    self.assertEqual(call["out"].dtype, "float32")
                    self.assertEqual("out_dtype" in call, mode[1] != "float32")

    def test_correctness_failure_and_invalid_event_timing_rejected(self):
        args = SimpleNamespace(n=4096, warmup_seconds=2, samples=1)
        torch = fake_torch()
        torch.count_nonzero = lambda value: SimpleNamespace(item=lambda: 1)
        with patch.object(B.time, "perf_counter", side_effect=[0, 2]), self.assertRaises(B.BenchmarkError):
            B.measure(torch, *B.MODES[0], args)
        for timing in (float("nan"), 1e-320, 1e308):
            with self.subTest(timing=timing):
                torch = fake_torch()
                with patch.object(B.time, "perf_counter", side_effect=[0, 2]), \
                        patch.object(Event, "elapsed_time", return_value=timing), self.assertRaises(B.BenchmarkError):
                    B.measure(torch, *B.MODES[0], args)

    def test_settings_change_after_import_stops_before_first_measurement(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "changed.json"
            torch = fake_torch()
            with patch.object(B, "wait_for_idle", side_effect=[gpu(), gpu(**{"power.limit": "400"})]), \
                    patch.object(B.importlib, "import_module", return_value=torch), \
                    patch.object(B, "torch_metadata", return_value={"synthetic": True}), \
                    patch.object(B, "measure") as measure:
                self.assertEqual(self.quiet_main(["--label", "unlocked", "--output", str(output)]), 1)
            measure.assert_not_called()
            self.assertIn("before the first measurement", json.loads(output.read_text())["error"])

    def test_file_identity_does_not_publish_parent_path(self):
        with tempfile.TemporaryDirectory(prefix="private-user-") as directory:
            path = Path(directory) / "sample.dll"
            path.write_bytes(b"synthetic")
            identity = B.file_identity(path)
            self.assertEqual(identity["name"], "sample.dll")
            self.assertNotIn(directory, json.dumps(identity))
            self.assertEqual(len(identity["sha256"]), 64)

    def test_complete_default_protocol_control_flow_with_fake_cuda(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "synthetic-result.json"
            torch = fake_torch()
            with patch.dict(B.os.environ, {}, clear=True), \
                    patch.object(B, "gpu_snapshot", return_value=gpu()) as snapshots, \
                    patch.object(B.time, "sleep"), \
                    patch.object(B.time, "perf_counter", side_effect=[0, 2] * 12), \
                    patch.object(B.importlib, "import_module", return_value=torch), \
                    patch.object(B, "torch_metadata", return_value={"fixture": "SYNTHETIC; no real GPU"}):
                self.assertEqual(self.quiet_main(["--label", "stock", "--output", str(output)]), 0)
            result = json.loads(output.read_text())
            self.assertEqual(result["status"], "complete")
            self.assertEqual(result["label"], "stock")
            self.assertEqual(result["protocol"], {"n": 4096, "warmup_seconds": 2.0,
                                                  "samples": 30, "trials": 3,
                                                  "modes": [mode[0] for mode in B.MODES]})
            self.assertEqual(snapshots.call_count, 9)  # 3 idle + 3 premeasure + 3 post-trial.
            self.assertEqual(len(result["trials"]), 3)
            self.assertEqual(sum(len(trial["measurements"]) for trial in result["trials"]), 12)
            self.assertEqual(set(result["summary"]), {mode[0] for mode in B.MODES})
            self.assertEqual(set(result["environment_sha256"]), set(B.ENVIRONMENT_FIELDS))

    def test_external_override_stops_before_gpu_access_and_redacts_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "override.json"
            with patch.dict(B.os.environ, {"NVIDIA_TF32_OVERRIDE": r"C:\Users\Private\override"}), \
                    patch.object(B, "gpu_snapshot") as query, patch.object(B.importlib, "import_module") as load:
                self.assertEqual(self.quiet_main(["--label", "stock", "--output", str(output)]), 1)
            raw = output.read_text()
            self.assertNotIn("Private", raw)
            self.assertEqual(json.loads(raw)["environment"]["NVIDIA_TF32_OVERRIDE"], "<path redacted>")
            query.assert_not_called()
            load.assert_not_called()

    def test_mocked_benchmark_outputs_round_trip_through_comparator(self):
        comparator_spec = importlib.util.spec_from_file_location(
            "tensor_roundtrip_comparator", SCRIPT.with_name("compare-tensors.py"))
        comparator = importlib.util.module_from_spec(comparator_spec)
        comparator_spec.loader.exec_module(comparator)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            module = root / "torch" / "__init__.py"
            module.parent.mkdir()
            module.write_text("# synthetic Torch module fixture", encoding="utf-8")
            libraries = module.parent / "lib"
            libraries.mkdir()
            for name in ("cublas64_13.dll", "cublasLt64_13.dll"):
                (libraries / name).write_bytes(b"synthetic fixture; never loaded")
            torch = fake_torch()
            torch.__file__ = str(module)
            torch.__version__ = "synthetic-test-only"
            torch.__config__ = SimpleNamespace(show=lambda: "synthetic build configuration")
            outputs = []
            for label in ("stock", "unlocked"):
                output = root / (label + ".json")
                with patch.dict(B.os.environ, {}, clear=True), \
                        patch.object(B, "gpu_snapshot", return_value=gpu()), \
                        patch.object(B.time, "sleep"), \
                        patch.object(B.time, "perf_counter", side_effect=[0, 2] * 12), \
                        patch.object(B.importlib, "import_module", return_value=torch):
                    self.assertEqual(self.quiet_main(["--label", label, "--output", str(output)]), 0)
                result = json.loads(output.read_text())
                result["data_kind"] = "synthetic"
                outputs.append(result)
            report = comparator.compare(*outputs)
            self.assertEqual(report["status"], "comparison_complete")
            self.assertEqual(report["data_kind"], "synthetic")
            self.assertEqual(len(report["modes"]), 4)
            for mode in report["modes"].values():
                self.assertAlmostEqual(mode["speed_ratio"], 1.0)
                self.assertAlmostEqual(mode["percent_gain"], 0.0)


if __name__ == "__main__":
    unittest.main()
