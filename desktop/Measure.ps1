# SPDX-License-Identifier: GPL-2.0-only
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Status','Provision','Stock','Unlocked')][string]$Action='Status',
    [string]$Python,
    [string]$Gpu,
    [ValidatePattern('^[D-Zd-z]$')][string]$Drive,
    [string]$VolumeId,
    [switch]$Execute,
    [switch]$RefreshStock
)

$script:RtxMeasureKit = Split-Path -Parent $PSScriptRoot
$script:RtxMeasureSettings = @('name','pci.bus_id','driver_version','vbios_version',
    'power.limit','power.default_limit','clocks.max.sm','clocks.max.memory','uuid')
. (Join-Path $PSScriptRoot 'BenchmarkRuntime.ps1')

function ConvertTo-RtxMeasureBdf([string]$Address) {
    if($Address -notmatch '\A(?:0000)?(?<short>[0-9a-f]{4}:[0-9a-f]{2}:[01][0-9a-f]\.0)\z'){
        throw 'Expected a full PCI address such as 0000:01:00.0.'
    }
    return $Matches.short.ToLowerInvariant()
}

function Get-RtxMeasureSnapshots($Targets) {
    $smi=Get-Command nvidia-smi.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $fields=$script:RtxMeasureSettings + @('pci.device_id','pci.sub_device_id')
    $lines=@(& $smi.Source ('--query-gpu='+($fields -join ',')) '--format=csv,noheader,nounits')
    if($LASTEXITCODE -ne 0 -or $lines.Count -ne $Targets.Count){throw 'NVIDIA GPU inventory changed. Refresh Setup.'}
    $snapshots=@{}
    $identities=@{}
    foreach($line in $lines) {
        $values=$line.Split(',')
        if($values.Length -ne $fields.Count){throw 'NVIDIA returned incomplete benchmark settings.'}
        $snapshot=[ordered]@{}
        for($i=0;$i -lt $fields.Count;$i++){$snapshot[$fields[$i]]=$values[$i].Trim()}
        $bdf=ConvertTo-RtxMeasureBdf $snapshot['pci.bus_id']
        $uuid=$snapshot.uuid.ToLowerInvariant()
        $card=@($Targets | Where-Object Bdf -CEQ $bdf)
        if($card.Count -ne 1 -or $snapshots.ContainsKey($bdf) -or $identities.ContainsKey($uuid) -or
           $uuid -cnotmatch '^gpu-[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$' -or
           $uuid -ceq 'gpu-00000000-0000-0000-0000-000000000000' -or
           $snapshot['pci.device_id'] -ine ('0x'+$card[0].Device+'10de') -or
           $snapshot['pci.sub_device_id'] -ine ('0x'+$card[0].Subsystem)) {
            throw 'The exact physical NVIDIA GPU identities changed. Refresh Setup.'
        }
        $snapshot['pci.bus_id']='0000'+$bdf
        $snapshot.uuid='GPU-'+$uuid.Substring(4)
        $snapshots[$bdf]=[pscustomobject]$snapshot
        $identities[$uuid]=$true
    }
    return $snapshots
}

function Get-RtxMeasureKey($Card,$GpuSnapshot) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        $identity="$($Card.Bdf) $($Card.Device) $($Card.Subsystem) $($GpuSnapshot.uuid)"
        return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($identity))).Replace('-','').ToLowerInvariant()
    } finally {$sha.Dispose()}
}

function Assert-RtxMeasureDirectory([string]$Path) {
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if(!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Benchmark folders must be ordinary local directories.'
    }
}

function Get-RtxMeasureRoot {
    $base=[Environment]::GetFolderPath('LocalApplicationData')
    if(!$base -or ![IO.Path]::IsPathRooted($base) -or
       ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($base))).DriveType -ne 'Fixed') {
        throw 'Benchmarks require a local Windows application data folder.'
    }
    Assert-RtxMeasureDirectory $base
    foreach($part in @('Windows GPU Unlock','measurements-v1')) {
        $base=Join-Path $base $part
        if(Test-Path -LiteralPath $base){Assert-RtxMeasureDirectory $base}
    }
    return $base
}

function Get-RtxMeasureFile([string]$Path,[int]$Limit=8MB) {
    $file=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
       $file.Length -lt 1 -or $file.Length -gt $Limit) {
        throw 'A benchmark file is invalid or outside the expected size.'
    }
    return $file
}

