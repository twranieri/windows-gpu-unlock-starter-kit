# SPDX-License-Identifier: GPL-2.0-only
# Mocked coordinator checks: no firmware, USB, boot, GPU or security writes.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../Start.ps1')
# Any unexpected inventory call must fail rather than query the test host.
function Get-CimInstance {throw 'Host inventory is forbidden in mocked runner tests.'}
$script:passed=0
function Assert-True($Value,$Message){if(!$Value){throw $Message};$script:passed++}
function Ready {
    [pscustomobject]@{Checks=@((New-UGCheck 'Source' 'PASS' 'fixture'),(New-UGCheck 'USB' 'PASS' 'fixture'),(New-UGCheck 'Secure Boot' 'PASS' 'fixture'),(New-UGCheck 'GPU preliminary identity' 'CANDIDATE' 'ID only; fixture'));CaptureCount=0;Config=@{Repo='fixture';Drive='Z';WindowsEspGuid=[guid]'00000000-0000-0000-0000-000000000001';Assets='assets';Python='python';Clang='clang';LldLink='lld-link';VcVars='vcvars'}}
}
$script:calls=0
function Invoke-UGPipeline($Config,[string]$SelectedAction){$script:calls++;$script:lastParams=New-UGPipelineParameters $Config $SelectedAction}
$r=Ready
$d=Invoke-UGExecution $r 'Probe' $false
Assert-True ($d.PlanOnly -and !$d.WillExecute -and $script:calls -eq 0) 'Default plan invoked the pipeline.'
$d=Invoke-UGExecution $r 'Check' $true
Assert-True (!$d.WillExecute -and $script:calls -eq 0) 'Check -Execute invoked the pipeline.'
foreach($bad in @('Source','USB','Secure Boot')){
    $r=Ready;($r.Checks | Where-Object Name -eq $bad).Status=if($bad -eq 'Secure Boot'){'UNKNOWN'}else{'BLOCKED'}
    $d=Invoke-UGExecution $r 'Probe' $true
    Assert-True (!$d.WillExecute -and $d.Blockers.Count -eq 1 -and $script:calls -eq 0) "Unsafe $bad did not block execution."
}
$r=Ready;$r.CaptureCount=1
Assert-True (!(Invoke-UGExecution $r 'Build' $true).WillExecute -and $script:calls -eq 0) 'One capture allowed Build.'
$r.CaptureCount=2
Assert-True (!(Invoke-UGExecution $r 'Probe' $true).WillExecute -and $script:calls -eq 0) 'Probe with two captures allowed unintended advancement.'
$d=Invoke-UGExecution $r 'Build' $true
Assert-True ($d.WillExecute -and $script:calls -eq 1 -and !$script:lastParams.ContainsKey('StageUnlock')) 'Build did not preserve separate staging.'
$d=Invoke-UGExecution $r 'StageUnlock' $true
Assert-True ($d.WillExecute -and $script:calls -eq 2 -and $script:lastParams.StageUnlock -eq $true -and $script:lastParams.Drive -eq 'Z') 'StageUnlock parameters incorrect.'
Assert-True ($script:UGPin -eq '75071aa134616c3d65ad315e0cf2810bf34b191b') 'Source pin changed.'
$p=[pscustomobject]@{DriveLetter='Z';IsSystem=$false;IsBoot=$false}
$disk=[pscustomobject]@{BusType='USB';IsSystem=$false;IsBoot=$false}
$vol=[pscustomobject]@{FileSystem='FAT32'}
Assert-True (Test-UGUsb $p $disk $vol 'C:') 'Valid USB rejected.'
$disk.IsBoot=$true
Assert-True (!(Test-UGUsb $p $disk $vol 'C:')) 'Boot disk accepted.'
$disk.IsBoot=$false;$disk.BusType='NVMe'
Assert-True (!(Test-UGUsb $p $disk $vol 'C:')) 'Internal data disk accepted.'
$disk.BusType='USB';$vol.FileSystem='NTFS'
Assert-True (!(Test-UGUsb $p $disk $vol 'C:')) 'Non-FAT32 accepted.'
$vol.FileSystem='FAT32';$p.IsSystem=$true
Assert-True (!(Test-UGUsb $p $disk $vol 'C:')) 'System partition accepted.'
$missing=Join-Path $PSScriptRoot 'this-source-checkout-does-not-exist'
Assert-True ((Get-UGRepositoryCheck $missing).Status -eq 'BLOCKED') 'Missing source checkout accepted.'
$runner=(Join-Path $PSScriptRoot '../Start.ps1').Replace("'","''")
$childCheck=@"
. '$runner'
function Get-UGReadiness { [pscustomobject]@{Checks=@((New-UGCheck 'Source' 'BLOCKED' 'fixture'));CaptureCount=0;Config=@{}} }
function Invoke-UGPipeline { Write-Output 'UNEXPECTED_PIPELINE'; exit 99 }
Invoke-UGMain @{Action='Probe';Execute=`$true;ReportPath=`$null}
"@
$childResult=@(& (Get-Process -Id $PID).Path -NoProfile -Command $childCheck 2>&1)
$childExit=$LASTEXITCODE
Assert-True ($childExit -ne 0 -and $childExit -ne 99 -and ($childResult -join ' ') -notmatch 'UNEXPECTED_PIPELINE') 'Blocked -Execute CLI did not fail without calling the pipeline.'
$ids=@(ConvertFrom-UGCandidateEnvelope ([pscustomobject]@{probe_device_ids=@('220410de','248410de')}))
Assert-True ($ids.Count -eq 2 -and $ids -contains '248410de' -and $ids -notcontains '220610de') 'Preliminary IDs were not derived from the envelope.'
$invalidEnvelopeRefused=$false
try {$null=ConvertFrom-UGCandidateEnvelope ([pscustomobject]@{probe_device_ids=@('all-RTX30')})} catch {$invalidEnvelopeRefused=$true}
Assert-True $invalidEnvelopeRefused 'Malformed candidate manifest accepted.'
function Video($Device,[string]$Name='NVIDIA fixture') {[pscustomobject]@{Name=$Name;PNPDeviceID=('PCI\VEN_10DE&DEV_'+$Device+'&SUBSYS_00000000\PRIVATE-INSTANCE')}}
$unsupported=Get-UGGpuAssessment @((Video '2206' 'NVIDIA GeForce RTX 3080')) $ids
Assert-True ($unsupported.Status -eq 'BLOCKED' -and $unsupported.Detail -match '2206') 'RTX3080 PCI2206 incorrectly accepted.'
$otherCandidate=Get-UGGpuAssessment @((Video '2484' 'NVIDIA GeForce RTX 3070')) $ids
Assert-True ($otherCandidate.Status -eq 'CANDIDATE' -and $otherCandidate.Status -ne 'PASS' -and $otherCandidate.Detail -match 'preliminary ID list only') 'A selected other GPU did not remain preliminary.'
$intel=[pscustomobject]@{Name='Intel fixture';PNPDeviceID='PCI\VEN_8086&DEV_1234\PRIVATE-INSTANCE'}
Assert-True ((Get-UGGpuAssessment @($intel,(Video '2484')) $ids).Status -eq 'CANDIDATE') 'One NVIDIA plus integrated non-NVIDIA display was rejected.'
$ambiguous=Get-UGGpuAssessment @((Video '2204'),(Video '2484')) $ids
Assert-True ($ambiguous.Status -eq 'BLOCKED' -and $ambiguous.Detail -match 'More than one') 'Multiple NVIDIA controllers accepted.'
$unknown=Get-UGGpuAssessment @([pscustomobject]@{Name='NVIDIA fixture';PNPDeviceID='unknown'}) $ids
Assert-True ($unknown.Status -eq 'UNKNOWN') 'Unknown NVIDIA PCI identity accepted.'
Assert-True ((Get-UGGpuAssessment @($intel) $ids).Status -eq 'BLOCKED') 'No NVIDIA controller accepted.'
Assert-True ((Get-UGGpuAssessment @() $ids).Status -eq 'UNKNOWN') 'Empty inventory incorrectly identified a target.'
Assert-True ((Get-UGGpuAssessment $null $ids).Status -eq 'UNKNOWN') 'Null inventory incorrectly identified a target.'
Assert-True ((Get-UGGpuCheck 'missing-source').Status -eq 'UNKNOWN') 'Unreadable pinned ID list did not produce UNKNOWN.'
$originalCandidateReader=(Get-Item Function:Get-UGCandidateIds).ScriptBlock
try {
    function Get-UGCandidateIds {return @('220410de','248410de')}
    Assert-True ((Get-UGGpuCheck 'mock-source').Status -eq 'UNKNOWN') 'Unavailable mocked CIM inventory did not produce UNKNOWN.'
} finally {Set-Item Function:Get-UGCandidateIds $originalCandidateReader}
$callsBefore=$script:calls
foreach($gpuCheck in @($unsupported,$unknown,$ambiguous)){
    foreach($selected in @('Probe','Build','StageUnlock')){
        $r=Ready;$r.Checks=@($r.Checks | Where-Object Name -ne 'GPU preliminary identity')+@($gpuCheck)
        $r.CaptureCount=if($selected -eq 'Probe'){0}else{2}
        $d=Invoke-UGExecution $r $selected $true
        Assert-True (!$d.WillExecute -and $script:calls -eq $callsBefore) "$selected bypassed an unsupported/unknown/ambiguous GPU."
    }
}
$r=Ready;$r.Checks=@($r.Checks | Where-Object Name -ne 'GPU preliminary identity')
Assert-True (!(Invoke-UGExecution $r 'Probe' $true).WillExecute -and $script:calls -eq $callsBefore) 'Missing GPU assessment bypassed the gate.'
$r=Ready;$r.Checks=@($r.Checks | Where-Object Name -ne 'GPU preliminary identity')+@($otherCandidate)
Assert-True ((Invoke-UGExecution $r 'Probe' $true).WillExecute -and $script:calls -eq ($callsBefore+1)) 'Preliminary candidate could not reach unchanged upstream checks.'
$good=ConvertFrom-UGDiagnostic "probe-pci-handles=00000001`r`ncapture-complete=1`r`n" 'DIAG00.TXT'
Assert-True ($good.Complete -and !$good.Reasons.Count) 'Complete native-format probe not recognized.'
$badText="PRIVATE-HOST PCI\VEN_10DE&DEV_2206\PRIVATE-INSTANCE`r`nincomplete reason=probe-unreviewed-envelope status=0x8000000000000003`r`ncapture-complete=0`r`n"
$badCapture=ConvertFrom-UGDiagnostic $badText 'DIAG01.TXT'
$badJson=$badCapture | ConvertTo-Json -Depth 4
Assert-True (!$badCapture.Complete -and $badCapture.Reasons[0] -match 'probe-unreviewed-envelope' -and $badJson -notmatch 'PRIVATE-HOST|PRIVATE-INSTANCE|VEN_10DE') 'Refusal extraction leaked raw hardware logs or lost the reason.'
$lfRefusal=ConvertFrom-UGDiagnostic "incomplete reason=probe-inventory status=0x8000000000000003`ncapture-complete=0`n" 'DIAG02.TXT'
Assert-True (!$lfRefusal.Complete -and $lfRefusal.Reasons[0] -match 'probe-inventory') 'LF-normalized refusal was not explained.'
$contradiction=ConvertFrom-UGDiagnostic ($badText+"probe-pci-handles=00000001`r`ncapture-complete=1`r`n") 'DIAG03.TXT'
Assert-True (!$contradiction.Complete) 'A refusal mixed with a success marker was counted complete.'
$failedEvidence=[pscustomobject]@{CompleteCount=0;Files=@($badCapture)}
$captureCheck=Get-UGCaptureCheck $failedEvidence
Assert-True ($captureCheck.Status -eq 'BLOCKED' -and $captureCheck.Detail -match 'probe-unreviewed-envelope') 'Unsupported capture was presented only as a reboot count.'
$r=Ready;$r.Checks+=@($captureCheck);$callsBefore=$script:calls
Assert-True ((Invoke-UGExecution $r 'Probe' $true).WillExecute -and $script:calls -eq ($callsBefore+1)) 'Reviewed candidate could not explicitly retry the read-only probe.'
$callsBefore=$script:calls;$r.CaptureCount=2
foreach($writeAction in @('Build','StageUnlock')){
    Assert-True (!(Invoke-UGExecution $r $writeAction $true).WillExecute -and $script:calls -eq $callsBefore) 'Refused evidence bypassed a write-build gate.'
}
$completeEvidence=[pscustomobject]@{CompleteCount=2;Files=@($good,$good,$badCapture)}
$captureCheck=Get-UGCaptureCheck $completeEvidence
Assert-True ($captureCheck.Status -eq 'INFO' -and !$captureCheck.RequiredFor.Count) 'Older failed captures incorrectly blocked two complete captures from upstream assessment.'
Write-Output "$script:passed runner checks passed; pipeline calls were mocked."
