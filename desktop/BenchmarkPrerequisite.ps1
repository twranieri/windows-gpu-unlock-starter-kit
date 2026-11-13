# SPDX-License-Identifier: GPL-2.0-only
#Requires -Version 5.1

# Exact x64 package reached from Microsoft's https://aka.ms/vc14/vc_redist.x64.exe.
$script:RtxBenchmarkRedistVersion = [version]'14.51.36247.0'
$script:RtxBenchmarkRedistBytes = 18731856
$script:RtxBenchmarkRedistHash = '843068991DAAA1F73AD9F6239BCE4D0F6A07A51F18C37EA2A867E9BECA71295C'
$script:RtxBenchmarkRedistUrl = 'https://download.visualstudio.microsoft.com/download/pr/ebdab8e5-1d7b-4d9f-a11b-cbb1720c3b12/843068991DAAA1F73AD9F6239BCE4D0F6A07A51F18C37EA2A867E9BECA71295C/VC_redist.x64.exe'
$script:RtxBenchmarkRedistSigner = '1D77A9B9E8FE2075D9AD15123257FB90DB0DA4A1'

function Test-RtxBenchmarkPrerequisite {
    foreach ($name in @('msvcp140.dll','vcruntime140_threads.dll')) {
        $file = Get-Item -LiteralPath (Join-Path ([Environment]::SystemDirectory) $name) -Force -ErrorAction SilentlyContinue
        if (!$file -or $file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
        $info = $file.VersionInfo
        $version = [version]::new($info.FileMajorPart,$info.FileMinorPart,$info.FileBuildPart,$info.FilePrivatePart)
        if ($version -lt $script:RtxBenchmarkRedistVersion) { return $false }
    }
    return $true
}

function New-RtxBenchmarkPrerequisiteStage {
    $windows = Split-Path -Parent ([Environment]::SystemDirectory)
    $temp = Join-Path $windows 'Temp'
    foreach ($path in @($windows,$temp)) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Benchmark setup requires an ordinary Windows temporary directory.'
        }
    }
    $stage = Join-Path $temp ('rtx-vcredist-'+[guid]::NewGuid().ToString('N'))
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    # Set the owner as well as the DACL. The same user's non-elevated token must not be able to change the DACL.
    $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)')
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        $null = [IO.Directory]::CreateDirectory($stage,$acl)
    } else {
        [IO.FileSystemAclExtensions]::CreateDirectory([IO.DirectoryInfo]::new($stage),$acl)
    }
    return $stage
}

function Remove-RtxBenchmarkPrerequisiteStage([string]$Stage) {
    $temp = Join-Path (Split-Path -Parent ([Environment]::SystemDirectory)) 'Temp'
    $path = [IO.Path]::GetFullPath($Stage)
    if ((Split-Path -Parent $path) -ine $temp -or (Split-Path -Leaf $path) -cnotmatch '^rtx-vcredist-[0-9a-f]{32}$') { return }
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($item -and $item.PSIsContainer -and !($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        try { [IO.Directory]::Delete($path,$true) } catch { }
    }
}

function Save-RtxBenchmarkPrerequisiteInstaller([string]$Path) {
    $curl = Join-Path ([Environment]::SystemDirectory) 'curl.exe'
    if (!(Test-Path -LiteralPath $curl -PathType Leaf)) { throw 'Windows curl.exe is required to download the Microsoft benchmark prerequisite.' }
    $download = '--disable --fail --silent --show-error --proto =https --connect-timeout 15 --max-time 120 '+
        "--max-filesize $script:RtxBenchmarkRedistBytes --output VC_redist.x64.exe $script:RtxBenchmarkRedistUrl"
    $exit = Invoke-RtxBenchmarkPrerequisiteProcess $curl $download (Split-Path -Parent $Path) 125000
    if ($null -eq $exit -or $exit -ne 0) { throw 'The Microsoft Visual C++ download failed. Check your connection and retry benchmark setup.' }
}

function Assert-RtxBenchmarkPrerequisiteInstaller([string]$Path) {
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $file.Length -ne $script:RtxBenchmarkRedistBytes -or
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash -cne $script:RtxBenchmarkRedistHash) {
        throw 'The Microsoft Visual C++ installer failed its exact size or SHA-256 verification.'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    if ($signature.Status -ne 'Valid' -or $signature.SignatureType -ne 'Authenticode' -or
        $signature.SignerCertificate.Thumbprint -cne $script:RtxBenchmarkRedistSigner -or
        $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -cne 'Microsoft Corporation') {
        throw 'The Microsoft Visual C++ installer failed its Microsoft Authenticode verification.'
    }
}

function Invoke-RtxBenchmarkPrerequisiteProcess([string]$Executable,[string]$Arguments,[string]$Directory,[int]$Timeout) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.Arguments = $Arguments
    $start.WorkingDirectory = $Directory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.EnvironmentVariables['TEMP'] = $Directory
    $start.EnvironmentVariables['TMP'] = $Directory
    $system = [Environment]::SystemDirectory
    $start.EnvironmentVariables['PATH'] = $system+';'+(Split-Path -Parent $system)
    $process = [Diagnostics.Process]::Start($start)
    try {
        if (!$process.WaitForExit($Timeout)) { return $null }
        return $process.ExitCode
    } finally { $process.Dispose() }
}

