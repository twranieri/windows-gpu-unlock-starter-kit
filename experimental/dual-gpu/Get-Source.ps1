# SPDX-License-Identifier: GPL-2.0-only
# Experimental source preparation only: no build, staging, USB or settings change.
[CmdletBinding()]
param([string]$Destination,[switch]$Execute)
$ErrorActionPreference='Stop'
$script:UDSourceRoot=$PSScriptRoot
$script:UDPublicUrl='https://github.com/jingx8885/Windows-GPU-UNLOCK.git'
$script:UDBaseCommit='e27d200aaaee8de67a12bce4ab48eba58c0c8551'

function Assert-UDOrdinaryPath([string]$Path,[ValidateSet('File','Directory','NewDirectory')][string]$Kind) {
    $full=[IO.Path]::GetFullPath($Path)
    $exists=Test-Path -LiteralPath $full
    if($Kind -eq 'NewDirectory') {
        if($exists){throw 'Experimental destination already exists; it will not be overwritten.'}
        if(!(Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($full)) -PathType Container)){throw 'Destination parent must already exist.'}
    } elseif(!$exists -or ($Kind -eq 'File' -and !(Test-Path -LiteralPath $full -PathType Leaf)) -or
             ($Kind -eq 'Directory' -and !(Test-Path -LiteralPath $full -PathType Container))) {
        throw "Expected an ordinary $Kind path."
    }
    $cursor=$full
    while($cursor) {
        if(Test-Path -LiteralPath $cursor) {
            $item=Get-Item -LiteralPath $cursor -Force
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){
                throw 'A file or folder is a reparse point. Use a regular local folder outside cloud sync, symbolic links, and junctions.'
            }
        }
        $parent=[IO.Path]::GetDirectoryName($cursor)
        if(!$parent -or $parent -eq $cursor){break}
        $cursor=$parent
    }
}

