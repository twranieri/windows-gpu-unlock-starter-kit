// SPDX-License-Identifier: GPL-2.0-only
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading.Tasks;

namespace RtxSetup
{
    internal static class UserProcess
    {
        private const uint TokenQuery = 0x0008;
        private const uint TokenDuplicate = 0x0002;
        private const uint TokenAssignPrimary = 0x0001;
        private const int TokenSessionId = 12;
        private const int TokenElevation = 20;
        private const int MaxCapturedCharacters = 1024 * 1024;

        public static BackendResult RunPowerShell(string workingDirectory, string arguments)
        {
            var executable = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            var directory = Path.GetFullPath(workingDirectory);
            if (!File.Exists(executable) || !Directory.Exists(directory))
                throw new InvalidOperationException("Windows PowerShell or the extracted kit folder is missing.");
            if (arguments == null || arguments.IndexOf('\0') >= 0)
                throw new ArgumentException("Invalid benchmark arguments.", "arguments");
            var command = new StringBuilder("\"" + executable + "\" " + arguments);
            if (command.Length >= 1024)
                throw new InvalidOperationException("The benchmark command is too long. Extract Setup to a shorter path.");

            SecurityIdentifier user;
            bool alreadyOrdinary;
            using (var identity = WindowsIdentity.GetCurrent())
            {
                user = identity.User;
                alreadyOrdinary = IsOrdinaryToken(identity.Token, identity);
            }
            int session;
            using (var current = Process.GetCurrentProcess())
                session = current.SessionId;
            IntPtr token = GetDesktopToken(user, session);
            try
            {
                return Run(token, user, session, executable, directory, command, alreadyOrdinary);
            }
            finally { CloseHandle(token); }
        }

        private static IntPtr GetDesktopToken(SecurityIdentifier user, int session)
        {
            IntPtr window = GetShellWindow();
            uint pid;
            if (window == IntPtr.Zero || GetWindowThreadProcessId(window, out pid) == 0)
                throw new InvalidOperationException("The signed-in Windows desktop is unavailable. Open Setup from your desktop.");
            IntPtr shell = OpenProcess(0x1000, false, pid); // PROCESS_QUERY_LIMITED_INFORMATION
            if (shell == IntPtr.Zero) throw LastError("Could not open the desktop process.");
            try
            {
                IntPtr source;
                if (!OpenProcessToken(shell, TokenQuery | TokenDuplicate, out source))
                    throw LastError("Could not open the desktop user token.");
                try
                {
                    RequireOrdinaryToken(source, user, session);
                    IntPtr primary;
                    // SecurityImpersonation (2), TokenPrimary (1).
                    if (!DuplicateTokenEx(source, TokenAssignPrimary | TokenDuplicate | TokenQuery,
                        IntPtr.Zero, 2, 1, out primary))
                        throw LastError("Could not copy the desktop user token.");
                    return primary;
                }
                finally { CloseHandle(source); }
            }
            finally { CloseHandle(shell); }
        }

        private static void RequireOrdinaryToken(IntPtr token, SecurityIdentifier user, int session)
        {
            using (var identity = new WindowsIdentity(token))
            {
                if (user == null || !user.Equals(identity.User) || ReadTokenInt(token, TokenSessionId) != session)
                    throw new InvalidOperationException("Use Setup under the same account as the signed-in desktop to run benchmarks.");
                if (!IsOrdinaryToken(token, identity))
                    throw new InvalidOperationException("Setup could not verify a non-administrator desktop token for benchmarking.");
            }
        }

        private static bool IsOrdinaryToken(IntPtr token, WindowsIdentity identity)
        {
            return ReadTokenInt(token, TokenElevation) == 0 &&
                !new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
        }

        private static int ReadTokenInt(IntPtr token, int kind)
        {
            int value, returned;
            if (!GetTokenInformation(token, kind, out value, sizeof(int), out returned) || returned != sizeof(int))
                throw LastError("Could not verify the benchmark process identity.");
            return value;
        }

