# SPDX-License-Identifier: GPL-2.0-only
# Uses synthetic telemetry and boot evidence. Never invokes CUDA or USB APIs.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../desktop/Measure.ps1')
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('rtx-measure-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$script:RtxMeasureKit=$testRoot
$script:resultsRoot=Join-Path $testRoot 'results'
$script:boot=[datetime]::SpecifyKind([datetime]'2026-01-01T01:00:00',[DateTimeKind]::Utc)
$script:confirmed=$false
$script:logId='initial'
$script:simulatedFailure=$null
$script:benchCalls=0
$script:comparedStockPaths=@()
$script:provisionCalls=0
$script:runtimeInstalled=$false
$script:admin=$false
$script:driver='621.14'
$script:secondDriver=$null
$script:memoryTotal='10240'
$script:targets=@(
    [pscustomobject]@{Bdf='0000:01:00.0';Device='2206';Subsystem='40611458';Label='RTX 3080'},
    [pscustomobject]@{Bdf='0000:02:00.0';Device='2783';Subsystem='40e81458';Label='RTX 4070 SUPER'}
)
$script:pythonPath=Join-Path $testRoot 'python.exe'
$privateRuntime=Join-Path $testRoot 'bench-runtime-v1'
[void][IO.Directory]::CreateDirectory($privateRuntime)
$script:managedPython=Join-Path $privateRuntime 'python.exe'
foreach($file in @('python.exe','benchmark-tensors.py','compare-tensors.py')){
    [IO.File]::WriteAllText((Join-Path $testRoot $file),$file)
}
[IO.File]::Copy($script:pythonPath,$script:managedPython)
[IO.File]::WriteAllText((Join-Path $testRoot 'RTX.ps1'),@'
function Get-RtxInventory {$script:targets}
function Test-RtxAdministrator {$script:admin}
function Get-RtxBenchmarkBootEvidence($Letter,$Volume,$Targets) {
    [pscustomobject]@{Confirmed=$script:confirmed;BootId=[string]$script:boot.Ticks;LogId=$script:logId;Message='Synthetic boot evidence'}
}
'@)

function Get-CimInstance { param($ClassName,$Property) [pscustomobject]@{LastBootUpTime=$script:boot} }
function Get-RtxMeasureRoot { $script:resultsRoot }
function Get-RtxBenchmarkRuntimeRoot {$privateRuntime}
function Get-RtxManagedBenchmarkPython {if($script:runtimeInstalled){$script:managedPython}}
function Initialize-RtxBenchmarkRuntime([string[]]$GpuAddresses) {
    if(($GpuAddresses -join ',') -cne '0000:01:00.0,0000:02:00.0'){throw 'Provision did not bind the exact GPU set.'}
    if(!$script:runtimeInstalled){$script:provisionCalls++;$script:runtimeInstalled=$true}
    return $script:managedPython
}
function Get-RtxMeasureSnapshots($Targets) {
    $snapshots=@{}
    foreach($card in $Targets){
        $snapshots[$card.Bdf]=[pscustomobject]@{
            'pci.bus_id'='0000'+$card.Bdf;uuid='GPU-12345678-aaaa-bbbb-cccc-1234567890'+$card.Device.Substring(2)
            name=$card.Label;driver_version=if($script:secondDriver -and $card.Bdf -eq $Targets[1].Bdf){$script:secondDriver}else{$script:driver}
            vbios_version='94.02.00.00.00'
            'memory.total'=$script:memoryTotal;'power.limit'='350.00';'power.default_limit'='350.00';'clocks.max.sm'='2100';'clocks.max.memory'='9751'
        }
    }
    return $snapshots
}
function Invoke-RtxMeasurePython([string]$Exe,[string[]]$Arguments,[switch]$Quiet) {
    if($Arguments[0] -ceq '-c'){return}
    if([IO.Path]::GetFileName($Arguments[0]) -ceq 'benchmark-tensors.py'){
        $script:benchCalls++
        $label=$Arguments[2]
        $bdf=ConvertTo-RtxMeasureBdf $Arguments[4]
        if($script:simulatedFailure -ceq $bdf){throw 'Simulated second-card failure'}
        $data=[ordered]@{
            schema_version=3;status='complete';label=$label
            script=@{sha256=(Get-FileHash -LiteralPath $Arguments[0]).Hash}
            python=@{executable=@{sha256=(Get-FileHash -LiteralPath $Exe).Hash}}
            gpu_before=(Get-RtxMeasureSnapshots $script:targets)[$bdf]
            summary=@{fp32_ieee=@{median_tflops=20}}
        }
    }else{
        $script:comparedStockPaths+=$Arguments[2]
        $after=Read-RtxMeasureJson $Arguments[4]
        $data=[ordered]@{status='comparison_complete';gpu_settings=$after.gpu_before;modes=@{
            fp16_fp32_accumulate=@{before_median_tflops=40;after_median_tflops=60;speed_ratio=1.5;percent_gain=50}
        }}
    }
    [IO.File]::WriteAllText($Arguments[6],($data | ConvertTo-Json -Depth 7))
}
function Assert-Measure($Value,[string]$Message){if(!$Value){throw $Message}}
function Run-Measure([string]$Mode,[bool]$Run=$false,[string]$Gpu='',[bool]$RefreshStock=$false){
    Invoke-RtxDesktopMeasure $Mode $script:pythonPath $Gpu 'E' 'synthetic-id' $Run $RefreshStock
}

try {
    foreach($mode in @('Status','Provision','Unlocked')){
        $refused=$false
        try {$null=Run-Measure $mode $true '' $true}
        catch {$refused=$_.Exception.Message -eq 'RefreshStock requires Stock with Execute.'}
        Assert-Measure $refused "RefreshStock was accepted for $mode."
    }
    $refused=$false
    try {$null=Run-Measure Stock $false '' $true}
    catch {$refused=$_.Exception.Message -eq 'RefreshStock requires Stock with Execute.'}
    Assert-Measure ($refused -and !$script:benchCalls -and !(Test-Path $script:resultsRoot)) 'RefreshStock without Execute changed measurement state.'
    $status=Run-Measure Status
    Assert-Measure ($status.Cards.Count -eq 2 -and !$status.Cards[0].HasStock -and $status.CanProvision -and
        !$script:provisionCalls -and !(Test-Path $script:resultsRoot)) 'Status must be read-only and report provision eligibility.'
    $plan=Run-Measure Provision
    Assert-Measure ($plan.Status -ceq 'Plan' -and !$script:provisionCalls) 'Provision plan downloaded or installed a runtime.'
    foreach($invalidDriver in @('561.16','[N/A]')) {
        $script:secondDriver=$invalidDriver
        $status=Run-Measure Status
        Assert-Measure (!$status.CanProvision -and $status.ProvisionMessage -match '561\.17') 'One unsupported driver did not block provisioning.'
        $refused=$false
        try {$null=Run-Measure Provision $true} catch {$refused=$_.Exception.Message -match '561\.17'}
        Assert-Measure ($refused -and !$script:provisionCalls) 'Unsupported driver reached runtime initialization.'
    }
    $script:secondDriver='561.17'
    $script:admin=$true
    $refused=$false
    try {$null=Run-Measure Provision $true} catch {$refused=$_.Exception.Message -match 'without administrator'}
    Assert-Measure ($refused -and !$script:provisionCalls) 'Elevated provisioning was accepted.'
    $script:admin=$false
    $installed=Run-Measure Provision $true
    Assert-Measure ($installed.Status -ceq 'Ready' -and $installed.Python -ceq $script:managedPython -and
        $script:provisionCalls -eq 1 -and !$script:benchCalls -and !(Test-Path $script:resultsRoot)) 'Provision did not return the runtime without measuring.'
    $installed=Run-Measure Provision $true
    Assert-Measure ($installed.Python -ceq $script:managedPython -and $script:provisionCalls -eq 1) 'A second request did not reuse the installed runtime.'
    $script:runtimeInstalled=$false
    $refused=$false
    try {$null=Invoke-RtxDesktopMeasure Status $script:managedPython '' 'E' 'synthetic-id' $false}
    catch {$refused=$_.Exception.Message -match 'managed benchmark runtime'}
    Assert-Measure $refused 'An explicit managed Python path bypassed the ready receipt.'
    $script:runtimeInstalled=$true
    $script:secondDriver=$null
    $result=Run-Measure Stock $true
    Assert-Measure ($result.Status -ceq 'Complete' -and $result.Results.Count -eq 2 -and $script:benchCalls -eq 2) 'Stock run did not publish both cards.'
    foreach($card in $result.Results){Assert-Measure (Test-Path -LiteralPath $card.StockPath) 'Stock file missing.'}
    $originalStock=$result
    $originalFiles=@(Get-ChildItem -LiteralPath $script:resultsRoot -Recurse -File | ForEach-Object {
        [pscustomobject]@{Path=$_.FullName;Sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}
    })
    $again=Run-Measure Stock $true
    Assert-Measure ($again.Status -ceq 'AlreadyComplete' -and $script:benchCalls -eq 2) 'A repeat automatically overwrote a stock result.'
    $fresh=Run-Measure Stock $true '' $true
    Assert-Measure ($fresh.Status -ceq 'Complete' -and $fresh.Results.Count -eq 2 -and $script:benchCalls -eq 4 -and
        @(Get-ChildItem -LiteralPath $script:resultsRoot -Directory).Count -eq 2) 'Fresh stock did not publish a new baseline for both GPUs.'
    for($index=0;$index -lt $fresh.Results.Count;$index++){
        Assert-Measure ($fresh.Results[$index].StockPath -cne $originalStock.Results[$index].StockPath) 'Fresh stock reused the original result path.'
    }
    foreach($file in $originalFiles){
        Assert-Measure ((Test-Path -LiteralPath $file.Path) -and
            (Get-FileHash -LiteralPath $file.Path).Hash -ceq $file.Sha256) 'Fresh stock changed an earlier run.'
    }
    $again=Run-Measure Stock $true
    Assert-Measure ($again.Status -ceq 'AlreadyComplete' -and $script:benchCalls -eq 4) 'A default repeat overwrote the refreshed stock result.'

    $script:boot=$script:boot.AddMinutes(10)
    $script:confirmed=$true
    $script:logId='verified-log'
    $script:memoryTotal='[N/A]'
    $status=Run-Measure Status
    Assert-Measure (!$status.CanProvision -and $status.Cards[0].CanUnlocked -and $status.Cards[1].CanUnlocked) 'Fresh boot with unavailable driver VRAM telemetry did not match both stock results or refuse install.'
    $refused=$false
    try {$null=Run-Measure Provision $true} catch {$refused=$_.Exception.Message -match 'Windows Boot Manager'}
    Assert-Measure ($refused -and $script:provisionCalls -eq 1) 'Verified unlock boot allowed provisioning.'
    $sameBytes=Invoke-RtxDesktopMeasure Status $script:managedPython '' 'E' 'synthetic-id' $false
    Assert-Measure (!$sameBytes.Cards[0].HasStock -and !$sameBytes.Cards[0].CanUnlocked -and
        !$sameBytes.Cards[1].HasStock) 'An identical Python executable at a different path reused the stock result.'
    $script:simulatedFailure=$script:targets[1].Bdf
    $failed=$false
    try { $null=Run-Measure Unlocked $true } catch { $failed=$_.Exception.Message -eq 'Simulated second-card failure' }
    Assert-Measure ($failed -and @(Get-ChildItem -LiteralPath $script:resultsRoot -Force).Count -eq 2) 'Failure published incomplete results or removed stock.'

    $script:simulatedFailure=$null
    $result=Run-Measure Unlocked $true
    Assert-Measure ($result.Status -ceq 'Complete' -and $result.Results.Count -eq 2 -and $result.HasComparisonForBoot) 'Successful comparison did not publish both cards.'
    foreach($card in $result.Results){Assert-Measure (Test-Path -LiteralPath $card.ComparisonPath) 'Comparison file missing.'}
    foreach($card in $result.Results){
        $expected=@($fresh.Results | Where-Object Bdf -CEQ $card.Bdf)[0].StockPath
        Assert-Measure ($card.StockPath -ceq $expected -and $script:comparedStockPaths -ccontains $expected) 'Comparison did not use the newest stock baseline.'
    }
    $calls=$script:benchCalls
    $again=Run-Measure Unlocked $true
    Assert-Measure ($again.Status -ceq 'AlreadyComplete' -and $script:benchCalls -eq $calls) 'The same boot triggered a second comparison.'

    $script:confirmed=$false
    $detached=Run-Measure Status
    Assert-Measure (!$detached.Cards[0].CanStock -and !$detached.CanProvision -and !$detached.HasComparisonForBoot) 'Removing the USB turned a known post-unlock session into stock.'
    $refused=$false
    try {$null=Invoke-RtxDesktopMeasure Stock $script:pythonPath '' '' '' $true $true}
    catch {$refused=$_.Exception.Message -match 'saved post-unlock'}
    Assert-Measure ($refused -and $script:benchCalls -eq $calls) 'A known post-unlock Windows boot recorded a fresh stock baseline without its USB.'
    $script:confirmed=$true
    $script:boot=$script:boot.AddMinutes(1)
    $stale=Run-Measure Status
    Assert-Measure (!$stale.HasComparisonForBoot -and !$stale.Cards[0].CanUnlocked -and !$stale.Cards[0].ComparisonPath) 'An old EFI log was accepted on a later boot.'
    $script:logId='new-verified-log'
    $script:driver='622.01'
    $changed=Run-Measure Status
    Assert-Measure (!$changed.Cards[0].HasStock -and !$changed.Cards[0].CanUnlocked) 'A changed driver reused stock measurements.'
    'PASS desktop benchmark runner: guarded provisioning, exact interpreter, immutable stock refresh, newest-baseline comparison, atomic retry, fresh EFI evidence, deduplication and changed settings.'
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or
       ![IO.Path]::GetFileName($resolved).StartsWith('rtx-measure-test-')){throw 'Refusing cleanup outside the test folder.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
