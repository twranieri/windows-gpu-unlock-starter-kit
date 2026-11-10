# SPDX-License-Identifier: GPL-2.0-only
#Requires -Version 5.1

$script:RtxRuntimeDesktop = $PSScriptRoot
$script:RtxRuntimeArchive = 'python.3.14.10.nupkg'
$script:RtxRuntimeArchiveBytes = 15589216
$script:RtxRuntimeArchiveHash = 'f54ba67c9951c3d773ea47d2bb095150c037c399f0423a968bcda22809241784'
$script:RtxRuntimeArchiveUrl = 'https://api.nuget.org/v3-flatcontainer/python/3.14.10/python.3.14.10.nupkg'

function Get-RtxRuntimeOrdinary([string]$Path,[bool]$Directory) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -ne $Directory -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The benchmark runtime requires ordinary local files and directories.'
    }
    return $item
}

function Get-RtxBenchmarkRuntimeRoot {
    $base = [Environment]::GetFolderPath('LocalApplicationData')
    if ($base -notmatch '^[A-Za-z]:[\\/]' -or ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($base))).DriveType -ne 'Fixed') {
        throw 'The benchmark runtime needs a local Windows profile on a fixed drive.'
    }
    return [IO.Path]::GetFullPath((Join-Path $base 'WGU-Bench/v1'))
}

function Get-RtxRuntimePaths([switch]$Create) {
    $lockFile = Join-Path $script:RtxRuntimeDesktop 'benchmark-requirements.txt'
    if ((Get-RtxRuntimeOrdinary $lockFile $false).Length -gt 16KB) { throw 'Invalid benchmark requirements file.' }
    $pins = @([IO.File]::ReadAllLines($lockFile) | Where-Object { $_ -and $_ -notlike '#*' })
    $wheelPin = '\A[a-zA-Z0-9-]+ @ https://(?:download-r2\.pytorch\.org/whl/cu126/|files\.pythonhosted\.org/packages/[0-9a-f]{2}/[0-9a-f]{2}/[0-9a-f]{60}/)[a-zA-Z0-9._%+-]+\.whl --hash=sha256:[0-9a-f]{64}\z'
    if ($pins.Count -ne 10 -or @($pins | Where-Object { $_ -cnotmatch $wheelPin }).Count) { throw 'Invalid official benchmark wheel lock.' }
    $lockHash = (Get-FileHash -LiteralPath $lockFile -Algorithm SHA256).Hash.ToLowerInvariant()
    $root = Get-RtxBenchmarkRuntimeRoot
    $base = [Environment]::GetFolderPath('LocalApplicationData')
    $ancestors = @()
    for ($folder = [IO.DirectoryInfo]::new($base); $folder; $folder = $folder.Parent) { $ancestors += $folder.FullName }
    [array]::Reverse($ancestors)
    foreach ($ancestor in $ancestors) { $null = Get-RtxRuntimeOrdinary $ancestor $true }
    $edition = 'py314-'+$script:RtxRuntimeArchiveHash.Substring(0,8)+'-'+$lockHash.Substring(0,16)
    foreach ($base in @((Split-Path -Parent $root),$root,(Join-Path $root $edition))) {
        if (!(Test-Path -LiteralPath $base)) {
            if (!$Create) { return $null }
            $null = [IO.Directory]::CreateDirectory($base)
        }
        $null = Get-RtxRuntimeOrdinary $base $true
    }
    return [pscustomobject]@{
        Root=$base; Requirements=$lockFile; LockHash=$lockHash
        Archive=Join-Path $base $script:RtxRuntimeArchive
        Tools=Join-Path $base 'tools'; Python=Join-Path $base 'tools/python.exe'
        Pending=Join-Path $base 'installing'; Installed=Join-Path $base 'installed.json'
        Ready=Join-Path $base 'ready.json'; Lock=Join-Path $base 'runtime.lock'
        Cache=Join-Path $base 'pip-cache'
    }
}

