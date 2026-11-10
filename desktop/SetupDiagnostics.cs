// SPDX-License-Identifier: GPL-2.0-only
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace RtxSetup
{
    internal static class SetupDiagnostics
    {
        private const int MaxDetail = 12000;
        private static readonly Regex Sensitive = new Regex(
            @"(?im)^[ \t]*(?:At [A-Z]:[\\/]|\+(?:[ \t]|$)|File .*, line \d+).*$|" +
            @"\b(?:GPU-)?[a-f\d]{8}(?:-[a-f\d]{4}){3}-[a-f\d]{12}\b|" +
            @"\b[a-f\d]{32}\b|\b\d{6}(?:-\d{6}){7}\b|" +
            @"(?:\b[A-Z]:[\\/]|\\\\|/(?:home|Users|mnt)/)[^\r\n]*");

        internal static string GetCheckFailure(KitStatus status)
        {
            if (status == null) return null;
            if (!string.IsNullOrWhiteSpace(status.InventoryError)) return status.InventoryError;
            if (!string.IsNullOrWhiteSpace(status.StorageError)) return status.StorageError;
            if (!string.IsNullOrWhiteSpace(status.PackageError)) return status.PackageError;
            if (!status.HasPackage && !string.IsNullOrWhiteSpace(status.BundleError)) return status.BundleError;
            if (status.MediaFailed) return status.MediaMessage;
            if (status.HasLog && status.WindowsDisplayProblems != null && status.WindowsDisplayProblems.Length > 0)
                return string.Join(Environment.NewLine, status.WindowsDisplayProblems);
            return null;
        }

        internal static string Clean(string value)
        {
            if (string.IsNullOrWhiteSpace(value)) return "Unavailable";
            var limited = value.Substring(0, Math.Min(value.Length, MaxDetail));
            return Sensitive.Replace(Regex.Replace(limited, @"[^\S\r\n\t]|[\x00-\x08\x0b\x0c\x0e-\x1f]", " "), "[redacted]").Trim();
        }

        internal static string Save(string root, string step, string detail, KitStatus status, UsbDrive usb)
        {
            var body = new StringBuilder();
            body.AppendLine("Windows GPU Unlock Setup diagnostic report (format 1)");
            body.AppendLine("Review this file, then attach it to your support report.");
            body.AppendLine("Setup version: " + typeof(SetupDiagnostics).Assembly.GetName().Version);
            body.AppendLine("Recorded (UTC): " + DateTime.UtcNow.ToString("o"));
            body.AppendLine("Step: " + Clean(step));
            body.AppendLine("Result: " + Clean(detail));
            if (status != null)
            {
                body.AppendLine();
                body.AppendLine("WINDOWS AND SETUP CHECKS");
                body.AppendLine("Platform: " + Clean(status.Platform));
                body.AppendLine("Firmware: " + Clean(status.FirmwareState));
                body.AppendLine("Fast Startup: " + Clean(status.FastStartupState));
                body.AppendLine("BitLocker: " + Clean(status.EncryptionState) + " / " + Clean(status.ProtectionState));
                body.AppendLine("Prepared package verified: " + status.HasPackage);
                foreach (string problem in status.BootProblems ?? new string[0])
                    body.AppendLine("Boot prerequisite: " + Clean(problem));
                foreach (string problem in status.WindowsDisplayProblems ?? new string[0])
                    body.AppendLine("Windows display: " + Clean(problem));
                if (usb != null)
                {
                    body.AppendLine("Selected USB filesystem: " + Clean(usb.FileSystem));
                    body.AppendLine("Selected USB capacity (bytes): " + usb.TotalBytes);
                    body.AppendLine("USB state: " + Clean(status.MediaState) + " / " + Clean(status.MediaTitle));
                    body.AppendLine("USB result: " + Clean(status.MediaMessage));
                }
            }
            body.AppendLine();
            body.AppendLine(Collect(root, usb));
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (string.IsNullOrWhiteSpace(local) || local.StartsWith(@"\\", StringComparison.Ordinal))
                throw new IOException("A local Windows application data folder is required.");
            var reports = ReportFolder(ReportFolder(local, "WindowsGpuUnlock"), "Diagnostics");
            var path = Path.Combine(reports, "GPU-Unlock-Diagnostic-" + DateTime.UtcNow.ToString("yyyyMMdd-HHmmss") +
                "-" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".txt");
            using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            using (var writer = new StreamWriter(output, new UTF8Encoding(true)))
                writer.Write(body.ToString());
            return path;
        }

        private static string ReportFolder(string parent, string name)
        {
            var folder = Directory.CreateDirectory(Path.Combine(parent, name));
            if ((folder.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Setup requires an ordinary local diagnostics folder.");
            return folder.FullName;
        }

        private static string Collect(string root, UsbDrive usb)
        {
            var script = Path.Combine(root, "desktop", "Diagnostics.ps1");
            if (!File.Exists(script)) return "Hardware collector unavailable. Extract the whole Setup ZIP.";
            var arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + script + "\"";
            if (usb != null && Regex.IsMatch(usb.Letter ?? "", "^[D-Z]$") &&
                !string.IsNullOrEmpty(usb.VolumeId) && usb.VolumeId.IndexOf('"') < 0)
            {
                var trailing = usb.VolumeId.Length - usb.VolumeId.TrimEnd('\\').Length;
                arguments += " -Drive " + usb.Letter + " -VolumeId \"" + usb.VolumeId + new string('\\', trailing) + "\"";
            }
            try
            {
                var output = new StringBuilder();
                using (var process = new Process())
                {
                    process.StartInfo = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory,
                        @"WindowsPowerShell\v1.0\powershell.exe"), arguments)
                    {
                        UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = root,
                        RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8
                    };
                    process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e)
                    {
                        if (e.Data != null && output.Length < MaxDetail)
                            output.AppendLine(e.Data.Substring(0, Math.Min(e.Data.Length, MaxDetail - output.Length)));
                    };
                    process.ErrorDataReceived += delegate { };
                    process.Start();
                    process.BeginOutputReadLine();
                    process.BeginErrorReadLine();
                    if (!process.WaitForExit(20000))
                    {
                        try { process.Kill(); } catch (InvalidOperationException) { }
                        return "Hardware collector timed out.";
                    }
                    process.WaitForExit();
                    if (process.ExitCode != 0) return "Hardware collector exited with code " + process.ExitCode + ".";
                }
                return Clean(output.ToString());
            }
            catch (Exception)
            {
                return "Hardware collector could not complete.";
            }
        }
    }
}
