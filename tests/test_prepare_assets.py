"""Offline contract checks using synthetic data; never fetch or execute generators."""
import hashlib
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
import urllib.request


SCRIPT = Path(__file__).resolve().parents[1] / "prepare-assets.py"
SPEC = importlib.util.spec_from_file_location("starter_kit_prepare_assets", SCRIPT)
assets = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = assets
SPEC.loader.exec_module(assets)


class PrepareAssetsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def write(self, relative, data):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def archive(self, extra=(), omit=(), duplicate=False, oversize=False):
        path = self.root / "source.tar.gz"
        with tarfile.open(path, "w:gz") as archive:
            for name in assets.REQUIRED_SOURCE_MEMBERS:
                if name in omit:
                    continue
                data = ("synthetic source: " + name).encode()
                if oversize and name == assets.REQUIRED_SOURCE_MEMBERS[0]:
                    data = b"\0" * (16 * 1024 * 1024 + 1)
                member = tarfile.TarInfo("legal-source-root/" + name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
                if duplicate and name == assets.REQUIRED_SOURCE_MEMBERS[0]:
                    archive.addfile(member, io.BytesIO(data))
            for name, kind in extra:
                member = tarfile.TarInfo(name)
                if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                    member.type = kind
                    member.linkname = "../../outside"
                    archive.addfile(member)
                else:
                    data = b"must not be extracted"
                    member.size = len(data)
                    archive.addfile(member, io.BytesIO(data))
        return path

    def test_digest_and_verification_reject_corruption_and_wrong_size(self):
        path = self.write("data.bin", b"known synthetic input")
        expected = hashlib.sha256(path.read_bytes()).hexdigest()
        self.assertEqual(assets.digest(path), expected)
        assets.verify_file(path, expected, path.stat().st_size)
        with self.assertRaises(ValueError):
            assets.verify_file(path, "0" * 64)
        with self.assertRaises(ValueError):
            assets.verify_file(path, expected, path.stat().st_size + 1)

    def test_extraction_keeps_only_required_source_members(self):
        archive = self.archive(extra=[("legal-source-root/unneeded.txt", tarfile.REGTYPE)])
        output = self.root / "extracted"
        assets.extract_sources(archive, output)
        expected = {Path(name) for name in assets.REQUIRED_SOURCE_MEMBERS}
        actual = {p.relative_to(output) for p in output.rglob("*") if p.is_file()}
        self.assertEqual(actual, expected)
        for name in assets.REQUIRED_SOURCE_MEMBERS:
            self.assertEqual((output / name).read_bytes(), ("synthetic source: " + name).encode())

    def test_extraction_rejects_traversal_absolute_and_backslash_names(self):
        for name in ("../outside", "legal-source-root/../outside", "/absolute/outside",
                     "C:/outside", "legal-source-root\\outside"):
            with self.subTest(name=name):
                archive = self.archive(extra=[(name, tarfile.REGTYPE)])
                with self.assertRaises(ValueError):
                    assets.extract_sources(archive, self.root / "extracted")
        self.assertFalse((self.root.parent / "outside").exists())

    def test_extraction_rejects_links_even_when_not_required(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
            with self.subTest(kind=kind):
                archive = self.archive(extra=[("legal-source-root/unneeded-link", kind)])
                with self.assertRaises(ValueError):
                    assets.extract_sources(archive, self.root / "extracted")

    def test_extraction_rejects_duplicate_and_missing_required_members(self):
        with self.assertRaises(ValueError):
            assets.extract_sources(self.archive(duplicate=True), self.root / "duplicate")
        with self.assertRaises(ValueError):
            assets.extract_sources(self.archive(omit=[assets.REQUIRED_SOURCE_MEMBERS[0]]),
                                   self.root / "missing")

    def test_extraction_rejects_required_source_above_size_limit(self):
        with self.assertRaises(ValueError):
            assets.extract_sources(self.archive(oversize=True), self.root / "oversize")

    def test_native_package_copy_verifies_bytes_and_rejects_collision(self):
        source = self.write("nvidia-utils.pkg.tar.zst", b"synthetic package bytes")
        work = self.root / "work"
        work.mkdir()
        result = Path(assets.native_package_copy(source, work))
        self.assertEqual(result, work / "verified-nvidia-utils.pkg.tar.zstd")
        self.assertEqual(result.read_bytes(), source.read_bytes())
        self.assertEqual(Path(assets.native_package_copy(source, work)), result)
        # Remove only the synthetic test link before creating a distinct bad file.
        result.unlink()
        result.write_bytes(b"unrelated existing file")
        with self.assertRaises(ValueError):
            assets.native_package_copy(source, work)
        self.assertEqual(result.read_bytes(), b"unrelated existing file")
        self.assertEqual(source.read_bytes(), b"synthetic package bytes")

    def test_output_state_rejects_unknown_or_nonmatching_assets(self):
        output = self.root / "assets"
        payload = b"synthetic generated asset"
        specs = {"example.bin": (len(payload), hashlib.sha256(payload).hexdigest())}
        self.assertEqual(assets.output_state(output, specs=specs), "absent")
        output.mkdir()
        self.assertEqual(assets.output_state(output, specs=specs), "empty")
        (output / "example.bin").write_bytes(payload)
        license_data, notice_data = b"synthetic license", b"synthetic notice"
        (output / "NVIDIA-LICENSE").write_bytes(license_data)
        (output / "NOTICE.md").write_bytes(notice_data)
        with mock.patch.object(assets, "LICENSE_SHA", hashlib.sha256(license_data).hexdigest()), \
             mock.patch.object(assets, "NOTICE_SHA", hashlib.sha256(notice_data).hexdigest()):
            self.assertEqual(assets.output_state(output, specs=specs), "valid")
            (output / "unknown.bin").write_bytes(b"unknown")
            with self.assertRaises(ValueError):
                assets.output_state(output, specs=specs)
            (output / "unknown.bin").unlink()
            (output / "example.bin").write_bytes(b"corrupt")
            with self.assertRaises(ValueError):
                assets.output_state(output, specs=specs)

    def test_default_plan_has_no_filesystem_generation_process_or_network_effects(self):
        fw, win, work = (self.root / name for name in ("firmware-repo", "windows-repo", "work"))
        parser = assets.build_parser()
        args = parser.parse_args(["--firmware-repo", str(fw), "--windows-repo", str(win),
                                  "--work-dir", str(work)])
        self.assertFalse(args.execute)
        self.assertFalse(args.download)
        with mock.patch.object(assets, "verify_repositories") as verify_repositories, \
             mock.patch.object(assets, "validate_work_dir") as validate_work_dir, \
             mock.patch.object(subprocess, "run", side_effect=AssertionError("process forbidden")), \
             mock.patch.object(subprocess, "Popen", side_effect=AssertionError("process forbidden")), \
             mock.patch.object(urllib.request, "urlopen", side_effect=AssertionError("network forbidden")), \
             mock.patch.object(urllib.request.OpenerDirector, "open", side_effect=AssertionError("network forbidden")):
            assets.run(args)
            verify_repositories.assert_called_once()
            validate_work_dir.assert_called_once()
        self.assertEqual(list(self.root.iterdir()), [])

    def test_download_requires_explicit_execution(self):
        args = assets.build_parser().parse_args([
            "--firmware-repo", str(self.root / "firmware-repo"),
            "--windows-repo", str(self.root / "windows-repo"),
            "--work-dir", str(self.root / "work"), "--download"])
        with mock.patch.object(assets, "verify_repositories"), \
             mock.patch.object(assets, "validate_work_dir"), \
             mock.patch.object(subprocess, "Popen", side_effect=AssertionError("process forbidden")), \
             mock.patch.object(urllib.request.OpenerDirector, "open", side_effect=AssertionError("network forbidden")):
            with self.assertRaises(ValueError):
                assets.run(args)
        self.assertEqual(list(self.root.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