function Assert-UDRelativePath([string]$Path) {
    if(!$Path -or $Path.Length -gt 240 -or $Path -cnotmatch '^[A-Za-z0-9._/-]+$' -or $Path.StartsWith('/')) {
        throw 'Manifest paths must be bounded repository-relative paths.'
    }
    foreach($part in $Path.Split('/')) {
        if(!$part -or $part -in @('.','..') -or $part -ieq '.git' -or $part.EndsWith('.') -or
           $part -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {throw 'Unsafe manifest path component.'}
    }
}

function Get-UDManifest([string]$SourceRoot) {
    Assert-UDOrdinaryPath $SourceRoot Directory
    $manifestPath=Join-Path $SourceRoot 'source.json'
    Assert-UDOrdinaryPath $manifestPath File
    if((Get-Item -LiteralPath $manifestPath).Length -gt 1MB){throw 'Source manifest is too large.'}
    $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if($manifest.SourceUrl -cne $script:UDPublicUrl -or $manifest.SourceCommit -cne $script:UDBaseCommit -or
       $manifest.Patch -cne 'upstream.patch' -or $manifest.PatchSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Manifest does not name the reviewed public source, commit and patch.'
    }
    $files=@($manifest.Files)
    if(!$files.Count -or $files.Count -gt 1024){throw 'Manifest must list the changed/new source files.'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($file in $files) {
        Assert-UDRelativePath $file.Path
        if(!$seen.Add($file.Path) -or $file.Sha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'Duplicate file path or malformed source-file hash.'}
    }
    $patch=Join-Path $SourceRoot $manifest.Patch
    Assert-UDOrdinaryPath $patch File
    if((Get-Item -LiteralPath $patch).Length -gt 64MB -or
       (Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash.ToLowerInvariant() -cne $manifest.PatchSha256) {
        throw 'Reviewed patch SHA-256 mismatch.'
    }
    return $manifest
}

function Invoke-UDGit([string[]]$Arguments) {
    $git=Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
    # Public HTTPS only. Do not consult credential helpers, askpass or inherited
    # extra authentication headers, or modify persistent Git/global settings.
    $names=@('GIT_TERMINAL_PROMPT','GIT_ASKPASS','SSH_ASKPASS','GIT_OPTIONAL_LOCKS')
    $saved=@{}
    foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
    try {
        $env:GIT_TERMINAL_PROMPT='0';$env:GIT_ASKPASS='';$env:SSH_ASKPASS='';$env:GIT_OPTIONAL_LOCKS='0'
        $options=@('-c','credential.helper=','-c','core.askPass=','-c','http.extraHeader=',
                   '-c','http.https://github.com/.extraHeader=','-c','core.fsmonitor=false',
                   '-c','core.autocrlf=false','-c','core.eol=lf')
        $output=@(& $git.Source @options @Arguments)
        if($LASTEXITCODE -ne 0){throw 'Git source preparation/verification failed; existing or partial files were retained.'}
        return ($output -join "`n")
    } finally {
        foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$saved[$name],'Process')}
    }
}

function Assert-UDReviewedCheckout([string]$Target,$Manifest,[string]$Patch,[switch]$AllowWorkflowArtifacts) {
    Assert-UDOrdinaryPath $Target Directory
    Assert-UDOrdinaryPath (Join-Path $Target '.git') Directory
    $revision=[string](Invoke-UDGit -Arguments @('-C',$Target,'rev-parse','HEAD'))
    if($revision.Trim() -cne $Manifest.SourceCommit){throw 'Existing checkout has another HEAD; nothing will be overwritten.'}
    $expected=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($file in $Manifest.Files) {
        $path=Join-Path $Target $file.Path
        Assert-UDOrdinaryPath $path File
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.Sha256) {
            throw 'Existing source file is changed or does not match the reviewed manifest.'
        }
        $null=$expected.Add($file.Path)
    }
    $null=Invoke-UDGit -Arguments @('-C',$Target,'diff','--no-ext-diff','--no-textconv','--quiet','--')
    $raw=[string](Invoke-UDGit -Arguments @('-C',$Target,'diff','--no-ext-diff','--no-textconv','--cached','--name-only','-z','HEAD','--'))
    $paths=@($raw.Split([char]0) | Where-Object {$_ -ne ''})
    if($paths.Count -ne $expected.Count){throw 'Checkout diff does not match the reviewed file set.'}
    foreach($path in $paths){if(!$expected.Remove($path)){throw 'Checkout contains an unexpected or duplicate changed path.'}}
    if($expected.Count){throw 'Checkout is missing a reviewed change.'}
    $unknownArguments=@('-C',$Target,'ls-files','--others','-z')
    if($AllowWorkflowArtifacts){$unknownArguments+='--exclude-standard'}
    $unknownArguments+='--'
    $unknown=[string](Invoke-UDGit -Arguments $unknownArguments)
    if($unknown.Length){throw 'Checkout contains unknown files, including ignored files; nothing will be overwritten.'}
    $null=Invoke-UDGit -Arguments @('-C',$Target,'apply','--reverse','--check','--index','--',$Patch)
}

function Get-UDReceiptData([string]$SourceRoot,$Manifest) {
    [ordered]@{Format=1;SourceUrl=$Manifest.SourceUrl;SourceCommit=$Manifest.SourceCommit;
        PatchSha256=$Manifest.PatchSha256;
        SourceManifestSha256=(Get-FileHash -LiteralPath (Join-Path $SourceRoot 'source.json') -Algorithm SHA256).Hash.ToLowerInvariant()}
}
function Assert-UDSourceReceipt([string]$Target,[string]$SourceRoot,$Manifest) {
    $path=Join-Path $Target '.git/windows-gpu-unlock-dual-source.json'
    Assert-UDOrdinaryPath $path File
    if((Get-Item -LiteralPath $path).Length -gt 64KB){throw 'Unexpected experimental source receipt.'}
    $receipt=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $expected=Get-UDReceiptData $SourceRoot $Manifest
    if(@($receipt.PSObject.Properties).Count -ne $expected.Count){throw 'Experimental source receipt fields differ.'}
    foreach($key in $expected.Keys){if($receipt.$key -cne $expected[$key]){throw 'Experimental source receipt does not match this reviewed source manifest.'}}
}
function Write-UDSourceReceipt([string]$Target,[string]$SourceRoot,$Manifest) {
    $path=Join-Path $Target '.git/windows-gpu-unlock-dual-source.json'
    if(Test-Path -LiteralPath $path){Assert-UDSourceReceipt $Target $SourceRoot $Manifest;return}
    $data=(Get-UDReceiptData $SourceRoot $Manifest | ConvertTo-Json -Depth 4)+"`n"
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$bytes=[Text.Encoding]::UTF8.GetBytes($data);$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
    Assert-UDSourceReceipt $Target $SourceRoot $Manifest
}

