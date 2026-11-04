# SPDX-License-Identifier: GPL-2.0-only
# Temporary synthetic source/logs and mock Git/pipeline only; no host inventory.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../Start.ps1')
function Get-CimInstance {throw 'Real GPU inventory is forbidden in this test.'}
$script:passed=0
function Assert-True($Value,[string]$Message){if(!$Value){throw $Message};$script:passed++}
function Assert-Refused([scriptblock]$Action,[string]$Message){$bad=$false;try{& $Action | Out-Null}catch{$bad=$true};Assert-True $bad $Message}
function Video([string]$Id,[string]$Instance='a'){[pscustomobject]@{Name='NVIDIA synthetic';PNPDeviceID=('PCI\VEN_10DE&DEV_'+$Id+'&SUBSYS_00000000\SYNTHETIC-'+$Instance)}}
function PairLog([int]$Count=2) {
    $lines=@('probe-pci-handles=00000002','dual-probe-v1 max-targets=2 readonly=1')
    for($index=0;$index -lt $Count;$index++){
        $lines+=('dual-card-begin index={0:x4}' -f $index)
        $lines+=('probe-target seg=0x0000 bus=0x{0:x4} dev=0x0000 fun=0x0000' -f ($index+1))
        $lines+=('dual-card-end index={0:x4}' -f $index)
    }
    $lines+=('probe targets={0:x4} cfg-incomplete=0000' -f $Count)
    $lines+=@('capture-complete=1','diagnostic-result status=0x0000000000000000')
    return ($lines -join "`r`n")+"`r`n"
}
function ReadyPair([int]$Captures=2) {
    [pscustomobject]@{Checks=@((New-UGCheck 'Source' 'PASS' 'synthetic'),(New-UGCheck 'GPU preliminary identity' 'CANDIDATE' 'synthetic'));
        CaptureCount=$Captures;Config=@{Repo='synthetic';Workflow='pair';TargetCount=2;PairWriteReady=$true;Drive='Z';
        WindowsEspGuid=[guid]'00000000-0000-0000-0000-000000000001';Assets='assets';Python='python';Clang='clang';LldLink='lld-link';VcVars='vcvars'}}
}
$script:UGFixtureRoot=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('dual-runner-tests-'+[guid]::NewGuid().ToString('N'))))
$null=New-Item -ItemType Directory -Path $script:UGFixtureRoot
$originalSourceRoot=$script:UGDualSourceRoot;$originalKitRoot=$script:UGKitRoot
function Write-Fixture([string]$Path,[string]$Text){$null=New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -Force;[IO.File]::WriteAllBytes($Path,[Text.Encoding]::UTF8.GetBytes($Text))}
$script:UGGitCalls=@();$script:UGUnknown=''
function Invoke-UGFixtureNativeGit {
    $script:UGGitCalls+=,@($args);$global:LASTEXITCODE=0
    $position=[Array]::IndexOf([object[]]$args,'-C')
    if($position -lt 0){throw 'Network/clone is forbidden in runner tests.'}
    switch($args[$position+2]) {
        'rev-parse' {return 'e27d200aaaee8de67a12bce4ab48eba58c0c8551'}
        'diff' {if($args -contains '--cached'){return "research/dual/new-machine.ps1$([char]0)"};return ''}
        'ls-files' {return $script:UGUnknown}
        'apply' {if($args -notcontains '--reverse' -or $args -notcontains '--check'){throw 'Git mutation is forbidden.'};return ''}
        default {throw 'Unexpected native Git operation.'}
    }
}
function Get-Command {
    [CmdletBinding()]param([string]$Name,[string]$CommandType)
    if($Name -ne 'git.exe'){throw ('Unexpected executable lookup: '+$Name)}
    [pscustomobject]@{Source='Invoke-UGFixtureNativeGit'}
}
try {
    foreach($inventory in @(@((Video '2204')), @((Video '2204'),(Video '2484')), @((Video '2204' a),(Video '2204' b)))) {
        $check=Get-UGGpuAssessment $inventory $script:UGKnownIds
        Assert-True ($check.Status -eq 'CANDIDATE' -and $check.TargetCount -eq $inventory.Count) 'One/two per-card preliminary IDs were not retained.'
    }
    Assert-True ((Get-UGGpuAssessment @((Video '2204'),(Video '2206')) $script:UGKnownIds).Status -eq 'BLOCKED') 'Unsupported second card was skipped.'
    Assert-True ((Get-UGGpuAssessment @((Video '2204'),(Video '2484'),(Video '2504')) $script:UGKnownIds).Status -eq 'BLOCKED') 'Third GPU was accepted.'
    Assert-True ((Get-UGGpuAssessment @((Video '2204'),(Video '2204')) $script:UGKnownIds).Status -eq 'UNKNOWN') 'Duplicate CIM row was treated as two cards.'
    Assert-True ((Get-UGGpuAssessment @((Video '2206')) @('220610de')).Status -eq 'BLOCKED') 'An edited envelope widened the fixed candidate set.'
    Assert-True ((Get-UGGpuAssessment @((Video '220a')) $script:UGKnownIds).Status -eq 'CANDIDATE') 'The reviewed 3080 12 GB identity was refused.'
    $msi3070ti=Video '2482'
    $msi3070ti.PNPDeviceID=$msi3070ti.PNPDeviceID.Replace('SUBSYS_00000000','SUBSYS_50521462')
    Assert-True ((Get-UGGpuAssessment @($msi3070ti) $script:UGKnownIds).Status -eq 'CANDIDATE') 'The exact MSI 3070 Ti subsystem was refused.'
    foreach($id in @('2482','2206','2208','2584','25a2','28e3')) {
        $observation=Get-UGGpuAssessment @((Video '2204'),(Video $id)) $script:UGKnownIds -AllowObservation
        $ready=ReadyPair 2
        $ready.Checks=@($ready.Checks[0],$observation)
        $ready.Config.InventoryOnly=$true
        Assert-True ($observation.Status -eq 'OBSERVE' -and $observation.TargetCount -eq 2 -and
            (Get-UGDecision $ready Probe $true).WillExecute -and !(Get-UGDecision $ready Build $true).WillExecute -and
            !(Get-UGDecision $ready StageUnlock $true).WillExecute) ('Inventory-only GPU crossed the write boundary or could not be diagnosed: '+$id)
    }
    Assert-True ((Get-UGGpuAssessment @((Video '2704')) $script:UGKnownIds -AllowObservation).Status -eq 'BLOCKED') 'Unrelated GPU gained RTX 30 inventory admission.'

    $single=ConvertFrom-UGDiagnostic (PairLog 1) 'DIAG00.TXT' -ExpectedTargets 2 -PairMode
    Assert-True (!$single.Complete) 'A one-card file counted as a two-card whole-set capture.'
    $whole=ConvertFrom-UGDiagnostic (PairLog 2) 'DIAG00.TXT' -ExpectedTargets 2 -PairMode
    Assert-True $whole.Complete 'Complete whole-set capture did not count.'
    Assert-True (!(ConvertFrom-UGDiagnostic (PairLog 2) 'DIAG00.TXT').Complete) 'Dual log entered the legacy intake route.'
    foreach($text in @((PairLog 2).Replace('bus=0x0002','bus=0x0001'),
                       (PairLog 2).Replace('index=0001','index=0002'),
                       (PairLog 2).Replace('cfg-incomplete=0000','cfg-incomplete=0001'),
                       (PairLog 2).Replace('capture-complete=1',"capture-complete=1`r`ncapture-complete=1"),
                       (PairLog 2).Replace('capture-complete=1',"incomplete malformed`r`ncapture-complete=1"))) {
        Assert-True (!(ConvertFrom-UGDiagnostic $text 'DIAG00.TXT' -ExpectedTargets 2 -PairMode).Complete) 'Malformed pair record counted as complete.'
    }
    $legacyVideoLog=@'
dual-probe-v1 max-targets=2 readonly=1
incomplete reason=dual-unreviewed-envelope status=0x8000000000000003
handle id=0x0000000000000001
driver image=0x0000000000000001 binding=0x0000000000000001 version=0x0000000000000024 stop-address=0x0000000000000010
image-file-path-node raw=04061400f855cf2975b65d4f8f2fb87a3ecfd063
handle id=0x0000000000000002
protocol guid=4cf5b200-68b8-4ca5-9eec-b23e3f50029a
opens status=0x0000000000000000 count=0x0000000000000001
open agent=0x0000000000000001 controller=0x0000000000000002 attributes=0x0000000000000010 count=0x0000000000000001
pci config-status=0x0000000000000000
pci config-dwords=220410de 00100007 030000a1 00800010
handle id=0x0000000000000003
protocol guid=4cf5b200-68b8-4ca5-9eec-b23e3f50029a
pci config-status=0x0000000000000000
pci config-dwords=250410de 00100000 030000a1 00800010
capture-complete=0
diagnostic-result status=0x8000000000000006
'@
    $record=ConvertFrom-UGDiagnostic $legacyVideoLog 'DIAG00.TXT' -ExpectedTargets 2 -PairMode
    Assert-True (!$record.Complete -and ($record.Reasons -match 'disable Launch CSM') -and
        ($record.Reasons -match '10DE:2204.*bus mastering enabled') -and ($record.Reasons -match '10DE:2504.*memory decoding disabled')) 'Active legacy video ownership or PCI command refusal was not explained.'
    $passiveLog=$legacyVideoLog.Replace('attributes=0x0000000000000010','attributes=0x0000000000000002')
    $passive=ConvertFrom-UGDiagnostic $passiveLog 'DIAG00.TXT' -ExpectedTargets 2 -PairMode
    Assert-True (!$passive.Complete -and !($passive.Reasons -match 'Launch CSM')) 'A loaded legacy driver with only a passive open was reported as the GPU owner.'
    $captureFolder=Join-Path $script:UGFixtureRoot 'captures'
    Write-Fixture (Join-Path $captureFolder 'DIAG00.TXT') (PairLog 1)
    Write-Fixture (Join-Path $captureFolder 'DIAG01.TXT') (PairLog 1)
    function Get-ChildItem {
        [CmdletBinding()]param([string]$LiteralPath,[switch]$File)
        if($LiteralPath -ne 'Z:\RTX3090-UNLOCK'){throw 'Unexpected capture inventory path.'}
        Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $captureFolder -File
    }
    try {
        $evidence=Get-UGCaptureEvidence Z -ExpectedTargets 2 -PairMode
        Assert-True ($evidence.CompleteCount -eq 0) 'One capture per card was counted as two whole-pair boots.'
        Write-Fixture (Join-Path $captureFolder 'DIAG00.TXT') (PairLog 2)
        $evidence=Get-UGCaptureEvidence Z -ExpectedTargets 2 -PairMode
        Assert-True ($evidence.CompleteCount -eq 1) 'One two-card boot was counted as two captures.'
        Write-Fixture (Join-Path $captureFolder 'DIAG01.TXT') (PairLog 2)
        $evidence=Get-UGCaptureEvidence Z -ExpectedTargets 2 -PairMode
        Assert-True ($evidence.CompleteCount -eq 2) 'Two whole-pair capture files were not counted.'
    } finally {Remove-Item Function:Get-ChildItem}
    $ready=ReadyPair 1
    Assert-True (!(Get-UGDecision $ready Build $true).WillExecute) 'One whole-pair capture allowed Build.'
    $ready=ReadyPair 2
    Assert-True ((Get-UGDecision $ready Build $true).WillExecute) 'Two whole-set captures could not reach upstream proof checks.'
    $ready.Config.Workflow='legacy'
    Assert-True (!(Get-UGDecision $ready StageUnlock $true).WillExecute) 'Legacy dispatch accepted two GPUs.'
    Assert-Refused {Get-UGPipelineEntry $ready.Config} 'Legacy pipeline entry was selected for two GPUs.'
    $ready.Config.Workflow='pair';$ready.Config.PairWriteReady=$false
    Assert-True (!(Get-UGDecision $ready StageUnlock $true).WillExecute) 'Incomplete reviewed write pipeline allowed staging.'
    $ready.CaptureCount=0
    Assert-True ((Get-UGDecision $ready Probe $true).WillExecute) 'Read-only probe was incorrectly tied to write availability.'

    $source=Join-Path $script:UGFixtureRoot 'source-package'
    $target=Join-Path $script:UGFixtureRoot 'Windows-GPU-UNLOCK-dual-dev'
    $null=New-Item -ItemType Directory -Path (Join-Path $target '.git'),$source
    Copy-Item -LiteralPath (Join-Path $originalSourceRoot 'Get-Source.ps1') -Destination (Join-Path $source 'Get-Source.ps1')
    $entry=Join-Path $target 'research/dual/new-machine.ps1'
    Write-Fixture $entry @'
param($Drive,$WindowsEspGuid,$Assets,$Python,$Clang,$LldLink,$VcVars,[switch]$StageUnlock,[switch]$ProbeOnly)
$global:UGDispatched=@{Drive=$Drive;WindowsEspGuid=$WindowsEspGuid;Assets=$Assets;StageUnlock=[bool]$StageUnlock;ProbeOnly=[bool]$ProbeOnly;VcVars=$VcVars}
$global:LASTEXITCODE=0
'@
    Write-Fixture (Join-Path $target 'deps/edk2/MdePkg/Include/Uefi.h') 'SYNTHETIC HEADER; never compiled'
    Write-Fixture (Join-Path $source 'upstream.patch') 'SYNTHETIC PATCH; never applied'
    $manifest=[pscustomobject]@{SourceUrl='https://github.com/jingx8885/Windows-GPU-UNLOCK.git';
        SourceCommit='e27d200aaaee8de67a12bce4ab48eba58c0c8551';Patch='upstream.patch';
        PatchSha256=(Get-FileHash -LiteralPath (Join-Path $source 'upstream.patch')).Hash.ToLowerInvariant();
        Files=@([pscustomobject]@{Path='research/dual/new-machine.ps1';Sha256=(Get-FileHash -LiteralPath $entry).Hash.ToLowerInvariant()});
        CanBuildGenericDualUnlock=$true;SupportsProbeOnly=$true}
    function Save-SourceFixture {
        Write-Fixture (Join-Path $source 'source.json') ($manifest | ConvertTo-Json -Depth 6)
        $receipt=[ordered]@{Format=1;SourceUrl=$manifest.SourceUrl;SourceCommit=$manifest.SourceCommit;PatchSha256=$manifest.PatchSha256;
            SourceManifestSha256=(Get-FileHash -LiteralPath (Join-Path $source 'source.json')).Hash.ToLowerInvariant()}
        Write-Fixture (Join-Path $target '.git/windows-gpu-unlock-dual-source.json') ($receipt | ConvertTo-Json)
    }
    Save-SourceFixture
    $script:UGDualSourceRoot=$source
    $checked=Get-UGRepositoryCheck $target
    Assert-True ($checked.Status -eq 'PASS' -and $checked.Workflow -eq 'pair' -and $checked.SupportsPairWrite) ('Receipt-bound patched checkout refused: '+$checked.Detail)
    $config=(ReadyPair).Config;$config.Repo=$target;$config.SupportsProbeOnly=$true
    $global:UGDispatched=$null
    Invoke-UGPipeline $config StageUnlock
    Assert-True ($global:UGDispatched.Drive -eq 'Z' -and $global:UGDispatched.StageUnlock -and !$global:UGDispatched.ProbeOnly -and $global:UGDispatched.Assets -eq 'assets' -and $global:UGDispatched.VcVars -eq 'vcvars') 'Verified paired dispatch lost the existing pipeline contract.'
    $manifest.CanBuildGenericDualUnlock=$false;Save-SourceFixture
    $checked=Get-UGRepositoryCheck $target
    Assert-True ($checked.Status -eq 'PASS' -and !$checked.SupportsPairWrite) 'Source integrity was confused with write availability.'
    $global:UGDispatched=$null
    Assert-Refused {Invoke-UGPipeline $config StageUnlock} 'Incomplete source pipeline reached StageUnlock.'
    Assert-True ($null -eq $global:UGDispatched) 'Blocked write pipeline executed its entry script.'
    Invoke-UGPipeline $config Probe
    Assert-True ($null -ne $global:UGDispatched -and $global:UGDispatched.ProbeOnly -and !$global:UGDispatched.StageUnlock) 'Verified read-only route could not dispatch ProbeOnly.'
    $manifest.CanBuildGenericDualUnlock=$true;Save-SourceFixture
    $originalEntry=[IO.File]::ReadAllBytes($entry)
    Write-Fixture $entry 'unreviewed source edit'
    Assert-True ((Get-UGRepositoryCheck $target).Status -eq 'BLOCKED') 'Modified paired source file passed receipt validation.'
    [IO.File]::WriteAllBytes($entry,$originalEntry)
    $script:UGUnknown="research/dual/unreviewed.py$([char]0)"
    Assert-True ((Get-UGRepositoryCheck $target).Status -eq 'BLOCKED') 'Unreviewed untracked source passed validation.'
    $script:UGUnknown=''
    $receiptPath=Join-Path $target '.git/windows-gpu-unlock-dual-source.json'
    Write-Fixture $receiptPath '{}'
    Assert-True ((Get-UGRepositoryCheck $target).Status -eq 'BLOCKED') 'Mismatched receipt was accepted.'
    Remove-Item -LiteralPath $receiptPath
    Assert-True ((Get-UGRepositoryCheck $target).Status -eq 'BLOCKED') 'Missing source receipt was accepted.'
    Save-SourceFixture
    $script:UGKitRoot=$script:UGFixtureRoot
    Assert-True ((Get-UGDefaultRepository) -eq $target) 'Prepared patched source was not automatically selected.'

    # Exercise the real root source dispatch with a synthetic inner helper.
    $loader=Join-Path $script:UGFixtureRoot 'loader'
    $null=New-Item -ItemType Directory -Path $loader
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../Get-Source.ps1') -Destination (Join-Path $loader 'Get-Source.ps1')
    Write-Fixture (Join-Path $loader 'experimental/dual-gpu/Get-Source.ps1') @'
param([string]$Destination,[switch]$Execute)
$global:UGSourceDispatch=@{Destination=$Destination;Execute=[bool]$Execute}
'@
    $destination=Join-Path $script:UGFixtureRoot 'source-destination'
    $null=New-Item -ItemType Directory -Path $destination
    $script:UGGitCalls=@();$global:UGSourceDispatch=$null
    $null=& (Join-Path $loader 'Get-Source.ps1') -Destination $destination -DualGpu
    Assert-True ($global:UGSourceDispatch.Destination -eq $destination -and !$global:UGSourceDispatch.Execute) 'Root Get-Source did not delegate the paired plan.'
    Assert-True ($script:UGGitCalls.Count -eq 0 -and !(Test-Path -LiteralPath (Join-Path $destination 'Windows-GPU-UNLOCK'))) 'Paired source plan invoked Git or created legacy source.'
    Write-Fixture (Join-Path $loader 'experimental/dual-gpu/source.json') '{"CanBuildGenericDualUnlock":false}'
    $global:UGSourceDispatch=$null
    $null=& (Join-Path $loader 'Get-Source.ps1') -Destination $destination
    Assert-True ($null -eq $global:UGSourceDispatch -and $script:UGGitCalls.Count -eq 0) 'An unavailable pair pipeline became the default source route.'
    Write-Fixture (Join-Path $loader 'experimental/dual-gpu/source.json') '{"CanBuildGenericDualUnlock":true}'
    $null=& (Join-Path $loader 'Get-Source.ps1') -Destination $destination
    Assert-True ($null -ne $global:UGSourceDispatch -and !$global:UGSourceDispatch.Execute -and $script:UGGitCalls.Count -eq 0) 'Available unified one/two-card source did not become the default plan.'
    Write-Output ('PASS dual-runner mocked checks: '+$script:passed+'; no network, real inventory or device actions')
} finally {
    $script:UGDualSourceRoot=$originalSourceRoot;$script:UGKitRoot=$originalKitRoot
    $resolved=[IO.Path]::GetFullPath($script:UGFixtureRoot)
    $tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(!$resolved.StartsWith($tempParent,[StringComparison]::OrdinalIgnoreCase) -or ![IO.Path]::GetFileName($resolved).StartsWith('dual-runner-tests-')){throw 'Refusing cleanup outside the dedicated fixture directory.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
