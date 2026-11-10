# SPDX-License-Identifier: GPL-2.0-only
# Read-only physical PCI inventory for the RTX 30/40 route.
$script:RtxInventoryKitRoot = Split-Path -Parent $PSScriptRoot

function Get-RtxInventoryCatalog {
    $catalog = @{}
    foreach ($file in @('rtx30-pci.json', 'rtx40-pci.json')) {
        $document = Get-Content -LiteralPath (Join-Path $script:RtxInventoryKitRoot $file) -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($document.schema_version -ne 1 -or $document.vendor_id -cne '10de' -or $document.devices -isnot [pscustomobject]) {
            throw "Invalid NVIDIA PCI catalog $file."
        }
        $entries = @($document.devices.PSObject.Properties)
        if (!$entries.Count) { throw "Empty NVIDIA PCI catalog $file." }
        foreach ($entry in $entries) {
            $device = $entry.Name
            $model = $entry.Value
            if ($device -cnotmatch '\A[0-9a-f]{4}\z' -or $catalog.ContainsKey($device) -or
                $model.label -isnot [string] -or [string]::IsNullOrWhiteSpace($model.label) -or
                $model.group -cnotin @('desktop', 'mobile', 'ada')) {
                throw "Invalid or duplicate device in NVIDIA PCI catalog $file."
            }
            # Family names select the firmware asset family, not the exact GPU die.
            $family = if ($file -ceq 'rtx40-pci.json' -or $model.group -ceq 'ada') { 'ad102' } else { 'ga102' }
            $catalog[$device] = @{ Family = $family; Label = $model.label }
        }
    }
    return $catalog
}

function ConvertTo-RtxInventory {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$NvidiaRows,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$WindowsRows,
        [Parameter(Mandatory)][hashtable]$Catalog
    )

    if ($NvidiaRows.Count -lt 1 -or $NvidiaRows.Count -gt 2) {
        throw 'NVIDIA must report exactly one or two physical GPUs.'
    }

    $windowsPattern = [regex]'(?i)\APCI\\VEN_10DE&DEV_(?<device>[0-9a-f]{4})&SUBSYS_(?<subsystem>[0-9a-f]{8})(?:&REV_[0-9a-f]{2})?\\[^\\\s]+\z'
    $instances = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $windowsCounts = @{}
    foreach ($row in $WindowsRows) {
        $pnp = [string]$row.PNPDeviceID
        if ($pnp -notmatch '\APCI\\VEN_10DE' -and [string]$row.Name -notmatch '\bNVIDIA\b') { continue }

        $identity = $windowsPattern.Match($pnp)
        if (!$identity.Success -or !$instances.Add($pnp)) {
            throw 'Windows reports a missing, malformed or duplicate NVIDIA PCI instance.'
        }
        $key = ($identity.Groups['device'].Value + ':' + $identity.Groups['subsystem'].Value).ToLowerInvariant()
        $windowsCounts[$key] = 1 + [int]$windowsCounts[$key]
    }
    if ($instances.Count -ne $NvidiaRows.Count) {
        throw 'NVIDIA and Windows disagree on the number of installed NVIDIA display controllers.'
    }

    # nvidia-smi pads the 16-bit PCI segment to eight hex digits on current drivers.
    # Preserve a real nonzero segment. The EFI probe only targets function 0.
    $nvidiaPattern = [regex]'(?i)\A[ \t]*(?:0000)?(?<bdf>[0-9a-f]{4}:[0-9a-f]{2}:[01][0-9a-f]\.0),[ \t]*0x(?<device>[0-9a-f]{4})10de,[ \t]*0x(?<subsystem>[0-9a-f]{8})(?:,(?<memory>[^,\r\n]*))?[ \t]*\z'
    $addresses = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $cards = foreach ($line in $NvidiaRows) {
        $row = $nvidiaPattern.Match($line)
        if (!$row.Success) { throw 'NVIDIA returned a malformed PCI identity.' }
        $bdf = $row.Groups['bdf'].Value.ToLowerInvariant()
        $device = $row.Groups['device'].Value.ToLowerInvariant()
        $subsystem = $row.Groups['subsystem'].Value.ToLowerInvariant()
        if (!$addresses.Add($bdf) -or $subsystem.Substring(0, 4) -cin @('0000', 'ffff') -or
            $subsystem.Substring(4, 4) -cin @('0000', 'ffff')) {
            throw 'NVIDIA reports a duplicate PCI address or an invalid subsystem.'
        }
        $model = $Catalog[$device]
        if (!$model) { throw "NVIDIA PCI device 10de:$device is outside the RTX 30/40 catalogs." }

        $key = $device + ':' + $subsystem
        if (!$windowsCounts.ContainsKey($key) -or $windowsCounts[$key] -lt 1) {
            throw 'NVIDIA and Windows disagree on the installed NVIDIA PCI device/subsystem identities.'
        }
        $windowsCounts[$key]--
        # This Windows driver reading is display telemetry. EFI reads its own memory geometry.
        $reportedMemory = $row.Groups['memory'].Value.Trim()
        $capacity = 0
        $memory = if ($reportedMemory -cmatch '\A[1-9][0-9]{0,9}\z' -and [int]::TryParse($reportedMemory, [ref]$capacity)) { $capacity }
        [pscustomobject][ordered]@{
            Bdf = $bdf
            Device = $device
            Subsystem = $subsystem
            MemoryMiB = $memory
            Family = $model.Family
            Label = $model.Label
        }
    }
    $cards | Sort-Object -Property Bdf
}

