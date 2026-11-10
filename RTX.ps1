# SPDX-License-Identifier: GPL-2.0-only
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Check','Status','Build','Prepare','Probe','StageUnlock','RestoreProbe','FixFastStartup','DisableEncryption','FormatUsb')][string]$Action='Check',
    [ValidatePattern('^[D-Zd-z]$')][string]$Drive,
    [string]$VolumeId,
    [string]$WorkDirectory,
    [string]$Cargo='cargo',
    [string]$Inputs,
    [switch]$Desktop,
    [string]$DesktopBuild,
    [switch]$UsePrebuilt,
    [switch]$Execute
)

$ErrorActionPreference='Stop'
if($MyInvocation.InvocationName -ne '.' -and $Desktop -and $DesktopBuild -cne '0.4.0.9') {
    throw 'Setup executable and scripts are from different builds. Extract the whole matching ZIP into a new local folder and open Setup there.'
}
if(!$WorkDirectory){$WorkDirectory=Join-Path $PSScriptRoot '.local/rtx'}
. (Join-Path $PSScriptRoot 'rtx/Inventory.ps1')
. (Join-Path $PSScriptRoot 'rtx/Build.ps1')
. (Join-Path $PSScriptRoot 'rtx/Media.ps1')
. (Join-Path $PSScriptRoot 'rtx/WindowsPrep.ps1')

function Get-RtxBootProblems($Preparation) {
    if($null -eq $Preparation){$Preparation=Get-RtxWindowsPreparation}
    if(![Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
        'An x64 Windows PowerShell is required.'
    }
    if($Preparation.FirmwareState -eq 'SecureBootOn'){'Secure Boot must be disabled for the experimental EFI.'}
    elseif($Preparation.FirmwareState -ne 'Ready'){'Could not verify UEFI, the Windows EFI partition, and Secure Boot. Use administrator PowerShell.'}
    if($Preparation.EncryptionState -eq 'Unknown' -or $Preparation.ProtectionState -eq 'Unknown'){
        'Could not verify BitLocker state. Use administrator PowerShell.'
    } elseif($Preparation.EncryptionState -eq 'DecryptionInProgress') {
        "Windows volume decryption is in progress. $($Preparation.EncryptionPercentage)% remains encrypted. Refresh after it reaches 0%."
    } elseif($Preparation.EncryptionState -eq 'DecryptionPaused') {
        'Windows volume decryption is paused. Resume it in Windows and wait for it to finish.'
    } elseif($Preparation.EncryptionState -ne 'FullyDecrypted' -or $Preparation.ProtectionState -ne 'Off' -or
             $Preparation.EncryptionPercentage -ne 0) {
        'The Windows volume must be fully decrypted with BitLocker protection off.'
    }
    if($Preparation.FastStartupState -eq 'Enabled'){'Disable Windows Fast Startup before collecting a cold probe.'}
    elseif($Preparation.FastStartupState -eq 'ManagedEnabled'){'Windows policy requires Fast Startup. Contact the Windows administrator to review that policy before boot preparation.'}
    elseif($Preparation.FastStartupState -ne 'Disabled'){'Could not verify Windows Fast Startup.'}
}

function Get-RtxDesktopWork($Targets) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        $bytes=[Text.Encoding]::ASCII.GetBytes((Get-RtxTargetRows $Targets) -join "`n")
        $key=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()
    } finally {$sha.Dispose()}
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('Windows GPU Unlock/0.4.0/'+$key.Substring(0,24))
}

function Get-RtxPackagePath([string]$WorkPath,[bool]$UseDesktopWork) {
    $name=if($UseDesktopWork){'package-v0.4.0-preview.3'}else{'package'}
    Join-Path $WorkPath $name
}

