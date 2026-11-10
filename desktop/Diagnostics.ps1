# SPDX-License-Identifier: GPL-2.0-only
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidatePattern('^[D-Zd-z]$')][string]$Drive,
    [string]$VolumeId
)

$script:RtxDiagnosticsKit = Split-Path -Parent $PSScriptRoot

function Format-RtxDiagnosticLabel([string]$Value) {
    $clean = (($Value -replace '[^\p{L}\p{N} ._()+-]',' ') -replace ' +',' ').Trim()
    if (!$clean -or $clean.Length -gt 128) { return 'unavailable' }
    return $clean
}

function Get-RtxDiagnosticPlatform {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -Property Version,BuildNumber -ErrorAction Stop
        $revision = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' `
            -Name UBR -ErrorAction SilentlyContinue).UBR
        $build = Format-RtxDiagnosticLabel $os.BuildNumber
        if ($build -match '^\d{4,6}$' -and [string]$revision -match '^\d{1,6}$') { $build += ".$revision" }
        'Windows: {0} (build {1})' -f (Format-RtxDiagnosticLabel $os.Version),$build
    } catch { 'Windows build: unavailable' }
    try {
        $board = Get-CimInstance Win32_BaseBoard -Property Manufacturer,Product -ErrorAction Stop | Select-Object -First 1
        $bios = Get-CimInstance Win32_BIOS -Property SMBIOSBIOSVersion -ErrorAction Stop | Select-Object -First 1
        'Motherboard: {0} / {1}' -f (Format-RtxDiagnosticLabel $board.Manufacturer),(Format-RtxDiagnosticLabel $board.Product)
        'BIOS: {0}' -f (Format-RtxDiagnosticLabel $bios.SMBIOSBIOSVersion)
    } catch { 'Motherboard and BIOS: unavailable' }
    try {
        $cpu = Get-CimInstance Win32_Processor -Property Name -ErrorAction Stop | Select-Object -First 1
        'CPU: {0}' -f (Format-RtxDiagnosticLabel $cpu.Name)
    } catch { 'CPU: unavailable' }
}

function Read-RtxDiagnosticSmi([string]$Executable,[string[]]$Fields,[string]$Address) {
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $arguments = @(('--query-gpu='+($Fields -join ',')),'--format=csv,noheader,nounits')
    if ($Address) { $arguments += @('-i',$Address) }
    $rows = @(& $Executable @arguments 2>$null)
    if ($LASTEXITCODE -eq 0 -and $rows.Count -le 16) { $rows }
}

function Format-RtxDiagnosticMiB([string]$Value) {
    $Value = $Value.Trim()
    if ($Value -match '\A[0-9]{1,10}\z') { return "$Value MiB" }
    return 'unavailable'
}

