# SPDX-License-Identifier: GPL-2.0-only
# Synthetic Windows/NVIDIA and Storage inventory rows. No live hardware calls.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../rtx/Inventory.ps1')
$catalog = Get-RtxInventoryCatalog
$script:Checks = 0

function Assert-Inventory($Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
    $script:Checks++
}

function New-DisplayRow([string]$Device, [string]$Subsystem, [string]$Instance) {
    [pscustomobject]@{
        Name = 'NVIDIA Display Adapter'
        PNPDeviceID = "PCI\VEN_10DE&DEV_$Device&SUBSYS_$Subsystem&REV_A1\$Instance"
    }
}

function Assert-Refused([string[]]$Nvidia, [object[]]$Windows, [string]$Reason) {
    $emitted = [Collections.Generic.List[object]]::new()
    $failure = $null
    try {
        ConvertTo-RtxInventory -NvidiaRows $Nvidia -WindowsRows $Windows -Catalog $catalog |
            ForEach-Object { $emitted.Add($_) }
    } catch { $failure = $_ }
    Assert-Inventory ($failure -and $failure.Exception.Message -match $Reason -and !$emitted.Count) "Unexpected inventory result: $failure"
}

$gaRow = '00000000:2B:00.0, 0x220410DE, 0x147D10DE, 24576'
$adRow = '00000000:03:00.0, 0x278210DE, 0x40E81458, 12288'
$ga = New-DisplayRow '2204' '147D10DE' 'one'
$ad = New-DisplayRow '2782' '40E81458' 'two'
$amd = [pscustomobject]@{ Name = 'AMD Radeon Graphics'; PNPDeviceID = 'PCI\VEN_1002&DEV_164E&SUBSYS_88771043\other' }
$virtual = [pscustomobject]@{ Name = 'Virtual display adapter'; PNPDeviceID = 'ROOT\DISPLAY\0000' }

Assert-Inventory ($catalog.Count -eq 73) 'The 48 RTX 30 and 25 RTX 40 IDs must be distinct.'
$one = @(ConvertTo-RtxInventory -NvidiaRows @($gaRow) -WindowsRows @($amd,$ga,$virtual) -Catalog $catalog)
Assert-Inventory ($one.Count -eq 1 -and $one[0].Bdf -ceq '0000:2b:00.0' -and $one[0].Device -ceq '2204' -and
    $one[0].Subsystem -ceq '147d10de' -and $one[0].MemoryMiB -is [int] -and $one[0].MemoryMiB -eq 24576 -and
    $one[0].Family -ceq 'ga102' -and $one[0].Label -ceq 'GeForce RTX 3090') 'Single Ampere inventory or other-display filtering failed.'
$pair = @(ConvertTo-RtxInventory -NvidiaRows @($gaRow,$adRow) -WindowsRows @($ad,$ga) -Catalog $catalog)
Assert-Inventory ($pair.Count -eq 2 -and $pair[0].Device -ceq '2782' -and $pair[0].Family -ceq 'ad102' -and
    $pair[0].Subsystem -ceq '40e81458' -and $pair[1].Family -ceq 'ga102') 'Mixed pair was not sorted and classified by BDF.'

$gaTwin = New-DisplayRow '2204' '147D10DE' 'three'
$twins = @(ConvertTo-RtxInventory -NvidiaRows @($gaRow, $gaRow.Replace('00000000:2B', '00001234:02')) -WindowsRows @($gaTwin,$ga) -Catalog $catalog)
Assert-Inventory ($twins.Count -eq 2 -and $twins[1].Bdf -ceq '1234:02:00.0' -and
    $twins[0].Subsystem -ceq $twins[1].Subsystem) 'Identical cards or a nonzero PCI segment were lost.'