function Get-RtxRecentWindowsStarts {
    $filter=@{LogName='System';ProviderName='Microsoft-Windows-Kernel-General';Id=12}
    foreach($event in @(Get-WinEvent -FilterHashtable $filter -MaxEvents 2 -ErrorAction Stop)) {
        $xml=[xml]$event.ToXml()
        $field=$xml.Event.EventData.Data | Where-Object Name -EQ 'StartTime'
        $time=[DateTimeOffset]::MinValue
        if(![DateTimeOffset]::TryParse([string]$field.'#text',[Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal,[ref]$time)) {
            throw 'Windows startup event has no valid start time.'
        }
        $time.UtcDateTime
    }
}

function Get-RtxBenchmarkBootEvidence([string]$Letter,[string]$VolumeId,$Targets) {
    $evidence=[pscustomobject]@{
        Confirmed=$false; BootId=''; LogId=''
        Message='Windows did not report its startup time. Restart Windows before running the benchmark.'
    }
    try {
        $started=(Get-CimInstance Win32_OperatingSystem -Property LastBootUpTime -ErrorAction Stop).LastBootUpTime
        if($started -isnot [datetime] -or $started -eq [datetime]::MinValue){return $evidence}
        $boot=$started.ToUniversalTime()
        $evidence.BootId=$boot.Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
    } catch {return $evidence}
    $evidence.Message='Connect and select the USB that booted the unlock.'
    if(!$Letter -or !$VolumeId){return $evidence}
    try {
        $usb=Get-RtxUsbRoot $Letter $VolumeId
        $path=Get-RtxPackagePath (Get-RtxDesktopWork $Targets) $true
        $receipt=Get-RtxVerifiedPackage $path $Targets (Get-RtxEngineManifest $PSScriptRoot)
        $layout=Get-RtxMediaLayout $usb $receipt
        $evidence.Message='This USB has no complete unlock and Windows handoff for the installed cards.'
        if($layout.LiveKind -ne 'Unlock' -or !$layout.AssetsComplete -or !$layout.HasLog){return $evidence}
        $log=Get-RtxMediaFile $layout.Log
        $written=$log.LastWriteTimeUtc
        $outcome=Get-RtxLogOutcome $layout $receipt
        if(!$outcome.CompleteHandoff){return $evidence}
        # FAT timestamps have limited resolution. Allow a short boot window.
        $evidence.Message='The unlock log does not match this Windows startup. Boot the unlock USB again and leave it connected.'
        if($written -lt $boot.AddMinutes(-5) -or $written -gt $boot.AddSeconds(30)){return $evidence}
        try {
            $starts=@(Get-RtxRecentWindowsStarts)
        } catch {
            $starts=@()
        }
        if($starts.Count -ne 2 -or [Math]::Abs(($starts[0]-$boot).TotalSeconds) -gt 2 -or $starts[1] -ge $starts[0]) {
            $evidence.Message='Windows startup history could not be verified. Restart through the unlock USB and refresh Setup.'
            return $evidence
        }
        if($written -le $starts[1].AddSeconds(30)){return $evidence}
        $null=Get-RtxUsbRoot $Letter $VolumeId
        $evidence.LogId=$written.Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)+':'+(Get-RtxMediaHash $layout.Log)
        if((Get-RtxMediaFile $layout.Log).LastWriteTimeUtc -ne $written){return $evidence}
        $evidence.Confirmed=$true
        $evidence.Message='The selected USB records completed transactions and Windows handoff near this startup.'
    } catch {
        $evidence.Message='Setup could not verify the selected unlock USB. Reconnect it and refresh.'
    }
    return $evidence
}

function Build-RtxKitPackage([string]$KitRoot,[string]$WorkPath,[string]$Package,$Targets,$Engine,
                             [string]$CargoExe,[string]$InputCache,[bool]$Prebuilt) {
    if(Test-Path -LiteralPath $package){throw 'A package already exists. Keep using it or choose a new -WorkDirectory.'}
    $built=if($Prebuilt) {
        New-RtxPrebuiltPackage -KitRoot $KitRoot -WorkDirectory $WorkPath -Targets $Targets -Inputs $InputCache
    } else {
        New-RtxPackage -KitRoot $KitRoot -WorkDirectory $WorkPath -Targets $Targets -Cargo $CargoExe -Inputs $InputCache
    }
    $path=[IO.Path]::GetFullPath($built)
    $prefix=$WorkPath.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(!$path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or
       $path.Substring($prefix.Length) -notmatch '^build-[0-9a-f-]+[\\/]package$') {
        throw 'Unexpected package output location.'
    }
    New-RtxPackageReceipt $path $Targets $Engine
    $null=Get-RtxVerifiedPackage $path $Targets $Engine
    [IO.Directory]::Move($path,$package)
}

