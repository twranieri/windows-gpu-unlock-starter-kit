# SPDX-License-Identifier: GPL-2.0-only
# Uses ordinary temp folders and placeholder bytes. No real USB, EFI or GPU access.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../rtx/Media.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('rtx-media-test-'+[guid]::NewGuid().ToString('N'))
$usb=Join-Path $root 'usb'
$package=Join-Path $root 'package'
[void][IO.Directory]::CreateDirectory($usb)
[void][IO.Directory]::CreateDirectory((Join-Path $package 'assets'))
$targets=@(
    [pscustomobject]@{Bdf='0000:01:00.0';Device='2206';Subsystem='38901462';Family='ga102';MemoryMiB=10240},
    [pscustomobject]@{Bdf='0000:04:00.0';Device='2783';Subsystem='41001458';Family='ad102';MemoryMiB=12288}
)
$engine=@{SourceCommit=('0'*40);PatchSha256=('0'*64)}
foreach($relative in @(Get-RtxPackagePaths $targets)) {
    [IO.File]::WriteAllText((Join-Path $package $relative),$relative)
}
function Assert-Refused([scriptblock]$Run,[string]$Why) {
    $refused=$false
    try{& $Run}catch{$refused=$true}
    if(!$refused){throw $Why}
}
function Assert-State([string]$Expected,$Receipt) {
    $actual=Get-RtxMediaStatus -Usb $usb -Receipt $Receipt
    if($actual.State -cne $Expected){throw "Expected media state $Expected, got $($actual.State). $($actual.Message)"}
    return $actual
}
function Assert-Outcome([string]$State,[string]$Title,[bool]$HasLog,$Receipt,[bool]$CanBootUnlock=$false) {
    $actual=Assert-State $State $Receipt
    if($actual.Title -cne $Title -or $actual.HasLog -ne $HasLog -or $actual.CanBootUnlock -ne $CanBootUnlock) {
        throw "Unexpected media outcome: $($actual | ConvertTo-Json -Compress)"
    }
    return $actual
}
try {
    $null=Assert-State 'Empty' $null
    New-RtxPackageReceipt $package $targets $engine
    $receipt=Get-RtxVerifiedPackage $package $targets $engine
    if($receipt.Files.Count -ne 15){throw 'Mixed package should contain two loaders and thirteen assets.'}
    $updatedTargets=@($targets | Select-Object *)
    $updatedTargets[0].MemoryMiB=$null
    $updatedTargets[1].MemoryMiB=11788
    $reused=Get-RtxVerifiedPackage $package $updatedTargets $engine
    if($reused.Nonce -cne $receipt.Nonce -or (Get-RtxTargetFile $reused) -cne (Get-RtxTargetFile $receipt)) {
        throw 'Changed or missing Windows memory telemetry affected the package receipt or target manifest.'
    }
    $updatedTargets[0].Subsystem='38911462'
    Assert-Refused {Get-RtxVerifiedPackage $package $updatedTargets $engine} 'Package admitted a changed subsystem with unavailable memory.'
    Assert-Refused {Get-RtxVerifiedPackage $package @($targets[0]) $engine} 'Package admitted a changed live target set.'
    Publish-RtxProbe $usb $package $receipt
    Publish-RtxProbe $usb $package $receipt
    $boot=Join-Path $usb 'EFI/BOOT/BOOTX64.EFI'
    $pending=Join-Path $usb 'EFI/BOOT/RTX-UNLOCK.pending'
    $backup=Join-Path $usb 'EFI/BOOT/RTX-PROBE.backup'
    if([IO.File]::ReadAllText($boot) -cne 'Probe.EFI' -or (Get-ChildItem -LiteralPath $usb -Filter '*.bin').Count){
        throw 'Probe staging copied something other than the read-only loader and target list.'
    }
    $null=Assert-State 'Blocked' $null
    $ready=Assert-Outcome 'ProbeStaged' 'Probe USB ready' $false $receipt
    if($ready.Failed){throw 'Waiting for the first probe boot must not trigger a failure report.'}
    if($ready.Message -notmatch 'Two required files verified.*nothing to copy manually.*one-time boot menu') {
        throw 'Probe readiness did not explain USB files and the one-time boot menu.'
    }
    Assert-Refused {Publish-RtxUnlock $usb $package $receipt} 'Missing probe boot authorized staging.'
    $log=Join-Path $usb 'loader.log'
    $handoff='CHAIN: StartImage -> handing control to the OS loader'
    [IO.File]::WriteAllText($log,'')
    $empty=Assert-Outcome 'ProbeStaged' 'Probe log is empty' $true $receipt
    if(!$empty.Failed){throw 'An empty probe log must trigger a failure report.'}
    Assert-Refused {Publish-RtxUnlock $usb $package $receipt} 'Empty probe log authorized staging.'
    [IO.File]::WriteAllText($log,"private sample`nincomplete reason=probe-unreviewed-envelope`ncapture-complete=0`n")
    $legacy=Assert-Outcome 'ProbeStaged' 'Probe result incomplete' $true $receipt
    if($legacy.Message -match 'private sample|probe-unreviewed-envelope'){throw 'Legacy log text leaked into status.'}
    Assert-Refused {Publish-RtxUnlock $usb $package $receipt} 'Legacy diagnostic authorized staging.'
    foreach($case in @(
        @{Line='KIT: target manifest malformed';Hint='USB target list'},
        @{Line='KIT: live NVIDIA display set differs from the target manifest';Hint='different NVIDIA GPU set'}
    )) {
        [IO.File]::WriteAllText($log,"[1ms] INFO : loader: $($case.Line)`n$handoff`n")
        $reason=Assert-Outcome 'ProbeStaged' 'Probe refused' $true $receipt
        if($reason.Message -notmatch $case.Hint){throw 'Probe refusal reason was not surfaced.'}
        Assert-Refused {Publish-RtxUnlock $usb $package $receipt} 'A probe refusal authorized staging.'
    }
    [IO.File]::WriteAllText($log,"[1ms] INFO : loader: KIT: 0000:04:00.0 is in D3. Fully power off and check that firmware initializes this GPU before retrying.`n$handoff`n")
    $coldFailure=Assert-Outcome 'ProbeStaged' 'Probe refused' $true $receipt
    if($coldFailure.Message -notmatch '0000:04:00.0 is in D3'){
        throw 'The preflight power-state reason was not surfaced.'
    }
    Assert-Refused {Publish-RtxUnlock $usb $package $receipt} 'A non-D0 probe authorized staging.'
    [IO.File]::WriteAllText($log,"KIT-PROBE: $('1'*32) matched 2`n$handoff`n")
    $null=Assert-Outcome 'ProbeStaged' 'Probe result does not match' $true $receipt
    Assert-Refused {Publish-RtxUnlock $usb $package $receipt} 'Stale probe authorized staging.'
    $probeLine="[1ms] INFO : loader: KIT-PROBE: $($receipt.Nonce) matched 2"
    [IO.File]::WriteAllText($log,"$handoff`n$probeLine`n")
    $null=Assert-Outcome 'ProbeStaged' 'Probe handoff unconfirmed' $true $receipt
    Assert-Refused {Publish-RtxUnlock $usb $package $receipt} 'Handoff preceding the probe authorized staging.'
    [IO.File]::WriteAllText($log,"$probeLine`n$handoff`nCHAIN: failed: EFI_DEVICE_ERROR`n")
    $null=Assert-Outcome 'ProbeStaged' 'Probe handoff failed' $true $receipt
    Assert-Refused {Publish-RtxUnlock $usb $package $receipt} 'An explicit handoff failure authorized staging.'
    [IO.File]::WriteAllText($log,"$probeLine`nKIT: $('1'*32) matched 2 target(s)`n$handoff`n")
    $null=Assert-Outcome 'ProbeStaged' 'Probe result does not match' $true $receipt
    Assert-Refused {Publish-RtxUnlock $usb $package $receipt} 'Conflicting historical transaction authorized staging.'
    [IO.File]::WriteAllText($log,"$probeLine`n$handoff`n")
    $null=Assert-Outcome 'ProbePassed' 'Probe passed' $true $receipt
    $armed=Join-Path $usb 'i_know_what_i_am_doing.txt'
    [IO.File]::WriteAllText($armed,'5')
    $null=Assert-Outcome 'Blocked' 'USB needs attention' $true $receipt
    Assert-Refused {Publish-RtxUnlock $usb $package $receipt} 'An automatic unlock marker was accepted.'
    Remove-Item -LiteralPath $armed
    $partial=Join-Path $usb 'gsp_boot_ga102.bin'
    [IO.File]::WriteAllText($partial,'tampered')
    $null=Assert-State 'Blocked' $receipt
    Assert-Refused {Publish-RtxUnlock $usb $package $receipt} 'A stale firmware asset was accepted.'
    Assert-Refused {Publish-RtxRestoreProbe $usb $package $receipt} 'Restore accepted an altered asset.'
    if([IO.File]::ReadAllText($partial) -cne 'tampered'){throw 'Refused restore modified the altered asset.'}
    [IO.File]::Copy((Join-Path $package 'assets/gsp_boot_ga102.bin'),$partial,$true)
    [IO.File]::Copy((Join-Path $package 'Unlock.EFI'),$pending)
    $null=Assert-State 'Recoverable' $receipt
    Publish-RtxUnlock $usb $package $receipt
    if([IO.File]::ReadAllText($boot) -cne 'Unlock.EFI' -or
       [IO.File]::ReadAllText($backup) -cne 'Probe.EFI' -or
       @(Get-ChildItem -LiteralPath $usb -Filter '*.bin').Count -ne 13){throw 'Unlock staging or probe backup is incomplete.'}
    $null=Assert-Outcome 'UnlockStaged' 'Unlock USB ready' $true $receipt $true
    Remove-Item -LiteralPath $log
    $null=Assert-Outcome 'UnlockStaged' 'No unlock boot log' $false $receipt
    [IO.File]::WriteAllText($log,'')
    $empty=Assert-Outcome 'UnlockStaged' 'Unlock log is empty' $true $receipt
    if($empty.Message -notmatch 'cannot confirm.*Windows Boot Manager'){throw 'Empty unlock log did not explain uncertainty and recovery.'}
    [IO.File]::WriteAllText($log,"[1ms] INFO : loader::keywait: CONFIRM: 30s timeout - ABORT to Windows, NOTHING was unlocked this boot (zero GPU writes)`n$handoff`n")
    $null=Assert-Outcome 'UnlockStaged' 'Unlock not confirmed' $true $receipt
    $txLine="[2ms] INFO : loader: KIT: $($receipt.Nonce) matched 2 target(s)"
    [IO.File]::WriteAllText($log,"$txLine`n[3ms] INFO : loader: KIT: incomplete ga102 assets; no card was touched`n$handoff`n")
    $null=Assert-Outcome 'UnlockLogged' 'Unlock refused' $true $receipt
    [IO.File]::WriteAllText($log,"$txLine`n[3ms] INFO : loader: TX: transaction failed: PRIVATE-REASON - NOT retrying this session`n$handoff`n")
    $failure=Assert-Outcome 'UnlockLogged' 'Unlock transaction failed' $true $receipt
    if($failure.Message -match 'PRIVATE-REASON'){throw 'Raw transaction error leaked into status.'}
    $target1='[3ms] INFO : loader: TX: ===== target 1/2: 10de:2206 @ 0000:01:00.0 ====='
    $target2='[7ms] INFO : loader: TX: ===== target 2/2: 10de:2783 @ 0000:04:00.0 ====='
    $complete='[5ms] INFO : loader: SELECTOR RESULT: transaction complete'
    [IO.File]::WriteAllText($log,"$txLine`n$complete`n$handoff`n")
    $null=Assert-Outcome 'UnlockStaged' 'Unlock result does not match' $true $receipt
    [IO.File]::WriteAllText($log,"$txLine`n$target1`n$complete`n$complete`n$handoff`n")
    $null=Assert-Outcome 'UnlockStaged' 'Unlock result does not match' $true $receipt
    $wrongDevice=$target2.Replace('10de:2783','10de:2782')
    [IO.File]::WriteAllText($log,"$txLine`n$target1`n$complete`n$wrongDevice`n$complete`n$handoff`n")
    $null=Assert-Outcome 'UnlockStaged' 'Unlock result does not match' $true $receipt
    $sameCard=$target1.Replace('1/2','2/2')
    [IO.File]::WriteAllText($log,"$txLine`n$target1`n$complete`n$sameCard`n$complete`n$handoff`n")
    $null=Assert-Outcome 'UnlockStaged' 'Unlock result does not match' $true $receipt
    [IO.File]::WriteAllText($log,"$txLine`n$target1`n$complete`n$target2`n$handoff`n")
    $outcome=Assert-Outcome 'UnlockLogged' 'Partial unlock result' $true $receipt
    if($outcome.Message -notmatch '1 of 2' -or $outcome.Message -notmatch '0000:01:00.0' -or
       $outcome.Message -notmatch 'Check the results in Windows') {
        throw 'Status did not distinguish a partial EFI result from the Windows outcome.'
    }
    [IO.File]::WriteAllText($log,"$txLine`n$target1`n$complete`n$target2`n$complete`n$handoff`n")
    $full=Assert-Outcome 'UnlockLogged' 'EFI transactions recorded' $true $receipt
    if($full.Failed){throw 'A complete unlock and handoff must not trigger a failure report.'}
    if(!$full.CompleteHandoff){throw 'Completed target results and handoff were not exposed as typed evidence.'}
    [IO.File]::WriteAllText($log,"$txLine`n$target1`n$complete`n$target2`n$complete`n")
    $withoutHandoff=Assert-Outcome 'UnlockLogged' 'EFI transactions recorded' $true $receipt
    if(!$withoutHandoff.Failed){throw 'An unconfirmed handoff must trigger a failure report.'}
    if($withoutHandoff.CompleteHandoff){throw 'A completed transaction without handoff authorized benchmark evidence.'}
    [IO.File]::WriteAllText($log,"$txLine`n$target1`n$complete`n$target2`n[9ms] INFO : loader: FINAL: KIT-STOP: transaction failed: PRIVATE-REASON. Attempting emergency reset.`n")
    $stopped=Assert-Outcome 'UnlockLogged' 'Unlock stopped for recovery' $true $receipt
    if($stopped.Message -notmatch 'power off.*Windows Boot Manager' -or $stopped.Message -match 'PRIVATE-REASON') {
        throw 'A stopped transaction did not explain recovery safely.'
    }
    Publish-RtxRestoreProbe $usb $package $receipt
    Publish-RtxRestoreProbe $usb $package $receipt
    $null=Assert-State 'ProbeStaged' $receipt
    if((Test-Path -LiteralPath $backup) -or (Test-Path -LiteralPath $pending) -or
       (Test-Path -LiteralPath $log) -or @(Get-ChildItem -LiteralPath $usb -Filter '*.bin').Count) {
        throw 'Restore did not clear verified transaction files and old boot evidence.'
    }
    Assert-Refused {Publish-RtxUnlock $usb $package $receipt} 'Restored media reused prior probe authorization.'

    # Power loss after moving the probe aside leaves no live EFI.
    [IO.File]::WriteAllText($log,"$probeLine`n$handoff`n")
    [IO.File]::Copy((Join-Path $package 'Unlock.EFI'),$pending)
    [IO.File]::Move($boot,$backup)
    $null=Assert-State 'Recoverable' $receipt
    Publish-RtxRestoreProbe $usb $package $receipt
    $null=Assert-State 'ProbeStaged' $receipt
    if((Test-Path -LiteralPath $backup) -or (Test-Path -LiteralPath $pending) -or
       (Test-Path -LiteralPath $log) -or [IO.File]::ReadAllText($boot) -cne 'Probe.EFI') {
        throw 'The interrupted rename did not restore the verified probe.'
    }
    'PASS RTX media contract: exact targets, verified USB files, distinct probe/transaction outcomes, no raw log exposure, strict staging, interrupted rename and probe restore.'
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(!$resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or
       ![IO.Path]::GetFileName($resolved).StartsWith('rtx-media-test-')){throw 'Refusing cleanup outside the media test folder.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
