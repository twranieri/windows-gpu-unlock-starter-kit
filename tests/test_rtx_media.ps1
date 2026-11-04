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
try {
    New-RtxPackageReceipt $package $targets $engine
    $receipt=Get-RtxVerifiedPackage $package $targets $engine
    if($receipt.Files.Count -ne 15){throw 'Mixed package should contain two loaders and thirteen assets.'}
    Assert-Refused {Get-RtxVerifiedPackage $package @($targets[0]) $engine} 'Package admitted a changed live target set.'
    Publish-RtxProbe $usb $package $receipt
    Publish-RtxProbe $usb $package $receipt
    $boot=Join-Path $usb 'EFI/BOOT/BOOTX64.EFI'
    if([IO.File]::ReadAllText($boot) -cne 'Probe.EFI' -or (Get-ChildItem -LiteralPath $usb -Filter '*.bin').Count){
        throw 'Probe staging copied something other than the read-only loader and target list.'
    }
    Assert-Refused {Publish-RtxUnlock $usb $package $receipt} 'Missing probe boot authorized staging.'
    $log=Join-Path $usb 'loader.log'
    $handoff='CHAIN: StartImage -> handing control to the OS loader'
    [IO.File]::WriteAllText($log,"KIT-PROBE: $('1'*32) matched 2`n$handoff`n")
    Assert-Refused {Publish-RtxUnlock $usb $package $receipt} 'Stale probe authorized staging.'
    [IO.File]::WriteAllText($log,"[1ms] INFO : loader: KIT-PROBE: $($receipt.Nonce) matched 2`n$handoff`n")
    $armed=Join-Path $usb 'i_know_what_i_am_doing.txt'
    [IO.File]::WriteAllText($armed,'5')
    Assert-Refused {Publish-RtxUnlock $usb $package $receipt} 'An automatic unlock marker was accepted.'
    Remove-Item -LiteralPath $armed
    $partial=Join-Path $usb 'gsp_boot_ga102.bin'
    [IO.File]::WriteAllText($partial,'tampered')
    Assert-Refused {Publish-RtxUnlock $usb $package $receipt} 'A stale firmware asset was accepted.'
    [IO.File]::Copy((Join-Path $package 'assets/gsp_boot_ga102.bin'),$partial,$true)
    Publish-RtxUnlock $usb $package $receipt
    if([IO.File]::ReadAllText($boot) -cne 'Unlock.EFI' -or
       [IO.File]::ReadAllText((Join-Path $usb 'EFI/BOOT/RTX-PROBE.backup')) -cne 'Probe.EFI' -or
       @(Get-ChildItem -LiteralPath $usb -Filter '*.bin').Count -ne 13){throw 'Unlock staging or probe backup is incomplete.'}
    'PASS RTX media contract: exact targets, mixed assets, stale log, unsafe marker, asset tamper, resume and probe backup.'
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(!$resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or
       ![IO.Path]::GetFileName($resolved).StartsWith('rtx-media-test-')){throw 'Refusing cleanup outside the media test folder.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
