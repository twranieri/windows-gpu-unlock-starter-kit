# SPDX-License-Identifier: GPL-2.0-only
#Requires -Version 5.1
# Integration fixtures only. EFI evidence, GPU inventory and timings are synthetic.
# Runs the production launcher, measurement script, comparator and benchmark UI logic.
param([switch]$ExerciseExplorer)
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (!(Test-Path -LiteralPath $compiler)) { throw 'The x64 .NET Framework C# compiler is required.' }
$python = (Get-Command python.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$base = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$scratch = Join-Path $base ('rtx e2e ' + [char]0x00E9 + ' ' + [guid]::NewGuid().ToString('N'))
$repo = Split-Path -Parent $PSScriptRoot
[void][IO.Directory]::CreateDirectory((Join-Path $scratch 'desktop'))
[void][IO.Directory]::CreateDirectory((Join-Path $scratch 'tests'))
try {
    foreach ($file in @('desktop/Measure.ps1', 'desktop/BenchmarkRuntime.ps1', 'desktop/BenchmarkHost.ps1',
        'compare-tensors.py', 'tests/test_compare_tensors.py')) {
        [IO.File]::Copy((Join-Path $repo $file), (Join-Path $scratch $file))
    }
    $statePath = Join-Path $scratch 'fixture-state.json'
    $fixture = [ordered]@{
        EvidenceKind = 'synthetic'; BootUtc = '2000-01-01T01:00:00Z'; Confirmed = $false
        LogId = 'SYNTHETIC-no-efi-boot'; Driver = '621.14'; Python = $python
        FailBdf = '0000:02:00.0'; Calls = @{}; ProvisionCalls = 0
        Cards = @(
            @{Bdf='0000:01:00.0'; Device='2206'; Subsystem='40611458'; Label='Synthetic RTX 3080'; Family='ga102'; Uuid='GPU-11111111-1111-4111-8111-111111111111'},
            @{Bdf='0000:02:00.0'; Device='2783'; Subsystem='40e81458'; Label='Synthetic RTX 4070 SUPER'; Family='ad102'; Uuid='GPU-22222222-2222-4222-8222-222222222222'}
        )
    }
    [IO.File]::WriteAllText($statePath, ($fixture | ConvertTo-Json -Depth 8))

    # This provider replaces only machine inventory, boot evidence and result location.
    # No production USB/EFI module is staged or invoked.
    [IO.File]::WriteAllText((Join-Path $scratch 'RTX.ps1'), @'
$script:FixtureRoot = $PSScriptRoot
function Read-FixtureState {
    $state = [IO.File]::ReadAllText((Join-Path $script:FixtureRoot 'fixture-state.json')) | ConvertFrom-Json
    if ($state.EvidenceKind -cne 'synthetic') { throw 'Only synthetic integration evidence is permitted.' }
    return $state
}
function Get-RtxInventory { (Read-FixtureState).Cards }
function Test-RtxAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    finally { $identity.Dispose() }
}
function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName, [string[]]$Property, [string]$Filter)
    if ($ClassName -eq 'Win32_OperatingSystem') {
        [pscustomobject]@{LastBootUpTime=[datetime]::Parse((Read-FixtureState).BootUtc).ToUniversalTime()}
    } elseif ($ClassName -ne 'Win32_LogicalDisk') { throw 'Unexpected machine query in synthetic fixture.' }
}
function Get-RtxBenchmarkBootEvidence($Letter, $Volume, $Targets) {
    if ($Letter -cne 'E' -or $Volume -cne 'SYNTHETIC-volume') { throw 'Unexpected fixture USB identity.' }
    $state = Read-FixtureState
    [pscustomobject]@{
        Confirmed=[bool]$state.Confirmed
        BootId=([datetime]::Parse($state.BootUtc).ToUniversalTime()).Ticks.ToString()
        LogId=$state.LogId
        Message='SYNTHETIC EFI evidence; no physical EFI boot or GPU transaction occurred.'
    }
}
function Get-RtxMeasureRoot { Join-Path $script:FixtureRoot 'results' }
function Get-RtxBenchmarkRuntimeRoot { Join-Path $script:FixtureRoot 'unused-runtime' }
function Get-RtxManagedBenchmarkPython { return $null }
function Initialize-RtxBenchmarkRuntime {
    $state = Read-FixtureState
    $state.ProvisionCalls++
    [IO.File]::WriteAllText((Join-Path $script:FixtureRoot 'fixture-state.json'), ($state | ConvertTo-Json -Depth 8))
    throw 'SYNTHETIC runtime provisioning boundary reached; installation is forbidden in this fixture.'
}
function Get-Command {
    [CmdletBinding()]
    param([string]$Name, [string]$CommandType, [switch]$All)
    if ($Name -eq 'nvidia-smi.exe') { [pscustomobject]@{Source='Invoke-FixtureSmi'} }
    elseif ($Name -ne 'python.exe') { throw 'Unexpected executable discovery in synthetic fixture.' }
}
function Invoke-FixtureSmi([string]$Query, [string]$Format) {
    if (!$Query.StartsWith('--query-gpu=') -or $Format -cne '--format=csv,noheader,nounits') { throw 'Unexpected telemetry query.' }
    $fields = $Query.Substring('--query-gpu='.Length).Split(',')
    $state = Read-FixtureState
    foreach ($card in $state.Cards) {
        $values = @{
            name=$card.Label; 'pci.bus_id'=('0000'+$card.Bdf); uuid=$card.Uuid
            driver_version=$state.Driver; vbios_version='synthetic-vbios'
            'power.limit'='200.00'; 'power.default_limit'='200.00'; 'clocks.max.sm'='1800'; 'clocks.max.memory'='7000'
            'pci.device_id'=('0x'+$card.Device+'10de'); 'pci.sub_device_id'=('0x'+$card.Subsystem)
        }
        $row = foreach ($field in $fields) {
            if (!$values.ContainsKey($field)) { throw 'Unsupported synthetic telemetry field.' }
            $values[$field]
        }
        $row -join ', '
    }
    $global:LASTEXITCODE = 0
}
'@)

    # The workload boundary uses invented schema-3 data. The stock validator and
    # comparison still run through the production Python subprocess path.
    [IO.File]::WriteAllText((Join-Path $scratch 'benchmark-tensors.py'), @'
"""SYNTHETIC integration workload. No Torch import, GPU access or measured timings."""
import argparse
import hashlib
import json
from pathlib import Path
import runpy
import sys

root = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--label', choices=('stock', 'unlocked'), required=True)
parser.add_argument('--gpu', required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
state_path = root / 'fixture-state.json'
state = json.loads(state_path.read_text(encoding='utf-8-sig'))
assert state['EvidenceKind'] == 'synthetic'
bdf = args.gpu.removeprefix('0000')
card, = [card for card in state['Cards'] if card['Bdf'] == bdf]
key = args.label + '|' + bdf
state['Calls'][key] = state['Calls'].get(key, 0) + 1
state_path.write_text(json.dumps(state), encoding='utf-8')
if state['FailBdf'] == bdf:
    raise SystemExit('SYNTHETIC injected per-GPU workload failure')

fixtures = runpy.run_path(str(root / 'tests' / 'test_compare_tensors.py'))
result = fixtures['uuid_result'](args.label, factor=0.5 if args.label == 'unlocked' else 1.0,
                               uuid=card['Uuid'], bdf=args.gpu)
for snapshot in [result['gpu_before'], result['gpu_pre_measurement'], *[trial['gpu_after'] for trial in result['trials']]]:
    snapshot['name'] = card['Label']
    snapshot['driver_version'] = state['Driver']
result['torch']['gpu_properties']['name'] = card['Label']
def identity(path):
    data = path.read_bytes()
    return {'name': path.name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
result['script'] = identity(Path(__file__))
result['python']['executable'] = identity(Path(sys.executable))
result['purpose'] = 'Synthetic desktop integration fixture; no physical EFI or GPU work'
args.output.write_text(json.dumps(result), encoding='utf-8')
print('SYNTHETIC workload result saved; no hardware performance was measured.')
'@)

    $harness = Join-Path $scratch 'DesktopEndToEnd.cs'
    [IO.File]::WriteAllText($harness, @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace RtxSetup
{
    internal static class DesktopEndToEnd
    {
        private const BindingFlags Private = BindingFlags.NonPublic | BindingFlags.Instance;
        private const BindingFlags Static = BindingFlags.NonPublic | BindingFlags.Static;
        private static readonly Type Setup = typeof(SetupWindow);
        private static readonly Type Benchmark = Setup.GetNestedType("BenchmarkWindow", BindingFlags.NonPublic);
        private static readonly string Root = AppDomain.CurrentDomain.BaseDirectory;
        private static readonly UsbDrive Usb = new UsbDrive { Letter = "E", VolumeId = "SYNTHETIC-volume", FileSystem = "FAT32", Label = "Synthetic fixture" };
        private static int assertions, failures;
        private static string lastFailure;
        private static bool after;

        [STAThread]
        private static int Main(string[] args)
        {
            try
            {
                Check((string)State()["EvidenceKind"] == "synthetic", "Unmarked fixture evidence.");
                using (var setup = new SetupWindow(null))
                using (var automatic = new CheckBox { Checked = true })
                {
                    // Isolate the checkbox state without firing its registry preference handler.
                    Setup.GetField("automaticBenchmarks", Private).SetValue(setup, automatic);
                    Task work = args[0] == "stock" ? Stock(setup) : args[0] == "after" ? After(setup) : Review(setup);
                    while (!work.IsCompleted) { Application.DoEvents(); Thread.Sleep(5); }
                    work.GetAwaiter().GetResult();
                }
                Console.WriteLine("PASS synthetic desktop integration {0}: {1} assertions. No physical EFI/GPU validation.", args[0], assertions);
                return 0;
            }
            catch (Exception error) { Console.Error.WriteLine(error.GetBaseException()); return 1; }
        }

        private static async Task Stock(SetupWindow setup)
        {
            var python = (string)State()["Python"];
            var initial = await Status(setup, python);
            Check(!initial.BootConfirmed && initial.Cards.Length == 2 && initial.Cards.All(card => !card.HasStock && card.CanStock), "Stock status did not start without baselines.");
            Check(!Directory.Exists(Path.Combine(Root, "results")), "Status wrote measurement results.");
            Ui(setup, "ProbeStaged", false, false, "Show first USB boot");
            if (File.Exists(Path.Combine(Root, "exercise-explorer")))
            {
                string args = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + Path.Combine(Root, "desktop", "Measure.ps1") + "\" -Action Status -Python \"" + python + "\" -Drive E -VolumeId SYNTHETIC-volume";
                var response = await Task.Run(() => UserProcess.RunPowerShell(Root, args, true));
                var throughExplorer = Parse(response);
                Check(throughExplorer.Cards.Length == 2 && !throughExplorer.BootConfirmed, "Explorer did not preserve the synthetic stock status.");
            }
            int attempts = 0, prompts = 0;
            Func<Task<bool>> attempt = async () => {
                attempts++;
                var current = attempts == 1 ? initial : await Status(setup, python);
                using (var window = NewBenchmark(setup, current, python))
                {
                    await RunTest(window, "Stock");
                    var status = Measurement(window);
                    if (attempts == 1)
                        Check(status.Cards[0].HasStock && !status.Cards[1].HasStock, "Partial stock results were not refreshed after a per-GPU failure. " + lastFailure);
                    return status.Cards.All(card => card.HasStock);
                }
            };
            Func<DialogResult> choose = () => { prompts++; Set("FailBdf", ""); return DialogResult.Retry; };
            var resolver = Setup.GetMethod("ResolveBenchmarkStep", Static) ?? Setup.GetMethod("ResolveStockBeforeStaging", Static);
            bool complete = await (Task<bool>)resolver.Invoke(null, new object[] { attempt, choose });
            Check(complete && attempts == 2 && prompts == 1 && failures == 1, "Stock failure did not retry once and complete.");
            Check(Calls("stock|0000:01:00.0") == 1 && Calls("stock|0000:02:00.0") == 2, "Stock retry reran the already saved GPU.");
            Check(!Directory.GetDirectories(Path.Combine(Root, "results"), ".pending-*").Any(), "Failed stock work left a pending result.");
            var saved = await Status(setup, null);
            Check(saved.Python == python && saved.Cards.All(card => card.HasStock), "Saved receipts did not recover the Python selection.");
            Ui(setup, "ProbePassed", false, false, "Prepare unlock USB");
            Ui(setup, "UnlockStaged", true, false, "Show second USB boot");
        }

        private static async Task After(SetupWindow setup)
        {
            after = true;
            var initial = await Status(setup, null);
            Check(initial.Python == (string)State()["Python"] && initial.BootConfirmed && initial.Cards.All(card => card.HasStock && card.CanUnlocked),
                "A restarted app did not recover both stock receipts for synthetic after evidence.");
            MeasureStatus partial;
            using (var window = NewBenchmark(setup, initial, null))
            {
                await RunTest(window, "Unlocked");
                partial = Measurement(window);
                Check(!partial.Cards[0].HasComparisonForBoot && partial.Cards[1].HasComparisonForBoot && failures == 1,
                    "Automatic after processing did not continue to the second GPU and refresh partial results. " + lastFailure);
                Check(Calls("unlocked|0000:01:00.0") == 1 && Calls("unlocked|0000:02:00.0") == 1, "A first-card after failure skipped another eligible GPU.");
            }
            Set("FailBdf", "");
            MeasureStatus complete;
            using (var window = NewBenchmark(setup, partial, null))
            {
                await RunTest(window, "Unlocked");
                complete = Measurement(window);
                Check(complete.HasComparisonForBoot && complete.Cards.All(card => card.HasComparisonForBoot), "Retry did not finish both after comparisons.");
                Check(Calls("unlocked|0000:01:00.0") == 2 && Calls("unlocked|0000:02:00.0") == 1, "Retry reran a completed after result.");
            }
            using (var window = NewBenchmark(setup, complete, null))
            {
                await RunTest(window, "Unlocked");
                Check(Calls("unlocked|0000:01:00.0") == 2 && Calls("unlocked|0000:02:00.0") == 1, "Completed automatic results were repeated.");
                CheckRows(window);
            }
            Ui(setup, "UnlockLogged", false, true, "View benchmark results");
        }

        private static async Task Review(SetupWindow setup)
        {
            after = true;
            var status = await Status(setup, null);
            Check(status.HasComparisonForBoot && status.Python == (string)State()["Python"], "A new process did not recover the completed comparisons and Python path.");
            using (var window = NewBenchmark(setup, status, null)) { CheckRows(window); }
            var paths = Directory.GetFiles(Path.Combine(Root, "results"), "comparison.json", SearchOption.AllDirectories);
            Check(paths.Length == 2, "The completed run did not save exactly two per-GPU comparisons.");
            foreach (var path in paths)
            {
                var report = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(path));
                Check((string)report["data_kind"] == "synthetic", "A synthetic comparison lost its data kind.");
                Check(!(bool)((Dictionary<string, object>)report["operator_labels"])["verified"], "Operator labels were represented as physical unlock proof.");
            }
            foreach (var card in status.Cards)
                Check(card.Modes.Count == 4 && card.Modes.Values.All(mode => Math.Abs(mode.speed_ratio - 2) < 0.0001), "The actual comparator did not return all four invented ratios.");
            var automatic = (Task<bool>)Setup.GetMethod("RunAutomaticBenchmark", Private).Invoke(setup, new object[] { "Unlocked", Usb, false });
            Check(await automatic, "The already-complete automatic flow did not report success.");
            Check(Calls("unlocked|0000:01:00.0") == 2 && Calls("unlocked|0000:02:00.0") == 1, "Reopening Setup repeated completed after work.");
            Set("Confirmed", false);
            var disconnected = await Status(setup, null);
            Check(!disconnected.BootConfirmed && !disconnected.CanProvision && disconnected.Cards.All(card => !card.CanStock),
                "Removing synthetic USB evidence reclassified the known after boot as stock.");
            Check((await Run(setup, "StockFresh", null, null)).ExitCode != 0, "A known after boot accepted a fresh stock request.");
            Check((await Run(setup, "Provision", null, null)).ExitCode != 0 && Convert.ToInt32(State()["ProvisionCalls"]) == 0,
                "A known after boot reached runtime installation.");
            Set("Confirmed", true);
            Set("BootUtc", "2000-01-01T01:11:00Z");
            var stale = await Status(setup, null);
            Check(!stale.HasComparisonForBoot && stale.Cards.All(card => !card.CanUnlocked && !card.HasComparisonForBoot), "A stale synthetic EFI log authorized a later Windows boot.");
            Set("Confirmed", false);
            Set("BootUtc", "2000-01-01T01:20:00Z");
            Set("LogId", "SYNTHETIC-normal-boot");
            var unchanged = Parse(await Run(setup, "Stock", null, null));
            Check(unchanged.Status == "AlreadyComplete" && Calls("stock|0000:01:00.0") == 1 && Calls("stock|0000:02:00.0") == 2,
                "Automatic stock replaced an existing matching baseline.");
            var refreshed = Parse(await Run(setup, "StockFresh", null, null));
            Check(refreshed.Status == "Complete" && Calls("stock|0000:01:00.0") == 2 && Calls("stock|0000:02:00.0") == 3,
                "The manual fresh-stock action did not reach the measurement backend.");
            Set("BootUtc", "2000-01-01T01:30:00Z");
            Set("LogId", "SYNTHETIC-new-after-boot");
            Set("Confirmed", true);
            var nextBoot = await Status(setup, null);
            Check(nextBoot.Cards.All(card => card.HasStock && card.CanUnlocked), "The refreshed baseline did not authorize a later synthetic after comparison.");
        }

        private static Task<BackendResult> Run(SetupWindow setup, string action, string python, string gpu)
        {
            if (after) Check(python == null, "The fixture injected a Python selection after restarting.");
            return (Task<BackendResult>)Setup.GetMethod("RunMeasure", Private).Invoke(setup, new object[] { action, python, gpu, Usb });
        }

        private static async Task<MeasureStatus> Status(SetupWindow setup, string python)
        {
            return Parse(await Run(setup, "Status", python, null));
        }

        private static MeasureStatus Parse(BackendResult response)
        {
            return (MeasureStatus)Setup.GetMethod("ParseMeasureStatus", Static).Invoke(null, new object[] { response });
        }

        private static Form NewBenchmark(SetupWindow setup, MeasureStatus initial, string python)
        {
            Func<string, string, string, Task<BackendResult>> run = (action, path, gpu) => Run(setup, action, path, gpu);
            Func<string, string, Action<string>, Task> report = (step, detail, notify) => { failures++; lastFailure = detail; return Task.FromResult(0); };
            Func<Task> provision = () => { throw new Exception("Unexpected runtime installation in synthetic flow."); };
            return (Form)Activator.CreateInstance(Benchmark, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic, null,
                new object[] { run, report, provision, python, initial, null }, null);
        }

        private static Task RunTest(Form window, string action)
        {
            return (Task)Benchmark.GetMethod("RunTest", Private).Invoke(window, new object[] { action, true });
        }

        private static MeasureStatus Measurement(Form window)
        {
            return (MeasureStatus)Benchmark.GetProperty("Measurement").GetValue(window, null);
        }

        private static void CheckRows(Form window)
        {
            var list = (ListView)Benchmark.GetField("results", Private).GetValue(window);
            Check(list.Items.Count == 2, "Benchmark UI did not display both GPU rows.");
            foreach (ListViewItem row in list.Items)
                Check(row.SubItems.Cast<ListViewItem.ListViewSubItem>().Count(cell => cell.Text == 2.0.ToString("0.00") + "\u00D7") == 4,
                    "Benchmark UI did not display all four synthetic comparison ratios.");
        }

        private static void Ui(SetupWindow setup, string media, bool canBoot, bool complete, string expected)
        {
            Setup.GetField("state", Private).SetValue(setup, new KitStatus {
                Targets = new[] { new Card { Label = "Synthetic RTX 3080", Bdf = "0000:01:00.0", Device = "2206", MemoryMiB = 10240 } },
                Drives = new[] { Usb }, FormatDrives = new UsbDrive[0], BootProblems = new string[0], WindowsDisplayProblems = new string[0],
                HasPackage = true, FirmwareState = "Ready", FastStartupState = "Disabled", EncryptionState = "FullyDecrypted",
                ProtectionState = "Off", EncryptionPercentage = 0, MediaState = media, CanBootUnlock = canBoot, CompletedUnlockBoot = complete
            });
            Setup.GetMethod("ShowStatus", Private).Invoke(setup, new object[] { "E" });
            Setup.GetMethod("UpdateButtons", Private).Invoke(setup, null);
            var primary = (Button)Setup.GetField("primary", Private).GetValue(setup);
            Check(primary.Enabled && primary.Text == expected, "The synthetic " + media + " UI transition was wrong.");
        }

        private static Dictionary<string, object> State()
        {
            return new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(Path.Combine(Root, "fixture-state.json")));
        }

        private static void Set(string name, object value)
        {
            var state = State(); state[name] = value;
            File.WriteAllText(Path.Combine(Root, "fixture-state.json"), new JavaScriptSerializer().Serialize(state));
        }

        private static int Calls(string key)
        {
            var calls = (Dictionary<string, object>)State()["Calls"];
            return calls.ContainsKey(key) ? Convert.ToInt32(calls[key]) : 0;
        }

        private static void Check(bool condition, string message)
        {
            assertions++;
            if (!condition) throw new Exception(message);
        }
    }
}
'@)
    $exe = Join-Path $scratch 'DesktopEndToEnd.exe'
    $sources = @(Get-ChildItem -LiteralPath (Join-Path $repo 'desktop') -Filter '*.cs' -File | ForEach-Object FullName)
    & $compiler /nologo /target:exe /platform:x64 /main:RtxSetup.DesktopEndToEnd "/out:$exe" `
        /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll $sources $harness
    if ($LASTEXITCODE) { throw 'Desktop integration harness compilation failed.' }
    if ($ExerciseExplorer) { [IO.File]::WriteAllText((Join-Path $scratch 'exercise-explorer'), 'synthetic integration fixture') }

    foreach ($phase in @('stock', 'after', 'review')) {
        if ($phase -eq 'after') {
            $fixture = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
            $fixture.BootUtc = '2000-01-01T01:10:00Z'
            $fixture.Confirmed = $true
            $fixture.LogId = 'SYNTHETIC-not-a-physical-efi-boot'
            $fixture.FailBdf = '0000:01:00.0'
            [IO.File]::WriteAllText($statePath, ($fixture | ConvertTo-Json -Depth 8))
        }
        $start = [Diagnostics.ProcessStartInfo]::new($exe, $phase)
        $start.WorkingDirectory = $scratch
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($start)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (!$process.WaitForExit(60000)) { $process.Kill(); $null = $process.WaitForExit(5000); throw "Synthetic integration phase $phase timed out." }
            if ($process.ExitCode) { throw "Synthetic integration phase $phase failed. $($stderr.Result.TrimEnd())" }
            $stdout.Result.TrimEnd()
        } finally { $process.Dispose() }
    }
} finally {
    $resolved = [IO.Path]::GetFullPath($scratch)
    if (!$resolved.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -or
        ![IO.Path]::GetFileName($resolved).StartsWith('rtx e2e ')) { throw 'Unsafe integration fixture cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
