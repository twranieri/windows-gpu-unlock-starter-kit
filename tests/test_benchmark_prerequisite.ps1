# SPDX-License-Identifier: GPL-2.0-only
#Requires -Version 5.1

param([switch]$VerifyOfficialInstaller)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../desktop/BenchmarkPrerequisite.ps1')

function Assert-Failure([scriptblock]$Action,[string]$Message) {
    try { & $Action } catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        return
    }
    throw "Expected failure containing '$Message'."
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('rtx-vcredist-test-'+[guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($scratch)
$installer = Join-Path $scratch 'VC_redist.x64.exe'
try {
    [IO.File]::WriteAllText($installer,'corrupt installer')
    Assert-Failure { Assert-RtxBenchmarkPrerequisiteInstaller $installer } 'size or SHA-256 verification'
    $file = [IO.File]::OpenWrite($installer)
    try { $file.SetLength($script:RtxBenchmarkRedistBytes) } finally { $file.Dispose() }
    Assert-Failure { Assert-RtxBenchmarkPrerequisiteInstaller $installer } 'size or SHA-256 verification'
    [IO.File]::Delete($installer)
    if ($VerifyOfficialInstaller) {
        Save-RtxBenchmarkPrerequisiteInstaller $installer
        Assert-RtxBenchmarkPrerequisiteInstaller $installer
        'Pinned official download, exact SHA-256, and Microsoft Authenticode checks passed.'
    }
} finally {
    if ([IO.File]::Exists($installer)) { [IO.File]::Delete($installer) }
    [IO.Directory]::Delete($scratch)
}

function Reset-Fixture {
    $script:steps = [Collections.Generic.List[string]]::new()
    $script:ready = $false
    $script:verify = $true
    $script:verifyReadback = $true
    $script:mockExit = 0
}

function Test-RtxBenchmarkPrerequisite { $script:steps.Add('readiness'); return $script:ready }
function Assert-RtxBenchmarkPrerequisiteAdmin { $script:steps.Add('admin') }
function New-RtxBenchmarkPrerequisiteStage { $script:steps.Add('stage'); return $scratch }
function Remove-RtxBenchmarkPrerequisiteStage([string]$Stage) { $script:steps.Add('cleanup') }
function Save-RtxBenchmarkPrerequisiteInstaller([string]$Path) { $script:steps.Add('download') }
function Assert-RtxBenchmarkPrerequisiteInstaller([string]$Path) {
    $script:steps.Add('verify')
    if (!$script:verify) { throw 'Fixture failed Microsoft Authenticode verification.' }
}
function Invoke-RtxBenchmarkPrerequisiteInstaller([string]$Path) {
    $script:steps.Add('install')
    $script:ready = $script:verifyReadback
    return $script:mockExit
}
function Assert-Steps([string]$Expected) {
    $actual = $script:steps -join ' '
    if ($actual -cne $Expected) { throw "Expected '$Expected', got '$actual'." }
}

Reset-Fixture
$script:ready = $true
Install-RtxBenchmarkPrerequisite
Assert-Steps 'readiness'

Reset-Fixture
$script:verify = $false
Assert-Failure { Install-RtxBenchmarkPrerequisite } 'failed Microsoft Authenticode verification'
Assert-Steps 'readiness admin stage download verify cleanup'

Reset-Fixture
Install-RtxBenchmarkPrerequisite
Assert-Steps 'readiness admin stage download verify install readiness cleanup'

Reset-Fixture
$script:verifyReadback = $false
Assert-Failure { Install-RtxBenchmarkPrerequisite } 'required x64 libraries could not be verified'
Assert-Steps 'readiness admin stage download verify install readiness cleanup'

foreach ($restart in @(1641,3010,0x80070669,0x80070BC2)) {
    Reset-Fixture
    $script:mockExit = $restart
    Assert-Failure { Install-RtxBenchmarkPrerequisite } 'Restart Windows and reopen Setup'
    Assert-Steps 'readiness admin stage download verify install cleanup'
}

Reset-Fixture
$script:mockExit = 1618
Assert-Failure { Install-RtxBenchmarkPrerequisite } 'Another Windows installation is in progress'
Assert-Steps 'readiness admin stage download verify install cleanup'

Reset-Fixture
$script:mockExit = 0x80070666
Install-RtxBenchmarkPrerequisite
Assert-Steps 'readiness admin stage download verify install readiness cleanup'

Reset-Fixture
$script:mockExit = 0x80070643
Assert-Failure { Install-RtxBenchmarkPrerequisite } 'Microsoft Visual C++ installation failed'
Assert-Steps 'readiness admin stage download verify install cleanup'

Reset-Fixture
$script:mockExit = $null
Assert-Failure { Install-RtxBenchmarkPrerequisite } 'installer is still running'
Assert-Steps 'readiness admin stage download verify install'

'Microsoft Visual C++ prerequisite control-flow checks passed.'