        private static BackendResult Run(IntPtr token, SecurityIdentifier user, int session, string executable,
                                         string directory, StringBuilder command, bool alreadyOrdinary)
        {
            using (var input = new AnonymousPipeServerStream(PipeDirection.Out, HandleInheritability.Inheritable))
            using (var output = new AnonymousPipeServerStream(PipeDirection.In, HandleInheritability.Inheritable))
            using (var error = new AnonymousPipeServerStream(PipeDirection.In, HandleInheritability.Inheritable))
            {
                var startup = new StartupInfo
                {
                    Size = Marshal.SizeOf(typeof(StartupInfo)),
                    Flags = 0x00000100, // STARTF_USESTDHANDLES
                    StdInput = input.ClientSafePipeHandle.DangerousGetHandle(),
                    StdOutput = output.ClientSafePipeHandle.DangerousGetHandle(),
                    StdError = error.ClientSafePipeHandle.DangerousGetHandle()
                };
                IntPtr environment;
                if (!CreateEnvironmentBlock(out environment, token, false))
                    throw LastError("Could not load the desktop user's environment.");

                ProcessInformation child;
                try
                {
                    // CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED
                    const uint flags = 0x08000404;
                    // Direct inheritance is safe only when this process already has
                    // the verified desktop account and an ordinary token.
                    bool started = alreadyOrdinary
                        ? CreateProcessW(executable, command, IntPtr.Zero, IntPtr.Zero, true, flags,
                            environment, directory, ref startup, out child)
                        : CreateProcessWithTokenW(token, 0, executable, command, flags,
                            environment, directory, ref startup, out child);
                    if (!started) throw LastError("Could not start the non-administrator benchmark.");
                }
                finally { DestroyEnvironmentBlock(environment); }

                bool resumed = false;
                try
                {
                    input.DisposeLocalCopyOfClientHandle();
                    output.DisposeLocalCopyOfClientHandle();
                    error.DisposeLocalCopyOfClientHandle();
                    input.Dispose();

                    // Check the new process itself while it still cannot execute code.
                    IntPtr childToken;
                    if (!OpenProcessToken(child.Process, TokenQuery | TokenDuplicate, out childToken))
                        throw LastError("Could not verify the new benchmark process token.");
                    try { RequireOrdinaryToken(childToken, user, session); }
                    finally { CloseHandle(childToken); }

                    if (ResumeThread(child.Thread) == uint.MaxValue)
                        throw LastError("Could not start the verified benchmark process.");
                    resumed = true;

                    var stdout = Task.Run(delegate { return ReadCaptured(output); });
                    var stderr = Task.Run(delegate { return ReadCaptured(error); });
                    if (WaitForSingleObject(child.Process, uint.MaxValue) != 0)
                        throw LastError("Could not wait for the benchmark process.");
                    uint exitCode;
                    if (!GetExitCodeProcess(child.Process, out exitCode))
                        throw LastError("Could not read the benchmark exit status.");
                    return new BackendResult { ExitCode = unchecked((int)exitCode), Output = stdout.Result, Error = stderr.Result };
                }
                finally
                {
                    if (!resumed) TerminateProcess(child.Process, 1);
                    CloseHandle(child.Thread);
                    CloseHandle(child.Process);
                }
            }
        }

        private static string ReadCaptured(Stream stream)
        {
            using (var reader = new StreamReader(stream, Encoding.UTF8, true))
            {
                var buffer = new char[4096];
                var captured = new StringBuilder();
                bool truncated = false;
                int count;
                while ((count = reader.Read(buffer, 0, buffer.Length)) > 0)
                {
                    int keep = Math.Min(count, MaxCapturedCharacters - captured.Length);
                    captured.Append(buffer, 0, keep);
                    if (keep < count) truncated = true;
                }
                if (truncated) captured.AppendLine().Append("[Additional output omitted]");
                return captured.ToString();
            }
        }

        private static Exception LastError(string message)
        {
            return new InvalidOperationException(message, new Win32Exception(Marshal.GetLastWin32Error()));
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfo
        {
            public int Size;
            public string Reserved, Desktop, Title;
            public int X, Y, XSize, YSize, XChars, YChars, FillAttribute, Flags;
            public short ShowWindow, ReservedSize;
            public IntPtr ReservedPointer, StdInput, StdOutput, StdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation
        {
            public IntPtr Process, Thread;
            public uint ProcessId, ThreadId;
        }

        [DllImport("user32.dll")]
        private static extern IntPtr GetShellWindow();

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inheritHandle, uint processId);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool DuplicateTokenEx(IntPtr existing, uint access, IntPtr attributes,
            int impersonationLevel, int tokenType, out IntPtr token);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool GetTokenInformation(IntPtr token, int kind, out int data, int bytes, out int returned);

        [DllImport("userenv.dll", SetLastError = true)]
        private static extern bool CreateEnvironmentBlock(out IntPtr environment, IntPtr token, bool inherit);

        [DllImport("userenv.dll")]
        private static extern bool DestroyEnvironmentBlock(IntPtr environment);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern bool CreateProcessWithTokenW(IntPtr token, uint logonFlags, string application,
            StringBuilder command, uint creationFlags, IntPtr environment, string directory,
            ref StartupInfo startup, out ProcessInformation process);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern bool CreateProcessW(string application, StringBuilder command,
            IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint creationFlags,
            IntPtr environment, string directory, ref StartupInfo startup, out ProcessInformation process);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr thread);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint timeout);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

        [DllImport("kernel32.dll")]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);
    }
}