function Get-RtxKitStatus([string]$KitRoot,[string]$Letter,[string]$Work,[bool]$UseDesktopWork) {
    $prep=Get-RtxWindowsPreparation
    $status=[ordered]@{
        Targets=@();BootProblems=@(Get-RtxBootProblems $prep);Drives=@();FormatDrives=@()
        InventoryError='';BundleError='';StorageError='';PackageError='';WindowsDisplayProblems=@()
        Platform=''
        HasPackage=$false;MediaState='Unselected';MediaTitle='';HasLog=$false;CanBootUnlock=$false;MediaFailed=$false
        CompletedUnlockBoot=$false
        MediaMessage='Select a dedicated FAT32 USB drive.'
    }
    foreach($key in $prep.Keys){$status[$key]=$prep[$key]}
    try {$status.Drives=@(Get-RtxCandidateUsb)} catch {$status.StorageError=$_.Exception.Message}
    if($prep.IsAdministrator) {
        try {$status.FormatDrives=@(Get-RtxFormatDrives)} catch {
            if(!$status.StorageError){$status.StorageError=$_.Exception.Message}
        }
    }
    try {$status.Targets=@(Get-RtxInventory)} catch {$status.InventoryError=$_.Exception.Message}
    try {$status.WindowsDisplayProblems=@(Get-RtxWindowsDisplayProblems)} catch {
        $status.WindowsDisplayProblems=@('Windows Device Manager status could not be verified.')
    }
    $board=Get-CimInstance Win32_BaseBoard -Property Product -ErrorAction SilentlyContinue
    $status.Platform=[string]($board | Select-Object -First 1 -ExpandProperty Product)
    $bios=Get-CimInstance Win32_BIOS -Property SMBIOSBIOSVersion -ErrorAction SilentlyContinue
    if($status.Platform -and $bios.SMBIOSBIOSVersion){$status.Platform+=' / BIOS '+$bios.SMBIOSBIOSVersion}
    try {$null=Get-RtxPrebuiltBundle $KitRoot} catch {$status.BundleError=$_.Exception.Message}
    $receipt=$null
    if($status.Targets.Count) {
        $workPath=if($UseDesktopWork){Get-RtxDesktopWork $status.Targets}else{[IO.Path]::GetFullPath($Work)}
        $package=Get-RtxPackagePath $workPath $UseDesktopWork
        if(Test-Path -LiteralPath $package) {
            try {
                $receipt=Get-RtxVerifiedPackage $package $status.Targets (Get-RtxEngineManifest $KitRoot)
                $status.HasPackage=$true
            } catch {$status.PackageError=$_.Exception.Message}
        }
    }
    if($Letter) {
        try {
            $media=Get-RtxMediaStatus -Usb (Get-RtxUsbRoot $Letter) -Receipt $receipt
            $status.MediaState=$media.State
            $status.MediaTitle=$media.Title
            $status.HasLog=$media.HasLog
            $status.MediaFailed=$media.Failed
            $status.CanBootUnlock=$media.CanBootUnlock
            $status.MediaMessage=$media.Message
            if($UseDesktopWork -and $media.CompleteHandoff -and !$status.WindowsDisplayProblems.Count) {
                $selected=@($status.Drives | Where-Object Letter -EQ $Letter)
                if($selected.Count -eq 1 -and $selected[0].VolumeId) {
                    $status.CompletedUnlockBoot=(Get-RtxBenchmarkBootEvidence $Letter $selected[0].VolumeId $status.Targets).Confirmed
                }
            }
        } catch {
            $status.MediaState='Blocked'
            $status.MediaFailed=$true
            $status.MediaTitle='USB needs attention'
            $status.MediaMessage=$_.Exception.Message
        }
    }
    return ([pscustomobject]$status)
}

