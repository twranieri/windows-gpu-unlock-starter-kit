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

function Get-RtxUsbRoot([string]$Letter) {
    $part=Get-Partition -DriveLetter $Letter -ErrorAction Stop
    $disk=Get-Disk -Number $part.DiskNumber -ErrorAction Stop
    $volume=Get-Volume -DriveLetter $Letter -ErrorAction Stop
    if($Letter -notmatch '^[D-Z]$' -or ($Letter+':') -eq $env:SystemDrive -or
       $disk.BusType -ne 'USB' -or $volume.FileSystem -ne 'FAT32' -or
       $part.IsSystem -or $part.IsBoot -or $disk.IsSystem -or $disk.IsBoot) {
        throw 'Use an existing FAT32 USB data volume. System and boot disks are refused.'
    }
    return ($Letter.ToUpperInvariant()+':\')
}

function Assert-RtxUsbEntries([string]$Root,[string[]]$Allowed) {
    foreach($entry in @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop)) {
        if($entry.Name -in @('System Volume Information','$RECYCLE.BIN') -and $entry.PSIsContainer){continue}
        if($entry.Name -notin $Allowed -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Unexpected entry on the dedicated RTX USB: $($entry.Name). Use a dedicated backed-up volume."
        }
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
        $target=Get-RtxMediaFile $targetPath
        if($target.Length -gt 256 -or [IO.File]::ReadAllText($target.FullName) -cne (Get-RtxTargetFile $Receipt)) {
            throw 'The USB already has a target list from a different package.'
        }
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
    $files=@($Receipt.Files | Where-Object {$_.Path.StartsWith('assets/')})
    $assetNames=@($files | ForEach-Object {[IO.Path]::GetFileName($_.Path)})
    Assert-RtxUsbEntries $Usb (@('EFI','kit-targets.txt','loader.log')+$assetNames)
    foreach($file in $files) {
        $existing=Join-Path $Usb ([IO.Path]::GetFileName($file.Path))
        if((Test-Path -LiteralPath $existing) -and (Get-RtxMediaHash $existing) -cne $file.Sha256) {
            throw 'An existing USB firmware file differs from this package.'
        }
    }
    Assert-RtxUsbEntries (Join-Path $Usb 'EFI') @('BOOT')
    $boot=Join-Path $Usb 'EFI/BOOT'
    Assert-RtxUsbEntries $boot @('BOOTX64.EFI','RTX-UNLOCK.pending')
    $pending=Join-Path $boot 'RTX-UNLOCK.pending'
    if((Test-Path -LiteralPath $pending) -and (Get-RtxMediaHash $pending) -cne ($Receipt.Files | Where-Object Path -CEQ 'Unlock.EFI').Sha256) {
        throw 'An interrupted staging file differs from this package.'
    }
    $target=Get-RtxMediaFile (Join-Path $Usb 'kit-targets.txt')
    if($target.Length -gt 256 -or [IO.File]::ReadAllText($target.FullName) -cne (Get-RtxTargetFile $Receipt)) {
        throw 'The USB target list does not match this build. Stage the read-only probe on a dedicated volume.'
    }
    if((Get-RtxMediaHash (Join-Path $boot 'BOOTX64.EFI')) -cne ($Receipt.Files | Where-Object Path -CEQ 'Probe.EFI').Sha256) {
        throw 'The USB bootloader does not match the read-only probe for this package.'
    }
    $log=Get-RtxMediaFile (Join-Path $Usb 'loader.log')
    if($log.Length -gt 4MB){throw 'Unexpected size for the read-only probe log.'}
    $lines=[IO.File]::ReadAllText($log.FullName).Replace("`r`n","`n")
    $expected='KIT-PROBE: '+$Receipt.Nonce+' matched '+@($Receipt.Targets).Count
    if([regex]::Matches($lines,('(?m)'+[regex]::Escape($expected)+'$')).Count -ne 1 -or
       $lines -notmatch '(?m)CHAIN: StartImage -> handing control to the OS loader|CHAIN-PRE: start-time PE header probe ok - StartImage' -or
       $lines -match '(?m)CHAIN: failed:|CHAIN: bootmgfw returned unexpectedly') {
        throw 'The current read-only USB probe did not record matching cards and an OS handoff. Review loader.log before staging.'
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
