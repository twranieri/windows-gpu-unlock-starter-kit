# SPDX-License-Identifier: GPL-2.0-only
# Mocked entry point: does not enumerate or write physical media.
$ErrorActionPreference='Stop'
& {
    $scratch=Join-Path ([IO.Path]::GetTempPath()) ('rtx-build-gate-'+[guid]::NewGuid().ToString('N'))
    $modules=Join-Path $scratch 'rtx'
    [void][IO.Directory]::CreateDirectory($modules)
    $runner=Join-Path $scratch 'RTX.ps1'
    $stub=Join-Path $modules 'Inventory.ps1'
    try {
        [IO.File]::Copy((Join-Path $PSScriptRoot '../RTX.ps1'),$runner)
        [IO.File]::WriteAllText($stub,"throw 'Reached synthetic module import.'")
        $manifest=[xml](Get-Content -LiteralPath (Join-Path $PSScriptRoot '../desktop/Setup.manifest') -Raw)
        $build=[string]$manifest.assembly.assemblyIdentity.version
        $source=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../desktop/Setup.cs') -Raw
        if(!$build -or !$source.Contains('AssemblyVersion("'+$build+'")')){throw 'Setup build versions disagree.'}
        $expected='Setup executable and scripts are from different builds.'
        $ErrorActionPreference='Continue'
        $PSNativeCommandUseErrorActionPreference=$false
        $legacyOutput=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Desktop -Action Status 2>&1 | Out-String
        if($LASTEXITCODE -eq 0 -or !$legacyOutput.Contains($expected) -or $legacyOutput.Contains('Reached synthetic module import.')){
            throw 'An older desktop executable reached the backend modules.'
        }
        $wrongOutput=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Desktop -DesktopBuild 0.0.0.0 -Action FormatUsb -Execute 2>&1 | Out-String
        if($LASTEXITCODE -eq 0 -or !$wrongOutput.Contains($expected) -or $wrongOutput.Contains('Reached synthetic module import.')){
            throw 'A mismatched desktop executable reached the backend modules.'
        }
        $matchingOutput=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Desktop -DesktopBuild $build -Action Status 2>&1 | Out-String
        if(!$matchingOutput.Contains('Reached synthetic module import.')){throw 'The matching desktop executable was refused.'}
        $cliOutput=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Action Check 2>&1 | Out-String
        if(!$cliOutput.Contains('Reached synthetic module import.')){throw 'The ordinary CLI was refused.'}
    } finally {
        [IO.File]::Delete($stub)
        [IO.File]::Delete($runner)
        [IO.Directory]::Delete($modules)
        [IO.Directory]::Delete($scratch)
    }
}
'PASS desktop build matching before backend modules load, with ordinary CLI unaffected.'
. (Join-Path $PSScriptRoot '../RTX.ps1')
function Get-RtxInventory {
    [pscustomobject]@{Label='GeForce RTX 4090';Bdf='0000:01:00.0';Device='2684';Subsystem='51031462';Family='ad102';MemoryMiB=23028}
}
function Get-RtxBootProblems {}
function Get-RtxEngineManifest($Root) {@{}}
function Get-RtxVerifiedPackage($Package,$Targets,$Engine) {@{}}
function Get-RtxUsbRoot($Letter,$ExpectedVolume) {
    if($ExpectedVolume -ne 'test-volume'){throw 'USB identity changed.'}
    'test-usb'
}
function Publish-RtxProbe($Usb,$Package,$Receipt) {$script:ProbeCalls++}
function Publish-RtxUnlock($Usb,$Package,$Receipt) {$script:UnlockCalls++}
$script:ProbeCalls=0
$script:UnlockCalls=0
$kitRoot=Split-Path -Parent $PSScriptRoot
$work=Join-Path $kitRoot 'unused'
Invoke-RtxKit $kitRoot 'pRoBe' 'E' $work 'cargo' '' $true $false $false 'test-volume'
if($script:ProbeCalls -ne 1 -or $script:UnlockCalls){throw 'RTX 4090 with 23028 MiB did not reach the read-only probe.'}
$refused=$false
try {Invoke-RtxKit $kitRoot 'StageUnlock' 'E' $work 'cargo' '' $true $false $false 'wrong-volume'}
catch {$refused=$_.Exception.Message -eq 'USB identity changed.'}
if(!$refused -or $script:UnlockCalls){throw 'Changed USB identity reached unlock staging.'}
'PASS read-only probe dispatch for the reported RTX 4090 and wrong-volume refusal.'

function Get-CimInstance {
    [pscustomobject]@{Name='NVIDIA with unavailable resources';PNPDeviceID='PCI\VEN_10DE&DEV_2783';ConfigManagerErrorCode=12;Present=$true}
    [pscustomobject]@{Name='Disconnected NVIDIA';PNPDeviceID='PCI\VEN_10DE&DEV_2204';ConfigManagerErrorCode=45;Present=$false}
    [pscustomobject]@{Name='Other display';PNPDeviceID='PCI\VEN_1002&DEV_164E';ConfigManagerErrorCode=43;Present=$true}
}
$issues=@(Get-RtxWindowsDisplayProblems)
if($issues.Count -ne 1 -or $issues[0] -notmatch 'Code 12.*PCI resources'){throw 'Device Manager resource error diagnosis failed.'}
'PASS present NVIDIA Device Manager diagnostics.'

