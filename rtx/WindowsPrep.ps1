# SPDX-License-Identifier: GPL-2.0-only

$script:RtxPowerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$script:RtxFastStartupPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'

function Test-RtxAdministrator {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        return [Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } finally {$identity.Dispose()}
}

function Get-RtxSystemDrive {
    $root=[IO.Path]::GetPathRoot([Environment]::SystemDirectory)
    if($root -match '^[A-Z]:\\$'){return $root.Substring(0,2).ToUpperInvariant()}
    return ''
}

function Get-RtxFirmwareState {
    try {
        $esp=@(Get-Partition -ErrorAction Stop | Where-Object IsSystem)
        if($esp.Count -ne 1 -or !$esp[0].Guid){return 'LegacyOrUnverified'}
        $disk=@(Get-Disk -Number $esp[0].DiskNumber -ErrorAction Stop)
        if($disk.Count -ne 1 -or $disk[0].PartitionStyle -ne 'GPT'){return 'LegacyOrUnverified'}
        $secure=Confirm-SecureBootUEFI -ErrorAction Stop
        if($secure -isnot [bool]){return 'LegacyOrUnverified'}
        if($secure){return 'SecureBootOn'}
        return 'Ready'
    } catch {return 'LegacyOrUnverified'}
}

function Get-RtxFastStartupState {
    try {
        $policy=Get-ItemProperty -LiteralPath $script:RtxFastStartupPolicyKey -ErrorAction Stop
        $required=$policy.PSObject.Properties['HiberbootEnabled']
        if($required) {
            if($required.Value -isnot [int] -or $required.Value -notin @(0,1)){return 'Unknown'}
            if($required.Value -eq 1){return 'ManagedEnabled'}
        }
    } catch [System.Management.Automation.ItemNotFoundException] {
        # When the policy key is absent, Windows uses the local power setting.
    } catch {return 'Unknown'}
    try {
        $value=(Get-ItemProperty -LiteralPath $script:RtxPowerKey -Name HiberbootEnabled -ErrorAction Stop).HiberbootEnabled
        if($value -is [int]) {
            if($value -eq 0){return 'Disabled'}
            if($value -eq 1){return 'Enabled'}
        }
    } catch {}
    return 'Unknown'
}

