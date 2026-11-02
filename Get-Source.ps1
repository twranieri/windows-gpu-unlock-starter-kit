# SPDX-License-Identifier: GPL-2.0-only
# Download pinned public source into new local directories. Never runs a build.
[CmdletBinding()]
param(
    [string]$Destination = $PSScriptRoot,
    [switch]$Execute,
    [switch]$DualGpu
)
$ErrorActionPreference = 'Stop'
$repositories = @(
    @{ Name='Windows-GPU-UNLOCK'; Url='https://github.com/impacifist/Windows-GPU-UNLOCK.git'; Commit='75071aa134616c3d65ad315e0cf2810bf34b191b' },
    @{ Name='gpu-unlock-firmware-source'; Url='https://github.com/Zagitta/gpu-unlock.git'; Commit='0ebdb1c6308b6a2072be5bf04513472942541956' }
)
$destinationPath = [IO.Path]::GetFullPath($Destination)
if (!(Test-Path -LiteralPath $destinationPath -PathType Container)) {
    throw 'Destination must be an existing local folder.'
}
if ((Get-Item -LiteralPath $destinationPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw 'Choose a normal local folder, not a reparse point.'
}
$usePaired=[bool]$DualGpu
if(!$usePaired) {
    $manifestPath=Join-Path $PSScriptRoot 'experimental/dual-gpu/source.json'
    if(Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $capability=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $usePaired=($capability.CanBuildGenericDualUnlock -is [bool] -and $capability.CanBuildGenericDualUnlock)
    }
}
if($usePaired) {
    & (Join-Path $PSScriptRoot 'experimental/dual-gpu/Get-Source.ps1') -Destination $destinationPath -Execute:$Execute
    if(!$?){throw 'Reviewed one/two-card source preparation did not complete.'}
    # The patched core replaces the legacy checkout for this route; firmware
    # source acquisition remains the same independently pinned public repository.
    $repositories=@($repositories | Where-Object Name -ne 'Windows-GPU-UNLOCK')
}
$git = Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
foreach ($repository in $repositories) {
    $target = Join-Path $destinationPath $repository.Name
    Write-Output ("{0}: {1} at {2}" -f $repository.Name, $repository.Url, $repository.Commit)
    if (Test-Path -LiteralPath $target) {
        if (!(Test-Path -LiteralPath (Join-Path $target '.git')) -or
            ((Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Existing destination is not an ordinary Git checkout: $target"
        }
        $revision = & $git.Source -C $target rev-parse HEAD
        if ($LASTEXITCODE -ne 0 -or "$revision".Trim() -ne $repository.Commit) {
            throw "Existing checkout has another revision; nothing will be overwritten: $target"
        }
        & $git.Source -C $target diff --quiet HEAD --
        if ($LASTEXITCODE -ne 0) { throw "Existing checkout has tracked changes: $target" }
        Write-Output '  Already at the required revision; left unchanged.'
        continue
    }
    if (!$Execute) {
        Write-Output "  PLAN: clone to $target and check out the pinned commit."
        continue
    }
    & $git.Source clone --no-checkout --filter=blob:none -- $repository.Url $target
    if ($LASTEXITCODE -ne 0) { throw "Source download failed. The partial folder was retained at $target" }
    & $git.Source -C $target checkout --detach $repository.Commit
    if ($LASTEXITCODE -ne 0) { throw "Pinned checkout failed. The folder was retained at $target" }
    $revision = & $git.Source -C $target rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or "$revision".Trim() -ne $repository.Commit) {
        throw 'Pinned source verification failed.'
    }
    Write-Output '  Pinned source downloaded; no build or firmware program was run.'
}
if (!$Execute) { Write-Output 'Plan only. Add -Execute to download these public source repositories.' }
