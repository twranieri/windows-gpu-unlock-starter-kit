# SPDX-License-Identifier: GPL-2.0-only
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Check','Build','Probe','StageUnlock')][string]$Action='Check',
    [ValidatePattern('^[D-Zd-z]$')][string]$Drive,
    [string]$WorkDirectory=(Join-Path $PSScriptRoot '.local/rtx'),
    [string]$Cargo='cargo',
    [string]$Inputs,
    [switch]$Execute
)

$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'rtx/Inventory.ps1')
. (Join-Path $PSScriptRoot 'rtx/Build.ps1')
. (Join-Path $PSScriptRoot 'rtx/Media.ps1')

function Get-RtxBootProblems {
    if(![Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
        'An x64 Windows PowerShell is required.'
    }
    try {
        $esp=@(Get-Partition -ErrorAction Stop | Where-Object IsSystem)
        if($esp.Count -ne 1 -or !$esp[0].Guid -or
           (Get-Disk -Number $esp[0].DiskNumber -ErrorAction Stop).PartitionStyle -ne 'GPT') {
            throw 'No unique GPT system partition.'
        }
        if(Confirm-SecureBootUEFI -ErrorAction Stop){'Secure Boot must be disabled for the locally built EFI.'}
    } catch { 'Could not verify UEFI, the Windows EFI partition, and Secure Boot. Use administrator PowerShell.' }
    try {
        $volume=Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        if($volume.VolumeStatus -ne 'FullyDecrypted' -or $volume.ProtectionStatus -ne 'Off' -or
           $volume.EncryptionPercentage -ne 0){'The Windows volume must be fully decrypted with BitLocker protection off.'}
    } catch { 'Could not verify BitLocker state. Use administrator PowerShell.' }
    try {
        $fast=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction Stop
        if($fast.HiberbootEnabled -ne 0){'Disable Windows Fast Startup before collecting a cold probe.'}
    } catch { 'Could not verify Windows Fast Startup.' }
}

function Invoke-RtxKit([string]$KitRoot,[string]$SelectedAction,[string]$Letter,[string]$Work,
                       [string]$CargoExe,[string]$InputCache,[bool]$DoExecute) {
    $ErrorActionPreference='Stop'
    $targets=@(Get-RtxInventory)
    $targets | Select-Object Label,Bdf,Device,Subsystem,MemoryMiB,Family | Format-Table -AutoSize | Out-Host
    $workPath=[IO.Path]::GetFullPath($Work)
    $package=Join-Path $workPath 'package'
    if($SelectedAction -ceq 'Check') {
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
    if($SelectedAction -ceq 'Build') {
        if(Test-Path -LiteralPath $package){throw 'A package already exists. Keep using it or choose a new -WorkDirectory.'}
        $built=New-RtxPackage -KitRoot $KitRoot -WorkDirectory $workPath -Targets $targets -Cargo $CargoExe -Inputs $InputCache
        $path=[IO.Path]::GetFullPath($built)
        $prefix=$workPath.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if(!$path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or
           $path.Substring($prefix.Length) -notmatch '^build-[0-9a-f-]+[\\/]package$') {
            throw 'Unexpected package output location.'
        }
        New-RtxPackageReceipt $path $targets $engine
        $null=Get-RtxVerifiedPackage $path $targets $engine
        [IO.Directory]::Move($path,$package)
        Write-Host ("Built read-only and unlock packages at $package. Run Probe next.")
        return
    }
    if(!$Letter){throw 'Specify the letter of a dedicated FAT32 USB data volume with -Drive.'}
    $problems=@(Get-RtxBootProblems)
    if($problems.Count){throw ($problems -join "`n")}
    $receipt=Get-RtxVerifiedPackage $package $targets $engine
    $usb=Get-RtxUsbRoot $Letter
    if($SelectedAction -ceq 'Probe') {
        Publish-RtxProbe $usb $package $receipt
        Write-Host 'Read-only probe staged. Fully power off and boot this USB once using the firmware boot menu. Return to Windows before StageUnlock.'
    } else {
        Publish-RtxUnlock $usb $package $receipt
        Write-Host 'Unlock loader staged. Fully power off, boot this USB once, and press Space or Enter to confirm. Review each card in loader.log after Windows returns.'
    }
}

if($MyInvocation.InvocationName -ne '.') {
    Invoke-RtxKit $PSScriptRoot $Action $Drive $WorkDirectory $Cargo $Inputs ([bool]$Execute)
}
