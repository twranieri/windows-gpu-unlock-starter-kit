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
$script:driver='621.14'
$script:memoryTotal='10240'
$script:targets=@(
    [pscustomobject]@{Bdf='0000:01:00.0';Device='2206';Subsystem='40611458';Label='RTX 3080'},
    [pscustomobject]@{Bdf='0000:02:00.0';Device='2783';Subsystem='40e81458';Label='RTX 4070 SUPER'}
)
$script:pythonPath=Join-Path $testRoot 'python.exe'
foreach($file in @('python.exe','benchmark-tensors.py','compare-tensors.py')){
    [IO.File]::WriteAllText((Join-Path $testRoot $file),$file)
}
[IO.File]::WriteAllText((Join-Path $testRoot 'RTX.ps1'),@'
function Get-RtxInventory {$script:targets}
function Get-RtxBenchmarkBootEvidence($Letter,$Volume,$Targets) {
    [pscustomobject]@{Confirmed=$script:confirmed;BootId=[string]$script:boot.Ticks;LogId=$script:logId;Message='Synthetic boot evidence'}
}
'@)

function Get-CimInstance { param($ClassName,$Property) [pscustomobject]@{LastBootUpTime=$script:boot} }
function Get-RtxMeasureRoot { $script:resultsRoot }
function Get-RtxMeasureSnapshots($Targets) {
    $snapshots=@{}
    foreach($card in $Targets){
        $snapshots[$card.Bdf]=[pscustomobject]@{
            'pci.bus_id'='0000'+$card.Bdf;uuid='GPU-12345678-aaaa-bbbb-cccc-1234567890'+$card.Device.Substring(2)
            name=$card.Label;driver_version=$script:driver;vbios_version='94.02.00.00.00'
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
        $after=Read-RtxMeasureJson $Arguments[4]
        $data=[ordered]@{status='comparison_complete';gpu_settings=$after.gpu_before;modes=@{
            fp16_fp32_accumulate=@{before_median_tflops=40;after_median_tflops=60;speed_ratio=1.5;percent_gain=50}
        }}
    }
    [IO.File]::WriteAllText($Arguments[6],($data | ConvertTo-Json -Depth 7))
}
function Assert-Measure($Value,[string]$Message){if(!$Value){throw $Message}}
function Run-Measure([string]$Mode,[bool]$Run=$false,[string]$Gpu=''){
    Invoke-RtxDesktopMeasure $Mode $script:pythonPath $Gpu 'E' 'synthetic-id' $Run
}

try {
    $status=Run-Measure Status
    Assert-Measure ($status.Cards.Count -eq 2 -and !$status.Cards[0].HasStock -and !(Test-Path $script:resultsRoot)) 'Status must be read-only.'
    $result=Run-Measure Stock $true
    Assert-Measure ($result.Status -ceq 'Complete' -and $result.Results.Count -eq 2 -and $script:benchCalls -eq 2) 'Stock run did not publish both cards.'
    foreach($card in $result.Results){Assert-Measure (Test-Path -LiteralPath $card.StockPath) 'Stock file missing.'}
    $again=Run-Measure Stock $true
    Assert-Measure ($again.Status -ceq 'AlreadyComplete' -and $script:benchCalls -eq 2) 'A repeat automatically overwrote a stock result.'

    $script:boot=$script:boot.AddMinutes(10)
    $script:confirmed=$true
    $script:logId='verified-log'
    $script:memoryTotal='[N/A]'
    $status=Run-Measure Status
    Assert-Measure ($status.Cards[0].CanUnlocked -and $status.Cards[1].CanUnlocked) 'Fresh boot with unavailable driver VRAM telemetry did not match both stock results.'
    $script:simulatedFailure=$script:targets[1].Bdf
    $failed=$false
    try { $null=Run-Measure Unlocked $true } catch { $failed=$_.Exception.Message -eq 'Simulated second-card failure' }
    Assert-Measure ($failed -and @(Get-ChildItem -LiteralPath $script:resultsRoot -Force).Count -eq 1) 'Failure published incomplete results or removed stock.'

    $script:simulatedFailure=$null
    $result=Run-Measure Unlocked $true
    Assert-Measure ($result.Status -ceq 'Complete' -and $result.Results.Count -eq 2 -and $result.HasComparisonForBoot) 'Successful comparison did not publish both cards.'
    foreach($card in $result.Results){Assert-Measure (Test-Path -LiteralPath $card.ComparisonPath) 'Comparison file missing.'}
    $calls=$script:benchCalls
    $again=Run-Measure Unlocked $true
    Assert-Measure ($again.Status -ceq 'AlreadyComplete' -and $script:benchCalls -eq $calls) 'The same boot triggered a second comparison.'

    $script:boot=$script:boot.AddMinutes(1)
    $stale=Run-Measure Status
    Assert-Measure (!$stale.HasComparisonForBoot -and !$stale.Cards[0].CanUnlocked -and !$stale.Cards[0].ComparisonPath) 'An old EFI log was accepted on a later boot.'
    $script:logId='new-verified-log'
    $script:driver='622.01'
    $changed=Run-Measure Status
    Assert-Measure (!$changed.Cards[0].HasStock -and !$changed.Cards[0].CanUnlocked) 'A changed driver reused stock measurements.'
    'PASS desktop benchmark runner: two-card stock, atomic retry, fresh EFI evidence, deduplication and changed settings.'
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or
       ![IO.Path]::GetFileName($resolved).StartsWith('rtx-measure-test-')){throw 'Refusing cleanup outside the test folder.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