function Read-RtxMeasureJson([string]$Path) {
    $file=Get-RtxMeasureFile $Path
    return [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json -ErrorAction Stop
}

function Get-RtxMeasureHistory([string]$Root) {
    if(!(Test-Path -LiteralPath $Root)){return}
    foreach($directory in @(Get-ChildItem -LiteralPath $Root -Directory -Force | Sort-Object Name -Descending)) {
        if($directory.Name -cnotmatch '^(stock|unlocked)-[0-9]{8}T[0-9]{13}Z-[a-f0-9]{32}$'){continue}
        Assert-RtxMeasureDirectory $directory.FullName
        $record=Read-RtxMeasureJson (Join-Path $directory.FullName 'run.json')
        if($record.Format -ne 1 -or $record.Mode -cne $directory.Name.Split('-')[0] -or
           $record.BootId -cnotmatch '^[0-9]{1,19}$' -or @($record.Cards).Count -notin @(1,2)){
            throw 'A saved benchmark receipt is invalid.'
        }
        [pscustomobject]@{Path=$directory.FullName;Record=$record}
    }
}

function Get-RtxMeasureSaved($Run,[string]$Key,[string]$File,[string]$HashField) {
    $entry=@($Run.Record.Cards | Where-Object Key -CEQ $Key)
    if(!$entry.Count){return}
    if($entry.Count -ne 1){throw 'A saved benchmark has ambiguous GPU records.'}
    $folder=Join-Path $Run.Path $Key
    Assert-RtxMeasureDirectory $folder
    $path=Join-Path $folder $File
    $value=Read-RtxMeasureJson $path
    if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $entry[0].$HashField){
        throw 'A saved benchmark file has changed.'
    }
    return [pscustomobject]@{Path=$path;Data=$value;Record=$Run.Record}
}

function Test-RtxMeasureSettings($Saved,$Live) {
    if(!$Saved){return $false}
    foreach($field in $script:RtxMeasureSettings) {
        if([string]$Saved.$field -cne [string]$Live.$field){return $false}
    }
    return $true
}

