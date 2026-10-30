# SPDX-License-Identifier: GPL-2.0-only
# Mocked coordinator checks: no firmware, USB, boot, GPU or security writes.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../Start.ps1')
$script:passed=0
function Assert-True($Value,$Message){if(!$Value){throw $Message};$script:passed++}
function Ready {
    [pscustomobject]@{Checks=@((New-UGCheck 'Source' 'PASS' 'fixture'),(New-UGCheck 'USB' 'PASS' 'fixture'),(New-UGCheck 'Secure Boot' 'PASS' 'fixture'));CaptureCount=0;Config=@{Repo='fixture';Drive='Z';WindowsEspGuid=[guid]'00000000-0000-0000-0000-000000000001';Assets='assets';Python='python';Clang='clang';LldLink='lld-link';VcVars='vcvars'}}
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
Write-Output "$script:passed runner checks passed; pipeline calls were mocked."
