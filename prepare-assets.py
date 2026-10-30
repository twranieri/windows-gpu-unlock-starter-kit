"""Plan or locally generate pinned firmware assets. No GPU, driver or kernel install.

GPL-2.0-only. This adapter invokes the unchanged pinned upstream generators.
Firmware is obtained locally and is not covered by this adapter's license.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tarfile
import tempfile

FIRMWARE_COMMIT = "0ebdb1c6308b6a2072be5bf04513472942541956"
WINDOWS_COMMIT = "75071aa134616c3d65ad315e0cf2810bf34b191b"
INPUT_SPECS = {
    "NVIDIA-kernel-module-source-610.43.03.tar.xz": "7e118923c7a23edc36114d63273a46e3e04e9af98695a42203e7ac2dfe9fc1dc",
    "nvidia-utils-610.43.03-1-x86_64_v3.pkg.tar.zst": "e17e7c92eeffa178b0fe1f40eb17a47095f8fc3ce4a77bf115cf5bd5a4df86e9",
}
ASSET_SPECS = {
    "booter_load_ga102.bin": (61256, "056cbc064a888f80717726c54d7f64fcd68044d123870c95a74f37f4975dcaa4"),
    "v67-ga102-610.43.03.bin": (64000, "2a0aa1f86d0b6afff5214d641d87d46dc98ef06ed908ff05d0ddbad5ffb7e197"),
    "gsp_ga10x.bin": (84277400, "572373620a37418f24dc16b5031c39338778c3257e48e8408de9a57291b24f3a"),
    "gsp_boot_ga102.bin": (24576, "3df651acb174fd5f5561a1996965b192f50c5d763168446ed0d4ead19d895768"),
    "gsp_boot_desc_ga102.bin": (84, "cc5a3fc1f4c47f2fe107b1b68f0176d8a448e6dec84b575e5560ccef5262bf15"),
}
LICENSE_SHA = "c692fb14ad4f499c6aee1b9e144e6905148c420e6225b17cb2937366c1e507ad"
NOTICE_SHA = "56c8d56ca47d705de6c68a62630d42115040ab47f94fb93ca37ba74a428cb875"
FIRMWARE_FILES = {
    "firmware/fetch_artifacts.py": "5655e3e497b16e17e3a9c307cf733ef2207cd7a3d0be5a9d0b2c532d66abe76b",
    "firmware/generate_v67.py": "4b41e5199c6b9968d134c43a5a42d8127d094eebfe9dca78204be4d7c8237fd0",
    "firmware/extract_boot_assets.py": "7acc5f488cd35700c499bc942a07e7d0d9b0822b1e2ad040cd34bacf99fa5986",
    "firmware/artifacts-610.43.03.json": "766be4acb90a9ce2448adc3eb4cead81ea142e96b614f30bde1600b74fe5a4bc",
    "firmware/NOTICE.md": NOTICE_SHA,
}
WINDOWS_FILES = {name: "644849b375f7c37f0a46118aac1d55c8c1428b0c29cc017fcaa94b462cc924b0"
                 for name in ("unlock/assets.json", "internal-boot/unlock/assets.json")}
REQUIRED_SOURCE_MEMBERS = (
    "src/nvidia/generated/g_bindata_kgspGetBinArchiveBooterLoadUcode_GA102.c",
    "src/nvidia/generated/g_bindata_kgspGetBinArchiveGspRmBoot_GA102.c",
)
MAX_SOURCE_BYTES = 16 * 1024 * 1024


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def regular(path):
    path = Path(path)
    reparse = bool(path.exists() and getattr(path.stat(), "st_file_attributes", 0) & 0x400)
    if path.is_symlink() or not path.is_file() or reparse:
        raise ValueError("Not an ordinary file: " + str(path))
    return path


def verify_file(path, expected_sha, expected_size=None):
    path = regular(path)
    if expected_size is not None and path.stat().st_size != expected_size:
        raise ValueError("Size mismatch: " + path.name)
    if digest(path) != expected_sha:
        raise ValueError("SHA-256 mismatch: " + path.name)


def git_head(repo):
    git = repo / ".git"
    if git.is_file():
        line = git.read_text().strip()
        if not line.startswith("gitdir: "):
            raise ValueError("Invalid .git file")
        git = (repo / line[8:]).resolve()
    head = (git / "HEAD").read_text().strip()
    if head.startswith("ref: "):
        ref = head[5:]
        if not ref.startswith("refs/") or ".." in ref.split("/"):
            raise ValueError("Invalid Git HEAD reference")
        common = git
        if (git / "commondir").is_file():
            common = (git / (git / "commondir").read_text().strip()).resolve()
        for base in (git, common):
            if (base / ref).is_file():
                return (base / ref).read_text().strip()
        for line in (common / "packed-refs").read_text().splitlines():
            if line.endswith(" " + ref):
                return line.split()[0]
        raise ValueError("Cannot resolve Git HEAD")
    return head


def verify_repositories(firmware, windows):
    # Pure file reads: even plan mode never starts a process. Canonical LF hashes
    # allow ordinary Git autocrlf checkout while rejecting changed generator code.
    for repo, commit, files in ((firmware, FIRMWARE_COMMIT, FIRMWARE_FILES),
                                (windows, WINDOWS_COMMIT, WINDOWS_FILES)):
        if git_head(repo) != commit:
            raise ValueError("Repository HEAD is not the required pin: " + str(repo))
        for relative, expected in files.items():
            path = regular(repo / relative)
            if not path.resolve().is_relative_to(repo.resolve()):
                raise ValueError("Source file escapes its repository")
            actual = hashlib.sha256(path.read_bytes().replace(b"\r\n", b"\n")).hexdigest()
            if actual != expected:
                raise ValueError("Tracked source/spec changed: " + relative)


def validate_work_dir(work):
    if os.name != "nt":
        raise ValueError("Asset execution requires native Windows and local NTFS storage")
    existing = work
    while not existing.exists():
        existing = existing.parent
    if existing.is_symlink():
        raise ValueError("Work directory cannot use a reparse point")
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    volume = ctypes.create_unicode_buffer(32768)
    if not kernel.GetVolumePathNameW(str(existing), volume, len(volume)):
        raise ValueError("Cannot identify work volume")
    fs = ctypes.create_unicode_buffer(64)
    if not kernel.GetVolumeInformationW(volume.value, None, 0, None, None, None, fs, len(fs)) or fs.value.upper() != "NTFS":
        raise ValueError("Work directory must be on NTFS")
    if kernel.GetDriveTypeW(volume.value) != 3:
        raise ValueError("Work directory must be on a fixed local volume")
    # StorageDeviceProperty, no access rights requested and no device writes.
    kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32,
                                  ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
    kernel.CreateFileW.restype = ctypes.c_void_p
    kernel.DeviceIoControl.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32,
                                      ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p]
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    handle = kernel.CreateFileW("\\\\.\\" + volume.value.rstrip("\\"), 0, 7, None, 3, 0, None)
    if handle in (None, ctypes.c_void_p(-1).value):
        raise ValueError("Cannot verify that work storage is not USB")
    try:
        query, data, count = ctypes.create_string_buffer(12), ctypes.create_string_buffer(4096), ctypes.c_uint32()
        if not kernel.DeviceIoControl(handle, 0x2D1400, query, 12, data, len(data), ctypes.byref(count), None) or count.value < 32:
            raise ValueError("Cannot verify work storage bus type")
        if int.from_bytes(data.raw[28:32], "little") in (0, 7):
            raise ValueError("Unknown/USB work storage refused")
    finally:
        kernel.CloseHandle(handle)


def output_state(output, specs=ASSET_SPECS):
    if output.is_symlink():
        raise ValueError("Output cannot be a link")
    if not output.exists():
        return "absent"
    if not output.is_dir():
        raise ValueError("Output is not a directory")
    names = {p.name for p in output.iterdir()}
    if not names:
        return "empty"
    if names != set(specs) | {"NVIDIA-LICENSE", "NOTICE.md"}:
        raise ValueError("Nonempty output has unknown or missing files; nothing overwritten")
    for name, (size, sha) in specs.items():
        verify_file(output / name, sha, size)
    verify_file(output / "NVIDIA-LICENSE", LICENSE_SHA)
    notice = regular(output / "NOTICE.md").read_bytes().replace(b"\r\n", b"\n")
    if hashlib.sha256(notice).hexdigest() != NOTICE_SHA:
        raise ValueError("NOTICE mismatch")
    return "valid"


def native_package_copy(package, work_dir):
    expected = digest(regular(package))
    target = work_dir / "verified-nvidia-utils.pkg.tar.zstd"
    if target.exists() or target.is_symlink():
        verify_file(target, expected, package.stat().st_size)
        return target
    work_dir.mkdir(parents=True, exist_ok=True)
    try:
        os.link(package, target)
    except OSError:
        # Exclusive destination creation never overwrites a competing file.
        with package.open("rb") as source, target.open("xb") as destination:
            shutil.copyfileobj(source, destination)
    verify_file(target, expected, package.stat().st_size)
    return target


def extract_sources(archive_path, destination):
    found = {}
    with tarfile.open(archive_path, "r:*") as archive:
        for member in archive:
            path = PurePosixPath(member.name)
            if "\\" in member.name or path.is_absolute() or ".." in path.parts or ":" in member.name or member.issym() or member.islnk():
                raise ValueError("Unsafe archive member")
            matches = [name for name in REQUIRED_SOURCE_MEMBERS
                       if member.name == name or member.name.endswith("/" + name)]
            for name in matches:
                if name in found or not member.isfile() or not (0 < member.size <= MAX_SOURCE_BYTES):
                    raise ValueError("Missing/duplicate/nonregular/oversized source member")
                stream = archive.extractfile(member)
                if stream is None:
                    raise ValueError("Unreadable source member")
                with stream:
                    data = stream.read(MAX_SOURCE_BYTES + 1)
                if len(data) != member.size:
                    raise ValueError("Truncated/oversized source member")
                found[name] = data
    if set(found) != set(REQUIRED_SOURCE_MEMBERS):
        raise ValueError("Missing required source member")
    if destination.exists():
        raise ValueError("Extraction destination already exists")
    destination.mkdir(parents=True)
    for relative, data in found.items():
        path = destination / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("xb") as output:
            output.write(data)
    return destination


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--firmware-repo", required=True, type=Path)
    parser.add_argument("--windows-repo", required=True, type=Path)
    parser.add_argument("--work-dir", required=True, type=Path)
    parser.add_argument("--output", type=Path, help="Default: WINDOWS_REPO/assets")
    parser.add_argument("--download", action="store_true", help="With --execute, explicitly download pinned inputs")
    parser.add_argument("--execute", action="store_true", help="Generate locally; default is a plan with no writes/processes")
    return parser


def run(args):
    if sys.version_info < (3, 14):
        raise ValueError("Python 3.14 or newer is required")
    if args.download and not args.execute:
        raise ValueError("--download requires --execute")
    firmware, windows, work = (p.absolute() for p in (args.firmware_repo, args.windows_repo, args.work_dir))
    output = (args.output or windows / "assets").absolute()
    verify_repositories(firmware, windows)
    validate_work_dir(work)
    state = output_state(output)
    report = {"mode": "execute" if args.execute else "plan", "output": str(output),
              "output_state": state, "download_requested": args.download,
              "firmware_commit": FIRMWARE_COMMIT, "windows_commit": WINDOWS_COMMIT,
              "actions": ["verify two pinned input hashes", "run unchanged upstream generators",
                          "verify five assets and preserve license/notice", "publish a new complete directory"]}
    if state == "valid":
        report["status"] = "already_valid_no_op"
        return report
    if not args.execute:
        report["status"] = "plan_only_no_processes_or_writes"
        return report
    work.mkdir(parents=True, exist_ok=True)
    inputs = work / "inputs"
    if args.download:
        subprocess.run([sys.executable, "-I", str(firmware / "firmware/fetch_artifacts.py"), str(inputs)], check=True)
    for name, sha in INPUT_SPECS.items():
        verify_file(inputs / name, sha)
    alias = native_package_copy(inputs / next(n for n in INPUT_SPECS if n.endswith(".zst")), work)
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".gpu-unlock-assets-", dir=output.parent))
    sources = work / ("source-members-" + staging.name.removeprefix(".gpu-unlock-assets-"))
    report["staging"] = str(staging)
    report["source_members"] = str(sources)
    try:
        subprocess.run([sys.executable, "-I", str(firmware / "firmware/generate_v67.py"), str(alias), str(staging)], check=True)
        extract_sources(inputs / next(n for n in INPUT_SPECS if n.endswith(".xz")), sources)
        subprocess.run([sys.executable, "-I", str(firmware / "firmware/extract_boot_assets.py"), str(sources), str(staging)], check=True)
        shutil.copyfile(firmware / "firmware/NOTICE.md", staging / "NOTICE.md")
        output_state(staging)
        if output_state(output) not in ("absent", "empty"):
            raise ValueError("Output changed during preparation; verified staging retained")
        if output.exists():
            output.rmdir()  # Only an unchanged empty directory can be removed.
        staging.rename(output)
        report["status"] = "generated_verified_published"
        return report
    except Exception as exc:
        raise ValueError(f"Preparation stopped; inputs/work and staging retained at {staging}: {exc}") from exc


def main(argv=None):
    parser = build_parser()
    try:
        result = run(parser.parse_args(argv))
    except (ValueError, OSError, subprocess.CalledProcessError, tarfile.TarError) as exc:
        print(json.dumps({"status": "refused", "error": str(exc)}), file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
