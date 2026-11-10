# SPDX-License-Identifier: GPL-2.0-only

function Get-RtxPackagePaths($Targets) {
    'Probe.EFI'
    'Unlock.EFI'
    'assets/scrubber_ad10x.bin'
    foreach($family in @($Targets.Family | Sort-Object -Unique)) {
        if($family -cnotin @('ga102','ad102')){throw 'Unexpected firmware family.'}
        foreach($stem in @('booter_load','gsp_boot_desc','gsp_boot','fwimage','fwsignature')) {
            "assets/${stem}_${family}.bin"
        }
        "assets/v67-${family}-four-plm.bin"
    }
}

function Get-RtxTargetRows($Targets) {
    if(@($Targets).Count -notin @(1,2)){throw 'An exact one- or two-card NVIDIA inventory is required.'}
    $seen=@{}
    foreach($card in @($Targets | Sort-Object Bdf)) {
        if($card.Bdf -cnotmatch '^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$' -or
           $card.Device -cnotmatch '^[0-9a-f]{4}$' -or $card.Subsystem -cnotmatch '^[0-9a-f]{8}$' -or
           $seen.ContainsKey($card.Bdf)){throw 'Invalid or ambiguous RTX target identity.'}
        $seen[$card.Bdf]=$true
        "$($card.Bdf) $($card.Device) $($card.Subsystem)"
    }
}

function Get-RtxMediaFile([string]$Path) {
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Expected an ordinary file at $Path."
    }
    return $item
}

