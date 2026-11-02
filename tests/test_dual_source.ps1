# SPDX-License-Identifier: GPL-2.0-only
# Synthetic files and mocked Git only; no network, auth, build or device actions.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../experimental/dual-gpu/Get-Source.ps1')
$script:passed=0
function Assert-True($Value,[string]$Message){if(!$Value){throw $Message};$script:passed++}
function Assert-Refused([scriptblock]$Action,[string]$Message){$refused=$false;try{& $Action | Out-Null}catch{$refused=$true};Assert-True $refused $Message}
$script:UDTestRoot=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('dual-source-tests-'+[guid]::NewGuid().ToString('N'))))
$null=New-Item -ItemType Directory -Path $script:UDTestRoot
$script:caseId=0
$script:UDFileContents=@{'new/dual.c'='synthetic new source';'existing.c'='synthetic replacement source'}
function Write-UDText([string]$Path,[string]$Text) {
    $null=New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -Force
    [IO.File]::WriteAllBytes($Path,[Text.Encoding]::UTF8.GetBytes($Text))
}
function New-UDCase {
    $script:caseId++
    $folder=Join-Path $script:UDTestRoot ('case'+$script:caseId)
    $source=Join-Path $folder 'experimental'
    $parent=Join-Path $folder 'destination'
    $null=New-Item -ItemType Directory -Path $source,$parent
    $patch=Join-Path $source 'upstream.patch'
    Write-UDText $patch "synthetic reviewed patch; never passed to real Git`n"
    $files=@(foreach($path in @('existing.c','new/dual.c')) {
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($script:UDFileContents[$path])))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        [pscustomobject]@{Path=$path;Sha256=$hash}
    })
    $manifest=[pscustomobject]@{SourceUrl=$script:UDPublicUrl;SourceCommit=$script:UDBaseCommit;Patch='upstream.patch';
        PatchSha256=(Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash.ToLowerInvariant();Files=$files}
    Write-UDText (Join-Path $source 'source.json') ($manifest | ConvertTo-Json -Depth 8)
    $script:UDCalls=@();$script:UDMockHead=$script:UDBaseCommit;$script:UDMockPaths=@($files.Path)
    $script:UDMockUnknown='';$script:UDMockUnstaged=$false;$script:UDMockReverseFailure=$false
    [pscustomobject]@{Source=$source;Parent=$parent;Target=(Join-Path $parent 'Windows-GPU-UNLOCK-dual-dev');Manifest=$manifest}
}
function Save-UDManifest($Case){Write-UDText (Join-Path $Case.Source 'source.json') ($Case.Manifest | ConvertTo-Json -Depth 8)}
function Invoke-UDGit([string[]]$Arguments) {
    $script:UDCalls+=,@($Arguments)
    if($Arguments[0] -eq 'clone') {
        $target=$Arguments[-1]
        $null=New-Item -ItemType Directory -Path (Join-Path $target '.git')
        return ''
    }
    if($Arguments[0] -ne '-C'){throw 'Unexpected mocked Git invocation.'}
    $target=$Arguments[1];$verb=$Arguments[2]
    switch($verb) {
        'config' {if(($Arguments -join ' ') -notmatch 'config --local core.autocrlf false$'){throw 'Unexpected Git config mutation.'};return ''}
        'checkout' {return ''}
        'rev-parse' {return $script:UDMockHead}
        'status' {return ''}
        'diff' {
            if($Arguments -contains '--quiet'){if($script:UDMockUnstaged){throw 'Synthetic unstaged changes'};return ''}
            if($Arguments -notcontains '--cached' -or $Arguments -notcontains '-z'){throw 'Unexpected diff command.'}
            return (($script:UDMockPaths -join [char]0)+[char]0)
        }
        'ls-files' {return $script:UDMockUnknown}
        'apply' {
            if($Arguments -contains '--check') {
                if($Arguments -contains '--reverse' -and $script:UDMockReverseFailure){throw 'Synthetic reverse check failure'}
                return ''
            }
            if($Arguments -notcontains '--index'){throw 'Patch application must update the index.'}
            foreach($path in $script:UDFileContents.Keys){Write-UDText (Join-Path $target $path) $script:UDFileContents[$path]}
            return ''
        }
        default {throw ('Unexpected mocked Git verb: '+$verb)}
    }
}
function Count-UDCalls([string]$Verb,[switch]$MutationOnly) {
    $count=0
    foreach($call in $script:UDCalls){if($call -contains $Verb -and (!$MutationOnly -or $call -notcontains '--check')){$count++}}
    return $count
}
try {
    $case=New-UDCase
    $null=Invoke-UDGetSource -Destination $case.Parent -SourceRoot $case.Source
    Assert-True ($script:UDCalls.Count -eq 0 -and !(Test-Path -LiteralPath $case.Target)) 'Plan mode invoked Git or created a checkout.'
    $production=Join-Path $case.Parent 'Windows-GPU-UNLOCK'
    $null=New-Item -ItemType Directory -Path $production
    Write-UDText (Join-Path $production 'keep.txt') 'production sentinel'
    $null=Invoke-UDGetSource -Destination $case.Parent -SourceRoot $case.Source -Execute
    Assert-True ((Count-UDCalls clone) -eq 1 -and (Count-UDCalls checkout) -eq 1 -and (Count-UDCalls apply -MutationOnly) -eq 1) 'Execution did not clone/check out/apply exactly once.'
    Assert-True ((Count-UDCalls config) -eq 1) 'New checkout did not pin repository-local newline behavior.'
    $configIndex=-1;$checkoutIndex=-1
    for($index=0;$index -lt $script:UDCalls.Count;$index++) {
        if($script:UDCalls[$index] -contains 'config'){$configIndex=$index}
        if($script:UDCalls[$index] -contains 'checkout'){$checkoutIndex=$index}
    }
    Assert-True ($configIndex -ge 0 -and $configIndex -lt $checkoutIndex) 'autocrlf was configured after checkout.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $production 'keep.txt') -Raw) -ceq 'production sentinel') 'Production source was touched.'
    $script:UDCalls=@()
    $null=Invoke-UDGetSource -Destination $case.Parent -SourceRoot $case.Source -Execute
    Assert-True ((Count-UDCalls clone) -eq 0 -and (Count-UDCalls checkout) -eq 0 -and (Count-UDCalls config) -eq 0 -and (Count-UDCalls apply -MutationOnly) -eq 0) 'Matching existing checkout was modified.'

    foreach($failure in @('head','missing','changed','unknown','extra-diff','missing-diff','unstaged','reverse')) {
        $case=New-UDCase
        $null=Invoke-UDGetSource -Destination $case.Parent -SourceRoot $case.Source -Execute
        switch($failure) {
            'head' {$script:UDMockHead='0'*40}
            'missing' {Remove-Item -LiteralPath (Join-Path $case.Target 'existing.c')}
            'changed' {Write-UDText (Join-Path $case.Target 'existing.c') 'unreviewed edit'}
            'unknown' {$script:UDMockUnknown="ignored-build-output.bin$([char]0)"}
            'extra-diff' {$script:UDMockPaths+=@('unreviewed.c')}
            'missing-diff' {$script:UDMockPaths=@('existing.c')}
            'unstaged' {$script:UDMockUnstaged=$true}
            'reverse' {$script:UDMockReverseFailure=$true}
        }
        $script:UDCalls=@()
        Assert-Refused {Invoke-UDGetSource -Destination $case.Parent -SourceRoot $case.Source -Execute} ('Unsafe existing checkout accepted: '+$failure)
        Assert-True ((Count-UDCalls clone) -eq 0 -and (Count-UDCalls checkout) -eq 0 -and (Count-UDCalls apply -MutationOnly) -eq 0) ('Unsafe existing checkout was repaired/overwritten: '+$failure)
    }

    foreach($failure in @('url','commit','patch-hash','traversal','absolute','git-path','duplicate','reserved')) {
        $case=New-UDCase
        switch($failure) {
            'url' {$case.Manifest.SourceUrl='https://example.invalid/unreviewed.git'}
            'commit' {$case.Manifest.SourceCommit='0'*40}
            'patch-hash' {Write-UDText (Join-Path $case.Source 'upstream.patch') 'tampered patch'}
            'traversal' {$case.Manifest.Files[0].Path='../outside.c'}
            'absolute' {$case.Manifest.Files[0].Path='C:/outside.c'}
            'git-path' {$case.Manifest.Files[0].Path='.git/config'}
            'duplicate' {$case.Manifest.Files[1].Path='EXISTING.C'}
            'reserved' {$case.Manifest.Files[0].Path='NUL.c'}
        }
        Save-UDManifest $case
        Assert-Refused {Invoke-UDGetSource -Destination $case.Parent -SourceRoot $case.Source -Execute} ('Unsafe manifest accepted: '+$failure)
        Assert-True ($script:UDCalls.Count -eq 0 -and !(Test-Path -LiteralPath $case.Target)) ('Unsafe manifest caused Git/file mutation: '+$failure)
    }

    $case=New-UDCase
    $null=New-Item -ItemType Directory -Path $case.Target
    Write-UDText (Join-Path $case.Target 'sentinel.txt') 'unrelated directory'
    Assert-Refused {Invoke-UDGetSource -Destination $case.Parent -SourceRoot $case.Source -Execute} 'Existing unrelated directory accepted.'
    Assert-True ($script:UDCalls.Count -eq 0 -and (Get-Content -LiteralPath (Join-Path $case.Target 'sentinel.txt') -Raw) -ceq 'unrelated directory') 'Existing unrelated directory was touched.'
    $case=New-UDCase
    $production=Join-Path $case.Parent 'custom-name-production'
    Write-UDText (Join-Path $production 'internal-boot/boot/handoff.c') 'fixture'
    Write-UDText (Join-Path $production 'research/profile/proven.json') '{}'
    Assert-Refused {Invoke-UDGetSource -Destination $production -SourceRoot $case.Source -Execute} 'Destination within renamed production source accepted.'
    Assert-True ($script:UDCalls.Count -eq 0) 'Production source guard invoked Git.'

    # Mock the filesystem metadata lookup to model reparse points without
    # creating junctions or requiring symlink privileges on the test machine.
    $case=New-UDCase
    foreach($blocked in @($case.Source,(Join-Path $case.Source 'upstream.patch'),$case.Parent)) {
        $script:UDReparseBlocked=[IO.Path]::GetFullPath($blocked)
        function Get-Item {
            [CmdletBinding()]param([string]$LiteralPath,[switch]$Force)
            if([IO.Path]::GetFullPath($LiteralPath) -eq $script:UDReparseBlocked){return [pscustomobject]@{Attributes=[IO.FileAttributes]::ReparsePoint}}
            Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force:$Force
        }
        try {Assert-Refused {Invoke-UDGetSource -Destination $case.Parent -SourceRoot $case.Source -Execute} 'Reparse path accepted.'}
        finally {Remove-Item Function:Get-Item}
        Assert-True ($script:UDCalls.Count -eq 0) 'Reparse path caused Git execution.'
    }
    Write-Output ('PASS dual-source mocked checks: '+$script:passed+'; no Git/network/device execution')
} finally {
    $resolved=[IO.Path]::GetFullPath($script:UDTestRoot)
    $tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(!$resolved.StartsWith($tempParent,[StringComparison]::OrdinalIgnoreCase) -or
       ![IO.Path]::GetFileName($resolved).StartsWith('dual-source-tests-')){throw 'Refusing cleanup outside the dedicated test directory.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