function Invoke-UDGetSource([string]$Destination,[switch]$Execute,[string]$SourceRoot=$script:UDSourceRoot) {
    $SourceRoot=[IO.Path]::GetFullPath($SourceRoot)
    $manifest=Get-UDManifest $SourceRoot
    if(!$Destination){$Destination=Join-Path $SourceRoot '../..'}
    $parent=[IO.Path]::GetFullPath($Destination)
    Assert-UDOrdinaryPath $parent Directory
    # The destination is a sibling source checkout, never a subfolder of the
    # production unlock/firmware checkout, regardless of its directory name.
    $cursor=$parent
    while($cursor) {
        if((Test-Path -LiteralPath (Join-Path $cursor 'internal-boot/boot/handoff.c')) -and
           (Test-Path -LiteralPath (Join-Path $cursor 'research/profile/proven.json'))) {
            throw 'Choose the parent beside the production checkout, not a folder within it.'
        }
        if([IO.Path]::GetFileName($cursor) -in @('Windows-GPU-UNLOCK','gpu-unlock-firmware-source')) {
            throw 'The production source directory cannot be the destination parent.'
        }
        $next=[IO.Path]::GetDirectoryName($cursor)
        if(!$next -or $next -eq $cursor){break};$cursor=$next
    }
    $target=Join-Path $parent 'Windows-GPU-UNLOCK-dual-dev'
    $patch=Join-Path $SourceRoot $manifest.Patch
    Write-Output ('EXPERIMENTAL source only: '+$manifest.SourceUrl+' at '+$manifest.SourceCommit)
    if(Test-Path -LiteralPath $target) {
        Assert-UDReviewedCheckout $target $manifest $patch
        $receipt=Join-Path $target '.git/windows-gpu-unlock-dual-source.json'
        if(!(Test-Path -LiteralPath $receipt)) {
            if(!$Execute){Write-Output 'PLAN: reviewed source matches; -Execute will create its missing local integrity receipt. Source bytes remain unchanged.';return}
            Write-UDSourceReceipt $target $SourceRoot $manifest
        } else {Assert-UDSourceReceipt $target $SourceRoot $manifest}
        Write-Output 'Reviewed experimental checkout already matches; left unchanged.'
        return
    }
    Assert-UDOrdinaryPath $target NewDirectory
    if(!$Execute) {
        Write-Output ('PLAN: clone into new '+$target+'; check out the pinned commit and apply the SHA-256-verified patch with --index.')
        Write-Output 'Plan only. Add -Execute to prepare experimental source. No build or device action is included.'
        return
    }
    $null=Invoke-UDGit -Arguments @('clone','--no-checkout','--filter=blob:none','--',$manifest.SourceUrl,$target)
    Assert-UDOrdinaryPath $target Directory
    Assert-UDOrdinaryPath (Join-Path $target '.git') Directory
    $null=Invoke-UDGit -Arguments @('-C',$target,'config','--local','core.autocrlf','false')
    $null=Invoke-UDGit -Arguments @('-C',$target,'checkout','--quiet','--detach',$manifest.SourceCommit)
    $revision=[string](Invoke-UDGit -Arguments @('-C',$target,'rev-parse','HEAD'))
    if($revision.Trim() -cne $manifest.SourceCommit){throw 'New checkout did not resolve to the pinned source commit.'}
    $dirty=[string](Invoke-UDGit -Arguments @('-C',$target,'status','--porcelain=v1','--untracked-files=all','--ignored=matching','--'))
    if($dirty.Length){throw 'New checkout is not clean; partial source was retained.'}
    # Recheck after download callbacks and before applying anything.
    $manifest=Get-UDManifest $SourceRoot
    $null=Invoke-UDGit -Arguments @('-C',$target,'apply','--check','--index','--',$patch)
    $null=Invoke-UDGit -Arguments @('-C',$target,'apply','--index','--',$patch)
    Assert-UDReviewedCheckout $target $manifest $patch
    Write-UDSourceReceipt $target $SourceRoot $manifest
    Write-Output 'Reviewed experimental source prepared. No build, staging, firmware execution or settings change was performed.'
}

if($MyInvocation.InvocationName -ne '.') {Invoke-UDGetSource -Destination $Destination -Execute:$Execute}
