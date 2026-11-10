// SPDX-License-Identifier: GPL-2.0-only
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading;

namespace RtxSetup
{
    internal static class UserProcess
    {
        private const uint ProcessQueryLimitedInformation = 0x1000;
        private const uint TokenQuery = 0x0008;
        private const uint TokenDuplicate = 0x0002;
        private const int TokenSessionId = 12;
        private const int TokenElevation = 20;
        private const int StartupTimeoutSeconds = 20;
        private const string DesktopHelp = "Open the fully extracted Setup ZIP from the signed-in Windows desktop, using that same account, and retry Tensor benchmarks.";

        public static BackendResult RunPowerShell(string workingDirectory, string arguments)
        {
            using (var identity = WindowsIdentity.GetCurrent())
                return RunPowerShell(workingDirectory, arguments, !IsOrdinaryToken(identity));
        }

        internal static BackendResult RunPowerShell(string workingDirectory, string arguments, bool useExplorer)
        {
            var executable = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            var directory = Path.GetFullPath(workingDirectory);
            var host = Path.Combine(directory, "desktop", "BenchmarkHost.ps1");
            if (!File.Exists(executable) || !File.Exists(host))
                throw new InvalidOperationException("Windows PowerShell or the benchmark launcher is missing. " + DesktopHelp);
            if (string.IsNullOrWhiteSpace(arguments) || arguments.IndexOf('\0') >= 0 || arguments.Length > 16000)
                throw new ArgumentException("Invalid benchmark arguments.", "arguments");

            SecurityIdentifier user;
            using (var identity = WindowsIdentity.GetCurrent())
            {
                user = identity.User;
                if (user == null || (!useExplorer && !IsOrdinaryToken(identity)))
                    throw new InvalidOperationException("Setup could not start benchmarks as a standard Windows user. " + DesktopHelp);
            }
            int session;
            using (var current = Process.GetCurrentProcess())
                session = current.SessionId;
            if (useExplorer)
            {
                uint desktopPid;
                var desktop = GetShellWindow();
                if (desktop == IntPtr.Zero || GetWindowThreadProcessId(desktop, out desktopPid) == 0)
                    throw new InvalidOperationException("The Windows desktop is unavailable. " + DesktopHelp);
                RequireOrdinaryProcess(desktopPid, user, session);
            }

            // The desktop shell does not inherit this process's redirected handles.
            // Use a private pipe and check the connecting process before sending the command.
            string name = "WindowsGpuUnlock-Bench-" + Guid.NewGuid().ToString("N");
            var security = new PipeSecurity();
            security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new PipeAccessRule(user, PipeAccessRights.ReadWrite, AccessControlType.Allow));
            using (var pipe = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous, 0, 0, security))
            using (var direct = useExplorer ? null : new Process())
            {
                string hostArgs = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + host + "\" -PipeName " + name;
                var connect = pipe.BeginWaitForConnection(null, null);
                if (useExplorer)
                    LaunchOnDesktop(executable, hostArgs, directory);
                else
                {
                    direct.StartInfo = new ProcessStartInfo(executable, hostArgs)
                    {
                        WorkingDirectory = directory, UseShellExecute = false, CreateNoWindow = true
                    };
                    try { direct.Start(); }
                    catch (Win32Exception error) { throw LaunchError("Windows could not start the benchmark launcher.", error); }
                }

                using (var ready = connect.AsyncWaitHandle)
                {
                    if (!ready.WaitOne(TimeSpan.FromSeconds(StartupTimeoutSeconds)))
                        throw new InvalidOperationException("The standard-user benchmark launcher did not respond. " + DesktopHelp);
                    pipe.EndWaitForConnection(connect);
                }
                uint workerPid;
                if (!GetNamedPipeClientProcessId(pipe.SafePipeHandle, out workerPid))
                    throw LastError("Could not identify the benchmark process.");
                if (direct != null && workerPid != (uint)direct.Id)
                    throw new InvalidOperationException("An unexpected process connected to the benchmark launcher.");
                RequireOrdinaryProcess(workerPid, user, session);

                try
                {
                    // Readers and writers share the connection. Closing the pipe owns both.
                    var writer = new BinaryWriter(pipe);
                    var reader = new BinaryReader(pipe);
                    writer.Write(arguments);
                    writer.Flush();
                    return new BackendResult { ExitCode = reader.ReadInt32(), Output = reader.ReadString(), Error = reader.ReadString() };
                }
                catch (IOException error)
                {
                    throw new InvalidOperationException("The benchmark launcher closed before returning a result. " + DesktopHelp, error);
                }
            }
        }

        private static void LaunchOnDesktop(string executable, string arguments, string directory)
        {
            Exception failure = null;
            var thread = new Thread(delegate()
            {
                object shell = null, windows = null, desktop = null, view = null, application = null;
                try
                {
                    shell = Activator.CreateInstance(Type.GetTypeFromProgID("Shell.Application", true));
                    windows = ((dynamic)shell).Windows();
                    int hwnd;
                    desktop = ((dynamic)windows).FindWindowSW(0, 0, 8, out hwnd, 1); // SWC_DESKTOP, SWFO_NEEDDISPATCH
                    if (desktop == null) throw new InvalidOperationException("Windows Explorer could not find the signed-in desktop.");
                    view = ((dynamic)desktop).Document;
                    application = ((dynamic)view).Application;
                    ((dynamic)application).ShellExecute(executable, arguments, directory, "open", 0);
                }
                catch (Exception error) { failure = error; }
                finally
                {
                    foreach (var item in new[] { application, view, desktop, windows, shell })
                        if (item != null && Marshal.IsComObject(item)) Marshal.ReleaseComObject(item);
                }
            });
            thread.IsBackground = true;
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
            if (!thread.Join(TimeSpan.FromSeconds(StartupTimeoutSeconds)))
                throw new InvalidOperationException("Windows Explorer did not respond to the benchmark launch request. " + DesktopHelp);
            if (failure != null)
                throw new InvalidOperationException("Windows Explorer could not start the benchmark launcher (0x" +
                    failure.HResult.ToString("X8") + "). " + DesktopHelp, failure);
        }

        private static void RequireOrdinaryProcess(uint pid, SecurityIdentifier user, int session)
        {
            IntPtr process = OpenProcess(ProcessQueryLimitedInformation, false, pid);
            if (process == IntPtr.Zero) throw LastError("Could not open the benchmark desktop or worker process.");
            try
            {
                IntPtr token;
                if (!OpenProcessToken(process, TokenQuery | TokenDuplicate, out token))
                    throw LastError("Could not open the benchmark process token.");
                try
                {
                    using (var identity = new WindowsIdentity(token))
                    {
                        if (!user.Equals(identity.User) || ReadTokenInt(token, TokenSessionId) != session)
                            throw new InvalidOperationException("The benchmark process belongs to a different account or session. " + DesktopHelp);
                        if (!IsOrdinaryToken(identity))
                            throw new InvalidOperationException("The benchmark process has administrator privileges. " + DesktopHelp);
                    }
                }
                finally { CloseHandle(token); }
            }
            finally { CloseHandle(process); }
        }

        private static bool IsOrdinaryToken(WindowsIdentity identity)
        {
            return ReadTokenInt(identity.Token, TokenElevation) == 0 &&
                !new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
        }

        private static int ReadTokenInt(IntPtr token, int kind)
        {
            int value, returned;
            if (!GetTokenInformation(token, kind, out value, sizeof(int), out returned))
                throw LastError("Could not verify the benchmark process identity.");
            if (returned != sizeof(int))
                throw new InvalidOperationException("Windows returned an invalid benchmark process identity.");
            return value;
        }

        private static Exception LastError(string message)
        {
            return LaunchError(message, new Win32Exception(Marshal.GetLastWin32Error()));
        }

        private static Exception LaunchError(string message, Win32Exception error)
        {
            return new InvalidOperationException(message + " Win32 " + error.NativeErrorCode + ": " + error.Message, error);
        }

        [DllImport("user32.dll")]
        private static extern IntPtr GetShellWindow();

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetNamedPipeClientProcessId(Microsoft.Win32.SafeHandles.SafePipeHandle pipe, out uint processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inheritHandle, uint processId);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool GetTokenInformation(IntPtr token, int kind, out int data, int bytes, out int returned);

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);
    }
}
