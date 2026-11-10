// SPDX-License-Identifier: GPL-2.0-only
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Security.Principal;
using System.Text;

namespace RtxSetup
{
    internal static class Resume
    {
        private const string LinkName = "Windows GPU Unlock Setup - Resume.lnk";
        private const string LinkDescription = "Windows GPU Unlock Setup one-shot resume";
        private const string VolumeSwitch = "--resume-volume";
        private const int MaxVolumeLength = 256;
        private const int MaxShortcutArguments = 1023;

        public static void Schedule(string exe, string volumeId)
        {
            RequireShellUser();
            string application = Path.GetFullPath(exe);
            if (!File.Exists(application) || !string.Equals(Path.GetExtension(application), ".exe", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Keep the extracted Setup executable available until the next sign-in.");

            string directory = Path.GetDirectoryName(application);
            string arguments = BuildArguments(Path.GetFileName(application), volumeId);
            string path = GetLinkPath();
            string powerShell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(powerShell))
                throw new InvalidOperationException("Windows PowerShell is required for reopening Setup after sign-in.");

            WithShortcut(delegate(IShellLinkW link, IPersistFile file)
            {
                if (File.Exists(path)) RequireOwnedShortcut(path, link, file, powerShell);
                link.SetPath(powerShell);
                link.SetWorkingDirectory(directory);
                link.SetArguments(arguments);
                link.SetDescription(LinkDescription);
                file.Save(path, true);
            });
        }

        public static void Cancel()
        {
            string path = GetLinkPath();
            if (!File.Exists(path)) return;
            RequireShellUser();
            string powerShell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            WithShortcut(delegate(IShellLinkW link, IPersistFile file)
            {
                RequireOwnedShortcut(path, link, file, powerShell);
            });
            File.Delete(path);
        }

        public static string ReadVolume(string[] args)
        {
            if (args == null || args.Length != 2 || args[0] != VolumeSwitch ||
                string.IsNullOrEmpty(args[1]) || args[1].Length > ((MaxVolumeLength + 2) / 3) * 4)
                return null;

            byte[] bytes;
            try { bytes = Convert.FromBase64String(args[1]); }
            catch (FormatException) { return null; }
            if (Convert.ToBase64String(bytes) != args[1]) return null;
            string volumeId = Encoding.UTF8.GetString(bytes);
            return IsVolumeId(volumeId) ? volumeId : null;
        }

        private static string BuildArguments(string fileName, string volumeId)
        {
            string resumeArgument = "";
            if (!string.IsNullOrEmpty(volumeId))
            {
                if (!IsVolumeId(volumeId))
                    throw new ArgumentException("The selected drive does not have a valid resume identity.", "volumeId");
                resumeArgument = " -ArgumentList '" + VolumeSwitch + " " +
                    Convert.ToBase64String(Encoding.ASCII.GetBytes(volumeId)) + "'";
            }

            // The shortcut's working directory holds the extracted folder. Only
            // fixed text and Base64 data enter the PowerShell command.
            string name = Convert.ToBase64String(Encoding.UTF8.GetBytes(fileName));
            string command = "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -Command \"" +
                "$ErrorActionPreference='Stop';" +
                "$startup=[Environment]::GetFolderPath('Startup');if(!$startup){exit};" +
                "$link=[IO.Path]::Combine($startup,'" + LinkName + "');if(![IO.File]::Exists($link)){exit};" +
                "[IO.File]::Delete($link);" +
                "$name=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + name + "'));" +
                "$folder=[Environment]::CurrentDirectory;$exe=[IO.Path]::Combine($folder,$name);" +
                "if([IO.File]::Exists($exe)){Start-Process -FilePath $exe -WorkingDirectory $folder" +
                resumeArgument + " -Verb RunAs}\"";
            if (command.Length > MaxShortcutArguments)
                throw new InvalidOperationException("The Setup file name or USB identity is too long to save a resume shortcut.");
            return command;
        }

        private static bool IsVolumeId(string value)
        {
            if (string.IsNullOrWhiteSpace(value) || value.Length > MaxVolumeLength) return false;
            foreach (char c in value)
                if (c < ' ' || c > '~') return false;
            return true;
        }

        private static string GetLinkPath()
        {
            string folder = Environment.GetFolderPath(Environment.SpecialFolder.Startup);
            if (string.IsNullOrEmpty(folder) || !Directory.Exists(folder))
                throw new InvalidOperationException("Windows could not find the current user's Startup folder.");
            return Path.Combine(folder, LinkName);
        }

        private static void RequireOwnedShortcut(string path, IShellLinkW link, IPersistFile file, string powerShell)
        {
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidOperationException("The Startup shortcut is a redirected file.");
            file.Load(path, 0); // STGM_READ
            var target = new StringBuilder(1024);
            var description = new StringBuilder(1024);
            link.GetPath(target, target.Capacity, IntPtr.Zero, 0);
            link.GetDescription(description, description.Capacity);
            if (!string.Equals(description.ToString(), LinkDescription, StringComparison.Ordinal) ||
                !string.Equals(target.ToString(), powerShell, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The Startup shortcut already exists and does not belong to Setup.");
        }

        private static void WithShortcut(Action<IShellLinkW, IPersistFile> action)
        {
            var link = new ShellLink();
            try { action((IShellLinkW)link, (IPersistFile)link); }
            finally { Marshal.ReleaseComObject(link); }
        }

        [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
        private class ShellLink
        {
        }

        // The method order is the native IShellLinkW vtable order.
        [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
        private interface IShellLinkW
        {
            void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int capacity, IntPtr findData, uint flags);
            void GetIDList(out IntPtr idList);
            void SetIDList(IntPtr idList);
            void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder description, int capacity);
            void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string description);
            void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder directory, int capacity);
            void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string directory);
            void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder arguments, int capacity);
            void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string arguments);
            void GetHotkey(out ushort hotkey);
            void SetHotkey(ushort hotkey);
            void GetShowCmd(out int showCmd);
            void SetShowCmd(int showCmd);
            void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int capacity, out int iconIndex);
            void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int iconIndex);
            void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
            void Resolve(IntPtr window, uint flags);
            void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
        }

        // UAC can run Setup under a different administrator account. Its Startup
        // folder would be for that account, so fail before changing it.
        private static void RequireShellUser()
        {
            IntPtr window = GetShellWindow();
            uint pid;
            if (window != IntPtr.Zero && GetWindowThreadProcessId(window, out pid) != 0)
            {
                IntPtr process = OpenProcess(0x1000, false, pid); // PROCESS_QUERY_LIMITED_INFORMATION
                if (process != IntPtr.Zero)
                {
                    try
                    {
                        IntPtr token;
                        if (OpenProcessToken(process, 0x0008, out token)) // TOKEN_QUERY
                        {
                            try
                            {
                                using (var shell = new WindowsIdentity(token))
                                using (var current = WindowsIdentity.GetCurrent())
                                    if (shell.User != null && shell.User.Equals(current.User)) return;
                            }
                            finally { CloseHandle(token); }
                        }
                    }
                    finally { CloseHandle(process); }
                }
            }
            throw new InvalidOperationException("Reopening at sign-in requires Setup to be elevated under the signed-in Windows account.");
        }

        [DllImport("user32.dll")]
        private static extern IntPtr GetShellWindow();

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

        [DllImport("kernel32.dll")]
        private static extern IntPtr OpenProcess(uint access, bool inheritHandle, uint processId);

        [DllImport("advapi32.dll")]
        private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);
    }
}
