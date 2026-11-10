# SPDX-License-Identifier: GPL-2.0-only
# Synthetic ready-state fixtures. Optional -Archive verifies an existing pinned archive without downloads.
param([string]$Archive)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../desktop/BenchmarkRuntime.ps1')

$expectedRoot = [IO.Path]::Combine([Environment]::GetFolderPath('LocalApplicationData'),'WGU-Bench','v1')
if ((Get-RtxBenchmarkRuntimeRoot) -cne $expectedRoot) { throw 'The managed benchmark runtime path must remain short.' }

$base = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$scratch = [IO.Path]::GetFullPath((Join-Path $base ('rtx-runtime-test-'+[guid]::NewGuid().ToString('N'))))
if (!$scratch.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($scratch) -cnotmatch '^rtx-runtime-test-[a-f0-9]{32}$') { throw 'Unsafe scratch path.' }
$null = [IO.Directory]::CreateDirectory($scratch)
try {
    $script:fixture = [pscustomobject]@{
        Root=$scratch; Archive=$Archive; LockHash=('0'*64)
        Tools=Join-Path $scratch 'tools'; Python=Join-Path $scratch 'tools/python.exe'
        Installed=Join-Path $scratch 'installed.json'; Ready=Join-Path $scratch 'ready.json'
    }
    $null = [IO.Directory]::CreateDirectory($fixture.Tools)
    if ($Archive) {
        Assert-RtxRuntimeArchive $Archive
        Expand-RtxRuntimeArchive $fixture
        $check = 'import os,struct,sys,pip; p=os.path.normcase(os.path.abspath(sys.argv[1])); assert sys.version_info[:3]==(3,14,10) and struct.calcsize("P")==8; assert os.path.normcase(sys.prefix)==p and os.path.normcase(pip.__file__).startswith(p+os.sep); assert os.environ["PIP_CONFIG_FILE"]==os.devnull'
        Invoke-RtxRuntimeProcess $fixture.Python @('-I','-B','-c',$check,$fixture.Tools) $scratch 60 'Portable Python verification'
        'Pinned archive extraction and isolated portable Python checks passed.'
    } else {
        [IO.File]::WriteAllText($fixture.Python,'synthetic')
        [IO.File]::WriteAllText((Join-Path $fixture.Tools 'python314.dll'),'synthetic')
    }
    $torchLib = Join-Path $fixture.Tools 'Lib/site-packages/torch/lib'
    $null = [IO.Directory]::CreateDirectory($torchLib)
    [IO.File]::WriteAllText((Join-Path $torchLib 'torch_cuda.dll'),'synthetic')
    function Get-RtxRuntimePaths { $script:fixture }
    if (Get-RtxManagedBenchmarkPython) { throw 'Incomplete runtime was accepted.' }
    $receipt = Get-RtxRuntimeInstalledIdentity $fixture | ConvertTo-Json -Compress
    Write-RtxRuntimeTextFile $fixture.Installed $receipt
    if (Get-RtxManagedBenchmarkPython) { throw 'Installed runtime was accepted before validation.' }
    Write-RtxRuntimeTextFile $fixture.Ready $receipt
    if ((Get-RtxManagedBenchmarkPython) -cne $fixture.Python) { throw 'Completed runtime was refused.' }
    [IO.File]::AppendAllText((Join-Path $fixture.Tools 'python314.dll'),'tampered')
    if (Get-RtxManagedBenchmarkPython) { throw 'A changed runtime was accepted.' }
    'Private runtime readiness checks passed.'
} finally {
    Assert-RtxRuntimeTree $scratch
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