function Get-RtxMediaHash([string]$Path) {
    $item=Get-RtxMediaFile $Path
    return (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-RtxPackageReceipt([string]$Package,$Targets,$Engine) {
    $files=foreach($relative in @(Get-RtxPackagePaths $Targets)) {
        $path=Join-Path $Package $relative
        $item=Get-RtxMediaFile $path
        if($item.Length -le 0){throw "Empty build output: $relative"}
        [ordered]@{Path=$relative;Bytes=$item.Length;Sha256=(Get-RtxMediaHash $path)}
    }
    $receipt=[ordered]@{
        Format=1;EngineCommit=$Engine.SourceCommit;PatchSha256=$Engine.PatchSha256
        Nonce=[guid]::NewGuid().ToString('N');Targets=@($Targets);Files=@($files)
    }
    $path=Join-Path $Package 'kit-package.json'
    if(Test-Path -LiteralPath $path){throw 'This package already has a receipt.'}
    [IO.File]::WriteAllText($path,($receipt | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
}

function Get-RtxVerifiedPackage([string]$Package,$Targets,$Engine) {
    $root=Get-Item -LiteralPath $Package -Force -ErrorAction Stop
    $assets=Get-Item -LiteralPath (Join-Path $Package 'assets') -Force -ErrorAction Stop
    foreach($folder in @($root,$assets)) {
        if(!$folder.PSIsContainer -or ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Package and assets must be ordinary directories.'
        }
    }
    $receiptFile=Get-RtxMediaFile (Join-Path $Package 'kit-package.json')
    if($receiptFile.Length -gt 64KB){throw 'Invalid package receipt size.'}
    $receipt=Get-Content -LiteralPath $receiptFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if($receipt.Format -ne 1 -or $receipt.EngineCommit -cne $Engine.SourceCommit -or
       $receipt.PatchSha256 -cne $Engine.PatchSha256 -or $receipt.Nonce -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Package was built for a different engine revision. Rebuild it in a new work directory.'
    }
    if(((Get-RtxTargetRows $Targets) -join "`n") -cne ((Get-RtxTargetRows $receipt.Targets) -join "`n")) {
        throw 'The current NVIDIA cards differ from the build target. Build a package for this installed set.'
    }
    $expected=@(Get-RtxPackagePaths $Targets)
    if(@($receipt.Files).Count -ne $expected.Count){throw 'Package file list changed.'}
    foreach($relative in $expected) {
        $rows=@($receipt.Files | Where-Object Path -CEQ $relative)
        $path=Join-Path $Package $relative
        $item=Get-RtxMediaFile $path
        if($rows.Count -ne 1 -or $item.Length -le 0 -or $item.Length -ne $rows[0].Bytes -or
           (Get-RtxMediaHash $path) -cne $rows[0].Sha256) {throw "Package file did not match its receipt: $relative"}
    }
    return $receipt
}

function Get-RtxTargetFile($Receipt) {
    $rows=@("kit-v1 $($Receipt.Nonce)") + @(Get-RtxTargetRows $Receipt.Targets)
    return ($rows -join "`n")+"`n"
}

function Get-RtxUsbRoot([string]$Letter,[string]$ExpectedVolume) {
    $part=Get-Partition -DriveLetter $Letter -ErrorAction Stop
    $disk=Get-Disk -Number $part.DiskNumber -ErrorAction Stop
    $volume=Get-Volume -DriveLetter $Letter -ErrorAction Stop
    if($Letter -notmatch '^[D-Z]$' -or ($Letter+':') -eq $env:SystemDrive -or
       $disk.BusType -ne 'USB' -or $volume.FileSystem -ne 'FAT32' -or
       $part.IsSystem -or $part.IsBoot -or $disk.IsSystem -or $disk.IsBoot) {
        throw 'Use an existing FAT32 USB data volume. System and boot disks are refused.'
    }
    if($ExpectedVolume -and $volume.UniqueId -ne $ExpectedVolume){
        throw 'The selected USB changed. Refresh the drive list and select it again.'
    }
    return ($Letter.ToUpperInvariant()+':\')
}

function Assert-RtxUsbEntries([string]$Root,[string[]]$Allowed) {
    $directory=Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    if(!$directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Expected an ordinary directory at $Root."
    }
    foreach($entry in @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop)) {
        if($entry.Name -in @('System Volume Information','$RECYCLE.BIN') -and $entry.PSIsContainer -and
           !($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)){continue}
        if($entry.Name -notin $Allowed -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Unexpected entry on the dedicated RTX USB: $($entry.Name). Use a dedicated backed-up volume."
        }
    }
}

function Assert-RtxMediaTargets([string]$Path,$Receipt) {
    $target=Get-RtxMediaFile $Path
    if($target.Length -gt 256 -or
       [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($target.FullName)) -cne (Get-RtxTargetFile $Receipt)) {
        throw 'The USB target list does not match this package.'
    }
}

function Get-RtxMediaLayout([string]$Usb,$Receipt) {
    $files=@()
    if($null -ne $Receipt) {
        $files=@($Receipt.Files | Where-Object {$_.Path.StartsWith('assets/')})
    }
    $assetNames=@($files | ForEach-Object {[IO.Path]::GetFileName($_.Path)})
    Assert-RtxUsbEntries $Usb (@('EFI','kit-targets.txt','loader.log')+$assetNames)
    $efi=Join-Path $Usb 'EFI'
    $boot=Join-Path $efi 'BOOT'
    if(Test-Path -LiteralPath $efi){Assert-RtxUsbEntries $efi @('BOOT')}
    if(Test-Path -LiteralPath $boot){Assert-RtxUsbEntries $boot @('BOOTX64.EFI','RTX-UNLOCK.pending','RTX-PROBE.backup')}
    $layout=[pscustomobject]@{
        Boot=$boot; Live=Join-Path $boot 'BOOTX64.EFI'
        Pending=Join-Path $boot 'RTX-UNLOCK.pending'; Backup=Join-Path $boot 'RTX-PROBE.backup'
        Log=Join-Path $Usb 'loader.log'; AssetPaths=@()
        Owned=$false; LiveKind=''; HasPending=$false; HasBackup=$false
        HasLog=$false; AssetsComplete=$false
    }
    $targetPath=Join-Path $Usb 'kit-targets.txt'
    if(!(Test-Path -LiteralPath $targetPath)) {
        if(@($layout.Live,$layout.Pending,$layout.Backup,$layout.Log | Where-Object {Test-Path -LiteralPath $_}).Count -or
           @($assetNames | Where-Object {Test-Path -LiteralPath (Join-Path $Usb $_)}).Count) {
            throw 'The USB has files without a matching kit target list.'
        }
        return $layout
    }
    if($null -eq $Receipt){throw 'This USB has a kit target list. Open its matching local package first.'}
    Assert-RtxMediaTargets $targetPath $Receipt
    $layout.Owned=$true
    $probeHash=($Receipt.Files | Where-Object Path -CEQ 'Probe.EFI').Sha256
    $unlockHash=($Receipt.Files | Where-Object Path -CEQ 'Unlock.EFI').Sha256
    if(Test-Path -LiteralPath $layout.Live) {
        $hash=Get-RtxMediaHash $layout.Live
        if($hash -ceq $probeHash){$layout.LiveKind='Probe'}
        elseif($hash -ceq $unlockHash){$layout.LiveKind='Unlock'}
        else{throw 'The USB bootloader does not match this package.'}
    }
    if(Test-Path -LiteralPath $layout.Pending) {
        if((Get-RtxMediaHash $layout.Pending) -cne $unlockHash){throw 'The interrupted unlock staging file does not match this package.'}
        $layout.HasPending=$true
    }
    if(Test-Path -LiteralPath $layout.Backup) {
        if((Get-RtxMediaHash $layout.Backup) -cne $probeHash){throw 'The USB probe backup does not match this package.'}
        $layout.HasBackup=$true
    }
    if(($layout.LiveKind -eq 'Unlock' -and (!$layout.HasBackup -or $layout.HasPending)) -or
       ($layout.LiveKind -eq 'Probe' -and $layout.HasBackup) -or
       (!$layout.LiveKind -and $layout.HasPending -and !$layout.HasBackup)) {
        throw 'The USB boot files are in an unexpected combination.'
    }
    $layout.AssetPaths=@(foreach($file in $files) {
        $path=Join-Path $Usb ([IO.Path]::GetFileName($file.Path))
        if(Test-Path -LiteralPath $path) {
            if((Get-RtxMediaHash $path) -cne $file.Sha256){throw "An existing USB firmware file differs from this package: $($file.Path)."}
            $path
        }
    })
    $layout.AssetsComplete=$files.Count -gt 0 -and $layout.AssetPaths.Count -eq $files.Count
    if(Test-Path -LiteralPath $layout.Log) {
        if((Get-RtxMediaFile $layout.Log).Length -gt 4MB){throw 'Unexpected size for loader.log.'}
        $layout.HasLog=$true
    }
    return $layout
}

function New-RtxMediaStatus([string]$State,[string]$Title,[string]$Message,[bool]$HasLog=$false,[bool]$CanBootUnlock=$false,[bool]$CompleteHandoff=$false) {
    [pscustomobject]@{
        State=$State;Title=$Title;Message=$Message;HasLog=$HasLog
        CanBootUnlock=$CanBootUnlock;CompleteHandoff=$CompleteHandoff
    }
}

function Get-RtxLogRefusal([string]$Lines,[string]$Prefix) {
    if($Lines -cmatch ($Prefix+'KIT: target manifest (?:missing or unreadable|malformed|contains an unsupported family)$')) {
        return 'UEFI could not read or accept the USB target list. Refresh Setup and verify this USB before booting it again.'
    }
    if($Lines -cmatch ($Prefix+'KIT: live NVIDIA display set differs from the target manifest$')) {
        return 'UEFI saw a different NVIDIA GPU set than Windows. Check which cards the firmware initializes and keep the GPU layout unchanged.'
    }
    $gpu='KIT: (?<bdf>[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]) '
    $power=[regex]::Match($Lines,$Prefix+$gpu+'is in (?<power>D[123])\. Fully power off and check that firmware initializes this GPU before retrying\.$')
    if($power.Success){
        return "GPU $($power.Groups['bdf'].Value) is in $($power.Groups['power'].Value) in UEFI. Fully power off and check that firmware initializes this GPU."
    }
    $pci=[regex]::Match($Lines,$Prefix+$gpu+'PCI (?:I/O unavailable|identity unreadable or changed|power-management capability unavailable|power state unreadable)\.[^\n]{0,120}$')
    if($pci.Success){return "UEFI could not verify the PCI identity or power state of GPU $($pci.Groups['bdf'].Value). Check its firmware configuration and GPU layout."}
}

function Get-RtxCompletedTargets([string]$Lines,[string]$Prefix,$Targets) {
    $header=$Prefix+'TX: ===== target (?<index>[12])/(?<count>[12]): 10de:(?<device>[0-9a-f]{4}) @ (?<bdf>[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]) =====$'
    $complete=$Prefix+'SELECTOR RESULT: transaction complete$'
    $sections=[regex]::Matches($Lines,$header)
    $verdicts=[regex]::Matches($Lines,$complete)
    $expected=@{}
    foreach($target in $Targets){$expected[$target.Bdf]=$target.Device}
    $seen=@{}
    $completed=@()
    for($i=0;$i -lt $sections.Count;$i++) {
        $row=$sections[$i]
        $bdf=$row.Groups['bdf'].Value
        if($row.Groups['count'].Value -ne [string]$expected.Count -or
           $row.Groups['index'].Value -ne [string]($i+1) -or
           $expected[$bdf] -cne $row.Groups['device'].Value -or $seen.ContainsKey($bdf)){
            return $null
        }
        $seen[$bdf]=$true
        $end=if($i+1 -lt $sections.Count){$sections[$i+1].Index}else{$Lines.Length}
        $result=[regex]::Matches($Lines.Substring($row.Index,$end-$row.Index),$complete).Count
        if($result -gt 1){return $null}
        if($result -eq 1){$completed+=$bdf}
    }
    if($completed.Count -ne $verdicts.Count){return $null}
    return [pscustomobject]@{Completed=$completed}
}

function Get-RtxLogOutcome($Layout,$Receipt) {
    $isProbe=$Layout.LiveKind -eq 'Probe'
    $recovery='If Windows did not start or the GPU is missing, fully power off, remove the USB, and boot Windows Boot Manager.'
    $probeReady='Two required files verified. There is nothing to copy manually. Fully power off, select this UEFI USB in the one-time boot menu, then reopen Setup and refresh after Windows returns.'
    $unlockReady='Unlock files verified. Fully power off and select this UEFI USB in the one-time boot menu. Press Space or Enter to confirm, then refresh Setup in Windows.'
    if(!$Layout.HasLog) {
        if($isProbe){return New-RtxMediaStatus 'ProbeStaged' 'Probe USB ready' $probeReady}
        return New-RtxMediaStatus 'UnlockStaged' 'No unlock boot log' "Setup found no USB boot log. $recovery Restore the read-only probe before trying again."
    }
    $lines=[IO.File]::ReadAllText($Layout.Log).Replace("`r`n","`n")
    if([string]::IsNullOrWhiteSpace($lines)) {
        if($isProbe){return New-RtxMediaStatus 'ProbeStaged' 'Probe log is empty' "The probe result could not be verified. $recovery" $true}
        return New-RtxMediaStatus 'UnlockStaged' 'Unlock log is empty' "An empty log cannot confirm what happened during the EFI boot. $recovery" $true
    }

    $count=@($Receipt.Targets).Count
    $prefix='(?m)^(?:\[[^\n]*\][ \t]+(?:INFO[ \t]*:[ \t]+)?loader:[ \t]+)?'
    $modulePrefix='(?m)^(?:\[[^\n]*\][ \t]+(?:INFO[ \t]*:[ \t]+)?loader(?:::[a-z0-9_]+)*:[ \t]+)?'
    $probe=[regex]::Matches($lines,$prefix+'KIT-PROBE: (?<nonce>[0-9a-f]{32}) matched (?<count>[12])$')
    $unlock=[regex]::Matches($lines,$prefix+'KIT: (?<nonce>[0-9a-f]{32}) matched (?<count>[12]) target\(s\)$')
    $probeMatches=$probe.Count -eq 1 -and $unlock.Count -eq 0 -and
        $probe[0].Groups['nonce'].Value -ceq $Receipt.Nonce -and $probe[0].Groups['count'].Value -eq [string]$count
    $unlockMatches=$unlock.Count -eq 1 -and $probe.Count -eq 0 -and
        $unlock[0].Groups['nonce'].Value -ceq $Receipt.Nonce -and $unlock[0].Groups['count'].Value -eq [string]$count
    $handoff='CHAIN: StartImage -> handing control to the OS loader|CHAIN-PRE: start-time PE header probe ok - StartImage'
    $handoffFailed=$lines -match 'CHAIN: failed:|CHAIN: bootmgfw returned unexpectedly'
    $refusal=Get-RtxLogRefusal $lines $prefix

    if($isProbe) {
        if($refusal){return New-RtxMediaStatus 'ProbeStaged' 'Probe refused' $refusal $true}
        if($handoffFailed){return New-RtxMediaStatus 'ProbeStaged' 'Probe handoff failed' "The probe reported a Windows handoff failure. $recovery" $true}
        if($probeMatches) {
            if($lines.Substring($probe[0].Index) -match $handoff) {
                return New-RtxMediaStatus 'ProbePassed' 'Probe passed' 'The read-only probe matched every card, verified it was awake in UEFI, and started the Windows handoff.' $true
            }
            return New-RtxMediaStatus 'ProbeStaged' 'Probe handoff unconfirmed' "The probe matched the GPU set, but the log does not show a Windows handoff after that check. $recovery" $true
        }
        if($probe.Count -or $unlock.Count) {
            return New-RtxMediaStatus 'ProbeStaged' 'Probe result does not match' 'The boot log does not match this package or has conflicting results. Use this USB for a fresh read-only probe.' $true
        }
        return New-RtxMediaStatus 'ProbeStaged' 'Probe result incomplete' "The USB log has no complete result from this probe. Older DIAG files cannot verify this package. $recovery" $true
    }

    if($probeMatches -and !$refusal -and !$handoffFailed -and $lines.Substring($probe[0].Index) -match $handoff) {
        return New-RtxMediaStatus 'UnlockStaged' 'Unlock USB ready' "The USB still has its read-only probe log. $unlockReady $recovery" $true $true
    }
    $confirmationAborted=$lines -cmatch ($modulePrefix+'CONFIRM: [^\n]{1,120} - ABORT to Windows, NOTHING was unlocked this boot \(zero GPU writes\)$')
    if(!$unlockMatches) {
        if($confirmationAborted -and !$probe.Count -and !$unlock.Count) {
            return New-RtxMediaStatus 'UnlockStaged' 'Unlock not confirmed' "The EFI prompt timed out or received a key other than Space or Enter. $recovery" $true
        }
        if($refusal){return New-RtxMediaStatus 'UnlockStaged' 'Unlock refused' "$refusal $recovery" $true}
        if($lines -cmatch ($prefix+'KIT: transaction refused before any GPU write$')) {
            return New-RtxMediaStatus 'UnlockStaged' 'Unlock refused' "EFI refused the transaction before any GPU write. $recovery" $true
        }
        if($handoffFailed){return New-RtxMediaStatus 'UnlockStaged' 'Windows handoff failed' "The USB log reports a Windows handoff failure. $recovery" $true}
        if($unlock.Count -or $probe.Count) {
            return New-RtxMediaStatus 'UnlockStaged' 'Unlock result does not match' "The boot log does not match this package or has conflicting results. $recovery" $true
        }
        return New-RtxMediaStatus 'UnlockStaged' 'Unlock result unconfirmed' "The USB log has no matching EFI transaction result. $recovery" $true
    }

    $afterMatch=$lines.Substring($unlock[0].Index)
    $evidence=Get-RtxCompletedTargets $afterMatch $prefix $Receipt.Targets
    if($null -eq $evidence -or $confirmationAborted) {
        return New-RtxMediaStatus 'UnlockStaged' 'Unlock result does not match' "The log contains conflicting transaction records. $recovery" $true
    }
    $completed=$evidence.Completed.Count
    $summary="The EFI log records $completed of $count completed transactions."
    if($afterMatch -cmatch ($prefix+'FINAL: KIT-STOP: transaction failed:')) {
        return New-RtxMediaStatus 'UnlockLogged' 'Unlock stopped for recovery' "$summary The kit stopped before starting Windows. Fully power off, remove the USB, and start Windows Boot Manager. Save the log and restore the read-only probe." $true
    }
    if($handoffFailed){return New-RtxMediaStatus 'UnlockLogged' 'Windows handoff failed' "$summary The log reports a Windows handoff failure. $recovery" $true}
    $handoffStarted=$afterMatch -match $handoff
    $handoffMessage=if($handoffStarted){'Windows handoff started.'}else{'The log does not confirm a Windows handoff.'}
    if($completed -eq $count) {
        return New-RtxMediaStatus 'UnlockLogged' 'EFI transactions recorded' "$summary $handoffMessage Check the results in Windows." $true $false $handoffStarted
    }
    if($completed) {
        return New-RtxMediaStatus 'UnlockLogged' 'Partial unlock result' "$summary Completed in EFI: $($evidence.Completed -join ', '). $handoffMessage Check the results in Windows per GPU. $recovery" $true
    }
    if($afterMatch -cmatch ($prefix+'KIT: incomplete (?:ga102|ad102) assets; no card was touched$')) {
        return New-RtxMediaStatus 'UnlockLogged' 'Unlock refused' "EFI could not load all firmware assets. Verify the staged USB in Setup. $recovery" $true
    }
    if($refusal -or $afterMatch -cmatch ($prefix+'KIT: a target changed or D0 could not be confirmed; no card was touched$')) {
        return New-RtxMediaStatus 'UnlockLogged' 'Unlock refused' "The GPU identity or power state failed the transaction check. $recovery" $true
    }
    if($afterMatch -cmatch ($prefix+'TX: transaction failed: [^\n]{1,160} - NOT retrying this session$')) {
        return New-RtxMediaStatus 'UnlockLogged' 'Unlock transaction failed' "$summary EFI recorded a transaction failure. $recovery" $true
    }
    if($afterMatch -cmatch ($prefix+'TX: (?:aborted on warm/resume entry|refused \(EBUSY: WPR2 already initialized this power cycle\)|already unlocked / not cold \(EALREADY\))[^\n]{0,220}$')) {
        return New-RtxMediaStatus 'UnlockLogged' 'Unlock stopped at cold-state check' "$summary EFI refused or skipped a GPU that was not in the expected cold state. $recovery" $true
    }
    return New-RtxMediaStatus 'UnlockLogged' 'Unlock result incomplete' "$summary $handoffMessage $recovery" $true
}

function Get-RtxMediaStatus {
    param([Parameter(Mandatory)][string]$Usb,$Receipt)
    try {
        $layout=Get-RtxMediaLayout $Usb $Receipt
        if(!$layout.Owned){return New-RtxMediaStatus 'Empty' 'Ready to prepare the probe' 'Setup writes and verifies the read-only probe files on this USB.'}
        if(!$layout.LiveKind -or $layout.HasPending -or
           ($layout.LiveKind -eq 'Probe' -and $layout.AssetPaths.Count) -or
           ($layout.LiveKind -eq 'Unlock' -and !$layout.AssetsComplete)) {
            return New-RtxMediaStatus 'Recoverable' 'Restore the probe to resume' 'This package has an incomplete USB layout. Restore the read-only probe before booting it.' $layout.HasLog
        }
        return Get-RtxLogOutcome $layout $Receipt
    } catch {
        $message=$_.Exception.Message
        $hasLog=$false
        try {$hasLog=(Get-RtxMediaFile (Join-Path $Usb 'loader.log')).Length -le 4MB} catch {}
        return New-RtxMediaStatus 'Blocked' 'USB needs attention' $message $hasLog
    }
}

function Copy-RtxVerifiedFile([string]$Source,[string]$Target,[string]$Expected) {
    if(!(Test-Path -LiteralPath $Target)){[IO.File]::Copy($Source,$Target,$false)}
    if((Get-RtxMediaHash $Target) -cne $Expected){throw "USB copy verification failed: $Target"}
}

function Publish-RtxProbe([string]$Usb,[string]$Package,$Receipt) {
    Assert-RtxUsbEntries $Usb @('EFI','kit-targets.txt','loader.log')
    $targetPath=Join-Path $Usb 'kit-targets.txt'
    if(Test-Path -LiteralPath $targetPath) {
        Assert-RtxMediaTargets $targetPath $Receipt
    } elseif(Test-Path -LiteralPath (Join-Path $Usb 'loader.log')) {throw 'Choose a fresh dedicated USB for this package.'}
    $efi=Join-Path $Usb 'EFI'
    $boot=Join-Path $Usb 'EFI/BOOT'
    if(Test-Path -LiteralPath $efi){Assert-RtxUsbEntries $efi @('BOOT')}
    if(Test-Path -LiteralPath $boot){Assert-RtxUsbEntries $boot @('BOOTX64.EFI')}
    $hash=($Receipt.Files | Where-Object Path -CEQ 'Probe.EFI').Sha256
    $loader=Join-Path $boot 'BOOTX64.EFI'
    if((Test-Path -LiteralPath $loader) -and (Get-RtxMediaHash $loader) -cne $hash) {
        throw 'The USB already has a different bootloader. Use a dedicated backed-up volume.'
    }
    [void][IO.Directory]::CreateDirectory($boot)
    if(!(Test-Path -LiteralPath $targetPath)) {
        [IO.File]::WriteAllText($targetPath,(Get-RtxTargetFile $Receipt),[Text.Encoding]::ASCII)
    }
    Copy-RtxVerifiedFile (Join-Path $Package 'Probe.EFI') $loader $hash
}

function Assert-RtxProbeBoot([string]$Usb,$Receipt) {
    $layout=Get-RtxMediaLayout $Usb $Receipt
    if(!$layout.Owned -or $layout.LiveKind -ne 'Probe') {
        throw 'The USB bootloader does not match the read-only probe for this package.'
    }
    $outcome=Get-RtxLogOutcome $layout $Receipt
    if($outcome.State -ne 'ProbePassed') {
        throw "A verified read-only probe is required before staging. $($outcome.Title). $($outcome.Message)"
    }
}

function Publish-RtxUnlock([string]$Usb,[string]$Package,$Receipt) {
    Assert-RtxProbeBoot $Usb $Receipt
    $boot=Join-Path $Usb 'EFI/BOOT'
    foreach($file in @($Receipt.Files | Where-Object {$_.Path.StartsWith('assets/')})) {
        Copy-RtxVerifiedFile (Join-Path $Package $file.Path) (Join-Path $Usb ([IO.Path]::GetFileName($file.Path))) $file.Sha256
    }
    $live=Join-Path $boot 'BOOTX64.EFI'
    $pending=Join-Path $boot 'RTX-UNLOCK.pending'
    $backup=Join-Path $boot 'RTX-PROBE.backup'
    $hash=($Receipt.Files | Where-Object Path -CEQ 'Unlock.EFI').Sha256
    Copy-RtxVerifiedFile (Join-Path $Package 'Unlock.EFI') $pending $hash
    [IO.File]::Move($live,$backup)
    try { [IO.File]::Move($pending,$live) }
    catch { [IO.File]::Move($backup,$live);throw }
}

function Publish-RtxRestoreProbe([string]$Usb,[string]$Package,$Receipt) {
    $layout=Get-RtxMediaLayout $Usb $Receipt
    if(!$layout.Owned){throw 'The USB does not belong to this kit package.'}
    $probeHash=($Receipt.Files | Where-Object Path -CEQ 'Probe.EFI').Sha256
    $source=Join-Path $Package 'Probe.EFI'
    if((Get-RtxMediaHash $source) -cne $probeHash){throw 'The local read-only probe differs from the receipt.'}
    # Invalidate prior boot evidence before touching the EFI or any asset.
    if($layout.HasLog){Remove-Item -LiteralPath $layout.Log -ErrorAction Stop}
    if($layout.LiveKind -eq 'Unlock'){[IO.File]::Move($layout.Live,$layout.Pending)}
    if($layout.LiveKind -ne 'Probe') {
        if($layout.HasBackup){[IO.File]::Move($layout.Backup,$layout.Live)}
        else {
            [void][IO.Directory]::CreateDirectory($layout.Boot)
            Copy-RtxVerifiedFile $source $layout.Live $probeHash
        }
    }
    if((Get-RtxMediaHash $layout.Live) -cne $probeHash){throw 'The restored probe failed verification.'}
    if($layout.HasPending -or $layout.LiveKind -eq 'Unlock'){Remove-Item -LiteralPath $layout.Pending -ErrorAction Stop}
    foreach($path in $layout.AssetPaths){Remove-Item -LiteralPath $path -ErrorAction Stop}
}
