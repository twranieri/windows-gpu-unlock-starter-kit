# SPDX-License-Identifier: GPL-2.0-only
#Requires -Version 5.1
# Uses a constructor-free form and a stub Resume class. No Startup or registry writes.
$ErrorActionPreference = 'Stop'

$compiler = Join-Path $env:SystemRoot 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (!(Test-Path -LiteralPath $compiler)) { throw 'The x64 .NET Framework C# compiler is required.' }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('rtx-resume-completion-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($scratch)
$harness = Join-Path $scratch 'DesktopResumeCompletionSmoke.cs'
$executable = Join-Path $scratch 'DesktopResumeCompletionSmoke.exe'
try {
    [IO.File]::WriteAllText($harness, @'
using System;
using System.Reflection;
using System.Runtime.Serialization;
using System.Windows.Forms;

namespace RtxSetup
{
    internal static class Resume
    {
        internal static int Cancellations;
        internal static int Schedules;
        public static void Cancel() { Cancellations++; }
        public static void Schedule(string exe, string volumeId) { Schedules++; }
        public static bool Consume(string exe, string[] args) { return false; }
        public static string ReadVolume(string[] args) { return null; }
    }

    internal static class DesktopResumeCompletionSmoke
    {
        private static FieldInfo Field(string name)
        {
            return typeof(SetupWindow).GetField(name, BindingFlags.Instance | BindingFlags.NonPublic);
        }

        private static void Set(SetupWindow window, string name, object value)
        {
            Field(name).SetValue(window, value);
        }

        private static object Get(SetupWindow window, string name)
        {
            return Field(name).GetValue(window);
        }

        private static object Invoke(SetupWindow window, string name, params object[] args)
        {
            return typeof(SetupWindow).GetMethod(name, BindingFlags.Instance | BindingFlags.NonPublic).Invoke(window, args);
        }

        private static SetupWindow Make(bool completed, bool automatic, bool finished, bool skipped, bool reopen)
        {
            // Skip the real constructor, which reads preferences and wires registry-saving events.
            var window = (SetupWindow)FormatterServices.GetUninitializedObject(typeof(SetupWindow));
            Set(window, "state", new KitStatus { CompletedUnlockBoot = completed });
            Set(window, "automaticBenchmarks", new CheckBox { Checked = automatic });
            Set(window, "reopen", new CheckBox { Checked = reopen });
            Set(window, "drives", new ComboBox());
            Set(window, "activity", new TextBox());
            Set(window, "afterBenchmarksFinished", finished);
            Set(window, "afterBenchmarksSkipped", skipped);
            Set(window, "reopenPreference", reopen);
            Resume.Cancellations = Resume.Schedules = 0;
            return window;
        }

        private static void Check(bool condition, string message)
        {
            if (!condition) throw new Exception(message);
        }

        private static void CheckFinish(string name, bool completed, bool automatic, bool finished, bool skipped, bool expected)
        {
            var window = Make(completed, automatic, finished, skipped, true);
            Check((bool)Invoke(window, "CanFinishCurrentBoot") == expected, name + " finish predicate");
            Invoke(window, "UpdateResumeAfterFlow", null, false);
            Check((bool)Get(window, "resumeDisarmed") == expected, name + " resume decision");
            Check(Resume.Cancellations == (expected ? 1 : 0), name + " cancellation decision");
            Invoke(window, "ArmResume");
            Check(Resume.Schedules == (expected ? 0 : 1), name + " scheduling decision");
            Console.WriteLine("PASS " + name);
        }

        [STAThread]
        private static int Main()
        {
            try
            {
                CheckFinish("Verified boot alone stays pending with auto on", true, true, false, false, false);
                CheckFinish("Completed comparisons finish the verified boot", true, true, true, false, true);
                CheckFinish("Explicit skip finishes the verified boot", true, true, false, true, true);
                CheckFinish("Auto off finishes the verified boot", true, false, false, false, true);
                CheckFinish("Incomplete boot stays pending even with saved comparisons", false, true, true, true, false);
                CheckFinish("Incomplete boot stays pending with auto off", false, false, true, true, false);
                foreach (bool reopen in new[] { true, false })
                {
                    var window = Make(true, false, false, false, reopen);
                    Invoke(window, "UpdateResumeAfterFlow", null, false);
                    Check((bool)Get(window, "resumeDisarmed"), "Auto-off setup must finish first");
                    ((CheckBox)Get(window, "automaticBenchmarks")).Checked = true;
                    Invoke(window, "UpdateResumeAfterFlow", null, false);
                    Check(!(bool)Get(window, "resumeDisarmed"), "Re-enabled auto must restore pending state");
                    Check(!(bool)Get(window, "resumeCleanupComplete"), "Pending state must reset cleanup");
                    Check(((CheckBox)Get(window, "reopen")).Checked == reopen, "Pending state must preserve reopen choice");
                    Invoke(window, "ArmResume");
                    Check(Resume.Schedules == (reopen ? 1 : 0), "Pending state must schedule only when reopening was selected");
                    Console.WriteLine("PASS Auto re-enable respects reopen preference " + reopen);
                }
                Console.WriteLine("PASS Eight completion and resume cases. All Resume calls used stubs.");
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
    $sources = @(Get-ChildItem -LiteralPath $desktop -Filter '*.cs' -File |
        Where-Object Name -ne 'Resume.cs' | ForEach-Object FullName)
    & $compiler /nologo /target:exe /platform:x64 /main:RtxSetup.DesktopResumeCompletionSmoke "/out:$executable" `
        /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll $sources $harness
    if ($LASTEXITCODE -ne 0) { throw 'The desktop resume completion harness could not be compiled.' }

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
            throw 'The desktop resume completion test timed out.'
        }
        if ($process.ExitCode -ne 0) { throw ('Desktop resume completion test failed. ' + $stderr.Result.TrimEnd()) }
        $stdout.Result.TrimEnd()
    } finally { $process.Dispose() }
} finally {
    [IO.File]::Delete($harness)
    [IO.File]::Delete($executable)
    [IO.Directory]::Delete($scratch)
}