function Invoke-RtxBenchmarkPrerequisiteInstaller([string]$Path) {
    Invoke-RtxBenchmarkPrerequisiteProcess $Path '/install /quiet /norestart' (Split-Path -Parent $Path) 300000
}

function Assert-RtxBenchmarkPrerequisiteAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Administrator permission is required to install the Microsoft Visual C++ benchmark prerequisite.'
        }
    } finally { $identity.Dispose() }
}

function Install-RtxBenchmarkPrerequisite {
    if ([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne [Runtime.InteropServices.Architecture]::X64) {
        throw 'The benchmark prerequisite requires 64-bit Windows PowerShell.'
    }
    if (Test-RtxBenchmarkPrerequisite) { return }
    Assert-RtxBenchmarkPrerequisiteAdmin
    $stage = New-RtxBenchmarkPrerequisiteStage
    $installer = Join-Path $stage 'VC_redist.x64.exe'
    $cleanup = $true
    try {
        Save-RtxBenchmarkPrerequisiteInstaller $installer
        Assert-RtxBenchmarkPrerequisiteInstaller $installer
        [Console]::Error.WriteLine('Installing the verified Microsoft Visual C++ x64 benchmark prerequisite.')
        $exit = Invoke-RtxBenchmarkPrerequisiteInstaller $installer
        if ($null -eq $exit) {
            # Windows Installer owns the transaction. Do not kill it or remove its source while it runs.
            $cleanup = $false
            throw 'The Microsoft Visual C++ installer is still running. Let it finish before retrying benchmark setup.'
        }
        if ($exit -in @(1641,3010,0x80070669,0x80070BC2)) {
            throw 'The Microsoft Visual C++ installer requires a Windows restart. Restart Windows and reopen Setup to finish benchmark setup.'
        }
        if ($exit -in @(1618,0x80070652)) {
            throw 'Another Windows installation is in progress. Let it finish before retrying benchmark setup.'
        }
        # A concurrent or newer Microsoft installation may already have supplied both libraries.
        if ($exit -notin @(0,1638,0x80070666)) {
            throw "Microsoft Visual C++ installation failed (exit $exit). Open Microsoft's x64 redistributable installer to repair it, then retry benchmark setup. https://aka.ms/vc14/vc_redist.x64.exe"
        }
        if (!(Test-RtxBenchmarkPrerequisite)) {
            throw 'Microsoft Visual C++ setup finished, but the required x64 libraries could not be verified. Repair the current x64 redistributable and retry benchmark setup. https://aka.ms/vc14/vc_redist.x64.exe'
        }
    } finally {
        if ($cleanup) { Remove-RtxBenchmarkPrerequisiteStage $stage }
    }
}
