# SPDX-License-Identifier: GPL-2.0-only
#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$csc = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (!(Test-Path -LiteralPath $csc -PathType Leaf)) { throw '64-bit .NET Framework C# compiler is required.' }
$output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($output)
$zip = Join-Path $output 'RTX-Tensor-Benchmark-v1.0.0-win-x64.zip'
if (Test-Path -LiteralPath $zip) { throw "The ZIP already exists at $zip." }
$stage = Join-Path $output ('benchmark-build-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($stage)
$temporaryZip = "$stage.zip"
try {
    $files = @(
        'LICENSE',
        'benchmark-tensors.py',
        'compare-tensors.py',
        'desktop/BenchmarkPrerequisite.ps1',
        'desktop/BenchmarkRuntime.ps1',
        'desktop/benchmark-requirements.txt',
        'desktop/benchmark-app/BenchmarkApp.cs',
        'desktop/benchmark-app/Build-Benchmark.ps1',
        'desktop/benchmark-app/Run-Benchmark.ps1'
    )
    foreach ($file in $files) {
        $destination = Join-Path $stage $file
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        Copy-Item -LiteralPath (Join-Path $root $file) -Destination $destination
    }
    $guide = Join-Path $PSScriptRoot 'START HERE.txt'
    if (!(Test-Path -LiteralPath $guide)) { $guide = Join-Path $root 'START HERE.txt' }
    Copy-Item -LiteralPath $guide -Destination $stage
    $exe = Join-Path $stage 'RTX Tensor Benchmark.exe'
    $compilerArguments = @('/nologo', '/target:winexe', '/platform:x64', '/optimize+', '/warnaserror+', "/out:$exe",
        '/reference:System.Windows.Forms.dll', '/reference:System.Drawing.dll', '/reference:System.Web.Extensions.dll',
        (Join-Path $stage 'desktop/benchmark-app/BenchmarkApp.cs'))
    & $csc @compilerArguments
    if ($LASTEXITCODE -ne 0) { throw "Benchmark compilation failed (exit $LASTEXITCODE)." }
    [IO.Compression.ZipFile]::CreateFromDirectory($stage,$temporaryZip,[IO.Compression.CompressionLevel]::Optimal,$false)
    [IO.File]::Move($temporaryZip,$zip)
    Get-FileHash -LiteralPath $zip -Algorithm SHA256
} finally {
    if (Test-Path -LiteralPath $temporaryZip -PathType Leaf) { Remove-Item -LiteralPath $temporaryZip -Force }
    $resolved = (Resolve-Path -LiteralPath $stage).ProviderPath
    if ($resolved -ne $stage -or (Split-Path -Parent $resolved) -ne $output -or
        (Split-Path -Leaf $resolved) -notmatch '^benchmark-build-[0-9a-f]{32}$') {
        throw 'Unexpected benchmark build folder. Automatic cleanup stopped.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