function Get-RtxDiagnosticGpu {
    $smi = Get-Command nvidia-smi.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$smi) { 'NVIDIA telemetry: nvidia-smi is unavailable.'; return }
    $required = @('name','pci.bus_id','pci.device_id','pci.sub_device_id','vbios_version','driver_version')
    $optional = @('memory.total','memory.reserved','memory.free','ecc.mode.current')
    $rows = @(Read-RtxDiagnosticSmi $smi.Source ($required+$optional))
    $fallback = !$rows.Count
    if ($fallback) { $rows = @(Read-RtxDiagnosticSmi $smi.Source $required) }
    $fieldCount = if ($fallback) { $required.Count } else { $required.Count+$optional.Count }
    $found = $false
    foreach ($line in $rows) {
        $values = @($line.Split(',') | ForEach-Object { $_.Trim() })
        if ($values.Count -ne $fieldCount -or
            $values[1] -notmatch '\A(?:0000)?(?<bdf>[0-9a-f]{4}:[0-9a-f]{2}:[01][0-9a-f]\.[0-7])\z') { continue }
        $bdf = $Matches.bdf.ToLowerInvariant()
        if ($values[2] -notmatch '\A0x(?<device>[0-9a-f]{4})10de\z') { continue }
        $device = $Matches.device.ToLowerInvariant()
        $subsystem = 'unavailable'
        if ($values[3] -match '\A0x(?<subsystem>[0-9a-f]{8})\z') { $subsystem = $Matches.subsystem.ToLowerInvariant() }
        if ($fallback) {
            foreach ($field in $optional) { $values += [string](Read-RtxDiagnosticSmi $smi.Source @($field) $values[1] | Select-Object -First 1) }
        }
        $ecc = if ($values[9] -in @('Enabled','Disabled')) { $values[9] } else { 'unavailable' }
        $found = $true
        '{0} | PCI {1} | device 10de:{2} | subsystem {3}' -f (Format-RtxDiagnosticLabel $values[0]),$bdf,$device,$subsystem
        '  VBIOS: {0} | NVIDIA driver: {1}' -f (Format-RtxDiagnosticLabel $values[4]),(Format-RtxDiagnosticLabel $values[5])
        '  VRAM total: {0} | reserved: {1} | free: {2} | ECC: {3}' -f `
            (Format-RtxDiagnosticMiB $values[6]),(Format-RtxDiagnosticMiB $values[7]),(Format-RtxDiagnosticMiB $values[8]),$ecc
    }
    if (!$found) { 'NVIDIA telemetry: no usable PCI records returned by nvidia-smi.' }
}

function Get-RtxDiagnosticRegisterState([string]$Hex) {
    if ($Hex -eq '0xffffffff') { return 'no decode' }
    if ($Hex -like '0xbadf*') { return 'inaccessible' }
    return 'readable'
}

function Format-RtxDiagnosticFramebuffer([string]$Hex) {
    $state = Get-RtxDiagnosticRegisterState $Hex
    if ($state -ne 'readable') { return "$state ($Hex)" }
    return ('{0} MiB ({1})' -f [Convert]::ToUInt32($Hex.Substring(2),16),$Hex)
}

function Get-RtxDiagnosticLogEvidence([string]$Lines) {
    $bdf = '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]'
    $hex = '0x[0-9a-f]{8}'
    $prefix = '^(?:\[[^\r\n]{1,32}\][ \t]+(?:INFO[ \t]*:[ \t]+)?loader(?:::[a-z0-9_]+)*:[ \t]+)?'
    $target = 'unknown PCI address'
    $reported = 0
    foreach ($line in $Lines.Split("`n")) {
        if ($reported -ge 24) { 'Additional recognized EFI records omitted.'; break }
        $line = $line.TrimEnd("`r")
        $evidence = switch -Regex -CaseSensitive ($line) {
            ($prefix+"SAMPLE: GPU 10de:(?<device>[0-9a-f]{4}) @ (?<bdf>$bdf)$") {
                "Cold register sample: 10de:$($Matches.device) at $($Matches.bdf)"; break
            }
            ($prefix+'KIT-PROBE: [0-9a-f]{32} matched (?<count>[12])$') {
                "EFI read-only identity and power-state check logged for $($Matches.count) GPU(s)."; break
            }
            ($prefix+'KIT: [0-9a-f]{32} matched (?<count>[12]) target\(s\)$') {
                "EFI unlock target set logged for $($Matches.count) GPU(s)."; break
            }
            ($prefix+"SAMPLE FB_SIZE_MIB 0x1183a4 = (?<fb>$hex) \[(?:ok|NO_DECODE|PRIV_VIOLATION|UNDECODED|FLOORSWEPT|BADF_VARIANT)\]$") {
                'Cold usable framebuffer: {0}' -f (Format-RtxDiagnosticFramebuffer $Matches.fb); break
            }
            ($prefix+"SAMPLE (?<reg>VGA_WORKSPACE|MMU_PLM|MMU_LOCK_LO|MMU_LOCK_HI) 0x[0-9a-f]{6} = (?<value>$hex) \[[A-Za-z_]+\]$") {
                'Cold {0}: {1}' -f $Matches.reg,(Get-RtxDiagnosticRegisterState $Matches.value); break
            }
            ($prefix+"KIT: (?<bdf>$bdf) is in (?<state>D[123])\.") {
                "EFI power-state refusal: $($Matches.bdf) in $($Matches.state)."; break
            }
            ($prefix+"KIT: (?<bdf>$bdf) PCI (?<reason>I/O unavailable|identity unreadable or changed|power-management capability unavailable|power state unreadable)\.") {
                "EFI PCI refusal at $($Matches.bdf): $($Matches.reason)."; break
            }
            ($prefix+'KIT: live NVIDIA display set differs from the target manifest$') {
                'EFI identity refusal: the live NVIDIA display set differs from the staged list.'; break
            }
            ($prefix+"TX: ===== target [12]/[12]: 10de:[0-9a-f]{4} @ (?<bdf>$bdf) =====$") {
                $target = $Matches.bdf; break
            }
            ($prefix+"layout inputs: fb_mib=(?<fb>$hex) vga=(?<vga>$hex) mmu_plm=(?<plm>$hex) mmu_lo=(?<lo>$hex) mmu_hi=(?<hi>$hex) ") {
                $plm = Get-RtxDiagnosticRegisterState $Matches.plm
                if ($plm -eq 'readable') { $plm += ', lock bit '+([Convert]::ToUInt32($Matches.plm.Substring(2),16) -band 1) }
                'EFI layout at {0}: framebuffer {1}, VGA {2}, MMU PLM {3}, MMU lower {4}, MMU upper {5}' -f `
                    $target,(Format-RtxDiagnosticFramebuffer $Matches.fb),(Get-RtxDiagnosticRegisterState $Matches.vga),$plm,
                    (Get-RtxDiagnosticRegisterState $Matches.lo),(Get-RtxDiagnosticRegisterState $Matches.hi); break
            }
            ($prefix+'layout rejected: (?<reason>usable FB below 256 MiB|VGA base at or above usable FB|reservation calculation)$') {
                "EFI layout rejected at ${target}: $($Matches.reason)."; break
            }
            ($prefix+'(?:FINAL: KIT-STOP: |TX: )transaction failed: (?<reason>EIO|ENodev|ETimeout|EInval|ERange|EBusy|EAlready|EClaimUnreadable|EWarm)(?:[ .{]|$)') {
                "EFI transaction error at ${target}: $($Matches.reason)."; break
            }
            ($prefix+'SELECTOR RESULT: transaction complete$') { "EFI transaction complete at $target."; break }
            ($prefix+'CHAIN: StartImage -> handing control to the OS loader|'+$prefix+'CHAIN-PRE: start-time PE header probe ok - StartImage') {
                'EFI log records the start of the Windows handoff.'; break
            }
            ($prefix+'CHAIN: (?:failed:|bootmgfw returned unexpectedly)') { 'EFI log records a Windows handoff failure.'; break }
        }
        if ($evidence) { $evidence; $reported++ }
    }
    if (!$reported) { 'No recognized diagnostic records in the EFI log.' }
}

function Get-RtxDiagnosticUsb([string]$SelectedDrive,[string]$ExpectedVolume) {
    try {
        $usb = Get-RtxUsbRoot $SelectedDrive $ExpectedVolume
        $root = Get-Item -LiteralPath $usb -Force
        if (!$root.PSIsContainer -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe USB root.' }
    } catch { 'USB status: selected FAT32 USB identity could not be verified.'; return }

    $receipt = $null
    try {
        $targets = @(Get-RtxInventory)
        $package = Get-RtxPackagePath (Get-RtxDesktopWork $targets) $true
        $receipt = Get-RtxVerifiedPackage $package $targets (Get-RtxEngineManifest $script:RtxDiagnosticsKit)
    } catch { }

    try {
        $null = Get-RtxUsbRoot $SelectedDrive $ExpectedVolume
        $log = Join-Path $usb 'loader.log'
        if (!(Test-Path -LiteralPath $log)) {
            'EFI log: no loader.log on the selected USB.'
            return
        }
        $file = Get-RtxMediaFile $log
        $stream = [IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try {
            if ($stream.Length -gt 4MB) { 'EFI log: exceeds the 4 MiB diagnostic limit.'; return }
            $status = if ($receipt) { Get-RtxMediaStatus -Usb $usb -Receipt $receipt }
            if ($status -and $status.State -ne 'Blocked') {
                "USB status: $($status.State) / $($status.Title)"
                'EFI log handoff and complete transaction set: {0}' -f $(if ($status.CompleteHandoff) { 'verified' } else { 'unconfirmed' })
            } else { 'USB status: matching local package and layout could not be verified. Log indicators below are unverified.' }
            $reader = [IO.StreamReader]::new($stream)
            try { Get-RtxDiagnosticLogEvidence ($reader.ReadToEnd()) } finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
    } catch { 'EFI log: unavailable or unsafe to read.' }
}

function Invoke-RtxDiagnostics([string]$SelectedDrive,[string]$ExpectedVolume) {
    if ([bool]$SelectedDrive -ne [bool]$ExpectedVolume) { throw 'Specify both -Drive and -VolumeId, or omit both.' }
    . (Join-Path $script:RtxDiagnosticsKit 'RTX.ps1')
    'GPU Unlock Setup diagnostic report'
    'Review this report before sharing. Hardware serials, volume identifiers and raw EFI logs are omitted.'
    Get-RtxDiagnosticPlatform
    ''
    Get-RtxDiagnosticGpu
    if ($SelectedDrive) {
        ''
        Get-RtxDiagnosticUsb $SelectedDrive $ExpectedVolume
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    Invoke-RtxDiagnostics $Drive $VolumeId
}