$script:BootTestTime=[datetime]::UtcNow.AddMinutes(-1)
$script:BootTestPrevious=$script:BootTestTime.AddMinutes(-2)
$script:BootTestLogTime=$script:BootTestTime.AddSeconds(-2)
$script:BootTestComplete=$true
function Get-CimInstance { [pscustomobject]@{LastBootUpTime=$script:BootTestTime} }
function Get-RtxRecentWindowsStarts {
    $script:BootTestTime
    if($script:BootTestPrevious){$script:BootTestPrevious}
}
function Get-RtxDesktopWork($Targets) { $work }
function Get-RtxMediaLayout {
    [pscustomobject]@{LiveKind='Unlock';AssetsComplete=$true;HasLog=$true;Log='test-log'}
}
function Get-RtxMediaFile { [pscustomobject]@{LastWriteTimeUtc=$script:BootTestLogTime} }
function Get-RtxMediaHash { 'a'*64 }
function Get-RtxLogOutcome { [pscustomobject]@{CompleteHandoff=$script:BootTestComplete} }
$targets=@(Get-RtxInventory)
$evidence=Get-RtxBenchmarkBootEvidence 'E' 'test-volume' $targets
if(!$evidence.Confirmed -or !$evidence.BootId -or !$evidence.LogId){throw 'Current complete unlock evidence was refused.'}
if((Get-RtxBenchmarkBootEvidence 'E' 'wrong-volume' $targets).Confirmed){throw 'A different USB authorized a benchmark.'}
if((Get-RtxBenchmarkBootEvidence '' '' $targets).Confirmed){throw 'A missing USB authorized a benchmark.'}
$script:BootTestComplete=$false
if((Get-RtxBenchmarkBootEvidence 'E' 'test-volume' $targets).Confirmed){throw 'An incomplete handoff authorized a benchmark.'}
$script:BootTestComplete=$true
$script:BootTestLogTime=$script:BootTestTime.AddMinutes(-6)
if((Get-RtxBenchmarkBootEvidence 'E' 'test-volume' $targets).Confirmed){throw 'An old unlock log authorized a benchmark.'}
$script:BootTestLogTime=$script:BootTestPrevious.AddSeconds(30)
if((Get-RtxBenchmarkBootEvidence 'E' 'test-volume' $targets).Confirmed){throw 'A log still in the previous boot window authorized a benchmark.'}
$script:BootTestLogTime=$script:BootTestTime.AddSeconds(-2)
$script:BootTestPrevious=$null
if((Get-RtxBenchmarkBootEvidence 'E' 'test-volume' $targets).Confirmed){throw 'Unverified previous startup authorized a benchmark.'}
$script:BootTestPrevious=$script:BootTestTime.AddMinutes(-2)
$script:BootTestLogTime=$script:BootTestTime.AddSeconds(31)
if((Get-RtxBenchmarkBootEvidence 'E' 'test-volume' $targets).Confirmed){throw 'An out-of-window unlock log authorized a benchmark.'}
'PASS benchmark boot evidence is bound to the expected USB, completion and current startup.'

function Get-CimInstance($ClassName) {
    switch($ClassName) {
        'Win32_OperatingSystem' { [pscustomobject]@{LastBootUpTime=$script:BootTestTime} }
        'Win32_BaseBoard' { [pscustomobject]@{Product='Test board'} }
        'Win32_BIOS' { [pscustomobject]@{SMBIOSBIOSVersion='Test BIOS'} }
    }
}
function Get-RtxWindowsPreparation { [ordered]@{IsAdministrator=$false} }
function Get-RtxPrebuiltBundle {}
function Get-RtxCandidateUsb { [pscustomobject]@{Letter='E';VolumeId='test-volume'} }
function Get-RtxWindowsDisplayProblems { if($script:BootTestDisplayProblem){'GPU missing in Windows'} }
function Get-RtxUsbRoot($Letter,$ExpectedVolume) {
    if($Letter -ne 'E' -or ($ExpectedVolume -and $ExpectedVolume -ne 'test-volume')){throw 'USB identity changed.'}
    'test-usb'
}
function Get-RtxMediaStatus {
    [pscustomobject]@{
        State='UnlockLogged';Title='Test EFI result';Message='Test EFI log';HasLog=$true
        CanBootUnlock=$false;CompleteHandoff=$script:BootTestComplete
    }
}
$script:BootTestLogTime=$script:BootTestTime.AddSeconds(-2)
$script:BootTestDisplayProblem=$false
if(!(Get-RtxKitStatus $kitRoot 'E' $work $true).CompletedUnlockBoot){throw 'A verified current boot did not finish desktop setup.'}
$script:BootTestLogTime=$script:BootTestTime.AddMinutes(-6)
if((Get-RtxKitStatus $kitRoot 'E' $work $true).CompletedUnlockBoot){throw 'An old unlock log finished desktop setup.'}
$script:BootTestLogTime=$script:BootTestTime.AddSeconds(-2)
$script:BootTestDisplayProblem=$true
if((Get-RtxKitStatus $kitRoot 'E' $work $true).CompletedUnlockBoot){throw 'A Windows GPU problem finished desktop setup.'}
$script:BootTestDisplayProblem=$false
$script:BootTestComplete=$false
if((Get-RtxKitStatus $kitRoot 'E' $work $true).CompletedUnlockBoot){throw 'An incomplete handoff finished desktop setup.'}
'PASS desktop setup completion requires the current unlock boot and healthy Windows display devices.'