function Get-RtxRuntimeFileHash([string]$Path) {
    $null = Get-RtxRuntimeOrdinary $Path $false
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-RtxRuntimeInstalledIdentity($Paths) {
    foreach ($relative in @('tools','tools/Lib','tools/Lib/site-packages','tools/Lib/site-packages/torch','tools/Lib/site-packages/torch/lib')) {
        $null = Get-RtxRuntimeOrdinary (Join-Path $Paths.Root $relative) $true
    }
    $null = Get-RtxRuntimeOrdinary (Join-Path $Paths.Tools 'Lib/site-packages/torch/lib/torch_cuda.dll') $false
    return [ordered]@{
        Format=1; ArchiveSha256=$script:RtxRuntimeArchiveHash; RequirementsSha256=$Paths.LockHash
        PythonSha256=Get-RtxRuntimeFileHash $Paths.Python
        PythonDllSha256=Get-RtxRuntimeFileHash (Join-Path $Paths.Tools 'python314.dll')
    }
}

function Assert-RtxRuntimeReceipt($Paths,[string]$Receipt) {
    if ((Get-RtxRuntimeOrdinary $Receipt $false).Length -gt 4KB) { throw 'Invalid benchmark runtime receipt.' }
    $saved = [IO.File]::ReadAllText($Receipt) | ConvertFrom-Json -ErrorAction Stop
    $live = Get-RtxRuntimeInstalledIdentity $Paths
    foreach ($key in $live.Keys) {
        if ($saved.$key -cne $live[$key]) { throw 'The private benchmark runtime changed after installation.' }
    }
}

function Get-RtxManagedBenchmarkPython {
    try {
        $paths = Get-RtxRuntimePaths
        if ($paths -and (Test-Path -LiteralPath $paths.Ready)) {
            Assert-RtxRuntimeReceipt $paths $paths.Ready
            return $paths.Python
        }
    } catch { }
    return $null
}

function ConvertTo-RtxRuntimeArgument([string]$Value) {
    # Quote for the Windows process argument parser, including trailing backslashes.
    return '"'+($Value -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1')+'"'
}

function Invoke-RtxRuntimeProcess([string]$Exe,[string[]]$Arguments,[string]$Directory,[int]$TimeoutSeconds,[string]$Stage) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Exe
    $start.Arguments = ($Arguments | ForEach-Object { ConvertTo-RtxRuntimeArgument $_ }) -join ' '
    $start.WorkingDirectory = $Directory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($name in @($start.EnvironmentVariables.Keys)) {
        if ($name -match '^(PYTHON|PIP_)|^(VIRTUAL_ENV|CONDA_PREFIX|CONDA_DEFAULT_ENV)$') { $start.EnvironmentVariables.Remove($name) }
    }
    $start.EnvironmentVariables['PIP_CONFIG_FILE'] = 'nul'
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (!$process.Start()) { throw "$Stage could not start." }
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($TimeoutSeconds*1000)) {
            try { $process.Kill(); $null = $process.WaitForExit(5000) } catch { }
            throw "$Stage timed out. Retry to reuse verified downloads."
        }
        if (![Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout,$stderr),5000)) { throw "$Stage output did not close." }
        if ($process.ExitCode -ne 0) {
            $detail = $stderr.Result.Trim()
            if (!$detail) { $detail = $stdout.Result.Trim() }
            if ($detail.Length -gt 3000) { $detail = $detail.Substring($detail.Length-3000) }
            if ($detail) { [Console]::Error.WriteLine($detail) }
            throw "$Stage failed (exit $($process.ExitCode))."
        }
    } finally { $process.Dispose() }
}

function Assert-RtxRuntimeArchive([string]$Path) {
    if ((Get-RtxRuntimeOrdinary $Path $false).Length -ne $script:RtxRuntimeArchiveBytes -or
        (Get-RtxRuntimeFileHash $Path) -cne $script:RtxRuntimeArchiveHash) {
        throw 'The portable CPython archive failed its exact size or SHA-256 check.'
    }
}