function Get-RtxDeviceEncryptionState([string]$SystemDrive) {
    # On editions without the BitLocker cmdlet, use only documented read methods.
    try {
        $volumes=@(Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' `
            -ClassName Win32_EncryptableVolume -Filter "DriveLetter = '$SystemDrive'" -ErrorAction Stop)
        if($volumes.Count -ne 1 -or $volumes[0].DriveLetter -ine $SystemDrive -or
           $volumes[0].VolumeType -isnot [uint32] -or $volumes[0].VolumeType -ne 0){return}
        $conversion=Invoke-CimMethod -InputObject $volumes[0] -MethodName GetConversionStatus `
            -Arguments @{PrecisionFactor=[uint32]0} -ErrorAction Stop
        $protection=Invoke-CimMethod -InputObject $volumes[0] -MethodName GetProtectionStatus -ErrorAction Stop
        if($conversion.ReturnValue -isnot [uint32] -or $conversion.ReturnValue -ne 0 -or
           $conversion.ConversionStatus -isnot [uint32] -or $conversion.ConversionStatus -gt 5 -or
           $conversion.EncryptionPercentage -isnot [uint32] -or $conversion.EncryptionPercentage -gt 100 -or
           $protection.ReturnValue -isnot [uint32] -or $protection.ReturnValue -ne 0 -or
           $protection.ProtectionStatus -isnot [uint32] -or $protection.ProtectionStatus -gt 1){return}
        $states=@('FullyDecrypted','FullyEncrypted','EncryptionInProgress','DecryptionInProgress','EncryptionPaused','DecryptionPaused')
        return [pscustomobject]@{
            EncryptionState=$states[$conversion.ConversionStatus]
            ProtectionState=@('Off','On')[$protection.ProtectionStatus]
            EncryptionPercentage=[int]$conversion.EncryptionPercentage
            CanDisableEncryption=$false
        }
    } catch {}
}

function Get-RtxEncryptionState([string]$SystemDrive) {
    $result=[ordered]@{EncryptionState='Unknown';ProtectionState='Unknown';EncryptionPercentage=$null;CanDisableEncryption=$false}
    if($SystemDrive -notmatch '^[A-Z]:$'){return [pscustomobject]$result}
    try {$volumes=@(Get-BitLockerVolume -MountPoint $SystemDrive -ErrorAction Stop)} catch {$volumes=@()}
    if(!$volumes.Count) {
        $fallback=Get-RtxDeviceEncryptionState $SystemDrive
        if($fallback){return $fallback}
    }
    try {
        if($volumes.Count -ne 1){return [pscustomobject]$result}
        $volume=$volumes[0]
        if($volume.MountPoint -ine $SystemDrive -or $volume.VolumeType -ne 'OperatingSystem'){
            return [pscustomobject]$result
        }
        $states=@('FullyDecrypted','FullyEncrypted','EncryptionInProgress','EncryptionPaused','DecryptionInProgress','DecryptionPaused')
        $state=[string]$volume.VolumeStatus
        $protection=[string]$volume.ProtectionStatus
        $percent=0
        if($state -cin $states -and [int]::TryParse([string]$volume.EncryptionPercentage,[ref]$percent) -and $percent -in 0..100) {
            $result.EncryptionState=$state
            $result.EncryptionPercentage=$percent
        }
        if($protection -cin @('On','Off')){$result.ProtectionState=$protection}
        $result.CanDisableEncryption=$result.ProtectionState -ne 'Unknown' -and
            $result.EncryptionState -cin @('FullyEncrypted','EncryptionInProgress','EncryptionPaused') -and
            $volume.LockStatus -eq 'Unlocked' -and $volume.AutoUnlockKeyStored -ne $true
    } catch {}
    return [pscustomobject]$result
}

function Get-RtxWindowsPreparation {
    $admin=Test-RtxAdministrator
    $systemDrive=Get-RtxSystemDrive
    $fast=Get-RtxFastStartupState
    $encryption=Get-RtxEncryptionState $systemDrive
    return [ordered]@{
        IsAdministrator=$admin
        FirmwareState=Get-RtxFirmwareState
        FastStartupState=$fast
        CanFixFastStartup=$admin -and $fast -eq 'Enabled'
        SystemDrive=$systemDrive
        EncryptionState=$encryption.EncryptionState
        ProtectionState=$encryption.ProtectionState
        EncryptionPercentage=$encryption.EncryptionPercentage
        CanDisableEncryption=$admin -and $encryption.CanDisableEncryption
    }
}

function Disable-RtxFastStartup {
    $state=Get-RtxFastStartupState
    if($state -eq 'Disabled'){Write-Host 'Windows Fast Startup is already off.';return}
    if($state -eq 'ManagedEnabled'){throw 'Windows policy requires Fast Startup. Contact the Windows administrator to review that policy.'}
    if($state -ne 'Enabled'){throw 'Could not verify the current Fast Startup setting.'}
    Set-ItemProperty -LiteralPath $script:RtxPowerKey -Name HiberbootEnabled -Value 0 -ErrorAction Stop
    if((Get-RtxFastStartupState) -ne 'Disabled'){throw 'Windows did not report Fast Startup off after the change. Refresh or check Windows power policy.'}
    Write-Host 'Windows Fast Startup is off.'
}

function Start-RtxSystemDriveDecryption {
    $drive=Get-RtxSystemDrive
    $state=Get-RtxEncryptionState $drive
    if($state.EncryptionState -eq 'FullyDecrypted' -and $state.ProtectionState -eq 'Off' -and $state.EncryptionPercentage -eq 0) {
        Write-Host "Windows volume $drive is already fully decrypted."
        return
    }
    if(!$state.CanDisableEncryption){throw 'The Windows volume is not ready to start decryption in Setup. Refresh or check BitLocker or Device Encryption in Windows settings.'}
    $null=Disable-BitLocker -MountPoint $drive -Confirm:$false -ErrorAction Stop
    Write-Host "Windows accepted the decryption request for $drive. Refresh to monitor progress. Boot preparation requires 0% encrypted and protection off."
}

function Get-RtxFormatTarget([string]$Letter,[string]$ExpectedVolume,$Volume) {
    if($Letter -notmatch '^[D-Z]$' -or ($Letter+':') -ieq (Get-RtxSystemDrive)){
        throw 'Select a dedicated USB data volume with a drive letter from D to Z.'
    }
    $volumes=if($null -ne $Volume){@($Volume)}else{@(Get-Volume -DriveLetter $Letter -ErrorAction Stop)}
    $volumes=@($volumes)
    if($volumes.Count -ne 1){throw 'The USB volume is missing or ambiguous. Refresh the drive list.'}
    $volume=$volumes[0]
    if(!$volume.UniqueId -or [string]$volume.DriveLetter -ine $Letter -or ($ExpectedVolume -and $volume.UniqueId -cne $ExpectedVolume)){
        throw 'The selected USB changed. Refresh the drive list and select it again.'
    }
    if($volume.DriveType -notin @('Fixed','Removable') -or $volume.HealthStatus -ne 'Healthy' -or
       $volume.FileSystem -notin @('FAT','FAT32','exFAT','NTFS')){
        throw 'Only a healthy, mounted USB data volume with a recognized file system can be formatted here.'
    }

    $selected=@(Get-Partition -DriveLetter $Letter -ErrorAction Stop)
    if($selected.Count -ne 1){throw 'The USB partition is missing or ambiguous.'}
    $diskRows=@(Get-Disk -Number $selected[0].DiskNumber -ErrorAction Stop)
    if($diskRows.Count -ne 1){throw 'The physical USB disk is missing or ambiguous.'}
    $disk=$diskRows[0]
    if($disk.BusType -ne 'USB' -or $disk.HealthStatus -ne 'Healthy' -or $disk.PartitionStyle -notin @('MBR','GPT') -or
       (!$disk.UniqueId -and !$disk.Path) -or $disk.Number -ne $selected[0].DiskNumber){
        throw 'Only an identified physical USB disk with a healthy MBR or GPT layout can be formatted here.'
    }
    foreach($flag in @('IsSystem','IsBoot','BootFromDisk','IsReadOnly','IsOffline','IsClustered')) {
        if($disk.$flag -isnot [bool] -or $disk.$flag){throw 'System, boot, offline, read-only and clustered disks cannot be formatted here.'}
    }
    $partitions=@(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop)
    if($disk.NumberOfPartitions -ne 1 -or $partitions.Count -ne 1){throw 'Use a dedicated USB disk with exactly one data partition.'}
    $part=$partitions[0]
    if($part.DiskNumber -ne $disk.Number -or [string]$part.DriveLetter -ine $Letter -or
       $part.PartitionNumber -ne $selected[0].PartitionNumber -or $part.Offset -ne $selected[0].Offset -or $part.Size -ne $selected[0].Size) {
        throw 'The selected USB partition changed. Refresh and select it again.'
    }
    foreach($flag in @('IsSystem','IsBoot','IsReadOnly','IsOffline','IsHidden','IsShadowCopy','IsDAX')) {
        if($part.$flag -isnot [bool] -or $part.$flag){throw 'Only an ordinary writable USB data partition can be formatted here.'}
    }
    foreach($path in $part.AccessPaths) {
        if($path -and $path -ine ($Letter+':\') -and $path -notmatch '^\\\\\?\\Volume\{[0-9a-f-]{36}\}\\$') {
            throw 'This USB partition also has a mounted folder. Remove that mount before formatting.'
        }
    }
    $basic=$false
    if($disk.PartitionStyle -eq 'GPT') {
        $type=[guid]::Empty
        $basic=[guid]::TryParse([string]$part.GptType,[ref]$type) -and $type -eq [guid]'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7'
    } else {
        $type=0
        $basic=[int]::TryParse([string]$part.MbrType,[ref]$type) -and $type -in @(6,7,11,12,14)
    }
    if(!$basic){throw 'Only a basic USB data partition can be formatted here.'}
    foreach($bytes in @($disk.Size,$part.Size,$volume.Size)) {
        [uint64]$size=0
        if(![uint64]::TryParse([string]$bytes,[ref]$size) -or $size -lt 7000000000 -or $size -gt 32GB){
            throw 'Use a dedicated USB drive of approximately 8 to 32 GB.'
        }
    }
    $bound=@(Get-Volume -Partition $part -ErrorAction Stop)
    if($bound.Count -ne 1 -or $bound[0].UniqueId -cne $volume.UniqueId -or
       [string]$bound[0].DriveLetter -ine $Letter -or $bound[0].FileSystem -ne $volume.FileSystem -or
       $bound[0].Size -ne $volume.Size -or $bound[0].ObjectId -cne $volume.ObjectId) {
        throw 'Windows could not link the selected volume to the verified USB partition.'
    }
    return [pscustomobject]@{Volume=$bound[0];Disk=$disk;Partition=$part}
}

function Get-RtxFormatDrives {
    $mounted=Get-Volume -ErrorAction Stop | Where-Object { [string]$_.DriveLetter -match '^[D-Z]$' } |
        Group-Object -Property DriveLetter | Sort-Object -Property Name
    foreach($entry in $mounted) {
        if($entry.Count -ne 1){continue}
        $volume=$entry.Group[0]
        try {$target=Get-RtxFormatTarget ([string]$volume.DriveLetter) ([string]$volume.UniqueId) $volume} catch {continue}
        [pscustomobject]@{
            Letter=([string]$volume.DriveLetter).ToUpperInvariant()
            Label=[string]$volume.FileSystemLabel
            FreeBytes=[uint64]$volume.SizeRemaining
            TotalBytes=[uint64]$volume.Size
            VolumeId=[string]$volume.UniqueId
            FileSystem=[string]$volume.FileSystem
            DiskModel=[string]$target.Disk.FriendlyName
        }
    }
}

function Test-RtxSameFormatPartition($First,$Second) {
    return $First.Disk.Number -eq $Second.Disk.Number -and
        $First.Disk.UniqueId -ceq $Second.Disk.UniqueId -and $First.Disk.Path -ceq $Second.Disk.Path -and
        $First.Disk.Size -eq $Second.Disk.Size -and $First.Disk.PartitionStyle -eq $Second.Disk.PartitionStyle -and
        $First.Partition.PartitionNumber -eq $Second.Partition.PartitionNumber -and
        $First.Partition.Offset -eq $Second.Partition.Offset -and $First.Partition.Size -eq $Second.Partition.Size -and
        $First.Partition.Guid -ceq $Second.Partition.Guid -and $First.Partition.UniqueId -ceq $Second.Partition.UniqueId
}

function Format-RtxUsb([string]$Letter,[string]$ExpectedVolume) {
    if(!$Letter -or [string]::IsNullOrWhiteSpace($ExpectedVolume)){throw 'Formatting requires the exact selected drive letter and volume identity.'}
    $before=Get-RtxFormatTarget $Letter $ExpectedVolume
    $target=Get-RtxFormatTarget $Letter $ExpectedVolume
    if(!(Test-RtxSameFormatPartition $before $target)){throw 'The physical USB or its partition changed. Refresh and select it again.'}
    $null=Format-Volume -InputObject $target.Volume -FileSystem FAT32 -NewFileSystemLabel 'GPU-UNLOCK' -Confirm:$false -ErrorAction Stop
    try {
        $after=Get-RtxFormatTarget $Letter
        if(!(Test-RtxSameFormatPartition $target $after) -or $after.Volume.FileSystem -ne 'FAT32'){throw 'USB verification failed.'}
    } catch {throw 'Windows reported that the format finished, but Setup could not verify the USB. Refresh before doing anything else.'}
    Write-Host "USB $($Letter.ToUpperInvariant()): formatted as FAT32. Refresh and select the USB to prepare the probe."
}
