# Rebuild the desktop preview

The desktop executable uses the x64 Windows .NET Framework C# compiler.
Run the following command from the kit root.

```powershell
.\desktop\Build-Desktop.ps1 -Output '.\Windows GPU Unlock Setup.exe'
```

The archive `source/engine-source.zip` contains the patched
`nv-uefi-unlocker` source and locked, vendored Cargo dependencies. The original
upstream commit and applied patch hashes are in `rtx/engine.json`. Extract the
source archive into a build folder outside your Windows user profile. Native
library assertions can embed source paths. In the `nv-uefi-unlocker` folder,
use an x64 Visual Studio
Developer PowerShell with the Windows SDK and Rust 1.95.0. Use a short absolute
output directory, especially on systems with legacy Windows path limits.

```powershell
rustup toolchain install 1.95.0-x86_64-pc-windows-msvc --profile minimal --target x86_64-unknown-uefi
$env:RUSTUP_TOOLCHAIN = '1.95.0-x86_64-pc-windows-msvc'
$source = (Get-Location).Path
$pathMap = @("--remap-path-prefix=$source=/src/nv-uefi-unlocker",
    "--remap-path-prefix=$($source.Replace('\','/'))=/src/nv-uefi-unlocker",
    "--remap-path-prefix=$env:USERPROFILE=/buildhost")
$env:CARGO_ENCODED_RUSTFLAGS = ($pathMap + @('-C','target-feature=+crt-static')) -join [char]31
$out = Join-Path ([IO.Path]::GetTempPath()) 'rtx-build'
cargo build --locked --offline --release --target-dir $out --target x86_64-pc-windows-msvc -p assets
if ($LASTEXITCODE) { throw 'Asset tool build failed' }
$env:CARGO_ENCODED_RUSTFLAGS = $pathMap -join [char]31
cargo build --locked --offline --release --target-dir $out --target x86_64-unknown-uefi -p loader --no-default-features --features kit
if ($LASTEXITCODE) { throw 'Probe build failed' }
Copy-Item (Join-Path $out 'x86_64-unknown-uefi/release/loader.efi') (Join-Path $out 'Probe.EFI')
cargo build --locked --offline --release --target-dir $out --target x86_64-unknown-uefi -p loader --no-default-features --features tx,kit
if ($LASTEXITCODE) { throw 'Unlock build failed' }
Copy-Item (Join-Path $out 'x86_64-unknown-uefi/release/loader.efi') (Join-Path $out 'Unlock.EFI')
```

The build uses the engine development commit and patch listed in
`rtx/engine.json` and the flags above. Output hashes
can vary with build paths, compiler metadata and environment. The preview
contains the SHA-256 manifest of the specific binaries it runs.

Run `desktop/package.py` with Python 3.10 or newer and pass the rebuilt tool
output directory, extracted engine source directory, compiled desktop executable
and destination ZIP. The packager checks binary types, matching patched sources,
the asset recipe and archive integrity. The corresponding-source archive omits
the upstream diagnostic kernel-driver binary and archived diagnostic reports.

## Release artwork

Give every GitHub release a versioned thumbnail. Save the source image in
`docs/media/` and upload the PNG alongside the installer ZIP and checksum.
Embed the PNG at the top of the release notes and link it to that release's ZIP.
Check the public release page for the rendered image before sharing the link.
