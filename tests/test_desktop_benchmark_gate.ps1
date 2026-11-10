# SPDX-License-Identifier: GPL-2.0-only
#Requires -Version 5.1
# Exercises the desktop decision gate using synthetic outcomes and no visible UI.
$ErrorActionPreference = 'Stop'

$compiler = Join-Path $env:SystemRoot 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (!(Test-Path -LiteralPath $compiler)) { throw 'The x64 .NET Framework C# compiler is required.' }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('rtx-benchmark-gate-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($scratch)
$harness = Join-Path $scratch 'DesktopBenchmarkGateSmoke.cs'
$executable = Join-Path $scratch 'DesktopBenchmarkGateSmoke.exe'
try {
    [IO.File]::WriteAllText($harness, @'
using System;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace RtxSetup
{
    internal static class DesktopBenchmarkGateSmoke
    {
        private static void Verify(string name, bool expected, bool[] stockResults, params DialogResult[] choices)
        {
            int stockCalls = 0;
            int choiceCalls = 0;
            bool actual = SetupWindow.ResolveBenchmarkStep(
                () => Task.FromResult(stockResults[stockCalls++]),
                () => choices[choiceCalls++]).GetAwaiter().GetResult();
            if (actual != expected || stockCalls != stockResults.Length || choiceCalls != choices.Length)
                throw new Exception(name + " did not produce the expected decision and number of calls.");
        }

        [STAThread]
        private static int Main()
        {
            try
            {
                Verify("Successful stock run", true, new[] { true });
                Verify("Retry until successful", true, new[] { false, false, true }, DialogResult.Retry, DialogResult.Retry);
                Verify("Back to Setup", false, new[] { false }, DialogResult.Cancel);
                Verify("Retry then back", false, new[] { false, false }, DialogResult.Retry, DialogResult.Cancel);
                Verify("Continue without comparison", true, new[] { false }, DialogResult.Ignore);
                Verify("Dismiss prompt", false, new[] { false }, DialogResult.None);
                Verify("Unexpected response", false, new[] { false }, DialogResult.OK);
                Console.WriteLine("PASS desktop stock benchmark gate: success, retries, back, explicit continue and dismissal.");
                return 0;
            }
            catch (Exception error)
            {
                Console.Error.WriteLine(error);
                return 1;
            }
        }
    }
}
'@)

    $desktop = Join-Path $PSScriptRoot '../desktop'
    $sources = @(Get-ChildItem -LiteralPath $desktop -Filter '*.cs' -File | ForEach-Object FullName)
    & $compiler /nologo /target:exe /platform:x64 /main:RtxSetup.DesktopBenchmarkGateSmoke "/out:$executable" `
        /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll $sources $harness
    if ($LASTEXITCODE -ne 0) { throw 'The desktop benchmark gate harness could not be compiled.' }

    $start = [Diagnostics.ProcessStartInfo]::new($executable)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(10000)) {
            $process.Kill()
            $null = $process.WaitForExit(5000)
            throw 'The desktop benchmark gate test timed out.'
        }
        if ($process.ExitCode -ne 0) { throw ('Desktop benchmark gate test failed. ' + $stderr.Result.TrimEnd()) }
        $stdout.Result.TrimEnd()
    } finally { $process.Dispose() }
} finally {
    [IO.File]::Delete($harness)
    [IO.File]::Delete($executable)
    [IO.Directory]::Delete($scratch)
}