function Get-RtxInventory {
    $catalog = Get-RtxInventoryCatalog
    $smi = Get-Command nvidia-smi.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$smi) { throw 'NVIDIA nvidia-smi.exe is required to resolve physical PCI addresses.' }
    $identityFields = 'pci.bus_id,pci.device_id,pci.sub_device_id'
    # Windows PowerShell can surface native stderr before we can check the exit code.
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $nvidiaRows = @(& $smi.Source "--query-gpu=$identityFields,memory.total" '--format=csv,noheader,nounits' 2>$null)
    if ($LASTEXITCODE -ne 0) {
        $nvidiaRows = @(& $smi.Source "--query-gpu=$identityFields" '--format=csv,noheader,nounits' 2>$null)
        if ($LASTEXITCODE -ne 0) { throw 'NVIDIA could not read PCI identities.' }
    }
    $windowsRows = @(Get-CimInstance -ClassName Win32_VideoController -Property Name, PNPDeviceID -ErrorAction Stop)
    ConvertTo-RtxInventory -NvidiaRows $nvidiaRows -WindowsRows $windowsRows -Catalog $catalog
}

function Get-RtxCandidateUsb {
    $null = Get-Command Get-RtxUsbRoot -CommandType Function -ErrorAction Stop
    $mounted = Get-Volume -ErrorAction Stop |
        Where-Object { [string]$_.DriveLetter -match '\A[D-Z]\z' } |
        Group-Object -Property DriveLetter |
        Sort-Object -Property Name

    foreach ($entry in $mounted) {
        if ($entry.Count -ne 1) { continue }
        $volume = $entry.Group[0]
        [uint64]$freeBytes = 0
        if ($volume.FileSystem -ne 'FAT32' -or $volume.HealthStatus -ne 'Healthy' -or
            ![uint64]::TryParse([string]$volume.SizeRemaining, [ref]$freeBytes)) { continue }

        $letter = ([string]$volume.DriveLetter).ToUpperInvariant()
        try {
            $null = Get-RtxUsbRoot $letter
        } catch {
            # A device can be unreadable or removed while refreshing the list.
            continue
        }
        [pscustomobject]@{
            Letter = $letter
            Label = [string]$volume.FileSystemLabel
            FreeBytes = $freeBytes
            TotalBytes = [uint64]$volume.Size
            FileSystem = [string]$volume.FileSystem
            VolumeId = [string]$volume.UniqueId
        }
    }
}

function Get-RtxWindowsDisplayProblems {
    $devices=Get-CimInstance Win32_PnPEntity -Filter "PNPClass = 'Display'" `
        -Property Name,PNPDeviceID,ConfigManagerErrorCode,Present -ErrorAction Stop
    foreach($device in $devices) {
        if($device.Present -eq $false -or $device.PNPDeviceID -notmatch '^PCI\\VEN_10DE' -or !$device.ConfigManagerErrorCode){continue}
        $code=$device.ConfigManagerErrorCode
        $reason=switch($code) {
            12 {'Windows could not allocate enough PCI resources.'}
            43 {'Windows stopped the device after a driver error.'}
            default {'Check the GPU status in Device Manager.'}
        }
        "$($device.Name) reports Device Manager Code $code. $reason"
    }
}
