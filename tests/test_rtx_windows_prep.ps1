# SPDX-License-Identifier: GPL-2.0-only
# Uses only mocked Windows and Storage providers. No settings or real media are written.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../RTX.ps1')

$script:Admin=$true
$script:Fast=1
$script:PolicyFast=$null
$script:Secure=$false
$script:FastWrites=0
$script:FastCreates=0
$script:FastReadFailure=$null
$script:IgnoreFastWrite=$false
$script:DecryptWrites=0
$script:FormatWrites=0
$script:DiskReads=0
$script:SwapDisk=$false
$script:UnboundVolume=$false
$script:ExtraPartition=$false
$script:BitLockerUnavailable=$false
$script:TestVolume=[pscustomobject]@{
    UniqueId='verified-usb-volume';ObjectId='verified-storage-object';DriveLetter=[char]'E';DriveType='Removable'
    HealthStatus='Healthy';FileSystem='exFAT';FileSystemLabel='Backup Stick';Size=15900000000;SizeRemaining=8000000000
}
$script:TestDisk=[pscustomobject]@{
    Number=9;UniqueId='usb-device';Path='usb-path';BusType='USB';HealthStatus='Healthy';PartitionStyle='MBR'
    Size=16000000000;NumberOfPartitions=1;FriendlyName='USB Stick';BootFromDisk=$false
    IsSystem=$false;IsBoot=$false;IsReadOnly=$false;IsOffline=$false;IsClustered=$false
}
$script:TestPart=[pscustomobject]@{
    DriveLetter=[char]'E';DiskNumber=9;PartitionNumber=1;Offset=1048576;Size=15910000000;MbrType=7
    Guid='';GptType='';UniqueId='verified-partition';AccessPaths=@('E:\','\\?\Volume{48205c4e-a3de-4468-8bc6-f5a6218533e8}\')
    IsSystem=$false;IsBoot=$false;IsReadOnly=$false;IsOffline=$false;IsHidden=$false;IsShadowCopy=$false;IsDAX=$false
}
$script:BitLocker=[pscustomobject]@{
    MountPoint='C:';VolumeType='OperatingSystem';VolumeStatus='FullyEncrypted';ProtectionStatus='On'
    EncryptionPercentage=100;LockStatus='Unlocked';AutoUnlockKeyStored=$false
}

function Test-RtxAdministrator { $script:Admin }
function Get-RtxSystemDrive { 'C:' }
function Get-RtxInventory { throw 'Preparation must not depend on NVIDIA inventory.' }
function Get-ItemProperty($LiteralPath) {
    if($LiteralPath -ceq $script:RtxFastStartupPolicyKey) {
        if($null -eq $script:PolicyFast){throw [System.Management.Automation.ItemNotFoundException]::new('Policy key missing.')}
        return [pscustomobject]@{HiberbootEnabled=$script:PolicyFast}
    }
    if($LiteralPath -cne $script:RtxPowerKey){throw 'Wrong registry read.'}
    if($script:FastReadFailure){throw $script:FastReadFailure}
    if($null -eq $script:Fast){return [pscustomobject]@{}}
    [pscustomobject]@{HiberbootEnabled=$script:Fast}
}
function Set-ItemProperty($LiteralPath,$Name,$Value) {
    if($LiteralPath -cne $script:RtxPowerKey -or $Name -cne 'HiberbootEnabled' -or $Value -ne 0){throw 'Wrong registry write.'}
    $script:FastWrites++
    if(!$script:IgnoreFastWrite){$script:Fast=$Value}
}
function New-ItemProperty($LiteralPath,$Name,$PropertyType,$Value,[switch]$Force) {
    if($LiteralPath -cne $script:RtxPowerKey -or $Name -cne 'HiberbootEnabled' -or $PropertyType -cne 'DWord' -or
       $Value -isnot [int] -or $Value -ne 0 -or $Force -or $null -ne $script:Fast){throw 'Wrong registry creation.'}
    $script:FastCreates++
    if(!$script:IgnoreFastWrite){$script:Fast=$Value}
}
function Get-BitLockerVolume($MountPoint) {
    if($MountPoint -cne 'C:'){throw 'Wrong BitLocker volume queried.'}
    if($script:BitLockerUnavailable){throw 'BitLocker cmdlet unavailable.'}
    $script:BitLocker
}
function Disable-BitLocker($MountPoint,[switch]$Confirm) {
    if($MountPoint -cne 'C:' -or $Confirm){throw 'Wrong BitLocker action.'}
    $script:DecryptWrites++
    $script:BitLocker.VolumeStatus='DecryptionInProgress'
    $script:BitLocker.ProtectionStatus='Off'
    $script:BitLocker.EncryptionPercentage=66
}
function Get-Partition($DriveLetter,$DiskNumber) {
    if(!$DriveLetter -and !$DiskNumber){
        return [pscustomobject]@{IsSystem=$true;Guid='{abbacc72-2728-4c2c-9994-5cbba40ca1b7}';DiskNumber=0}
    }
    $script:TestPart
    if($DiskNumber -and $script:ExtraPartition){[pscustomobject]@{PartitionNumber=2}}
}
function Get-Disk($Number) {
    if($Number -eq 0){return [pscustomobject]@{PartitionStyle='GPT'}}
    $script:DiskReads++
    if($script:SwapDisk -and $script:DiskReads -eq 2){
        $changed=$script:TestDisk.PSObject.Copy()
        $changed.Path='new-physical-usb'
        return $changed
    }
    $script:TestDisk
}
function Get-Volume($DriveLetter,$Partition) {
    if($Partition -and $script:UnboundVolume){return [pscustomobject]@{UniqueId='different-partition-volume'}}
    $script:TestVolume
}
function Format-Volume($InputObject,$FileSystem,$NewFileSystemLabel,[switch]$Confirm) {
    if(![object]::ReferenceEquals($InputObject,$script:TestVolume) -or $FileSystem -cne 'FAT32' -or
       $NewFileSystemLabel -cne 'GPU-UNLOCK' -or $Confirm){throw 'Wrong format target or arguments.'}
    $script:FormatWrites++
    $script:TestVolume.FileSystem='FAT32'
    $script:TestVolume.UniqueId='volume-id-after-format'
    $script:TestPart.MbrType=12
}
function Confirm-SecureBootUEFI { $script:Secure }

function Invoke-PrepTest([string]$Action,[bool]$Execute,[string]$Letter='E',[string]$VolumeId='verified-usb-volume') {
    Invoke-RtxKit $PSScriptRoot $Action $Letter $PSScriptRoot 'cargo' '' $Execute $true $true $VolumeId
}
function Assert-Refusal([scriptblock]$Run,[string]$Text) {
    $message='Action returned without a refusal.'
    try {& $Run} catch {$message=$_.Exception.Message}
    if($message -notlike $Text){throw "Expected refusal $Text. Got: $message"}
}

foreach($action in @('FixFastStartup','DisableEncryption','FormatUsb','FixBenchmarkRuntime')){Invoke-PrepTest $action $false}
if($script:FastWrites -or $script:DecryptWrites -or $script:FormatWrites){throw 'Preview performed a write.'}
$script:Admin=$false
foreach($action in @('FixFastStartup','DisableEncryption','FormatUsb','FixBenchmarkRuntime')){
    Assert-Refusal {Invoke-PrepTest $action $true} '*requires administrator*'
}
$script:Admin=$true
$script:Fast=0
$script:PolicyFast=1
$managed=Get-RtxWindowsPreparation
if($managed.FastStartupState -cne 'ManagedEnabled' -or $managed.CanFixFastStartup -or
   ((Get-RtxBootProblems $managed) -join ' ') -notmatch 'policy requires Fast Startup'){
    throw 'Managed Fast Startup did not override the local off setting.'
}
Assert-Refusal {Invoke-PrepTest 'FixFastStartup' $true} '*policy requires Fast Startup*'
if($script:FastWrites){throw 'Managed Fast Startup allowed a registry write.'}
$script:PolicyFast='unexpected'
if((Get-RtxWindowsPreparation).FastStartupState -cne 'Unknown'){throw 'Unknown policy data was treated as disabled.'}
$script:PolicyFast=0
if((Get-RtxWindowsPreparation).FastStartupState -cne 'Disabled'){throw 'Disabled policy did not defer to the local setting.'}
$script:PolicyFast=$null
$script:Fast=1
$status=Get-RtxWindowsPreparation
if($status.FirmwareState -cne 'Ready' -or !$status.CanFixFastStartup -or !$status.CanDisableEncryption -or
   $status.EncryptionPercentage -ne 100){throw 'Initial Windows preparation status is incorrect.'}
$script:Secure=$true
if((Get-RtxWindowsPreparation).FirmwareState -cne 'SecureBootOn'){throw 'Secure Boot state was not reported.'}
$script:Secure=$false
Invoke-PrepTest 'fixfaststartup' $true
Invoke-PrepTest 'FixFastStartup' $true
if($script:FastWrites -ne 1 -or $script:FastCreates -or
   (Get-RtxWindowsPreparation).FastStartupState -cne 'Disabled'){throw 'Fast Startup action was not verified or idempotent.'}

$script:Fast=$null
$missing=Get-RtxWindowsPreparation
if($missing.FastStartupState -cne 'NotConfigured' -or !$missing.CanFixFastStartup){
    throw 'An absent value in a readable Power key must offer the guided Fast Startup action.'
}
$script:Admin=$false
if((Get-RtxWindowsPreparation).CanFixFastStartup){throw 'A standard user was offered a machine-wide Fast Startup change.'}
$script:Admin=$true
$script:PolicyFast=1
Assert-Refusal {Invoke-PrepTest 'FixFastStartup' $true} '*policy requires Fast Startup*'
$script:PolicyFast=$null
foreach($failure in @([UnauthorizedAccessException]::new(),[System.Management.Automation.ItemNotFoundException]::new())){
    $script:FastReadFailure=$failure
    $unknown=Get-RtxWindowsPreparation
    if($unknown.FastStartupState -cne 'Unknown' -or $unknown.CanFixFastStartup){throw 'An inaccessible Power key allowed Fast Startup configuration.'}
    Assert-Refusal {Invoke-PrepTest 'FixFastStartup' $true} '*Could not verify the current Fast Startup setting*'
}
$script:FastReadFailure=$null
$script:Fast='0'
$malformed=Get-RtxWindowsPreparation
if($malformed.FastStartupState -cne 'Unknown' -or $malformed.CanFixFastStartup){throw 'A malformed local value allowed Fast Startup configuration.'}
Assert-Refusal {Invoke-PrepTest 'FixFastStartup' $true} '*Could not verify the current Fast Startup setting*'
if($script:FastWrites -ne 1 -or $script:FastCreates){throw 'An unverifiable Fast Startup state reached a registry write.'}

$script:IgnoreFastWrite=$true
foreach($initial in @(1,$null)){
    $script:Fast=$initial
    Assert-Refusal {Invoke-PrepTest 'FixFastStartup' $true} '*Windows did not report Fast Startup off after the change*'
}
$script:IgnoreFastWrite=$false
Invoke-PrepTest 'FixFastStartup' $true
Invoke-PrepTest 'FixFastStartup' $true
if($script:FastWrites -ne 2 -or $script:FastCreates -ne 2 -or
   (Get-RtxWindowsPreparation).FastStartupState -cne 'Disabled'){throw 'Fast Startup DWORD creation was not verified or idempotent.'}

$script:BitLocker.AutoUnlockKeyStored=$true
Assert-Refusal {Invoke-PrepTest 'DisableEncryption' $true} '*not ready to start decryption*'
$script:BitLocker.AutoUnlockKeyStored=$false
Invoke-PrepTest 'DisableEncryption' $true
$status=Get-RtxWindowsPreparation
if($script:DecryptWrites -ne 1 -or $status.EncryptionState -cne 'DecryptionInProgress' -or
   $status.ProtectionState -cne 'Off' -or $status.EncryptionPercentage -ne 66 -or $status.CanDisableEncryption -or
   ((Get-RtxBootProblems $status) -join ' ') -notmatch '66% remains encrypted'){
    throw 'Decryption progress did not continue to block boot preparation.'
}
Assert-Refusal {Invoke-PrepTest 'DisableEncryption' $true} '*not ready to start decryption*'

$drives=@(Get-RtxFormatDrives)
if($drives.Count -ne 1 -or $drives[0].VolumeId -cne 'verified-usb-volume' -or $drives[0].FileSystem -cne 'exFAT'){
    throw 'Eligible format target was not listed.'
}
Assert-Refusal {Invoke-PrepTest 'FormatUsb' $true 'E' ''} '*exact selected drive letter and volume identity*'
Assert-Refusal {Invoke-PrepTest 'FormatUsb' $true 'E' 'VERIFIED-USB-VOLUME'} '*USB changed*'
foreach($bus in @('SATA','File Backed Virtual')){
    $script:TestDisk.BusType=$bus
    Assert-Refusal {Invoke-PrepTest 'FormatUsb' $true} '*physical USB disk*'
}
$script:TestDisk.BusType='USB'
$script:TestDisk.IsReadOnly=$true
Assert-Refusal {Invoke-PrepTest 'FormatUsb' $true} '*read-only*'
$script:TestDisk.IsReadOnly=$false
$script:TestDisk.IsSystem=$true
Assert-Refusal {Invoke-PrepTest 'FormatUsb' $true} '*System, boot*'
$script:TestDisk.IsSystem=$false
$script:ExtraPartition=$true
Assert-Refusal {Invoke-PrepTest 'FormatUsb' $true} '*exactly one data partition*'
$script:ExtraPartition=$false
$script:TestPart.MbrType=66
Assert-Refusal {Invoke-PrepTest 'FormatUsb' $true} '*basic USB data partition*'
$script:TestPart.MbrType=7
$script:TestPart.AccessPaths+= 'C:\mounted-usb\'
Assert-Refusal {Invoke-PrepTest 'FormatUsb' $true} '*mounted folder*'
$script:TestPart.AccessPaths=$script:TestPart.AccessPaths[0..1]
$script:TestDisk.Size=64000000000
Assert-Refusal {Invoke-PrepTest 'FormatUsb' $true} '*8 to 32 GB*'
$script:TestDisk.Size=16000000000
$script:UnboundVolume=$true
Assert-Refusal {Invoke-PrepTest 'FormatUsb' $true} '*could not link*'
$script:UnboundVolume=$false
$script:DiskReads=0
$script:SwapDisk=$true
Assert-Refusal {Invoke-PrepTest 'FormatUsb' $true} '*physical USB or its partition changed*'
$script:SwapDisk=$false
if($script:FormatWrites){throw 'An ineligible target reached Format-Volume.'}
Invoke-PrepTest 'FormatUsb' $true
if($script:FormatWrites -ne 1 -or $script:TestVolume.FileSystem -cne 'FAT32'){throw 'Verified FAT32 format action did not run exactly once.'}

$script:BitLockerUnavailable=$true
$script:ConversionStatus=[uint32]0
$script:MissingConversionReturn=$false
function Get-CimInstance($Namespace,$ClassName,$Filter) {
    if($Namespace -cne 'root/CIMV2/Security/MicrosoftVolumeEncryption' -or
       $ClassName -cne 'Win32_EncryptableVolume' -or $Filter -cne "DriveLetter = 'C:'"){throw 'Unexpected CIM query.'}
    [pscustomobject]@{DriveLetter='C:';VolumeType=[uint32]0}
}
function Invoke-CimMethod($InputObject,$MethodName,$Arguments) {
    if($InputObject.DriveLetter -cne 'C:'){throw 'Wrong CIM volume.'}
    switch -CaseSensitive ($MethodName) {
        'GetConversionStatus' {
            $result=[pscustomobject]@{ConversionStatus=$script:ConversionStatus;EncryptionPercentage=[uint32]0}
            if(!$script:MissingConversionReturn){Add-Member -InputObject $result -NotePropertyName ReturnValue -NotePropertyValue ([uint32]0)}
            return $result
        }
        'GetProtectionStatus' {return [pscustomobject]@{ReturnValue=[uint32]0;ProtectionStatus=[uint32]0}}
        default {throw 'Device Encryption fallback must not mutate Windows.'}
    }
}
$status=Get-RtxWindowsPreparation
if($status.EncryptionState -cne 'FullyDecrypted' -or $status.ProtectionState -cne 'Off' -or
   $status.EncryptionPercentage -ne 0 -or $status.CanDisableEncryption){throw 'Read-only Device Encryption fallback did not verify the fully decrypted volume.'}
$script:ConversionStatus=[uint32]3
$status=Get-RtxWindowsPreparation
if($status.EncryptionState -cne 'DecryptionInProgress' -or $status.CanDisableEncryption -or
   ((Get-RtxBootProblems $status) -join ' ') -notmatch 'decryption is in progress'){
    throw 'A rounded 0% Device Encryption reading bypassed the full decryption requirement.'
}
Assert-Refusal {Invoke-PrepTest 'DisableEncryption' $true} '*not ready to start decryption*'
$script:MissingConversionReturn=$true
if((Get-RtxWindowsPreparation).EncryptionState -cne 'Unknown'){throw 'Incomplete CIM evidence was accepted.'}
'PASS Windows preparation: plan/elevation guards, explicit Fast Startup and OS decryption, read-only Device Encryption, progress gate, identity-bound FAT32 and refusal controls.'
