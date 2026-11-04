# SPDX-License-Identifier: GPL-2.0-only
# Source preparation and local builds. This file never stages boot media.
$script:RtxSourceVerifier = Join-Path $PSScriptRoot '../experimental/dual-gpu/Get-Source.ps1'

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

function New-RtxPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$KitRoot,[Parameter(Mandatory)][string]$WorkDirectory,
          [Parameter(Mandatory)][object[]]$Targets,[string]$Cargo='cargo',[string]$Inputs)
    $ErrorActionPreference='Stop'
    . $script:RtxSourceVerifier
    if(![IO.Path]::IsPathRooted($KitRoot) -or ![IO.Path]::IsPathRooted($WorkDirectory)){throw 'RTX build requires absolute kit and work paths.'}
    Assert-UDOrdinaryPath $KitRoot Directory
    $work=[IO.Path]::GetFullPath($WorkDirectory)
    $root=[IO.Path]::GetPathRoot($work)
    if($work.TrimEnd('\','/') -eq $root.TrimEnd('\','/') -or ([IO.DriveInfo]::new($root)).DriveType -ne 'Fixed') {
        throw 'RTX build requires a local work folder on a fixed drive.'
    }
    if($work.IndexOfAny([char[]]'[]*?') -ge 0){throw 'Choose a work path without wildcard characters.'}
    if($Targets.Count -lt 1 -or $Targets.Count -gt 2){throw 'RTX build requires one or two exact target profiles.'}
    $bdfs=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $families=@(foreach($target in $Targets) {
        if($target.Bdf -cnotmatch '\A[0-9a-f]{4}:[0-9a-f]{2}:[01][0-9a-f]\.[0-7]\z' -or
           !$bdfs.Add($target.Bdf)){throw 'Invalid or duplicate RTX target BDF.'}
        if($target.Device -cnotmatch '\A[0-9a-f]{4}\z' -or $target.Subsystem -cnotmatch '\A[0-9a-f]{8}\z' -or
           $target.Subsystem -cin @('00000000','ffffffff') -or
           ($target.MemoryMiB -isnot [int] -and $target.MemoryMiB -isnot [long]) -or $target.MemoryMiB -le 0){throw 'Invalid RTX target identity or VRAM.'}
        switch -CaseSensitive ([string]$target.Family) {
            'ga102' {'30';break}
            'ad102' {'40';break}
            default {throw 'RTX build supports only Ampere and Ada targets.'}
        }
    })
    $manifest=Get-RtxEngineManifest $KitRoot
    $manifestPath=Join-Path $KitRoot 'rtx/engine.json'
    $manifestHash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    $patch=Join-Path $KitRoot 'rtx/engine.patch'
    $cargoExe=(Get-Command -Name $Cargo -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $cargoVersion=@(& $cargoExe --version)
    if($LASTEXITCODE -ne 0 -or $cargoVersion.Count -ne 1 -or $cargoVersion[0] -cnotmatch '^cargo 1\.95\.0(?:\s|$)'){throw 'Use Cargo 1.95.0 with the Windows and x86_64-unknown-uefi targets installed.'}
    $ancestor=$work
    while(!(Test-Path -LiteralPath $ancestor)){$ancestor=[IO.Path]::GetDirectoryName($ancestor)}
    Assert-UDOrdinaryPath $ancestor Directory
    if($ancestor -cne $work){[void][IO.Directory]::CreateDirectory($work)}
    Assert-UDOrdinaryPath $work Directory
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

    $scratch=Join-Path $work ('build-'+[guid]::NewGuid().ToString('N'))
    Assert-UDOrdinaryPath $scratch NewDirectory
    $package=Join-Path $scratch 'package'
    $assetOut=Join-Path $package 'assets'
    $cache=Join-Path $scratch 'inputs'
    [void][IO.Directory]::CreateDirectory($assetOut)
    [void][IO.Directory]::CreateDirectory($cache)
    if($Inputs) {
        Assert-UDOrdinaryPath $Inputs Directory
        $pins=[ordered]@{
            'NVIDIA-kernel-module-source-610.43.03.tar.xz'='7e118923c7a23edc36114d63273a46e3e04e9af98695a42203e7ac2dfe9fc1dc'
            'nvidia-utils-610.43.03-1-x86_64_v3.pkg.tar.zst'='e17e7c92eeffa178b0fe1f40eb17a47095f8fc3ce4a77bf115cf5bd5a4df86e9'
        }
        foreach($name in $pins.Keys) {
            $file=Join-Path $Inputs $name
            Assert-UDOrdinaryPath $file File
            if((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pins[$name]){throw "Pinned RTX input cache hash mismatch for $name."}
            Copy-Item -LiteralPath $file -Destination $cache -ErrorAction Stop
        }
    }

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
        $assetsExe=Join-Path $targetDir 'x86_64-pc-windows-msvc/release/assets.exe'
        Assert-UDOrdinaryPath $assetsExe File
        $maker=Join-Path $engine 'release/make-usbroot.ps1'
        Assert-UDOrdinaryPath $maker File
        foreach($family in ($families | Select-Object -Unique)) {
            $out=Join-Path $scratch ('family-'+$family)
            Assert-UDOrdinaryPath $out NewDirectory
            Write-Host "Generating RTX $family firmware assets in local scratch."
            & $maker -Family $family -Out $out -Work $cache -AssetsExe $assetsExe -BootEfi (Join-Path $package 'Unlock.EFI') 6>$null | Out-Host
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
