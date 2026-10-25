# Builds every target the way this machine needs it.
#
#   .\tools\Build.ps1            # build
#   .\tools\Build.ps1 -Clean     # drop build/ and .xmake/ first (after a toolchain or SDK change)
#
# Why each setting:
# - Windows SDK 10.0.22621.0: 10.0.26100.0 breaks the build (docs/CAMPAIGN.md); both are installed.
# - XMAKE_GLOBALDIR on F: keeps the package cache (protobuf, abseil, openssl...) off C:.
# - npm_config_node_linker=hoisted: F: is exFAT, which has no symlinks, and pnpm's default
#   layout is made of them (ERR_PNPM_EISDIR in EmoteSystem/Admin).
# - -j 4: more parallel jobs have run out of memory on the precompiled header (C3859).
[CmdletBinding()]
param([switch]$Clean)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

$env:XMAKE_GLOBALDIR = 'F:\xmake-global'
$env:npm_config_node_linker = 'hoisted'
$env:PATH = "C:\Program Files\xmake;" + (npm prefix -g) + ";" + $env:PATH

Push-Location $repo
try
{
    if ($Clean)
    {
        foreach ($dir in 'build', '.xmake')
        {
            if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
        }
    }

    xmake f -y -m release --vs=2022 --vs_sdkver=10.0.22621.0
    if ($LASTEXITCODE -ne 0) { throw "xmake configure failed ($LASTEXITCODE)" }

    xmake -y -j 4
    if ($LASTEXITCODE -ne 0) { throw "xmake build failed ($LASTEXITCODE)" }

    Write-Host "Built: $repo\build\windows\x64\release" -ForegroundColor Green
}
finally
{
    Pop-Location
}