function Resolve-RtxMeasurePython([string]$Requested,$Stock) {
    if($Requested -and ![IO.Path]::IsPathRooted($Requested)){throw 'Select an absolute python.exe path.'}
    $stockPaths=@($Stock | ForEach-Object {$_.Record.Python} | Select-Object -Unique)
    $managed=Get-RtxManagedBenchmarkPython
    $runtimeRoot=Get-RtxBenchmarkRuntimeRoot
    $runtimePrefix=if($runtimeRoot){[IO.Path]::GetFullPath($runtimeRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar}
    $candidates=if($Requested){@($Requested)}else{
        @(
            $stockPaths
            $managed
            $drives=Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -Property DeviceID -ErrorAction SilentlyContinue
            $locations=@($drives | ForEach-Object {$_.DeviceID+'\'})
            if($env:USERPROFILE){$locations+=Join-Path $env:USERPROFILE 'Downloads'}
            foreach($location in $locations) {
                foreach($matrix in @('StabilityMatrix-win-x64','StabilityMatrix')) {
                    foreach($name in @('ComfyUI','forge-neo','Stable Diffusion WebUI Forge - Neo')) {
                        Join-Path $location "$matrix/Data/Packages/$name/venv/Scripts/python.exe"
                    }
                }
            }
            foreach($reg in @('HKCU:\Software\Python\PythonCore','HKLM:\Software\Python\PythonCore')) {
                foreach($version in @(Get-ChildItem -LiteralPath $reg -ErrorAction SilentlyContinue)) {
                    $install=Get-Item -LiteralPath (Join-Path $version.PSPath 'InstallPath') -ErrorAction SilentlyContinue
                    if($install){
                        $exe=$install.GetValue('ExecutablePath')
                        $directory=$install.GetValue('')
                        if($exe){$exe}elseif($directory){Join-Path $directory 'python.exe'}
                    }
                }
            }
            Get-Command python.exe -CommandType Application -All -ErrorAction SilentlyContinue | ForEach-Object Source
        )
    }
    foreach($candidate in $candidates) {
        if(!$candidate -or ![IO.Path]::IsPathRooted($candidate) -or $candidate -match '[\\/]Microsoft[\\/]WindowsApps[\\/]'){continue}
        $item=Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
        if(!$item -or $item.PSIsContainer -or $item.Name -ine 'python.exe' -or !$item.Length -or
           ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){continue}
        $verifiedManaged=[string]::Equals($item.FullName,$managed,[StringComparison]::OrdinalIgnoreCase)
        if($runtimePrefix -and $item.FullName.StartsWith($runtimePrefix,[StringComparison]::OrdinalIgnoreCase) -and !$verifiedManaged){
            if($Requested){throw 'The managed benchmark runtime is not verified. Run setup again or choose an external Python interpreter.'}
            continue
        }
        if($Requested -or $verifiedManaged -or $item.FullName -in $stockPaths){return $item.FullName}
        $pythonHome=if($item.Directory.Name -ieq 'Scripts'){$item.Directory.Parent.FullName}else{$item.DirectoryName}
        $torchLib=Join-Path $pythonHome 'Lib/site-packages/torch/lib'
        if((Test-Path -LiteralPath (Join-Path $torchLib 'torch_cuda.dll') -PathType Leaf) -and
           @(Get-ChildItem -LiteralPath $torchLib -Filter 'cublas64_*.dll' -File -ErrorAction SilentlyContinue).Count){
            return $item.FullName
        }
    }
    if($Requested){throw 'The selected path is not an ordinary Python executable.'}
    return $null
}

function Invoke-RtxMeasurePython([string]$Exe,[string[]]$Arguments,[switch]$Quiet) {
    $previous=$ErrorActionPreference
    $ErrorActionPreference='Continue'
    $last=''
    try {
        & $Exe -I -B @Arguments 2>&1 | ForEach-Object {
            $last=[string]$_
            if(!$Quiet){[Console]::Error.WriteLine($last)}
        }
        $code=$LASTEXITCODE
    } finally {$ErrorActionPreference=$previous}
    if($code -ne 0) {
        if($Quiet -and $last){[Console]::Error.WriteLine($last)}
        throw 'The tensor measurement or comparison failed. Review the activity and check the selected CUDA-enabled PyTorch environment.'
    }
}

function Invoke-RtxDesktopMeasure([string]$Mode,[string]$RequestedPython,[string]$RequestedGpu,
                                 [string]$SelectedDrive,[string]$SelectedVolume,[bool]$DoExecute,
                                 [bool]$RefreshStock=$false) {
    if($RefreshStock -and ($Mode -ne 'Stock' -or !$DoExecute)){
        throw 'RefreshStock requires Stock with Execute.'
    }
    . (Join-Path $script:RtxMeasureKit 'RTX.ps1')
    $targets=@(Get-RtxInventory)
    $snapshots=Get-RtxMeasureSnapshots $targets
    $boot=(Get-CimInstance Win32_OperatingSystem -Property LastBootUpTime -ErrorAction Stop).LastBootUpTime
    if($boot -isnot [datetime]){throw 'The current Windows boot could not be identified.'}
    $bootId=$boot.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
    $evidence=Get-RtxBenchmarkBootEvidence $SelectedDrive $SelectedVolume $targets
    if($evidence.Confirmed -and $evidence.BootId -cne $bootId){throw 'The Windows boot changed during verification.'}
    $provisionBlock=if($evidence.Confirmed){'Start Windows directly through Windows Boot Manager before installing the benchmark runtime.'}
        elseif(Test-RtxAdministrator){'Install the benchmark runtime from the signed-in desktop without administrator privileges.'}
        else{
            foreach($card in $targets){
                $driver=$null
                if(![version]::TryParse([string]$snapshots[$card.Bdf].driver_version,[ref]$driver) -or $driver -lt [version]'561.17'){
                    'The benchmark runtime requires NVIDIA driver 561.17 or later for every GPU.'
                    break
                }
            }
        }
    $root=Get-RtxMeasureRoot
    $history=@(Get-RtxMeasureHistory $root)
    $knownUnlockedBoot=@($history | Where-Object {
        $_.Record.Mode -ceq 'unlocked' -and $_.Record.BootId -ceq $bootId
    }).Count -gt 0
    if($knownUnlockedBoot -and !$provisionBlock){
        $provisionBlock='A post-unlock test was saved during this Windows boot. Start Windows directly through Windows Boot Manager before setting up a runtime or recording stock.'
    }
    $bench=Join-Path $script:RtxMeasureKit 'benchmark-tensors.py'
    $compare=Join-Path $script:RtxMeasureKit 'compare-tensors.py'
    $scriptHash=(Get-FileHash -LiteralPath (Get-RtxMeasureFile $bench).FullName).Hash
    $null=Get-RtxMeasureFile $compare
    $keys=@{}
    $stock=@{}
    foreach($card in $targets) {
        $key=Get-RtxMeasureKey $card $snapshots[$card.Bdf]
        $keys[$card.Bdf]=$key
        foreach($run in @($history | Where-Object {$_.Record.Mode -ceq 'stock'})) {
            $saved=Get-RtxMeasureSaved $run $key 'stock.json' 'ResultSha256'
            if(!$saved){continue}
            if($saved.Data.status -ceq 'complete' -and $saved.Data.label -ceq 'stock' -and
               $saved.Data.schema_version -eq 3 -and $saved.Data.script.sha256 -ieq $scriptHash -and
               (Test-RtxMeasureSettings $saved.Data.gpu_before $snapshots[$card.Bdf])){
                $stock[$card.Bdf]=$saved
            }
            break
        }
    }
    if($Mode -eq 'Provision' -and $DoExecute){
        if($provisionBlock){throw $provisionBlock}
        $RequestedPython=Initialize-RtxBenchmarkRuntime -GpuAddresses @($targets.Bdf)
        if(!$RequestedPython){throw 'Setup could not verify the installed benchmark runtime.'}
    }
    $exe=Resolve-RtxMeasurePython $RequestedPython @($stock.Values)
    $exeHash=if($exe){(Get-FileHash -LiteralPath $exe).Hash}
    $logUsedBefore=$evidence.Confirmed -and @($history | Where-Object {
        $_.Record.Mode -ceq 'unlocked' -and $_.Record.LogId -ceq $evidence.LogId -and $_.Record.BootId -cne $bootId
    }).Count -gt 0
    $cards=@(foreach($card in $targets) {
        $saved=$stock[$card.Bdf]
        $hasStock=$null -ne $saved -and $exeHash -and
            [string]::Equals([string]$saved.Record.Python,$exe,[StringComparison]::OrdinalIgnoreCase) -and
            $saved.Data.python.executable.sha256 -ieq $exeHash
        $result=$null
        if($hasStock -and $evidence.Confirmed -and !$logUsedBefore) {
            foreach($run in @($history | Where-Object {
                $_.Record.Mode -ceq 'unlocked' -and $_.Record.BootId -ceq $bootId -and $_.Record.LogId -ceq $evidence.LogId
            })) {
                $result=Get-RtxMeasureSaved $run $keys[$card.Bdf] 'comparison.json' 'ComparisonSha256'
                if($result -and $result.Data.status -ceq 'comparison_complete' -and
                   (Test-RtxMeasureSettings $result.Data.gpu_settings $snapshots[$card.Bdf])){break}
                $result=$null
            }
        }
        $canStock=[bool]($exe -and !$evidence.Confirmed -and !$knownUnlockedBoot)
        $canUnlocked=[bool]($hasStock -and !$result -and $evidence.Confirmed -and !$logUsedBefore -and
            [long]$saved.Record.BootId -lt [long]$bootId)
        $message=if(!$exe){'Choose a Python installation with CUDA-enabled PyTorch.'}
            elseif($knownUnlockedBoot -and !$evidence.Confirmed){'A post-unlock test was saved during this Windows boot. Reconnect the unlock USB to review it, or start Windows Boot Manager directly before recording stock.'}
            elseif($logUsedBefore){'This EFI log was already used on a different Windows boot.'}
            elseif($result){'A matched comparison is saved for this Windows boot.'}
            elseif($evidence.Confirmed -and !$canUnlocked){'A matching stock result from an earlier Windows boot is required.'}
            elseif($canUnlocked){'Ready to measure this GPU after the verified EFI boot.'}
            elseif($hasStock){'Matching stock result saved. Boot the verified unlock USB to compare.'}
            else{'Collect stock measurements after a normal Windows boot.'}
        [pscustomobject]@{
            Bdf=$card.Bdf;Label=$card.Label;HasStock=[bool]$hasStock;CanStock=$canStock;CanUnlocked=$canUnlocked
            HasComparisonForBoot=[bool]$result;Message=$message
            ComparisonPath=if($result){$result.Path}else{$null}
            Modes=if($result){$result.Data.modes}else{$null}
        }
    })
    $status=[ordered]@{
        Status='Ready';Message=if($exe){$evidence.Message}else{'Choose a Python environment with CUDA PyTorch, or install the benchmark runtime.'}
        Python=$exe;ResultsDirectory=$root;BootId=$bootId
        BootConfirmed=[bool]$evidence.Confirmed;Cards=$cards;Results=@()
        HasComparisonForBoot=@($cards | Where-Object HasComparisonForBoot).Count -eq $cards.Count
        CanProvision=!$provisionBlock
        ProvisionMessage=if($provisionBlock){$provisionBlock}else{'Install a private CUDA PyTorch runtime for benchmarks. The first download is about 2.6 GB.'}
    }
    if($Mode -eq 'Status'){return [pscustomobject]$status}
    if($Mode -eq 'Provision'){
        if(!$DoExecute){$status.Status='Plan';$status.Message='Add -Execute to install the benchmark runtime.'}
        else{$status.Message='Benchmark runtime ready. Run the stock test from a normal Windows boot.'}
        return [pscustomobject]$status
    }
    if(!$DoExecute){$status.Status='Plan';$status.Message='Add -Execute to start a tensor benchmark.';return [pscustomobject]$status}
    $selected=if($RequestedGpu){@($cards | Where-Object Bdf -CEQ (ConvertTo-RtxMeasureBdf $RequestedGpu))}else{$cards}
    if(!@($selected).Count){throw 'The selected GPU is not in the current Windows inventory.'}
    if(!$exe){throw 'Choose a Python installation with CUDA-enabled PyTorch before measuring.'}
    if($Mode -eq 'Unlocked'){
        if(!$evidence.Confirmed -or $logUsedBefore){throw 'A fresh, verified unlock USB boot is required before comparison.'}
        $selected=@($selected | Where-Object {!$_.HasComparisonForBoot})
        if(!@($selected).Count){
            $status.Status='AlreadyComplete';$status.Message='The selected GPUs already have a comparison for this boot.'
            return [pscustomobject]$status
        }
        if(@($selected | Where-Object {!$_.CanUnlocked}).Count){
            throw 'Each selected GPU needs matching stock measurements from an earlier Windows boot.'
        }
    } else {
        if($evidence.Confirmed -or $knownUnlockedBoot){throw 'The current Windows boot has verified unlock evidence or a saved post-unlock test. Boot normally before measuring stock.'}
        if(!$RequestedGpu -and !$RefreshStock){
            $selected=@($selected | Where-Object {!$_.HasStock})
            if(!$selected.Count){
                $status.Status='AlreadyComplete';$status.Message='Matching stock measurements are already saved.'
                return [pscustomobject]$status
            }
        }
    }

    [void][IO.Directory]::CreateDirectory($root)
    Assert-RtxMeasureDirectory $root
    $label=$Mode.ToLowerInvariant()
    $id=[guid]::NewGuid().ToString('N')
    $runName=$label+'-'+[datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')+'-'+$id
    $pending=Join-Path $root ('.pending-'+$id)
    $published=Join-Path $root $runName
    [void][IO.Directory]::CreateDirectory($pending)
    $pendingCards=@()
    $results=@()
    $entries=@()
    try {
        foreach($card in $selected) {
            $key=$keys[$card.Bdf]
            $folder=Join-Path $pending $key
            [void][IO.Directory]::CreateDirectory($folder)
            $pendingCards+=$folder
            $raw=Join-Path $folder ($label+'.json')
            $finalFolder=Join-Path $published $key
            $saved=$stock[$card.Bdf]
            [Console]::Error.WriteLine("Measuring $($card.Label) at $($card.Bdf) ($label).")
            Invoke-RtxMeasurePython $exe @($bench,'--label',$label,'--gpu',('0000'+$card.Bdf),'--output',$raw)
            $data=Read-RtxMeasureJson $raw
            if($data.status -cne 'complete' -or $data.schema_version -ne 3 -or $data.label -cne $label -or
               !(Test-RtxMeasureSettings $data.gpu_before $snapshots[$card.Bdf])){
                throw 'The benchmark did not return a complete result for the selected physical GPU and settings.'
            }
            $entry=[ordered]@{Key=$key;ResultSha256=(Get-FileHash -LiteralPath $raw).Hash;ComparisonSha256=$null}
            $row=[ordered]@{Bdf=$card.Bdf;Label=$card.Label;StockPath=$null;UnlockedPath=$null;ComparisonPath=$null;Modes=$null}
            if($Mode -eq 'Stock'){
                $validate="import pathlib,runpy,sys; m=runpy.run_path(sys.argv[1]); m['validate'](m['load_result'](pathlib.Path(sys.argv[2])),'stock')"
                Invoke-RtxMeasurePython $exe @('-c',$validate,$compare,$raw) -Quiet
                $row.StockPath=Join-Path $finalFolder 'stock.json'
                $row.Modes=$data.summary
            }else{
                $report=Join-Path $folder 'comparison.json'
                Invoke-RtxMeasurePython $exe @($compare,'--before',$saved.Path,'--after',$raw,'--output',$report) -Quiet
                $matched=Read-RtxMeasureJson $report
                if($matched.status -cne 'comparison_complete' -or
                   !(Test-RtxMeasureSettings $matched.gpu_settings $snapshots[$card.Bdf])){throw 'No matched comparison was produced.'}
                $entry.ComparisonSha256=(Get-FileHash -LiteralPath $report).Hash
                $row.StockPath=$saved.Path
                $row.UnlockedPath=Join-Path $finalFolder 'unlocked.json'
                $row.ComparisonPath=Join-Path $finalFolder 'comparison.json'
                $row.Modes=$matched.modes
            }
            $entries+=([pscustomobject]$entry)
            $results+=([pscustomobject]$row)
        }
        if($Mode -eq 'Unlocked'){
            $afterEvidence=Get-RtxBenchmarkBootEvidence $SelectedDrive $SelectedVolume $targets
            if(!$afterEvidence.Confirmed -or $afterEvidence.BootId -cne $bootId -or $afterEvidence.LogId -cne $evidence.LogId){
                throw 'Unlock boot evidence changed during measurement.'
            }
        }
        $receipt=[ordered]@{Format=1;Mode=$label;BootId=$bootId;LogId=$evidence.LogId;Python=$exe;Cards=$entries}
        [IO.File]::WriteAllText((Join-Path $pending 'run.json'),($receipt | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
        [IO.Directory]::Move($pending,$published)
    } finally {
        if(Test-Path -LiteralPath $pending){
            # Remove only filenames this invocation owns, never a recursive tree.
            Assert-RtxMeasureDirectory $pending
            foreach($folder in $pendingCards){
                Assert-RtxMeasureDirectory $folder
                foreach($file in @('stock.json','unlocked.json','comparison.json')){
                    $path=Join-Path $folder $file
                    if(Test-Path -LiteralPath $path -PathType Leaf){[IO.File]::Delete($path)}
                }
                try {[IO.Directory]::Delete($folder)} catch {}
            }
            $metadata=Join-Path $pending 'run.json'
            if(Test-Path -LiteralPath $metadata -PathType Leaf){[IO.File]::Delete($metadata)}
            try {[IO.Directory]::Delete($pending)} catch {}
        }
    }
    $status.Status='Complete'
    $status.Results=$results
    foreach($row in $results) {
        $card=$cards | Where-Object Bdf -CEQ $row.Bdf
        if($Mode -eq 'Stock'){
            $card.HasStock=$true
            $card.Message='Matching stock result saved. Boot the verified unlock USB to compare.'
        }else{
            $card.CanUnlocked=$false
            $card.HasComparisonForBoot=$true
            $card.ComparisonPath=$row.ComparisonPath
            $card.Modes=$row.Modes
            $card.Message='A matched comparison is saved for this Windows boot.'
        }
    }
    $status.HasComparisonForBoot=@($cards | Where-Object HasComparisonForBoot).Count -eq $cards.Count
    $status.Message=if($Mode -eq 'Stock'){'Stock measurements saved.'}else{'Matched per-GPU comparisons saved. Results measure tensor performance.'}
    return [pscustomobject]$status
}

if($MyInvocation.InvocationName -ne '.'){
    [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
    $ErrorActionPreference='Stop'
    $mutex=[Threading.Mutex]::new($false,'Local\WindowsGpuUnlockMeasurement')
    $locked=$false
    try {
        try {$locked=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$locked=$true}
        if(!$locked){throw 'Another tensor benchmark or status check is in progress.'}
        Invoke-RtxDesktopMeasure $Action $Python $Gpu $Drive $VolumeId ([bool]$Execute) ([bool]$RefreshStock) | ConvertTo-Json -Depth 12
    } catch {
        [pscustomobject]@{Status='Blocked';Message=$_.Exception.Message;Python=$null;ResultsDirectory=$null
            BootId=$null;BootConfirmed=$false;HasComparisonForBoot=$false;Cards=@();Results=@()
            CanProvision=$false;ProvisionMessage=$_.Exception.Message} | ConvertTo-Json -Depth 4
        exit 1
    } finally {
        if($locked){$mutex.ReleaseMutex()}
        $mutex.Dispose()
    }
}
