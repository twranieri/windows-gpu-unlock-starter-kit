# SPDX-License-Identifier: GPL-2.0-only
# Source-only coordinator. Check and plans never stage a USB or change settings.
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Check','Probe','Build','StageUnlock')][string]$Action='Check',
    [string]$Repo,
    [ValidatePattern('^[D-Zd-z]$')][string]$Drive,
    [string]$Assets,[string]$Python,[string]$Clang,[string]$LldLink,[string]$VcVars,
    [string]$ReportPath,[switch]$Execute
)
$script:UGPin='75071aa134616c3d65ad315e0cf2810bf34b191b'
$script:UGKitRoot=$PSScriptRoot
$script:UGDualSourceRoot=Join-Path $PSScriptRoot 'experimental/dual-gpu'
$script:UGKnownIds=@('220410de','220310de','248710de','250410de','248410de','24c910de','220a10de','248210de','221610de')
$script:UGCandidateSubsystems=@{'2482'='50521462';'2216'='20007377'}

function New-UGCheck($Name,$Status,$Detail,$RequiredFor=@('Probe','Build','StageUnlock')) {
    [pscustomobject]@{Name=$Name;Status=$Status;Detail=$Detail;RequiredFor=@($RequiredFor)}
}
function Test-UGUsb($Partition,$Disk,$Volume,$SystemDrive) {
    $letter=[string]$Partition.DriveLetter
    return ($letter -match '^[D-Zd-z]$' -and ($letter+':') -ne $SystemDrive -and
        [string]$Disk.BusType -eq 'USB' -and [string]$Volume.FileSystem -eq 'FAT32' -and
        -not $Partition.IsSystem -and -not $Partition.IsBoot -and -not $Disk.IsBoot -and -not $Disk.IsSystem)
}
function Get-UGRepositoryCheck([string]$Path) {
    try {
        $pairedEntry=Join-Path $Path 'research/dual/new-machine.ps1'
        $receipt=Join-Path $Path '.git/windows-gpu-unlock-dual-source.json'
        if((Test-Path -LiteralPath $pairedEntry) -or (Test-Path -LiteralPath $receipt) -or
           [IO.Path]::GetFileName([IO.Path]::GetFullPath($Path)) -eq 'Windows-GPU-UNLOCK-dual-dev') {
            return & {
                param($CheckedPath,$SourceRoot)
                . (Join-Path $SourceRoot 'Get-Source.ps1')
                $manifest=Get-UDManifest $SourceRoot
                Assert-UDSourceReceipt $CheckedPath $SourceRoot $manifest
                Assert-UDReviewedCheckout $CheckedPath $manifest (Join-Path $SourceRoot $manifest.Patch) -AllowWorkflowArtifacts
                $workflow='research/dual/new-machine.ps1'
                if(@($manifest.Files | Where-Object {$_.Path -ceq $workflow}).Count -ne 1 -or
                   !(Test-Path -LiteralPath (Join-Path $CheckedPath $workflow) -PathType Leaf)) {
                    throw 'Reviewed one/two-card pipeline is not available in this source package. Run Get-Source.ps1 -DualGpu -Execute after updating the kit.'
                }
                Assert-UDOrdinaryPath (Join-Path $CheckedPath 'deps/edk2/MdePkg/Include/Uefi.h') File
                $check=New-UGCheck 'Source' 'PASS' ('Reviewed one/two-card source receipt, base '+$manifest.SourceCommit+' and patched file hashes verified.')
                $check | Add-Member NoteProperty Workflow 'pair'
                $check | Add-Member NoteProperty SupportsPairWrite ($manifest.CanBuildGenericDualUnlock -is [bool] -and $manifest.CanBuildGenericDualUnlock)
                $check | Add-Member NoteProperty SupportsProbeOnly ($manifest.SupportsProbeOnly -is [bool] -and $manifest.SupportsProbeOnly)
                $check | Add-Member NoteProperty Revision $manifest.SourceCommit
                return $check
            } $Path $script:UGDualSourceRoot
        }
        $entry=Join-Path $Path 'research/profile/new-machine.ps1'
        $header=Join-Path $Path 'deps/edk2/MdePkg/Include/Uefi.h'
        if (!(Test-Path -LiteralPath $entry -PathType Leaf) -or !(Test-Path -LiteralPath $header -PathType Leaf)) {throw 'Workflow or pinned EDK2 header missing; finish the source/dependency setup.'}
        $head=@(& git -C $Path rev-parse HEAD 2>$null);$code=$LASTEXITCODE
        if ($code -ne 0 -or $head.Count -ne 1 -or $head[0].Trim() -ne $script:UGPin) {throw "Source must be pinned to $script:UGPin."}
        & git -C $Path diff --quiet HEAD -- 2>$null
        if ($LASTEXITCODE -ne 0) {throw 'Tracked source or dependency files changed; use a clean pinned checkout.'}
        $check=New-UGCheck 'Source' 'PASS' "Clean pinned legacy one-card source $script:UGPin"
        $check | Add-Member NoteProperty Workflow 'legacy'
        $check | Add-Member NoteProperty Revision $script:UGPin
        return $check
    } catch {return New-UGCheck 'Source' 'BLOCKED' $_.Exception.Message}
}
function ConvertFrom-UGCandidateEnvelope($Envelope) {
    $ids=@($Envelope.probe_device_ids)
    if(!$ids.Count -or @($ids | Select-Object -Unique).Count -ne $ids.Count){throw 'Invalid pinned candidate-ID list.'}
    foreach($id in $ids){if($id -isnot [string] -or $id -notmatch '^[0-9a-fA-F]{4}10[dD][eE]$'){throw 'Invalid pinned candidate-ID list.'}}
    return @($ids | ForEach-Object {$_.ToLowerInvariant()})
}
function Get-UGCandidateIds([string]$RepoPath) {
    $envelope=Get-Content -LiteralPath (Join-Path $RepoPath 'research/profile/proven.json') -Raw -ErrorAction Stop | ConvertFrom-Json
    return @(ConvertFrom-UGCandidateEnvelope $envelope)
}
function Get-UGGpuAssessment($Inventory,$AcceptedIds,[switch]$AllowObservation) {
    $name='GPU preliminary identity';$targets=@();$unqualified=@();$uncertain=$false
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $rows=@($Inventory | Where-Object {$null -ne $_})
    if(!$rows.Count){return New-UGCheck $name 'UNKNOWN' 'Windows returned no display-controller inventory; no NVIDIA target can be established.'}
    foreach($row in $rows){
        $pnp=[string]$row.PNPDeviceID
        $match=[regex]::Match($pnp,'(?i)^PCI\\VEN_([0-9a-f]{4})&DEV_([0-9a-f]{4})(?=&|\\|$)')
        if($match.Success -and $match.Groups[1].Value -ieq '10de'){
            if(!$seen.Add($pnp)){$uncertain=$true;continue}
            $device=$match.Groups[2].Value.ToLowerInvariant()
            $targets+=$device
            $identity=$device+'10de'
            $requiredSubsystem=$script:UGCandidateSubsystems[$device]
            if($AcceptedIds -notcontains $identity -or $script:UGKnownIds -notcontains $identity -or
               ($requiredSubsystem -and $pnp -notmatch ('(?i)&SUBSYS_'+$requiredSubsystem+'(?=&|\\|$)'))){$unqualified+=$device}
            continue
        }
        if([string]$row.Name -match '(?i)NVIDIA' -or $pnp -match '(?i)^PCI\\VEN_10DE'){$uncertain=$true}
    }
    if($uncertain){return New-UGCheck $name 'UNKNOWN' 'A possible NVIDIA controller has an incomplete or inconsistent PCI identity; Probe is blocked.'}
    if($targets.Count -gt 2){return New-UGCheck $name 'BLOCKED' 'More than two NVIDIA display controllers were found; this workflow accepts at most two.'}
    if(!$targets.Count){return New-UGCheck $name 'BLOCKED' 'No NVIDIA PCI display controller was identified for the pinned automatic LOCAL route.'}
    if($unqualified.Count) {
        $models=@()
        if($AllowObservation) {
            $catalog=Get-Content -LiteralPath (Join-Path $script:UGKitRoot 'rtx30-pci.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            if($catalog.schema_version -ne 1 -or $catalog.vendor_id -cne '10de'){throw 'Invalid RTX 30-series inventory catalog.'}
        }
        foreach($device in $unqualified) {
            $entry=if($AllowObservation){$catalog.devices.$device}
            if(!$entry -or $entry.group -cnotin @('desktop','mobile','ada')) {
                return New-UGCheck $name 'BLOCKED' "PCI 10de:$device is outside the reviewed candidate list and this route cannot collect an inventory for it."
            }
            $architecture=if($entry.group -ceq 'ada'){' (Ada)'}else{''}
            $models+=('PCI 10de:{0} {1}{2}' -f $device,$entry.label,$architecture)
        }
        $check=New-UGCheck $name 'OBSERVE' (($models -join ', ')+'. Probe can collect a read-only UEFI inventory. Build and StageUnlock require an admitted configuration for every NVIDIA card.') @('Build','StageUnlock')
        $check | Add-Member NoteProperty TargetCount $targets.Count
        return $check
    }
    $identities=($targets | ForEach-Object {'10de:'+$_}) -join ', '
    $check=New-UGCheck $name 'CANDIDATE' "$($targets.Count) card(s), PCI $identities match the preliminary ID list only. Chip/VRAM, firmware, topology and two whole-set cold captures still decide compatibility."
    $check | Add-Member NoteProperty TargetCount $targets.Count
    return $check
}

function Get-UGDefaultRepository {
    $paired=Join-Path $script:UGKitRoot 'Windows-GPU-UNLOCK-dual-dev'
    if(Test-Path -LiteralPath $paired -PathType Container){return $paired}
    return Join-Path $script:UGKitRoot 'Windows-GPU-UNLOCK'
}
function Get-UGGpuCheck([string]$RepoPath,[switch]$AllowObservation) {
    try {
        $ids=@(Get-UGCandidateIds $RepoPath)
        $inventory=@(Get-CimInstance -ClassName Win32_VideoController -Property Name,PNPDeviceID -ErrorAction Stop)
        return Get-UGGpuAssessment $inventory $ids -AllowObservation:$AllowObservation
    } catch {return New-UGCheck 'GPU preliminary identity' 'UNKNOWN' 'Could not read the pinned candidate list or Windows PCI display inventory. No GPU compatibility approval is inferred.'}
}
function Find-UGExe([string]$Given,[string]$Name,[string]$Fallback) {
    if ($Given) {if(Test-Path -LiteralPath $Given -PathType Leaf){return [IO.Path]::GetFullPath($Given)};return $null}
    $cmd=Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Source -notmatch '\\Microsoft\\WindowsApps\\') {return $cmd.Source}
    if ($Fallback -and (Test-Path -LiteralPath $Fallback -PathType Leaf)) {return $Fallback}
    return $null
}
function Get-UGDriverMemoryCheck {
    $name='GPU memory reported by Windows driver'
    try {
        $fallback=Join-Path $env:ProgramFiles 'NVIDIA Corporation/NVSMI/nvidia-smi.exe'
        $smi=Find-UGExe '' 'nvidia-smi.exe' $fallback
        if(!$smi){throw 'nvidia-smi is unavailable.'}
        $lines=@(& $smi '--query-gpu=pci.bus_id,memory.total' '--format=csv,noheader,nounits' 2>$null)
        if($LASTEXITCODE -ne 0 -or !$lines.Count){throw 'NVIDIA did not return GPU memory information.'}
        $devices=@()
        foreach($line in $lines) {
            if($line -notmatch '^\s*([0-9a-f]{4,8}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7])\s*,\s*([1-9][0-9]{0,5})\s*$') {
                throw 'Unexpected NVIDIA GPU memory information.'
            }
            $devices+=('{0} reports {1} MiB' -f $Matches[1],$Matches[2])
        }
        return New-UGCheck $name 'INFO' (($devices -join ', ')+'. The unlock profile uses the separate cold-boot VRAM measurement.') @()
    } catch {
        return New-UGCheck $name 'INFO' 'Driver memory information is unavailable. Use the cold-boot probe for exact profile evidence.' @()
    }
}
function Get-UGPython([string]$Given) {
    $exe=Find-UGExe $Given 'python.exe' ''
    if (!$exe -and !$Given) {
        $launcher=Find-UGExe '' 'py.exe' ''
        if($launcher){$candidate=@(& $launcher -3 -c 'import sys; print(sys.executable)' 2>$null);if($LASTEXITCODE -eq 0 -and $candidate.Count -eq 1){$exe=$candidate[0]}}
    }
    if (!$exe) {throw 'Python 3.10+ not found; supply -Python with its executable path.'}
    $result=@(& $exe -c 'import json,sys; print(json.dumps(dict(path=sys.executable,major=sys.version_info.major,minor=sys.version_info.minor)))' 2>$null)
    if ($LASTEXITCODE -ne 0) {throw 'Python did not run.'}
    $info=($result -join "`n") | ConvertFrom-Json
    if ($info.major -ne 3 -or $info.minor -lt 10 -or !(Test-Path -LiteralPath $info.path -PathType Leaf)) {throw 'Python 3.10+ is required.'}
    return [string]$info.path
}
function Get-UGVcVars([string]$Given) {
    if ($Given) {return Find-UGExe $Given '' ''}
    $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (!(Test-Path -LiteralPath $vswhere)) {return $null}
    $installation=@(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null)
    if ($LASTEXITCODE -eq 0 -and $installation.Count -eq 1) {return Find-UGExe (Join-Path $installation[0] 'VC/Auxiliary/Build/vcvars64.bat') '' ''}
    return $null
}
function Get-UGAssetCheck([string]$RepoPath,[string]$AssetPath) {
    try {
        $spec=@(Get-Content -LiteralPath (Join-Path $RepoPath 'unlock/assets.json') -Raw | ConvertFrom-Json)
        if ($spec.Count -ne 5 -or @($spec.Name | Select-Object -Unique).Count -ne 5) {throw 'Unexpected asset manifest.'}
        foreach($item in $spec){
            if ([IO.Path]::GetFileName($item.Name) -ne $item.Name) {throw 'Invalid asset filename.'}
            $file=Get-Item -LiteralPath (Join-Path $AssetPath $item.Name) -ErrorAction Stop
            if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Length -ne $item.Bytes -or
                (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -ne $item.Sha256) {throw "Asset did not match its pinned size/hash: $($item.Name)"}
        }
        return New-UGCheck 'Firmware assets' 'PASS' 'All five local assets match pinned sizes and SHA-256 hashes.' @('Build','StageUnlock')
    } catch {return New-UGCheck 'Firmware assets' 'BLOCKED' 'Five verified local firmware assets are needed for Build/StageUnlock; see upstream docs/ASSETS.en.md.' @('Build','StageUnlock')}
}
function Get-UGEnvelopeNotes([string]$Text) {
    $handles=[regex]::Split($Text,'(?m)^handle id=0x([0-9a-f]{16})\r?\n')
    $legacyVideo=@{};$displayOwners=@();$notes=@()
    for($index=1;$index -lt $handles.Length;$index+=2) {
        $id=$handles[$index];$body=$handles[$index+1]
        # EFI firmware volume file path for the BIOS video thunk (BiosVideo.inf).
        if($body -cmatch '(?m)^image-file-path-node raw=04061400f855cf2975b65d4f8f2fb87a3ecfd063\r?$' -and
           $body -cmatch "(?m)^driver image=0x$id binding=0x$id version="){$legacyVideo[$id]=$true}

        $pci=[regex]::Match($body,'(?ms)^protocol guid=4cf5b200-68b8-4ca5-9eec-b23e3f50029a\r?\n(.*?)(?=^protocol guid=|\z)')
        if(!$pci.Success){continue}
        $config=[regex]::Match($pci.Groups[1].Value,'(?m)^pci config-status=0x0000000000000000\r?\npci config-dwords=([0-9a-f]{4}10de) [0-9a-f]{4}([0-9a-f]{4}) 03[0-9a-f]{6}(?: |\r?$)')
        if(!$config.Success -or $script:UGKnownIds -cnotcontains $config.Groups[1].Value){continue}
        $device=$config.Groups[1].Value.Substring(0,4).ToUpperInvariant()
        $command=[Convert]::ToInt32($config.Groups[2].Value,16)
        $state=@()
        if($command -band 4){$state+='bus mastering enabled'}
        if(!($command -band 2)){$state+='memory decoding disabled'}
        if($state.Count){$notes+=('UEFI observed PCI 10DE:{0} command 0x{1:x4} ({2}). The probe requires memory decoding on and bus mastering off.' -f $device,$command,($state -join ', '))}

        if($pci.Groups[1].Value -cnotmatch '(?m)^opens status=0x0000000000000000 count=0x[0-9a-f]{16}\r?$'){continue}
        $owners=[regex]::Matches($pci.Groups[1].Value,'(?m)^open agent=0x([0-9a-f]{16}) controller=0x[0-9a-f]{16} attributes=0x00000000000000[13]0 count=0x0000000000000001\r?$')
        if($owners.Count -eq 1){$displayOwners+=$owners[0].Groups[1].Value}
    }
    foreach($owner in $displayOwners) {
        if($legacyVideo.ContainsKey($owner)) {
            'Legacy BIOS video owns an NVIDIA GPU. Confirm BIOS Mode is UEFI in msinfo32, then disable Launch CSM in firmware and take a fresh cold capture.'
            break
        }
    }
    $notes | Select-Object -Unique -First 2
}
function ConvertFrom-UGDiagnostic([string]$Text,[string]$FileName,[int]$ExpectedTargets=0,[switch]$PairMode) {
    if($FileName -notmatch '^DIAG\d\d\.TXT$'){throw 'Not a diagnostic capture filename.'}
    $reasons=@([regex]::Matches($Text,'(?m)^\s*incomplete reason=([a-zA-Z0-9_-]{1,80}) status=0x([0-9a-fA-F]{1,16})\r?$') |
        ForEach-Object {$_.Groups[1].Value+' (UEFI status 0x'+$_.Groups[2].Value.ToLowerInvariant()+')'} | Select-Object -Unique -First 5)
    $complete=$Text.Contains('probe-pci-handles=') -and $Text.Contains("capture-complete=1`r`n") -and !$reasons.Count
    if($PairMode) {
        $normalized=$Text.Replace("`r`n","`n")
        $headers=@([regex]::Matches($normalized,'(?m)^dual-probe-v1 max-targets=2 readonly=1$'))
        $summary=@([regex]::Matches($normalized,'(?m)^probe targets=([0-9a-f]{4}) cfg-incomplete=0000$'))
        $parts=@([regex]::Matches($normalized,'(?ms)^dual-card-begin index=([0-9a-f]{4})\n(.*?)^dual-card-end index=\1\n'))
        $markers=@([regex]::Matches($normalized,'(?m)^dual-card-(?:begin|end)'))
        $footers=@([regex]::Matches($normalized,'(?m)^capture-complete=.*$'))
        $results=@([regex]::Matches($normalized,'(?m)^diagnostic-result status=.*$'))
        $complete=$complete -and $ExpectedTargets -in @(1,2) -and $headers.Count -eq 1 -and
            $summary.Count -eq 1 -and [Convert]::ToInt32($summary[0].Groups[1].Value,16) -eq $ExpectedTargets -and
            $parts.Count -eq $ExpectedTargets -and $markers.Count -eq 2*$ExpectedTargets -and
            $footers.Count -eq 1 -and $footers[0].Value -ceq 'capture-complete=1' -and
            $results.Count -eq 1 -and $results[0].Value -ceq 'diagnostic-result status=0x0000000000000000' -and
            ![regex]::IsMatch($normalized,'(?m)^incomplete(?:\s|$)')
        $bdfs=@()
        for($index=0;$complete -and $index -lt $parts.Count;$index++) {
            if($parts[$index].Groups[1].Value -cne ('{0:x4}' -f $index)){$complete=$false;break}
            $targets=@([regex]::Matches($parts[$index].Groups[2].Value,'(?m)^probe-target seg=0x([0-9a-f]{1,4}) bus=0x([0-9a-f]{1,4}) dev=0x0000 fun=0x0000$'))
            if($targets.Count -ne 1){$complete=$false;break}
            $segment=[Convert]::ToInt32($targets[0].Groups[1].Value,16)
            $bus=[Convert]::ToInt32($targets[0].Groups[2].Value,16)
            if($bus -lt 1 -or $bus -gt 255){$complete=$false;break}
            $bdfs+=('{0:x8}:{1:x2}:00.0' -f $segment,$bus)
        }
        if($complete -and (($bdfs -join ',') -cne (@($bdfs | Sort-Object -Unique) -join ','))){$complete=$false}
        if(!$complete -and !$reasons.Count){$reasons=@('Not one complete whole-set capture for the current '+$ExpectedTargets+' card(s); two separate whole-set cold captures are required.')}
    } elseif($Text -match '(?m)^dual-probe-') {
        $complete=$false;$reasons=@('Experimental whole-set capture requires the reviewed one/two-card source route.')
    }
    $captureOnly=$Text -match '(?m)^[ \t]*probe-capture-only'
    if($captureOnly) {
        $complete=$false
        $reasons+=@('Read-only research capture. This GPU configuration is outside the unlock evidence path.')
    }
    if(!$complete -and !$reasons.Count){$reasons=@('Incomplete or unrecognized probe capture; review this file locally.')}
    if(!$complete -and ($reasons -match '^(?:dual|probe)-unreviewed-envelope ')) {
        $reasons+=@(Get-UGEnvelopeNotes $Text)
    }
    [pscustomobject]@{File=$FileName;Complete=$complete;CaptureOnly=$captureOnly;Reasons=$reasons;PairMode=[bool]$PairMode;TargetCount=$ExpectedTargets}
}
function Get-UGCaptureEvidence([string]$UsbLetter,[int]$ExpectedTargets=0,[switch]$PairMode) {
    $records=@()
    if($UsbLetter){
        foreach($file in @(Get-ChildItem -LiteralPath ($UsbLetter+':\RTX3090-UNLOCK') -File -ErrorAction SilentlyContinue)){
            if($file.Name -notmatch '^DIAG\d\d\.TXT$'){continue}
            try {
                if($file.Length -gt 16MB -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unexpected capture file.'}
                $records+=ConvertFrom-UGDiagnostic ([IO.File]::ReadAllText($file.FullName)) $file.Name -ExpectedTargets $ExpectedTargets -PairMode:$PairMode
            } catch {$records+=[pscustomobject]@{File=$file.Name;Complete=$false;Reasons=@('Capture could not be read safely; review it locally.')}}
        }
    }
    [pscustomobject]@{CompleteCount=@($records | Where-Object Complete).Count;Files=$records;PairMode=[bool]$PairMode;TargetCount=$ExpectedTargets}
}
function Get-UGCaptureCheck($Evidence) {
    $failed=@($Evidence.Files | Where-Object {!$_.Complete -and (!$_.CaptureOnly -or $_.Reasons.Count -gt 1)})
    if($Evidence.CompleteCount -ge 2){
        $detail=if($Evidence.PairMode){'At least two complete whole-set captures exist for the current '+$Evidence.TargetCount+' card(s).'}else{'At least two complete files exist.'}
        return New-UGCheck 'Existing probe evidence' 'INFO' ($detail+' Upstream must still verify agreement, exact identity, firmware and cold state. Older incomplete files are not counted.') @()
    }
    if($failed.Count){
        $summary=@($failed | Select-Object -First 3 | ForEach-Object {$_.File+': '+($_.Reasons -join '; ')}) -join ' | '
        $explanation=if($summary -match '(?:dual|probe)-unreviewed-envelope'){'The diagnostic refused the captured PCI identity or PCI resource/state conditions. '}else{'The diagnostic did not complete. '}
        return New-UGCheck 'Existing probe evidence' 'BLOCKED' ($explanation+$summary+' Build/StageUnlock remain blocked. Review the cause before an explicit Probe retry; unchanged reboots are not a fix. Preserve failed evidence locally.') @('Build','StageUnlock')
    }
    if(@($Evidence.Files | Where-Object CaptureOnly).Count){
        return New-UGCheck 'Existing probe evidence' 'INFO' 'Read-only research captures are available. The unlock workflow requires captures for an admitted configuration.' @()
    }
    return New-UGCheck 'Existing probe evidence' 'INFO' 'No refused captures were found. Two separate complete cold captures are still required.' @()
}
function Get-UGCaptureCount([string]$UsbLetter) {
    return (Get-UGCaptureEvidence $UsbLetter).CompleteCount
}
function Get-UGReadiness($Options) {
    $checks=New-Object 'System.Collections.Generic.List[object]'
    $selectedRepo=if($Options.Repo){$Options.Repo}else{Get-UGDefaultRepository}
    $config=[ordered]@{Repo=[IO.Path]::GetFullPath($selectedRepo);Drive=$null;WindowsEspGuid=$null;Assets=$Options.Assets;Python=$null;Clang=$null;LldLink=$null;VcVars=$null;Workflow='legacy';TargetCount=0;PairWriteReady=$false;SupportsProbeOnly=$false;InventoryOnly=$false;SourceRevision=$script:UGPin}
    if (!$config.Assets){$config.Assets=Join-Path $config.Repo 'assets'}
    $source=Get-UGRepositoryCheck $config.Repo;$checks.Add($source)
    if($source.Workflow){$config.Workflow=$source.Workflow}
    if($source.SupportsPairWrite){$config.PairWriteReady=$true}
    if($source.Revision){$config.SourceRevision=$source.Revision}
    $config.SupportsProbeOnly=$source.Status -eq 'PASS' -and $source.Workflow -eq 'pair' -and $source.SupportsProbeOnly -eq $true
    $gpu=Get-UGGpuCheck $config.Repo -AllowObservation:$config.SupportsProbeOnly;$checks.Add($gpu)
    if($Options.Action -eq 'Check'){$checks.Add((Get-UGDriverMemoryCheck))}
    $config.InventoryOnly=$gpu.Status -eq 'OBSERVE'
    if($gpu.TargetCount){$config.TargetCount=[int]$gpu.TargetCount}
    if($config.TargetCount -eq 2 -and $config.Workflow -ne 'pair') {
        $checks.Add((New-UGCheck 'One/two-card source route' 'BLOCKED' 'Two cards require the reviewed patched pipeline. Run .\Get-Source.ps1 -DualGpu -Execute, finish dependencies, then rerun Start.ps1; its patched checkout is selected automatically.'))
    }
    if($config.Workflow -eq 'pair' -and !$source.SupportsPairWrite) {
        $checks.Add((New-UGCheck 'Reviewed pair write pipeline' 'BLOCKED' 'This reviewed source package does not yet supply the complete pair build/stage pipeline. Source availability is separate from per-machine host-test permission.' @('Build','StageUnlock')))
    }
    try {
        $systems=@(Get-Partition -ErrorAction Stop | Where-Object IsSystem)
        if($systems.Count -ne 1 -or !$systems[0].Guid -or [guid]$systems[0].Guid -eq [guid]::Empty){throw 'Expected one current system EFI partition with a GPT GUID.'}
        $systemDisk=Get-Disk -Number $systems[0].DiskNumber -ErrorAction Stop
        if([string]$systemDisk.PartitionStyle -ne 'GPT'){throw 'Current system disk is not GPT.'}
        $config.WindowsEspGuid=[guid]$systems[0].Guid
        $checks.Add((New-UGCheck 'Windows EFI partition' 'PASS' 'Current system EFI partition found; its GUID stays local.'))
    } catch {$checks.Add((New-UGCheck 'Windows EFI partition' 'UNKNOWN' 'Could not identify one current GPT system EFI partition; run the check in an administrator PowerShell.'))}
    try {$secure=Confirm-SecureBootUEFI -ErrorAction Stop;$status=if($secure){'BLOCKED'}else{'PASS'};$checks.Add((New-UGCheck 'Secure Boot' $status $(if($secure){'Enabled; upstream requires it disabled.'}else{'Disabled.'})))}
    catch {$checks.Add((New-UGCheck 'Secure Boot' 'UNKNOWN' 'Cannot read Secure Boot state; check UEFI mode and rerun as administrator.'))}
    try {
        $volume=Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        $decrypted=([string]$volume.VolumeStatus -eq 'FullyDecrypted' -and [string]$volume.ProtectionStatus -eq 'Off' -and $volume.EncryptionPercentage -eq 0)
        $checks.Add((New-UGCheck 'Windows encryption' $(if($decrypted){'PASS'}else{'BLOCKED'}) $(if($decrypted){'Fully decrypted, protection off.'}else{'Upstream requires the Windows volume fully decrypted with protection off.'})))
    } catch {$checks.Add((New-UGCheck 'Windows encryption' 'UNKNOWN' 'Cannot verify encryption state; rerun as administrator. Unknown is never treated as off.'))}
    try {$fast=(Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction Stop).HiberbootEnabled
        $checks.Add((New-UGCheck 'Fast Startup' $(if($fast -eq 0){'PASS'}else{'BLOCKED'}) $(if($fast -eq 0){'Off.'}else{'On; full cold captures require Fast Startup off.'})))}
    catch {$checks.Add((New-UGCheck 'Fast Startup' 'UNKNOWN' 'Fast Startup state could not be verified.'))}
    try {$config.Python=Get-UGPython $Options.Python;$checks.Add((New-UGCheck 'Python' 'PASS' $config.Python))}
    catch {$checks.Add((New-UGCheck 'Python' 'BLOCKED' $_.Exception.Message))}
    foreach($tool in @('Clang','LldLink')){
        $name=if($tool -eq 'Clang'){'clang.exe'}else{'lld-link.exe'}
        $fallback=if($tool -eq 'LldLink' -and $config.Clang){Join-Path (Split-Path $config.Clang) $name}else{Join-Path $env:ProgramFiles ('LLVM/bin/'+$name)}
        $config[$tool]=Find-UGExe $Options[$tool] $name $fallback
        $good=$false
        if($config[$tool]){$version=(@(& $config[$tool] --version 2>$null) -join ' ');$good=($LASTEXITCODE -eq 0 -and $version -match '(?<!\d)20\.1\.8(?!\d)')}
        $checks.Add((New-UGCheck $tool $(if($good){'PASS'}else{'BLOCKED'}) $(if($good){$config[$tool]}else{'LLVM clang and lld-link 20.1.8 are required; provide explicit tool paths.'})))
    }
    $config.VcVars=Get-UGVcVars $Options.VcVars
    $checks.Add((New-UGCheck 'MSVC build tools' $(if($config.VcVars){'PASS'}else{'BLOCKED'}) $(if($config.VcVars){$config.VcVars}else{'Install MSVC C++ Build Tools + Windows SDK, or provide -VcVars.'}) @('Build','StageUnlock')))
    $checks.Add((Get-UGAssetCheck $config.Repo $config.Assets))
    try {
        $candidates=@()
        foreach($part in @(Get-Partition -ErrorAction Stop | Where-Object DriveLetter)){
            if($Options.Drive -and [string]$part.DriveLetter -ne $Options.Drive){continue}
            try {
                $disk=Get-Disk -Number $part.DiskNumber -ErrorAction Stop
                if([string]$disk.BusType -ne 'USB'){continue}
                $vol=Get-Volume -DriveLetter $part.DriveLetter -ErrorAction Stop
                if(Test-UGUsb $part $disk $vol $env:SystemDrive){$candidates+=([string]$part.DriveLetter).ToUpperInvariant()}
            } catch {if($Options.Drive){throw}}
        }
        if($candidates.Count -ne 1){throw 'Select exactly one existing FAT32 USB using -Drive X. System/boot disks are refused.'}
        $config.Drive=$candidates[0];$checks.Add((New-UGCheck 'USB' 'PASS' ($config.Drive+': is a FAT32 USB data volume.')))
    } catch {$checks.Add((New-UGCheck 'USB' 'BLOCKED' $_.Exception.Message))}
    $pairMode=$config.Workflow -eq 'pair' -or $config.TargetCount -eq 2
    $evidence=Get-UGCaptureEvidence $config.Drive -ExpectedTargets $config.TargetCount -PairMode:$pairMode
    $checks.Add((Get-UGCaptureCheck $evidence))
    [pscustomobject]@{Checks=@($checks.ToArray());Config=$config;CaptureCount=$evidence.CompleteCount;CaptureEvidence=$evidence}
}
function Get-UGDecision($Readiness,[string]$SelectedAction,[bool]$DoExecute) {
    $errors=@($Readiness.Checks | Where-Object {$_.RequiredFor -contains $SelectedAction -and $_.Status -ne 'PASS' -and
        !($_.Name -eq 'GPU preliminary identity' -and $_.Status -eq 'CANDIDATE')} | ForEach-Object {$_.Name+': '+$_.Detail})
    if($SelectedAction -ne 'Check' -and @($Readiness.Checks | Where-Object Name -eq 'GPU preliminary identity').Count -ne 1){$errors+='GPU preliminary identity was not established; Probe/Build/StageUnlock cannot proceed.'}
    if($SelectedAction -ne 'Check' -and $Readiness.Config.TargetCount -eq 2 -and $Readiness.Config.Workflow -ne 'pair'){$errors+='Two-card execution requires the verified one/two-card source route; legacy dispatch is refused.'}
    if($SelectedAction -in @('Build','StageUnlock') -and $Readiness.Config.Workflow -eq 'pair' -and !$Readiness.Config.PairWriteReady){$errors+='The reviewed source package does not include the complete one/two-card build/stage pipeline.'}
    if($SelectedAction -eq 'Probe' -and !$Readiness.Config.InventoryOnly -and $Readiness.CaptureCount -ge 2){$errors+='Two complete capture files exist. Choose Build so the upstream checker can assess them.'}
    if($SelectedAction -in @('Build','StageUnlock') -and $Readiness.CaptureCount -lt 2){$errors+='Need at least two complete probe captures from separate full shutdowns. Run Probe first.'}
    [pscustomobject]@{Action=$SelectedAction;Blockers=$errors;WillExecute=($SelectedAction -ne 'Check' -and $DoExecute -and $errors.Count -eq 0);PlanOnly=(!$DoExecute -and $SelectedAction -ne 'Check')}
}
function New-UGPipelineParameters($Config,[string]$SelectedAction) {
    if($SelectedAction -notin @('Probe','Build','StageUnlock')){throw 'Check cannot invoke the upstream pipeline.'}
    $options=@{Drive=$Config.Drive;WindowsEspGuid=[guid]$Config.WindowsEspGuid;Assets=$Config.Assets;Python=$Config.Python;Clang=$Config.Clang;LldLink=$Config.LldLink}
    if($Config.VcVars){$options.VcVars=$Config.VcVars}
    if($SelectedAction -eq 'StageUnlock'){$options.StageUnlock=$true}
    if($SelectedAction -eq 'Probe' -and $Config.SupportsProbeOnly){$options.ProbeOnly=$true}
    return $options
}
function Invoke-UGPipeline($Config,[string]$SelectedAction) {
    $options=New-UGPipelineParameters $Config $SelectedAction
    if($Config.Workflow -eq 'pair') {
        $source=Get-UGRepositoryCheck $Config.Repo
        if($source.Status -ne 'PASS' -or $source.Workflow -ne 'pair' -or
           ($SelectedAction -in @('Build','StageUnlock') -and !$source.SupportsPairWrite) -or
           ($options.ProbeOnly -and !$source.SupportsProbeOnly)) {
            throw 'Reviewed paired source integrity or pipeline availability changed; nothing was dispatched.'
        }
    }
    $entry=Get-UGPipelineEntry $Config
    & $entry @options | Out-Host
    if(!$? -or $LASTEXITCODE -ne 0){throw 'Upstream preparation refused or failed; read its message. No later step was attempted.'}
}
function Get-UGPipelineEntry($Config) {
    if($Config.TargetCount -eq 2 -and $Config.Workflow -ne 'pair'){throw 'Legacy pipeline cannot execute a two-card plan.'}
    $relative=if($Config.Workflow -eq 'pair'){'research/dual/new-machine.ps1'}else{'research/profile/new-machine.ps1'}
    return Join-Path $Config.Repo $relative
}
function Invoke-UGExecution($Readiness,[string]$SelectedAction,[bool]$DoExecute) {
    $decision=Get-UGDecision $Readiness $SelectedAction $DoExecute
    if($decision.WillExecute){Invoke-UGPipeline $Readiness.Config $SelectedAction}
    return $decision
}
function Invoke-UGMain($Options) {
    $ErrorActionPreference='Stop'
    $readiness=Get-UGReadiness $Options
    $readiness.Checks | Select-Object Name,Status,Detail | Format-Table -Wrap -AutoSize | Out-Host
    $decision=Get-UGDecision $readiness $Options.Action ([bool]$Options.Execute)
    Write-Host "Complete probe files: $($readiness.CaptureCount)/2. File count is not proof of compatibility or separate cold boots."
    if($decision.Blockers.Count){Write-Host ('Blocked: '+($decision.Blockers -join "`n"))}
    elseif($decision.PlanOnly){Write-Host "PLAN ONLY: $($Options.Action). Add -Execute to run this step after reviewing the checks."}
    if($Options.ReportPath){
        $report=[ordered]@{SourceRevision=$readiness.Config.SourceRevision;CheckedUtc=[DateTime]::UtcNow.ToString('o');Readiness=$readiness;Decision=$decision}
        $target=[IO.Path]::GetFullPath($Options.ReportPath)
        if(Test-Path -LiteralPath $target){throw 'Choose a new report filename; reports are never overwritten.'}
        $stream=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {$writer=New-Object IO.StreamWriter($stream,(New-Object Text.UTF8Encoding($false)));$writer.Write(($report | ConvertTo-Json -Depth 8));$writer.Flush()} finally {if($writer){$writer.Dispose()}else{$stream.Dispose()}}
        Write-Host 'Local report saved. It includes tool paths and your local EFI GUID; do not include it in public posts.'
    }
    if($Options.Execute -and $Options.Action -ne 'Check' -and $decision.Blockers.Count){throw 'Readiness checks blocked this step; nothing was executed.'}
    if($Options.Action -eq 'Probe' -and @($readiness.Checks | Where-Object {$_.Name -eq 'Existing probe evidence' -and $_.Status -eq 'BLOCKED'}).Count){
        Write-Host 'This is a diagnostic retry, not a compatibility approval. Review the refusal above and correct its cause before another cold capture. Existing private evidence is preserved by the upstream workflow.'
    }
    $null=Invoke-UGExecution $readiness $Options.Action ([bool]$Options.Execute)
    if($decision.WillExecute -and $Options.Action -eq 'Probe'){
        if($readiness.Config.InventoryOnly){Write-Host 'Inventory probe staged. Boot the USB once after a full shutdown and keep the resulting diagnostic for review.'}
        else{Write-Host 'Probe staged. Fully shut down, boot the USB, let Windows return, then do a second full-shutdown USB boot. Run Build afterward.'}
    }
    if($decision.WillExecute -and $Options.Action -eq 'Build'){Write-Host 'Build/test step finished. Review upstream output; StageUnlock is a separate explicit step.'}
    if($decision.WillExecute -and $Options.Action -eq 'StageUnlock'){Write-Host 'Unlock files staged. Read the upstream USB guide before the supervised first cold boot. No boot priority was changed.'}
    if($Options.Action -eq 'Check'){
        $next=if($readiness.CaptureCount -ge 2 -and !$readiness.Config.InventoryOnly){'Build'}else{'Probe'}
        $nextDecision=Get-UGDecision $readiness $next $false
        if($nextDecision.Blockers.Count){Write-Host "Check only: $next is blocked by the checks above. Do not stage or repeat USB boots until the reason is addressed."}
        elseif(@($readiness.Checks | Where-Object {$_.Name -eq 'Existing probe evidence' -and $_.Status -eq 'BLOCKED'}).Count){Write-Host 'Check only: review the diagnostic refusal above. Do not repeat unchanged boots. After correcting the cause, an explicit Probe retry can prepare another diagnostic capture; it does not authorize an unlock.'}
        else{Write-Host "Check only: preparation checks allow a $next plan. GPU identity remains a candidate; no compatibility or unlock success is established."}
    }
}
if($MyInvocation.InvocationName -ne '.'){
    $options=@{Action=$Action;Repo=$Repo;Drive=$Drive;Assets=$Assets;Python=$Python;Clang=$Clang;LldLink=$LldLink;VcVars=$VcVars;ReportPath=$ReportPath;Execute=$Execute}
    Invoke-UGMain $options
}