foreach ($series in @(30,40)) {
    $table = Get-Content -LiteralPath (Join-Path $PSScriptRoot "../rtx$series-pci.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($entry in $table.devices.PSObject.Properties) {
        $device = $entry.Name
        $family = if ($series -eq 40 -or $device -cin @('2822','28a3','28e3')) { 'ad102' } else { 'ga102' }
        $card = ConvertTo-RtxInventory -NvidiaRows @("0000:02:00.0, 0x${device}10de, 0x12341043, 8192") `
            -WindowsRows @(New-DisplayRow $device '12341043' 'one') -Catalog $catalog
        Assert-Inventory ($card.Device -ceq $device -and $card.Family -ceq $family) "Wrong asset family for device $device."
    }
}

foreach ($case in @(@('2206',10240), @('2216',10240), @('220a',12288), @('2504',12288), @('2504',8192))) {
    $device, $memory = $case
    $card = ConvertTo-RtxInventory -NvidiaRows @("0000:02:00.0, 0x${device}10de, 0x12341043, $memory") `
        -WindowsRows @(New-DisplayRow $device '12341043' 'one') -Catalog $catalog
    Assert-Inventory ($card.Family -ceq 'ga102' -and $card.MemoryMiB -eq $memory) "Wrong VRAM or family for device $device."
}

Assert-Refused @() @() 'exactly one or two'
Assert-Refused @($gaRow,$adRow,$gaRow) @($ga,$ad,$gaTwin) 'exactly one or two'
Assert-Refused @($gaRow,$gaRow.Replace('00000000:2B','0000:2b')) @($ga,$gaTwin) 'duplicate PCI address'
Assert-Refused @($gaRow,$adRow) @($ga,$ga) 'duplicate NVIDIA PCI instance'
Assert-Refused @($gaRow,$adRow) @($ga,$gaTwin) 'device/subsystem identities'
Assert-Refused @($gaRow,$adRow.Replace('40E81458','00011458')) @($ga,$ad) 'device/subsystem identities'
Assert-Refused @($gaRow) @($amd,$virtual) 'number of installed NVIDIA'
Assert-Refused @($gaRow) @($ga,$ad) 'number of installed NVIDIA'
Assert-Refused @($gaRow) @([pscustomobject]@{ Name = 'NVIDIA Display Adapter'; PNPDeviceID = 'PCI\VEN_10DE&DEV_2204\missing' }) 'malformed'
Assert-Refused @($gaRow) @([pscustomobject]@{ Name = 'NVIDIA Display Adapter'; PNPDeviceID = $amd.PNPDeviceID }) 'malformed'
foreach ($device in @('1e04','24b0','25a7','2b85','ffff')) {
    Assert-Refused @($gaRow.Replace('2204',$device)) @(New-DisplayRow $device '147d10de' 'one') 'outside the RTX 30/40 catalogs'
}
foreach ($badRow in @($gaRow.Replace('220410DE','22041002'), $gaRow.Replace('24576','[N/A]'),
    $gaRow.Replace('24576','2147483648'), $gaRow.Replace('24576','0'), $gaRow.Replace('24576','24576 MiB'),
    $gaRow.Replace('00000000:','00010000:'), $gaRow.Replace(':00.0',':20.0'),
    $gaRow.Replace(':00.0',':00.1'), $gaRow.Replace(':00.0',':00.7'), $gaRow.Replace(':00.0',':00.8'))) {
    Assert-Refused @($badRow) @($ga) 'malformed PCI identity or VRAM'
}
foreach ($badSubsystem in @('00000000', '000010DE', 'FFFF10DE', '147D0000', '147DFFFF')) {
    Assert-Refused @($gaRow.Replace('147D10DE',$badSubsystem)) @(New-DisplayRow '2204' $badSubsystem 'one') 'invalid subsystem'
}

& {
    . (Join-Path $PSScriptRoot '../rtx/Media.ps1')

    function New-UsbTestVolume($Letter, $Label, $FreeBytes, $FileSystem = 'FAT32', $Health = 'Healthy') {
        [pscustomobject]@{
            DriveLetter = $Letter
            FileSystemLabel = $Label
            SizeRemaining = $FreeBytes
            FileSystem = $FileSystem
            HealthStatus = $Health
        }
    }

    $volumes = @(
        New-UsbTestVolume 'z' $null 0
        New-UsbTestVolume 'N' 'Wrong filesystem' 100 'NTFS'
        New-UsbTestVolume 'F' 'System partition' 100
        New-UsbTestVolume 'Q' 'Removed before disk query' 100
        New-UsbTestVolume 'G' 'Boot disk' 100
        New-UsbTestVolume 'E' 'Unlock USB' (32GB)
        New-UsbTestVolume 'W' 'Unhealthy' 100 'FAT32' 'Warning'
        New-UsbTestVolume 'L' 'Internal disk' 100
        New-UsbTestVolume 'M' 'No capacity reading' $null
        New-UsbTestVolume 'Y' 'Duplicate letter' 100
        New-UsbTestVolume 'y' 'Duplicate letter' 100
        New-UsbTestVolume $null 'Unmounted' 100
    )
    function Get-Volume {
        [CmdletBinding()]
        param([string]$DriveLetter)
        if (!$DriveLetter) {
            if ($failEnumeration) { throw 'Storage provider unavailable' }
            return $volumes
        }
        $volumes | Where-Object DriveLetter -EQ $DriveLetter
    }
    function Get-Partition {
        [CmdletBinding()]
        param([string]$DriveLetter)
        [pscustomobject]@{
            DiskNumber = [int][char]$DriveLetter
            IsSystem = $DriveLetter -eq 'F'
            IsBoot = $false
        }
    }
    function Get-Disk {
        [CmdletBinding()]
        param([int]$Number)
        if ([char]$Number -eq 'Q') { throw 'USB removed' }
        [pscustomobject]@{
            BusType = if ([char]$Number -eq 'L') { 'SATA' } else { 'USB' }
            IsBoot = [char]$Number -eq 'G'
            IsSystem = $false
            IsOffline = $false
            IsReadOnly = $false
        }
    }

    $failEnumeration = $false
    $candidates = @(Get-RtxCandidateUsb)
    Assert-Inventory ($candidates.Count -eq 2 -and $candidates[0].Letter -ceq 'E' -and
        $candidates[1].Letter -ceq 'Z') 'USB candidates must be sorted, healthy, mounted FAT32 USB data volumes.'
    Assert-Inventory ($candidates[0].Label -ceq 'Unlock USB' -and $candidates[0].FreeBytes -is [uint64] -and
        $candidates[0].FreeBytes -eq 32GB -and $candidates[1].Label -ceq '' -and
        $candidates[1].FreeBytes -eq 0) 'USB labels or free byte counts were lost.'

    $failEnumeration = $true
    $failure = $null
    try { $null = Get-RtxCandidateUsb } catch { $failure = $_ }
    Assert-Inventory ($failure.Exception.Message -eq 'Storage provider unavailable') 'A failed USB refresh looked like an empty list.'
}

Write-Output "PASS $script:Checks RTX inventory checks with synthetic Windows, NVIDIA and Storage rows."
