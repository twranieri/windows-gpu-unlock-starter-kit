# SPDX-License-Identifier: GPL-2.0-only
#Requires -Version 5.1
# Exercise the signed-in Explorer handoff with -ExerciseExplorer even from ordinary PowerShell.
param([switch]$RequireElevated, [switch]$ExerciseExplorer)

$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if ($RequireElevated -and !$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this test in an elevated PowerShell to verify the desktop handoff.'
}

$compiler = Join-Path $env:SystemRoot 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (!(Test-Path -LiteralPath $compiler)) { throw 'The x64 .NET Framework C# compiler is required.' }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('rtx launcher smoke ' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($scratch)
$desktop = Join-Path $scratch 'desktop'
$benchmarkHost = Join-Path $desktop 'BenchmarkHost.ps1'
$harness = Join-Path $scratch 'UserProcessSmoke.cs'
$executable = Join-Path $scratch 'UserProcessSmoke.exe'
$fixture = Join-Path $scratch ('benchmark fixture ' + [char]0x00E9 + '.ps1')
try {
    $null = [IO.Directory]::CreateDirectory($desktop)
    [IO.File]::Copy((Join-Path $PSScriptRoot '../desktop/BenchmarkHost.ps1'), $benchmarkHost)

    [IO.File]::WriteAllText($harness, @'
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;

namespace RtxSetup
{
    internal sealed class BackendResult
    {
        public int ExitCode;
        public string Output, Error;
    }

    internal static class UserProcessSmoke
    {
        [DllImport("user32.dll")]
        private static extern IntPtr GetShellWindow();

        private static int Main(string[] args)
        {
            if (GetShellWindow() == IntPtr.Zero)
            {
                Console.WriteLine("SKIP: This test requires an interactive Windows desktop with Explorer.");
                return 77;
            }

            try
            {
                string directory = Environment.CurrentDirectory;
                string script = Path.Combine(directory, "benchmark fixture \u00E9.ps1");
                string command = "-NoLogo -NoProfile -NonInteractive -File \"" + script + "\"";
                string sid;
                int session;
                bool elevated;
                using (var identity = WindowsIdentity.GetCurrent())
                using (var process = Process.GetCurrentProcess())
                {
                    sid = identity.User.Value;
                    session = process.SessionId;
                    elevated = new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
                }
                string expectedOutput = sid + ":" + session + Environment.NewLine +
                    directory + Environment.NewLine + "stdout \u00E9 " + new string('o', 128 * 1024) + Environment.NewLine;
                string expectedError = "stderr \u00E9 " + new string('e', 128 * 1024) + Environment.NewLine;
                Verify(UserProcess.RunPowerShell(directory, command), expectedOutput, expectedError,
                    elevated ? "Elevated desktop handoff" : "Ordinary process launch");
                if (args.Length != 0 && !elevated)
                    Verify(UserProcess.RunPowerShell(directory, command, true), expectedOutput, expectedError, "Explorer handoff");
                return 0;
            }
            catch (Exception error)
            {
                Console.Error.WriteLine(error);
                return 1;
            }
        }

        private static void Verify(BackendResult result, string expectedOutput, string expectedError, string launch)
        {
            if (result.ExitCode != 19)
                throw new Exception(launch + " returned exit code " + result.ExitCode + ". " +
                    (result.Error ?? "").Substring(0, Math.Min((result.Error ?? "").Length, 256)));
            if (result.Output != expectedOutput) throw new Exception(launch + " did not capture stdout verbatim.");
            if (result.Error != expectedError) throw new Exception(launch + " did not capture stderr verbatim.");
            Console.WriteLine("PASS: " + launch +
                " preserved a non-admin child, the working directory, stdout, stderr, and the exit code.");
        }
    }
}
'@)

    [IO.File]::WriteAllText($fixture, @'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 99 }
[Console]::WriteLine(('{0}:{1}' -f $identity.User.Value, [Diagnostics.Process]::GetCurrentProcess().SessionId))
[Console]::WriteLine((Get-Location).ProviderPath)
[Console]::WriteLine('stdout ' + [char]0x00E9 + ' ' + ('o' * 128KB))
[Console]::Error.WriteLine('stderr ' + [char]0x00E9 + ' ' + ('e' * 128KB))
exit 19
'@)

    $source = Join-Path $PSScriptRoot '../desktop/UserProcess.cs'
    & $compiler /nologo /target:exe /platform:x64 "/out:$executable" $source $harness
    if ($LASTEXITCODE -ne 0) { throw 'The launcher test harness could not be compiled.' }

    $start = [Diagnostics.ProcessStartInfo]::new($executable)
    $start.WorkingDirectory = $scratch
    if ($ExerciseExplorer) { $start.Arguments = 'exercise-explorer' }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(45000)) {
            $process.Kill()
            $null = $process.WaitForExit(5000)
            throw 'The benchmark launcher test did not finish within 45 seconds.'
        }
        $stdout.Result.TrimEnd()
        if ($process.ExitCode -eq 77) {
            if ($RequireElevated -or $ExerciseExplorer) { throw 'The requested test requires an interactive Windows desktop with Explorer.' }
            return
        }
        if ($process.ExitCode -ne 0) { throw ('Benchmark launcher test failed. ' + $stderr.Result.TrimEnd()) }
    } finally { $process.Dispose() }
} finally {
    foreach ($file in @($harness, $executable, $fixture, $benchmarkHost)) { [IO.File]::Delete($file) }
    if ([IO.Directory]::Exists($desktop)) { [IO.Directory]::Delete($desktop) }
    [IO.Directory]::Delete($scratch)
}
