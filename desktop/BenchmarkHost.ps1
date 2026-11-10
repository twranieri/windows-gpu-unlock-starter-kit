# SPDX-License-Identifier: GPL-2.0-only
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^WindowsGpuUnlock-Bench-[a-f0-9]{32}$')]
    [string]$PipeName
)

$ErrorActionPreference = 'Stop'
# Refuse before connecting if Windows or a compatibility setting elevated this host.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try {
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Benchmarks must run without administrator privileges.'
    }
} finally { $identity.Dispose() }

$pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $PipeName, [IO.Pipes.PipeDirection]::InOut,
    [IO.Pipes.PipeOptions]::None, [Security.Principal.TokenImpersonationLevel]::Anonymous)
try {
    $pipe.Connect(10000)
    $reader = [IO.BinaryReader]::new($pipe)
    $writer = [IO.BinaryWriter]::new($pipe)
    # Setup checks this worker's Windows token before it sends the benchmark command.
    $arguments = $reader.ReadString()
    $code = 1
    $stdout = ''
    $stderr = ''
    try {
        $system = [Environment]::SystemDirectory
        $exe = Join-Path $system 'WindowsPowerShell/v1.0/powershell.exe'
        $start = [Diagnostics.ProcessStartInfo]::new($exe, $arguments)
        $start.WorkingDirectory = Split-Path -Parent $PSScriptRoot
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = [Text.Encoding]::UTF8
        $start.StandardErrorEncoding = [Text.Encoding]::UTF8
        $process = [Diagnostics.Process]::Start($start)
        try {
            $process.StandardInput.Close()
            $streams = @(
                @{ Reader = $process.StandardOutput; Buffer = [char[]]::new(4096); Text = [Text.StringBuilder]::new(); Truncated = $false }
                @{ Reader = $process.StandardError; Buffer = [char[]]::new(4096); Text = [Text.StringBuilder]::new(); Truncated = $false }
            )
            # Drain both channels concurrently, including anything beyond the capture limit.
            foreach ($stream in $streams) {
                $stream.Pending = $stream.Reader.ReadAsync($stream.Buffer, 0, $stream.Buffer.Length)
            }
            while ($null -ne $streams[0].Pending -or $null -ne $streams[1].Pending) {
                $pending = @($streams | Where-Object { $null -ne $_.Pending })
                $next = [Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]@($pending | ForEach-Object { $_.Pending }))
                $stream = $pending[$next]
                $count = $stream.Pending.GetAwaiter().GetResult()
                if (!$count) { $stream.Pending = $null; continue }
                $keep = [Math]::Min($count, 1MB - $stream.Text.Length)
                [void]$stream.Text.Append($stream.Buffer, 0, $keep)
                if ($keep -lt $count) { $stream.Truncated = $true }
                $stream.Pending = $stream.Reader.ReadAsync($stream.Buffer, 0, $stream.Buffer.Length)
            }
            foreach ($stream in $streams) {
                if ($stream.Truncated) { [void]$stream.Text.AppendLine().Append('[Additional output omitted]') }
            }
            $process.WaitForExit()
            $code = $process.ExitCode
            $stdout = $streams[0].Text.ToString()
            $stderr = $streams[1].Text.ToString()
        } finally { $process.Dispose() }
    } catch {
        $cause = $_.Exception.GetBaseException()
        $prefix = if ($cause -is [ComponentModel.Win32Exception]) { "Win32 $($cause.NativeErrorCode): " } else { '' }
        $stderr = "Could not run Windows PowerShell for the benchmark. $prefix$($cause.Message)"
    }
    $writer.Write([int]$code)
    $writer.Write([string]$stdout)
    $writer.Write([string]$stderr)
    $writer.Flush()
} finally { $pipe.Dispose() }
