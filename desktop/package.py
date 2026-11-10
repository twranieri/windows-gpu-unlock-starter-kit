"""Package the reviewed desktop preview and its corresponding engine source."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import struct
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
VERSION = "0.4.0"
FILES = (
    "README.md", "LICENSE", "NOTICES.txt", "VALIDATION.txt", "CHANGELOG.md",
    "pinned-source.json", "RTX.ps1", "Start.ps1", "Get-Source.ps1", "prepare-assets.py",
    "benchmark-tensors.py", "compare-tensors.py", "rtx30-pci.json", "rtx40-pci.json",
    "rtx/Build.ps1", "rtx/Inventory.ps1", "rtx/Media.ps1", "rtx/WindowsPrep.ps1", "rtx/engine.json", "rtx/engine.patch",
    "desktop/BUILD.md", "desktop/Build-Desktop.ps1", "desktop/Setup.cs", "desktop/Resume.cs",
    "desktop/UserProcess.cs", "desktop/Measure.ps1", "desktop/SetupDiagnostics.cs", "desktop/Diagnostics.ps1",
    "desktop/Setup.manifest", "desktop/package.py",
    "docs/RTX30-40.md", "docs/COMPARISON.md", "docs/COMPATIBILITY.md", "docs/QUICKSTART.md",
    "docs/ORIGINATING-RESULTS.md", "experimental/dual-gpu/README.md",
    "experimental/dual-gpu/Get-Source.ps1", "experimental/dual-gpu/source.json",
    "experimental/dual-gpu/upstream.patch", "tests/test_rtx_inventory.ps1",
    "tests/test_rtx_media.ps1", "tests/test_rtx_runner.ps1", "tests/test_rtx_windows_prep.ps1",
    "tests/test_rtx_measure.ps1", "tests/test_rtx_diagnostics.ps1",
)
PRIVATE = tuple(value.lower().encode(encoding)
                for value in (str(Path.home()), Path.home().as_posix())
                for encoding in ("utf-8", "utf-16le"))
FORBIDDEN = {".efi", ".exe", ".dll", ".sys", ".rom", ".dmp", ".vrom", ".bin"}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read(root, name):
    path = root / name
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"Missing or unsafe release member {name}")
    data = path.read_bytes()
    if any(value in data.lower() for value in PRIVATE):
        raise ValueError(f"Private machine data found in {name}")
    return data


def add(archive, name, data):
    entry = ZipInfo(name, (2026, 11, 7, 0, 0, 0))
    entry.compress_type = ZIP_DEFLATED
    entry.external_attr = 0o100644 << 16
    archive.writestr(entry, data)


def pe(data, subsystem):
    if data[:2] != b"MZ":
        raise ValueError("Missing DOS header")
    pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe_offset:pe_offset+4] != b"PE\0\0":
        raise ValueError("Missing PE header")
    if struct.unpack_from("<H", data, pe_offset + 4)[0] != 0x8664:
        raise ValueError("Expected an AMD64 image")
    if struct.unpack_from("<H", data, pe_offset + 24)[0] != 0x20B:
        raise ValueError("Expected a PE32+ image")
    if struct.unpack_from("<H", data, pe_offset + 24 + 68)[0] != subsystem:
        raise ValueError("Unexpected PE subsystem")


def archive_engine(source, engine):
    for item in engine["Files"]:
        if digest(read(source, item["Path"])) != item["Sha256"]:
            raise ValueError(f"Corresponding source differs at {item['Path']}")
    for required in ("Cargo.lock", "LICENSE", "loader/build.rs", "assets/Cargo.toml", ".cargo/config.toml"):
        read(source, required)
    if not (source / "vendor").is_dir() or not list((source / "vendor").glob("*/.cargo-checksum.json")):
        raise ValueError("Missing vendored Rust dependencies")
    output = io.BytesIO()
    with ZipFile(output, "w") as archive:
        for path in sorted(source.rglob("*")):
            if path.is_dir() and not path.is_symlink():
                continue
            name = path.relative_to(source).as_posix()
            if name == "tools/ssdiag/pmxdrv.sys" or name.startswith("docs/evidence/"):
                continue
            if path.suffix.lower() in FORBIDDEN:
                raise ValueError(f"Unexpected binary in corresponding source {name}")
            add(archive, "nv-uefi-unlocker/" + name, read(source, name))
    return output.getvalue()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine-output", required=True, type=Path)
    parser.add_argument("--engine-source", required=True, type=Path)
    parser.add_argument("--desktop-exe", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    contents = {name: read(ROOT, name) for name in FILES}
    engine = json.loads(contents["rtx/engine.json"])
    if digest(contents["rtx/engine.patch"]) != engine["PatchSha256"]:
        raise ValueError("RTX engine patch hash differs")
    tools = {
        "Probe.EFI": read(args.engine_output, "Probe.EFI"),
        "Unlock.EFI": read(args.engine_output, "Unlock.EFI"),
        "assets.exe": read(args.engine_output, "x86_64-pc-windows-msvc/release/assets.exe"),
        "release/make-usbroot.ps1": read(args.engine_source, "release/make-usbroot.ps1"),
    }
    pe(tools["Probe.EFI"], 10)
    pe(tools["Unlock.EFI"], 10)
    pe(tools["assets.exe"], 3)
    if b"TX: BEGIN" in tools["Probe.EFI"] or b"TX: BEGIN" not in tools["Unlock.EFI"]:
        raise ValueError("EFI transaction separation failed")
    if b"KIT-STOP:" in tools["Probe.EFI"] or b"KIT-STOP:" not in tools["Unlock.EFI"]:
        raise ValueError("EFI recovery-stop marker check failed")
    if digest(tools["release/make-usbroot.ps1"]) != "26bf2275c839defac808cdd485f455e08ea64bdb9bda98577b8b98d1b8d0ede2":
        raise ValueError("Asset generator differs from the pinned upstream script")
    desktop = read(args.desktop_exe.parent, args.desktop_exe.name)
    pe(desktop, 2)
    contents["Windows GPU Unlock Setup.exe"] = desktop
    manifest = {
        "Format": 1,
        "SourceCommit": engine["SourceCommit"],
        "PatchSha256": engine["PatchSha256"],
        "Files": [{"Path": name, "Bytes": len(data), "Sha256": digest(data)} for name, data in tools.items()],
    }
    contents["rtx/prebuilt.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
    contents.update({"rtx/prebuilt/" + name: data for name, data in tools.items()})
    contents["source/engine-source.zip"] = archive_engine(args.engine_source, engine)
    report_url = "https://github.com/twranieri/windows-gpu-unlock-starter-kit/tree/main/research/originating-rtx3090"
    for name, link in (("README.md", "(research/originating-rtx3090/)"),
                       ("docs/ORIGINATING-RESULTS.md", "(../research/originating-rtx3090/)")):
        contents[name] = contents[name].replace(link.encode(), f"({report_url})".encode())
    contents["SHA256SUMS.txt"] = "".join(f"{digest(data)}  {name}\n" for name, data in contents.items()).encode()
    prefix = "windows-gpu-unlock-setup/"
    with ZipFile(args.output, "x") as archive:
        for name, data in contents.items():
            add(archive, prefix + name, data)
    with ZipFile(args.output) as archive:
        if archive.testzip() or set(archive.namelist()) != {prefix + name for name in contents}:
            raise ValueError("Archive member or CRC verification failed")
        for name, data in contents.items():
            if archive.read(prefix + name) != data:
                raise ValueError(f"Archive verification failed at {name}")
    checksum = digest(args.output.read_bytes())
    args.output.with_suffix(args.output.suffix + ".sha256").write_text(
        f"{checksum}  {args.output.name}\n", encoding="ascii"
    )
    print(json.dumps({"version": VERSION, "file": args.output.name, "bytes": args.output.stat().st_size,
                      "sha256": checksum, "members": len(contents)}))


if __name__ == "__main__":
    main()
