# SPDX-License-Identifier: GPL-2.0-only
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('List','Check','Before','After')][string]$Action,
    [ValidatePattern('^[0-9a-f]{8}:[0-9a-f]{2}:[01][0-9a-f]\.[0-7]$')][string]$Gpu,
    [string]$OutputDirectory,
    [string]$Before
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$desktop = Split-Path -Parent $PSScriptRoot
$root = Split-Path -Parent $desktop
$benchmark = Join-Path $root 'benchmark-tensors.py'
$compare = Join-Path $root 'compare-tensors.py'
. (Join-Path $desktop 'BenchmarkRuntime.ps1')
. (Join-Path $desktop 'BenchmarkPrerequisite.ps1')

try {
    Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1')
    Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Security/Microsoft.PowerShell.Security.psd1')
    if (!(Test-Path -LiteralPath $benchmark -PathType Leaf) -or !(Test-Path -LiteralPath $compare -PathType Leaf)) {
        throw 'Extract the entire ZIP to a folder, then open RTX Tensor Benchmark.exe there.'
    }

    foreach ($folder in @([Environment]::SystemDirectory, (Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI'))) {
        $smi = Join-Path $folder 'nvidia-smi.exe'
        if (Test-Path -LiteralPath $smi -PathType Leaf) { break }
        $smi = $null
    }
    if (!$smi) { throw 'The NVIDIA driver tools are missing. Install or repair the NVIDIA graphics driver, then click Retry.' }
    $env:PATH = (Split-Path -Parent $smi) + ';' + $env:PATH
    foreach ($name in 'CUDA_VISIBLE_DEVICES','TORCH_ALLOW_TF32_CUBLAS_OVERRIDE','NVIDIA_TF32_OVERRIDE','CUBLAS_WORKSPACE_CONFIG') {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }

    if ($Action -eq 'List') {
        $rows = @(& $smi '--query-gpu=name,pci.bus_id,uuid' '--format=csv,noheader,nounits')
        if ($LASTEXITCODE -ne 0) { throw 'The NVIDIA driver could not list the GPUs. Check the driver and click Retry.' }
        if ($rows.Count -lt 1 -or $rows.Count -gt 2) { throw 'The benchmark supports one or two NVIDIA GPUs, testing one at a time.' }
        foreach ($row in $rows) {
            $fields = $row -split ',\s*'
            if ($fields.Count -ne 3) { throw 'The NVIDIA driver returned an invalid GPU list.' }
            $bdf = $fields[1].Trim().ToLowerInvariant()
            if ($bdf.Length -eq 12) { $bdf = '0000' + $bdf }
            $uuid = $fields[2].Trim()
            if ($bdf -notmatch '^[0-9a-f]{8}:[0-9a-f]{2}:[01][0-9a-f]\.[0-7]$' -or
                $uuid -notmatch '^GPU-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$') {
                throw 'The NVIDIA driver could not verify a physical GPU identity.'
            }
            [Console]::WriteLine("GPU|$bdf|$uuid|$($fields[0].Trim())")
        }
        exit 0
    }

    if (!$Gpu -or !$OutputDirectory) { throw 'The benchmark is missing its GPU or results folder.' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        if (([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Close the app and open it normally from Explorer to run under your desktop account.'
        }
    } finally { $identity.Dispose() }

    if (!(Test-RtxBenchmarkPrerequisite)) {
        [Console]::Error.WriteLine('Installing Microsoft Visual C++ x64. Approve the Windows prompt if it appears.')
        $installer = Join-Path $OutputDirectory 'VC_redist.x64.exe'
        Save-RtxBenchmarkPrerequisiteInstaller $installer
        Assert-RtxBenchmarkPrerequisiteInstaller $installer
        $setup = Start-Process -FilePath $installer -WorkingDirectory $OutputDirectory -Verb RunAs -PassThru -ArgumentList '/install','/passive','/norestart'
        $setup.WaitForExit()
        if ($setup.ExitCode -in @(1641,3010,0x80070669,0x80070BC2)) {
            throw 'Microsoft Visual C++ needs a Windows restart. Restart when convenient, then reopen the benchmark and retry.'
        }
        if (!(Test-RtxBenchmarkPrerequisite)) {
            throw "Microsoft Visual C++ installation did not supply the required libraries (exit $($setup.ExitCode)). Retry or ask your Windows administrator to install the current x64 redistributable."
        }
        Remove-Item -LiteralPath $installer -Force
    }

    $python = Get-RtxManagedBenchmarkPython
    if (!$python) {
        [Console]::Error.WriteLine('Setting up CUDA Python. The first download is about 2.6 GB and may take several minutes.')
        if (!$Gpu.StartsWith('0000') -or !$Gpu.EndsWith('.0')) { throw 'Private CUDA setup requires a standard NVIDIA PCI graphics function.' }
        $python = Initialize-RtxBenchmarkRuntime -GpuAddresses @($Gpu.Substring(4))
    }
    if ($Action -eq 'Check') {
        & $python -I -B $benchmark --check-runtime --gpu $Gpu
        exit $LASTEXITCODE
    }

    $label = if ($Action -eq 'Before') { 'stock' } else { 'unlocked' }
    $result = Join-Path $OutputDirectory ($Action.ToLowerInvariant()+'.json')
    [Console]::WriteLine('Checking GPU activity. Close games and GPU-heavy apps before testing.')
    & $python -I -B $benchmark --label $label --gpu $Gpu --output $result
    if ($LASTEXITCODE -ne 0) { throw 'This measurement could not finish. See the detail above, then retry.' }

    if ($Action -eq 'After') {
        if (!$Before -or !(Test-Path -LiteralPath $Before -PathType Leaf)) { throw 'The saved before result is missing. Run a new before test.' }
        & $python -I -B $compare --before $Before --after $result --output (Join-Path $OutputDirectory 'comparison.json') --summary
        if ($LASTEXITCODE -ne 0) { throw 'The after run was saved. The comparison detail above explains what needs to match.' }
    }
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.GetBaseException().Message)
    exit 1
}
