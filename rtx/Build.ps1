# SPDX-License-Identifier: GPL-2.0-only
# Source preparation and local builds. This file never stages boot media.
$script:RtxSourceVerifier = Join-Path $PSScriptRoot '../experimental/dual-gpu/Get-Source.ps1'
$script:RtxAssetMakerSha256 = '26bf2275c839defac808cdd485f455e08ea64bdb9bda98577b8b98d1b8d0ede2'

function Get-RtxEngineManifest([string]$KitRoot) {
    . $script:RtxSourceVerifier
    $path=Join-Path $KitRoot 'rtx/engine.json'
    Assert-UDOrdinaryPath $path File
    if((Get-Item -LiteralPath $path).Length -gt 128KB){throw 'RTX source manifest is too large.'}
    $manifest=Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    if($manifest.SourceUrl -cne 'https://github.com/physicsdolphin/nv-uefi-unlocker.git' -or
       $manifest.SourceCommit -cne '37327d53dfae1f475638cdb8897b56d3edd4eb20' -or
       $manifest.PatchSha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'Invalid pinned RTX source manifest.'}
    $files=@($manifest.Files)
    if(!$files.Count -or $files.Count -gt 128){throw 'Invalid RTX patch file list.'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($file in $files) {
        Assert-UDRelativePath $file.Path
        if(!$seen.Add($file.Path) -or $file.Sha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'Invalid RTX patch file identity.'}
    }
    $patch=Join-Path $KitRoot 'rtx/engine.patch'
    Assert-UDOrdinaryPath $patch File
    if((Get-Item -LiteralPath $patch).Length -gt 2MB -or
       (Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash.ToLowerInvariant() -cne $manifest.PatchSha256){throw 'RTX source patch SHA-256 mismatch.'}
    return $manifest
}

function Assert-RtxEngineCheckout([string]$Engine,$Manifest,[string]$Patch) {
    Assert-UDReviewedCheckout $Engine $Manifest $Patch -AllowWorkflowArtifacts
    $index=Invoke-UDGit -Arguments @('-C',$Engine,'ls-files','-v','-z','--')
    if($index -cmatch '(^|\x00)[a-zS] '){throw 'RTX source index has hidden or skipped changes.'}
}

function Get-RtxBuildWorkPath([string]$KitRoot,[string]$WorkDirectory) {
    if(![IO.Path]::IsPathRooted($KitRoot) -or ![IO.Path]::IsPathRooted($WorkDirectory)){throw 'RTX build requires absolute kit and work paths.'}
    Assert-UDOrdinaryPath $KitRoot Directory
    $work=[IO.Path]::GetFullPath($WorkDirectory)
    $root=[IO.Path]::GetPathRoot($work)
    if($work.TrimEnd('\','/') -eq $root.TrimEnd('\','/') -or ([IO.DriveInfo]::new($root)).DriveType -ne 'Fixed') {
        throw 'RTX build requires a local work folder on a fixed drive.'
    }
    if($work.IndexOfAny([char[]]'[]*?') -ge 0){throw 'Choose a work path without wildcard characters.'}
    return $work
}

function Get-RtxBuildFamilies($Targets) {
    if($Targets.Count -lt 1 -or $Targets.Count -gt 2){throw 'RTX build requires one or two exact target profiles.'}
    $bdfs=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $families=@(foreach($target in $Targets) {
        if($target.Bdf -cnotmatch '\A[0-9a-f]{4}:[0-9a-f]{2}:[01][0-9a-f]\.[0-7]\z' -or
           !$bdfs.Add($target.Bdf)){throw 'Invalid or duplicate RTX target BDF.'}
        if($target.Device -cnotmatch '\A[0-9a-f]{4}\z' -or $target.Subsystem -cnotmatch '\A[0-9a-f]{8}\z' -or
           $target.Subsystem -cin @('00000000','ffffffff')){throw 'Invalid RTX target identity.'}
        switch -CaseSensitive ([string]$target.Family) {
            'ga102' {'30';break}
            'ad102' {'40';break}
            default {throw 'RTX build supports only Ampere and Ada targets.'}
        }
    })
    return ($families | Select-Object -Unique)
}

function Initialize-RtxBuildWork([string]$Work) {
    $ancestor=$work
    while(!(Test-Path -LiteralPath $ancestor)){$ancestor=[IO.Path]::GetDirectoryName($ancestor)}
    Assert-UDOrdinaryPath $ancestor Directory
    if($ancestor -cne $work){[void][IO.Directory]::CreateDirectory($work)}
    Assert-UDOrdinaryPath $work Directory
}

function New-RtxBuildScratch([string]$Work) {
    $scratch=Join-Path $work ('build-'+[guid]::NewGuid().ToString('N'))
    Assert-UDOrdinaryPath $scratch NewDirectory
    [void][IO.Directory]::CreateDirectory((Join-Path $scratch 'package/assets'))
    return $scratch
}

function Open-RtxFirmwareCacheLock([string]$Cache) {
    if(!(Test-Path -LiteralPath $Cache)){[void][IO.Directory]::CreateDirectory($Cache)}
    Assert-UDOrdinaryPath $Cache Directory
    $lockPath=Join-Path $Cache 'cache.lock'
    # Directory enumeration also sees a dangling reparse point at the lock name.
    foreach($entry in @(Get-ChildItem -LiteralPath $Cache -Force -Filter 'cache.lock')) {
        Assert-UDOrdinaryPath $entry.FullName File
    }
    try {
        return [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    } catch [IO.IOException] {
        throw 'Could not lock the firmware cache. Close any other preparation using this work folder and retry.'
    }
}

function Get-RtxFirmwareSources {
    return @{
        Kernel=@{
            Name='NVIDIA-kernel-module-source-610.43.03.tar.xz'
            Sha256='7e118923c7a23edc36114d63273a46e3e04e9af98695a42203e7ac2dfe9fc1dc'
        }
        Arch=@{
            Name='nvidia-utils-610.43.03-1-x86_64.pkg.tar.zst'
            Url='https://archive.archlinux.org/packages/n/nvidia-utils/nvidia-utils-610.43.03-1-x86_64.pkg.tar.zst'
            Sha256='c3367ff68632ac7daf6ca50ef7cbdd1cb5d09f7fe0b26125b312c73e52a34cf4'
        }
        Cachy=@{
            Name='nvidia-utils-610.43.03-1-x86_64_v3.pkg.tar.zst'
            Url='https://archive.cachyos.org/archive/cachyos-v3/nvidia-utils-610.43.03-1-x86_64_v3.pkg.tar.zst'
            Sha256='e17e7c92eeffa178b0fe1f40eb17a47095f8fc3ce4a77bf115cf5bd5a4df86e9'
        }
    }
}

function Find-RtxFirmwareInput($Source,[string]$Cache,[string]$Inputs) {
    $paths=@((Join-Path $Cache $Source.Name),(Join-Path $Cache ($Source.Name+'.part')))
    if($Inputs){$paths+=Join-Path $Inputs $Source.Name}
    foreach($path in $paths) {
        if(!(Test-Path -LiteralPath $path)){continue}
        Assert-UDOrdinaryPath $path File
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ieq $Source.Sha256){
            return [IO.Path]::GetFullPath($path)
        }
    }
}

function Initialize-RtxFirmwareInputs([string]$Cache,[string]$Inputs,$Sources) {
    $names=@($Sources.Values | ForEach-Object {$_.Name; $_.Name+'.part'})
    foreach($entry in @(Get-ChildItem -LiteralPath $Cache -Force | Where-Object Name -In $names)) {
        Assert-UDOrdinaryPath $entry.FullName File
    }
    if($Inputs){Assert-UDOrdinaryPath $Inputs Directory}
    # Prefer the verified Arch package, or reuse an exact local CachyOS archive.
    $utils=$Sources.Arch
    $utilsPath=Find-RtxFirmwareInput $utils $Cache $Inputs
    if(!$utilsPath) {
        $utilsPath=Find-RtxFirmwareInput $Sources.Cachy $Cache $Inputs
        if($utilsPath){$utils=$Sources.Cachy}
        elseif($Inputs){throw "No verified nvidia-utils archive found. Use $($Sources.Arch.Name) or the exact legacy $($Sources.Cachy.Name)."}
    }
    $kernelPath=Find-RtxFirmwareInput $Sources.Kernel $Cache $Inputs
    foreach($entry in @(@{Pin=$Sources.Kernel;Path=$kernelPath},@{Pin=$utils;Path=$utilsPath})) {
        $path=Join-Path $Cache $entry.Pin.Name
        $part="$path.part"
        if($entry.Path -ieq $path){continue}
        if(!$entry.Path) {
            if($Inputs){throw "Missing or incorrect firmware input: $($entry.Pin.Name)"}
            Write-Host "Downloading pinned firmware input: $($entry.Pin.Name)"
            continue
        }
        if($entry.Path -ine $part) {
            Write-Host "Importing verified firmware input: $($entry.Pin.Name)"
            # Only the fixed scratch filename inside the locked cache is replaced.
            [IO.File]::Delete($part)
            [IO.File]::Copy($entry.Path,$part,$false)
            if((Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash -ine $entry.Pin.Sha256){
                throw "Copied firmware input hash mismatch for $($entry.Pin.Name)."
            }
        }
        # A completed .part survives a stop between deleting an invalid file and publishing.
        [IO.File]::Delete($path)
        [IO.File]::Move($part,$path)
    }
    return $utils
}

function New-RtxArchAssetMaker([string]$Maker,[string]$Scratch,$Sources) {
    # The Arch archive contains the same two pinned GSP ELF members. Adapt only
    # the transport record in an exact copy of the upstream generator.
    if((Get-FileHash -LiteralPath $Maker -Algorithm SHA256).Hash -ine $script:RtxAssetMakerSha256){
        throw 'Cannot adapt an asset generator that differs from the pinned upstream script.'
    }
    $text=[IO.File]::ReadAllText($Maker)
    $old=$Sources.Cachy
    $new=$Sources.Arch
    $replacements=[ordered]@{}
    $replacements[('Name = "{0}"' -f $old.Name)]='Name = "{0}"' -f $new.Name
    $replacements[('Urls = @("{0}")' -f $old.Url)]='Urls = @("{0}")' -f $new.Url
    $replacements[('Sha256 = "{0}"' -f $old.Sha256.ToUpperInvariant())]='Sha256 = "{0}"' -f $new.Sha256.ToUpperInvariant()
    foreach($from in $replacements.Keys) {
        $start=$text.IndexOf($from,[StringComparison]::Ordinal)
        if($start -lt 0 -or $start -ne $text.LastIndexOf($from,[StringComparison]::Ordinal)){
            throw 'The pinned asset generator transport record could not be adapted.'
        }
        $text=$text.Replace($from,$replacements[$from])
    }
    $adapted=Join-Path $Scratch 'make-usbroot-arch.ps1'
    [IO.File]::WriteAllText($adapted,$text,[Text.UTF8Encoding]::new($false))
    return $adapted
}

function Export-RtxPackageAssets([string]$Work,[string]$Scratch,[string[]]$Families,[string]$Maker,[string]$AssetsExe,[string]$Inputs) {
    Assert-UDOrdinaryPath $AssetsExe File
    Assert-UDOrdinaryPath $Maker File
    $package=Join-Path $Scratch 'package'
    $assetOut=Join-Path $package 'assets'
    $cache=Join-Path $Work 'firmware-inputs'
    # Windows PowerShell 5.1 otherwise prompts before parsing web responses.
    $PSDefaultParameterValues=@{'Invoke-WebRequest:UseBasicParsing'=$true}
    if((Get-Command Invoke-WebRequest -CommandType Cmdlet).Parameters.ContainsKey('OperationTimeoutSeconds')) {
        $PSDefaultParameterValues['Invoke-WebRequest:ConnectionTimeoutSeconds']=60
        $PSDefaultParameterValues['Invoke-WebRequest:OperationTimeoutSeconds']=120
    } else {
        $PSDefaultParameterValues['Invoke-WebRequest:TimeoutSec']=900
    }
    $lock=Open-RtxFirmwareCacheLock $cache
    try {
        $sources=Get-RtxFirmwareSources
        $utils=Initialize-RtxFirmwareInputs $cache $Inputs $sources
        if($utils.Name -ceq $sources.Arch.Name){$Maker=New-RtxArchAssetMaker $Maker $Scratch $sources}
        foreach($family in $Families) {
            $out=Join-Path $Scratch ('family-'+$family)
            Assert-UDOrdinaryPath $out NewDirectory
            Write-Host "Generating RTX $family firmware assets from pinned inputs."
            & $Maker -Family $family -Out $out -Work $cache -AssetsExe $AssetsExe -BootEfi (Join-Path $package 'Unlock.EFI') 6>$null | Out-Host
            if(!$?){throw 'Pinned RTX asset generation failed.'}
            $suffix=if($family -eq '30'){'ga102'}else{'ad102'}
            foreach($name in @("booter_load_$suffix.bin","gsp_boot_desc_$suffix.bin","gsp_boot_$suffix.bin",
                               "fwimage_$suffix.bin","fwsignature_$suffix.bin","v67-$suffix-four-plm.bin",'scrubber_ad10x.bin')) {
                $file=Join-Path $out $name
                Assert-UDOrdinaryPath $file File
                if(!(Get-Item -LiteralPath $file).Length){throw "Empty generated RTX asset $name."}
                $dest=Join-Path $assetOut $name
                $hash=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
                if($name -ceq 'scrubber_ad10x.bin' -and $hash.ToLowerInvariant() -cne '1cfc78136a4dff4993b7e5a1a09345f6a67d0762555e5bd9660e406831379348') {
                    throw 'Shared RTX scrubber differs from its pinned SHA-256.'
                }
                if(!(Test-Path -LiteralPath $dest)){Copy-Item -LiteralPath $file -Destination $dest -ErrorAction Stop}
                if((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -cne $hash){throw "RTX asset verification failed for $name."}
            }
        }
    } finally {$lock.Dispose()}
}

function New-RtxPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$KitRoot,[Parameter(Mandatory)][string]$WorkDirectory,
          [Parameter(Mandatory)][object[]]$Targets,[string]$Cargo='cargo',[string]$Inputs)
    $ErrorActionPreference='Stop'
    . $script:RtxSourceVerifier
    $work=Get-RtxBuildWorkPath $KitRoot $WorkDirectory
    $families=@(Get-RtxBuildFamilies $Targets)
    $manifest=Get-RtxEngineManifest $KitRoot
    $manifestPath=Join-Path $KitRoot 'rtx/engine.json'
    $manifestHash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    $patch=Join-Path $KitRoot 'rtx/engine.patch'
    $cargoExe=(Get-Command -Name $Cargo -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $cargoVersion=@(& $cargoExe --version)
    if($LASTEXITCODE -ne 0 -or $cargoVersion.Count -ne 1 -or $cargoVersion[0] -cnotmatch '^cargo 1\.95\.0(?:\s|$)'){throw 'Use Cargo 1.95.0 with the Windows and x86_64-unknown-uefi targets installed.'}
    Initialize-RtxBuildWork $work
    $engine=Join-Path $work 'engine'
    if(!(Test-Path -LiteralPath $engine)) {
        Assert-UDOrdinaryPath $engine NewDirectory
        $null=Invoke-UDGit -Arguments @('clone','--no-tags','--no-checkout','--filter=blob:none','--',$manifest.SourceUrl,$engine)
        $null=Invoke-UDGit -Arguments @('-C',$engine,'config','--local','core.autocrlf','false')
        $null=Invoke-UDGit -Arguments @('-C',$engine,'checkout','--quiet','--detach',$manifest.SourceCommit)
        $null=Invoke-UDGit -Arguments @('-C',$engine,'apply','--check','--index','--',$patch)
        $null=Invoke-UDGit -Arguments @('-C',$engine,'apply','--index','--',$patch)
    }
    Assert-RtxEngineCheckout $engine $manifest $patch

    $scratch=New-RtxBuildScratch $work
    $package=Join-Path $scratch 'package'

    # MSVC's linker cannot open deeply nested Cargo build-script outputs.
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    Assert-UDOrdinaryPath $tempRoot Directory
    $targetDir=Join-Path $tempRoot ('rtx-cargo-'+[guid]::NewGuid().ToString('N').Substring(0,12))
    Assert-UDOrdinaryPath $targetDir NewDirectory
    [void][IO.Directory]::CreateDirectory($targetDir)
    try {
        Push-Location -LiteralPath $engine
        try {
            & $cargoExe build --locked --release --target-dir $targetDir --target x86_64-pc-windows-msvc -p assets | Out-Host
            if($LASTEXITCODE -ne 0){throw 'RTX asset-tool build failed.'}
            foreach($mode in @(@{Features='kit';File='Probe.EFI'},@{Features='tx,kit';File='Unlock.EFI'})) {
                & $cargoExe build --locked --release --target-dir $targetDir --target x86_64-unknown-uefi -p loader --no-default-features --features $mode.Features | Out-Host
                if($LASTEXITCODE -ne 0){throw "RTX $($mode.File) build failed."}
                $image=Join-Path $targetDir 'x86_64-unknown-uefi/release/loader.efi'
                Assert-UDOrdinaryPath $image File
                if(!(Get-Item -LiteralPath $image).Length){throw 'RTX EFI output is empty.'}
                Copy-Item -LiteralPath $image -Destination (Join-Path $package $mode.File) -ErrorAction Stop
            }
        } finally {Pop-Location}
        $probeHash=(Get-FileHash -LiteralPath (Join-Path $package 'Probe.EFI') -Algorithm SHA256).Hash
        $unlockHash=(Get-FileHash -LiteralPath (Join-Path $package 'Unlock.EFI') -Algorithm SHA256).Hash
        if($probeHash -ceq $unlockHash){throw 'RTX probe and unlock EFI outputs must be distinct.'}
        Assert-RtxEngineCheckout $engine $manifest $patch
        Export-RtxPackageAssets $work $scratch $families (Join-Path $engine 'release/make-usbroot.ps1') `
            (Join-Path $targetDir 'x86_64-pc-windows-msvc/release/assets.exe') $Inputs
    } finally {
        try {
            Assert-UDOrdinaryPath $targetDir Directory
            $resolved=(Get-Item -LiteralPath $targetDir -Force).FullName
            if((Split-Path -Parent $resolved).TrimEnd('\','/') -cne $tempRoot.TrimEnd('\','/') -or
               (Split-Path -Leaf $resolved) -cnotmatch '^rtx-cargo-[0-9a-f]{12}$'){throw 'Refusing cleanup of an unexpected Cargo path.'}
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
        } catch {Write-Warning ('Temporary Cargo files retained. '+$_.Exception.Message)}
    }
    $null=Get-RtxEngineManifest $KitRoot
    if((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -cne $manifestHash){throw 'RTX build source manifest changed during build.'}
    Assert-RtxEngineCheckout $engine $manifest $patch
    return $package
}

function Get-RtxPrebuiltBundle([string]$KitRoot) {
    . $script:RtxSourceVerifier
    $engine=Get-RtxEngineManifest $KitRoot
    $bundle=Join-Path $KitRoot 'rtx/prebuilt'
    $manifestPath=Join-Path $KitRoot 'rtx/prebuilt.json'
    Assert-UDOrdinaryPath $bundle Directory
    Assert-UDOrdinaryPath $manifestPath File
    if((Get-Item -LiteralPath $manifestPath).Length -gt 16KB){throw 'RTX prebuilt manifest is too large.'}
    $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    if($manifest.Format -ne 1 -or $manifest.SourceCommit -cne $engine.SourceCommit -or
       $manifest.PatchSha256 -cne $engine.PatchSha256){throw 'The prebuilt bundle belongs to a different RTX source release.'}

    $required=@('Probe.EFI','Unlock.EFI','assets.exe','release/make-usbroot.ps1')
    if(@($manifest.Files).Count -ne $required.Count){throw 'Invalid RTX prebuilt file list.'}
    $verified=@{}
    foreach($relative in $required) {
        $rows=@($manifest.Files | Where-Object Path -CEQ $relative)
        if($rows.Count -ne 1 -or $rows[0].Sha256 -cnotmatch '^[0-9a-f]{64}$' -or
           ($rows[0].Bytes -isnot [int] -and $rows[0].Bytes -isnot [long]) -or
           $rows[0].Bytes -le 0 -or $rows[0].Bytes -gt 32MB){throw "Invalid RTX prebuilt manifest entry: $relative"}
        $path=Join-Path $bundle $relative
        Assert-UDOrdinaryPath $path File
        if((Get-Item -LiteralPath $path).Length -ne $rows[0].Bytes -or
           (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $rows[0].Sha256){
            throw "RTX prebuilt file did not match its SHA-256 manifest: $relative"
        }
        $verified[$relative]=@{Path=$path;Sha256=$rows[0].Sha256}
    }
    if($verified['Probe.EFI'].Sha256 -ceq $verified['Unlock.EFI'].Sha256){throw 'The bundled probe and unlock EFIs must be distinct.'}
    if($verified['release/make-usbroot.ps1'].Sha256 -cne $script:RtxAssetMakerSha256) {
        throw 'The bundled asset generator does not match the pinned upstream script.'
    }
    return $verified
}

function New-RtxPrebuiltPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$KitRoot,[Parameter(Mandatory)][string]$WorkDirectory,
          [Parameter(Mandatory)][object[]]$Targets,[string]$Inputs)
    $ErrorActionPreference='Stop'
    . $script:RtxSourceVerifier
    $work=Get-RtxBuildWorkPath $KitRoot $WorkDirectory
    $families=@(Get-RtxBuildFamilies $Targets)
    $bundle=Get-RtxPrebuiltBundle $KitRoot
    Initialize-RtxBuildWork $work
    $scratch=New-RtxBuildScratch $work
    $package=Join-Path $scratch 'package'
    $tools=Join-Path $scratch 'tools'
    [void][IO.Directory]::CreateDirectory($tools)
    $destinations=[ordered]@{
        'Probe.EFI'=(Join-Path $package 'Probe.EFI')
        'Unlock.EFI'=(Join-Path $package 'Unlock.EFI')
        'assets.exe'=(Join-Path $tools 'assets.exe')
        'release/make-usbroot.ps1'=(Join-Path $tools 'make-usbroot.ps1')
    }
    foreach($relative in $destinations.Keys) {
        $file=$bundle[$relative]
        $destination=$destinations[$relative]
        [IO.File]::Copy($file.Path,$destination,$false)
        if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.Sha256) {
            throw "Copy of RTX prebuilt file did not match its SHA-256 manifest: $relative"
        }
    }
    Export-RtxPackageAssets $work $scratch $families $destinations['release/make-usbroot.ps1'] $destinations['assets.exe'] $Inputs
    return $package
}