function Invoke-RtxKit([string]$KitRoot,[string]$SelectedAction,[string]$Letter,[string]$Work,
                       [string]$CargoExe,[string]$InputCache,[bool]$DoExecute,
                       [bool]$UseDesktopWork=$false,[bool]$Prebuilt=$false,[string]$ExpectedVolume) {
    $ErrorActionPreference='Stop'
    if($SelectedAction -eq 'Status') {
        [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
        Get-RtxKitStatus $KitRoot $Letter $Work $UseDesktopWork | ConvertTo-Json -Depth 6
        return
    }
    if($SelectedAction -in @('FixFastStartup','DisableEncryption','FormatUsb')) {
        if(!$DoExecute){Write-Host "Plan only. Add -Execute to perform $SelectedAction.";return}
        if(!(Test-RtxAdministrator)){throw 'This Windows preparation action requires administrator PowerShell.'}
        switch($SelectedAction) {
            'FixFastStartup' {Disable-RtxFastStartup}
            'DisableEncryption' {Start-RtxSystemDriveDecryption}
            'FormatUsb' {Format-RtxUsb $Letter $ExpectedVolume}
        }
        return
    }
    $targets=@(Get-RtxInventory)
    $targets | Select-Object Label,Bdf,Device,Subsystem,MemoryMiB,Family | Format-Table -AutoSize | Out-Host
    $workPath=if($UseDesktopWork){Get-RtxDesktopWork $targets}else{[IO.Path]::GetFullPath($Work)}
    $package=Get-RtxPackagePath $workPath $UseDesktopWork
    if($SelectedAction -eq 'Check') {
        $problems=@(Get-RtxBootProblems)
        if($problems.Count){$problems | ForEach-Object {Write-Host ('Boot prerequisite: '+$_)}}
        else{Write-Host 'Windows boot prerequisites passed. CSM and GPU initialization still need a native UEFI probe.'}
        Write-Host 'Detected cards can use the experimental source build. Hardware results depend on the exact card and platform.'
        return
    }
    if(!$DoExecute) {
        Write-Host ("Plan only. $SelectedAction uses $package. Add -Execute to perform the action.")
        return
    }
    $engine=Get-RtxEngineManifest $KitRoot
    if($SelectedAction -eq 'Build') {
        Build-RtxKitPackage $KitRoot $workPath $package $targets $engine $CargoExe $InputCache $Prebuilt
        Write-Host ("Built read-only and unlock packages at $package. Run Probe next.")
        return
    }
    if($SelectedAction -notin @('Prepare','Probe','StageUnlock','RestoreProbe')){throw 'Unknown RTX action.'}
    if(!$Letter){throw 'Specify the letter of a dedicated FAT32 USB data volume with -Drive.'}
    if($SelectedAction -ne 'RestoreProbe') {
        $problems=@(Get-RtxBootProblems)
        if($problems.Count){throw ($problems -join "`n")}
    }
    if($UseDesktopWork -and !$ExpectedVolume){throw 'Refresh and select a USB with a readable volume identity.'}
    $usb=Get-RtxUsbRoot $Letter $ExpectedVolume
    if($SelectedAction -eq 'Prepare' -and !(Test-Path -LiteralPath $package)) {
        $status=Get-RtxMediaStatus -Usb $usb
        if($status.State -ne 'Empty'){throw $status.Message}
        Build-RtxKitPackage $KitRoot $workPath $package $targets $engine $CargoExe $InputCache $true
    }
    $receipt=Get-RtxVerifiedPackage $package $targets $engine
    $usb=Get-RtxUsbRoot $Letter $ExpectedVolume
    switch($SelectedAction) {
        {$_ -in @('Prepare','Probe')} {
            Publish-RtxProbe $usb $package $receipt
            Write-Host 'Read-only probe staged. Fully power off and boot this USB once using the firmware boot menu. Return to Windows before StageUnlock.'
        }
        'StageUnlock' {
            Publish-RtxUnlock $usb $package $receipt
            Write-Host 'Unlock loader staged. Fully power off, boot this USB once, and press Space or Enter to confirm. Review each card in loader.log after Windows returns.'
        }
        'RestoreProbe' {
            Publish-RtxRestoreProbe $usb $package $receipt
            Write-Host 'Read-only probe restored. Boot the USB again before staging another unlock.'
        }
    }
}

if($MyInvocation.InvocationName -ne '.') {
    Invoke-RtxKit $PSScriptRoot $Action $Drive $WorkDirectory $Cargo $Inputs ([bool]$Execute) ([bool]$Desktop) ([bool]$UsePrebuilt) $VolumeId
}
