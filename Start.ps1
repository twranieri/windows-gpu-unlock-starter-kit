# SPDX-License-Identifier: GPL-2.0-only
# Source-only coordinator. Check and plans never stage a USB or change settings.
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Check','Probe','Build','StageUnlock')][string]$Action='Check',
    [string]$Repo=(Join-Path $PSScriptRoot 'Windows-GPU-UNLOCK'),
    [ValidatePattern('^[D-Zd-z]$')][string]$Drive,
    [string]$Assets,[string]$Python,[string]$Clang,[string]$LldLink,[string]$VcVars,
    [string]$ReportPath,[switch]$Execute
)
$script:UGPin='75071aa134616c3d65ad315e0cf2810bf34b191b'

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
        $entry=Join-Path $Path 'research/profile/new-machine.ps1'
        $header=Join-Path $Path 'deps/edk2/MdePkg/Include/Uefi.h'
        if (!(Test-Path -LiteralPath $entry -PathType Leaf) -or !(Test-Path -LiteralPath $header -PathType Leaf)) {throw 'Workflow or pinned EDK2 header missing; finish the source/dependency setup.'}
        $head=@(& git -C $Path rev-parse HEAD 2>$null);$code=$LASTEXITCODE
        if ($code -ne 0 -or $head.Count -ne 1 -or $head[0].Trim() -ne $script:UGPin) {throw "Source must be pinned to $script:UGPin."}
        & git -C $Path diff --quiet HEAD -- 2>$null
        if ($LASTEXITCODE -ne 0) {throw 'Tracked source or dependency files changed; use a clean pinned checkout.'}
        return New-UGCheck 'Source' 'PASS' "Clean pinned source $script:UGPin"
    } catch {return New-UGCheck 'Source' 'BLOCKED' $_.Exception.Message}
}
function Find-UGExe([string]$Given,[string]$Name,[string]$Fallback) {
    if ($Given) {if(Test-Path -LiteralPath $Given -PathType Leaf){return [IO.Path]::GetFullPath($Given)};return $null}
    $cmd=Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Source -notmatch '\\Microsoft\\WindowsApps\\') {return $cmd.Source}
    if ($Fallback -and (Test-Path -LiteralPath $Fallback -PathType Leaf)) {return $Fallback}
    return $null
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
function Get-UGCaptureCount([string]$UsbLetter) {
    if (!$UsbLetter) {return 0}
    $count=0
    foreach($file in @(Get-ChildItem -LiteralPath ($UsbLetter+':\RTX3090-UNLOCK') -File -ErrorAction SilentlyContinue)){
        if($file.Name -match '^DIAG\d\d\.TXT$'){
            $text=[IO.File]::ReadAllText($file.FullName)
            if($text.Contains('probe-pci-handles=') -and $text.Contains("capture-complete=1`r`n")){$count++}
        }
    }
    return $count
}
function Get-UGReadiness($Options) {
    $checks=New-Object 'System.Collections.Generic.List[object]'
    $config=[ordered]@{Repo=[IO.Path]::GetFullPath($Options.Repo);Drive=$null;WindowsEspGuid=$null;Assets=$Options.Assets;Python=$null;Clang=$null;LldLink=$null;VcVars=$null}
    if (!$config.Assets){$config.Assets=Join-Path $config.Repo 'assets'}
    $checks.Add((Get-UGRepositoryCheck $config.Repo))
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
    $captures=Get-UGCaptureCount $config.Drive
    [pscustomobject]@{Checks=@($checks.ToArray());Config=$config;CaptureCount=$captures}
}
function Get-UGDecision($Readiness,[string]$SelectedAction,[bool]$DoExecute) {
    $errors=@($Readiness.Checks | Where-Object {$_.RequiredFor -contains $SelectedAction -and $_.Status -ne 'PASS'} | ForEach-Object {$_.Name+': '+$_.Detail})
    if($SelectedAction -eq 'Probe' -and $Readiness.CaptureCount -ge 2){$errors+='Two complete capture files exist; choose Build so the upstream checker can assess them.'}
    if($SelectedAction -in @('Build','StageUnlock') -and $Readiness.CaptureCount -lt 2){$errors+='Need at least two complete probe captures from separate full shutdowns. Run Probe first.'}
    [pscustomobject]@{Action=$SelectedAction;Blockers=$errors;WillExecute=($SelectedAction -ne 'Check' -and $DoExecute -and $errors.Count -eq 0);PlanOnly=(!$DoExecute -and $SelectedAction -ne 'Check')}
}
function New-UGPipelineParameters($Config,[string]$SelectedAction) {
    if($SelectedAction -notin @('Probe','Build','StageUnlock')){throw 'Check cannot invoke the upstream pipeline.'}
    $options=@{Drive=$Config.Drive;WindowsEspGuid=[guid]$Config.WindowsEspGuid;Assets=$Config.Assets;Python=$Config.Python;Clang=$Config.Clang;LldLink=$Config.LldLink}
    if($Config.VcVars){$options.VcVars=$Config.VcVars}
    if($SelectedAction -eq 'StageUnlock'){$options.StageUnlock=$true}
    return $options
}
function Invoke-UGPipeline($Config,[string]$SelectedAction) {
    $options=New-UGPipelineParameters $Config $SelectedAction
    & (Join-Path $Config.Repo 'research/profile/new-machine.ps1') @options | Out-Host
    if(!$? -or $LASTEXITCODE -ne 0){throw 'Upstream preparation refused or failed; read its message. No later step was attempted.'}
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
        $report=[ordered]@{SourceRevision=$script:UGPin;CheckedUtc=[DateTime]::UtcNow.ToString('o');Readiness=$readiness;Decision=$decision}
        $target=[IO.Path]::GetFullPath($Options.ReportPath)
        if(Test-Path -LiteralPath $target){throw 'Choose a new report filename; reports are never overwritten.'}
        $stream=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {$writer=New-Object IO.StreamWriter($stream,(New-Object Text.UTF8Encoding($false)));$writer.Write(($report | ConvertTo-Json -Depth 8));$writer.Flush()} finally {if($writer){$writer.Dispose()}else{$stream.Dispose()}}
        Write-Host 'Local report saved. It includes tool paths and your local EFI GUID; do not include it in public posts.'
    }
    if($Options.Execute -and $Options.Action -ne 'Check' -and $decision.Blockers.Count){throw 'Readiness checks blocked this step; nothing was executed.'}
    $null=Invoke-UGExecution $readiness $Options.Action ([bool]$Options.Execute)
    if($decision.WillExecute -and $Options.Action -eq 'Probe'){Write-Host 'Probe staged. Fully shut down, boot the USB, let Windows return, then do a second full-shutdown USB boot. Run Build afterward.'}
    if($decision.WillExecute -and $Options.Action -eq 'Build'){Write-Host 'Build/test step finished. Review upstream output; StageUnlock is a separate explicit step.'}
    if($decision.WillExecute -and $Options.Action -eq 'StageUnlock'){Write-Host 'Unlock files staged. Read the upstream USB guide before the supervised first cold boot. No boot priority was changed.'}
    if($Options.Action -eq 'Check'){$next=if($readiness.CaptureCount -ge 2){'Build'}else{'Probe'};Write-Host "Check only: no USB files, boot settings or GPU tuning changed. Choose $next for the next plan."}
}
if($MyInvocation.InvocationName -ne '.'){
    $options=@{Action=$Action;Repo=$Repo;Drive=$Drive;Assets=$Assets;Python=$Python;Clang=$Clang;LldLink=$LldLink;VcVars=$VcVars;ReportPath=$ReportPath;Execute=$Execute}
    Invoke-UGMain $options
}
