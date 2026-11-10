# SPDX-License-Identifier: GPL-2.0-only
#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Output)

$ErrorActionPreference='Stop'
$compiler=Join-Path $env:SystemRoot 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if(!(Test-Path -LiteralPath $compiler)){throw 'The x64 .NET Framework C# compiler is required.'}
$outputPath=[IO.Path]::GetFullPath($Output)
$manifest=Join-Path $PSScriptRoot 'Setup.manifest'
$source=Join-Path $PSScriptRoot 'Setup.cs'
$diagnostics=Join-Path $PSScriptRoot 'SetupDiagnostics.cs'
$resume=Join-Path $PSScriptRoot 'Resume.cs'
$userProcess=Join-Path $PSScriptRoot 'UserProcess.cs'
& $compiler /nologo /target:winexe /platform:x64 /optimize+ "/win32manifest:$manifest" "/out:$outputPath" `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll $source $resume $userProcess $diagnostics
if($LASTEXITCODE -ne 0){throw 'Desktop compilation failed.'}
Get-Item -LiteralPath $outputPath
