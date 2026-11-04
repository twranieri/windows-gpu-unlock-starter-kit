# SPDX-License-Identifier: GPL-2.0-only
# Synthetic Windows/NVIDIA inventory rows. No live hardware calls.
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
    $gaRow.Replace('00000000:','00010000:'), $gaRow.Replace(':00.0',':20.0'), $gaRow.Replace(':00.0',':00.8'))) {
    Assert-Refused @($badRow) @($ga) 'malformed PCI identity or VRAM'
}
Assert-Refused @($gaRow.Replace('147D10DE','00000000')) @(New-DisplayRow '2204' '00000000' 'one') 'invalid subsystem'

Write-Output "PASS $script:Checks RTX inventory checks with synthetic Windows and NVIDIA rows."