function Get-RtxRuntimeArchive($Paths) {
    if (!(Test-Path -LiteralPath $Paths.Archive)) {
        [Console]::Error.WriteLine('Downloading the verified portable CPython runtime.')
        $curl = Join-Path ([Environment]::SystemDirectory) 'curl.exe'
        if (!(Test-Path -LiteralPath $curl -PathType Leaf)) { throw 'Windows curl.exe is required to download the portable runtime.' }
        $partial = $Paths.Archive+'.'+[guid]::NewGuid().ToString('N')+'.part'
        try {
            Invoke-RtxRuntimeProcess $curl @('--disable','--fail','--silent','--show-error','--location','--max-redirs','3',
                '--proto','=https','--proto-redir','=https','--connect-timeout','15','--max-time','180','--retry','2',
                '--retry-max-time','240','--max-filesize',[string]$script:RtxRuntimeArchiveBytes,'--output',$partial,
                $script:RtxRuntimeArchiveUrl) $Paths.Root 255 'Portable CPython download'
            Assert-RtxRuntimeArchive $partial
            [IO.File]::Move($partial,$Paths.Archive)
        } finally { if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force } }
    }
    Assert-RtxRuntimeArchive $Paths.Archive
}

function Assert-RtxRuntimeTree([string]$Root) {
    $null = Get-RtxRuntimeOrdinary $Root $true
    $directories = [Collections.Generic.Stack[string]]::new()
    $directories.Push($Root)
    while ($directories.Count) {
        foreach ($entry in Get-ChildItem -LiteralPath $directories.Pop() -Force -ErrorAction Stop) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The private benchmark folder contains a redirected entry.' }
            if ($entry.PSIsContainer) { $directories.Push($entry.FullName) }
        }
    }
}

function Expand-RtxRuntimeArchive($Paths) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Paths.Archive)
    try {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $root = $Paths.Tools.TrimEnd('\')+'\'
        [long]$total = 0
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            if (!$name.StartsWith('tools/',[StringComparison]::Ordinal)) { continue }
            $relative = $name.Substring(6).TrimEnd('/')
            if (!$relative) { continue }
            $directory = $name.EndsWith('/')
            $kind = ($entry.ExternalAttributes -shr 16) -band 0xf000
            $expectedKind = if ($directory) { 0x4000 } else { 0x8000 }
            if (!$seen.Add($relative) -or $seen.Count -gt 12000 -or
                ($kind -ne 0 -and $kind -ne $expectedKind) -or ($entry.ExternalAttributes -band 0x400) -or
                $relative -match '[\\:\x00-\x1f<>"|?*]|(^|/)(?:\.{1,2}|[^/]*[. ])(/|$)|(^|/)(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:[./]|$)|(^|/)/') {
                throw 'Unsafe entry in the pinned portable Python archive.'
            }
            $path = [IO.Path]::GetFullPath((Join-Path $Paths.Tools $relative))
            $total += $entry.Length
            if (!$path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or $total -gt 160MB) {
                throw 'The portable Python archive exceeds its extraction bounds.'
            }
            if ($directory) { $null = [IO.Directory]::CreateDirectory($path); continue }
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$path,$false)
        }
    } finally { $zip.Dispose() }
}

function Write-RtxRuntimeTextFile([string]$Path,[string]$Content) {
    $temporary = $Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temporary,$Content,[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary,$Path)
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Initialize-RtxBenchmarkRuntime {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateCount(1,2)][string[]]$GpuAddresses)

    $ErrorActionPreference = 'Stop'
    if (@($GpuAddresses | Select-Object -Unique).Count -ne $GpuAddresses.Count -or
        @($GpuAddresses | Where-Object { $_ -cnotmatch '\A[0-9a-f]{4}:[0-9a-f]{2}:[01][0-9a-f]\.0\z' }).Count) {
        throw 'One or two distinct canonical NVIDIA PCI addresses are required.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        if (([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Use the ordinary Windows desktop account to install the private benchmark runtime.'
        }
    } finally { $identity.Dispose() }
    $paths = Get-RtxRuntimePaths -Create
    if (Test-Path -LiteralPath $paths.Lock) { $null = Get-RtxRuntimeOrdinary $paths.Lock $false }
    try { $lock = [IO.File]::Open($paths.Lock,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch { throw 'The private benchmark runtime is busy or locked. Wait for Setup to finish and retry.' }
    try {
        if (Test-Path -LiteralPath $paths.Ready) { Assert-RtxRuntimeReceipt $paths $paths.Ready }
        elseif (Test-Path -LiteralPath $paths.Installed) { Assert-RtxRuntimeReceipt $paths $paths.Installed }
        else {
            if (Test-Path -LiteralPath $paths.Pending) {
                $marker = Get-RtxRuntimeOrdinary $paths.Pending $false
                if ($marker.Length -ne 64 -or [IO.File]::ReadAllText($paths.Pending) -cne $paths.LockHash) { throw 'Unrecognized benchmark installation marker.' }
            } else {
                if (Test-Path -LiteralPath $paths.Tools) { throw 'An unrecognized Python folder occupies the benchmark runtime path.' }
                Write-RtxRuntimeTextFile $paths.Pending $paths.LockHash
            }
            if (Test-Path -LiteralPath $paths.Tools) {
                $expected = [IO.Path]::GetFullPath((Join-Path $paths.Root 'tools'))
                if ([IO.Path]::GetFullPath($paths.Tools) -ine $expected) { throw 'Unsafe benchmark runtime retry path.' }
                Assert-RtxRuntimeTree $expected
                Remove-Item -LiteralPath $expected -Recurse -Force
            }
            $disk = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($paths.Root))
            if ($disk.AvailableFreeSpace -lt 10GB) { throw 'The private benchmark runtime needs 10 GiB of free disk space for download and installation.' }
            Get-RtxRuntimeArchive $paths
            $null = [IO.Directory]::CreateDirectory($paths.Tools)
            Expand-RtxRuntimeArchive $paths
            $null = Get-RtxRuntimeOrdinary $paths.Python $false
            $baseCheck = 'import os,struct,sys,pip; p=os.path.normcase(os.path.abspath(sys.argv[1])); assert sys.version_info[:3]==(3,14,10) and struct.calcsize("P")==8; assert os.path.normcase(sys.prefix)==p and os.path.normcase(pip.__file__).startswith(p+os.sep)'
            Invoke-RtxRuntimeProcess $paths.Python @('-I','-B','-c',$baseCheck,$paths.Tools) $paths.Root 60 'Portable Python verification'
            $null = [IO.Directory]::CreateDirectory($paths.Cache)
            Assert-RtxRuntimeTree $paths.Cache
            [Console]::Error.WriteLine('Installing the pinned CUDA PyTorch runtime. The first download can take several minutes.')
            $pip = @('-I','-B','-m','pip','--isolated','--disable-pip-version-check','--no-input','--cache-dir',$paths.Cache)
            Invoke-RtxRuntimeProcess $paths.Python ($pip+@('install','--no-index','--only-binary=:all:','--require-hashes',
                '--no-deps','--timeout','30','--retries','3','--progress-bar','off','-r',$paths.Requirements)) $paths.Root 3600 'Pinned CUDA wheel installation'
            Invoke-RtxRuntimeProcess $paths.Python ($pip+@('check')) $paths.Root 120 'Installed package validation'
            Write-RtxRuntimeTextFile $paths.Installed (Get-RtxRuntimeInstalledIdentity $paths | ConvertTo-Json -Compress)
            Remove-Item -LiteralPath $paths.Pending -Force
        }
        $benchmark = Join-Path (Split-Path -Parent $script:RtxRuntimeDesktop) 'benchmark-tensors.py'
        $null = Get-RtxRuntimeOrdinary $benchmark $false
        foreach ($bdf in $GpuAddresses) {
            Invoke-RtxRuntimeProcess $paths.Python @('-I','-B',$benchmark,'--check-runtime','--gpu',('0000'+$bdf)) $paths.Root 120 "CUDA runtime check for $bdf"
        }
        if (!(Test-Path -LiteralPath $paths.Ready)) {
            Write-RtxRuntimeTextFile $paths.Ready (Get-RtxRuntimeInstalledIdentity $paths | ConvertTo-Json -Compress)
        }
        return $paths.Python
    } finally { $lock.Dispose() }
}
