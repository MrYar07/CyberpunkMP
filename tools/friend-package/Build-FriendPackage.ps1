# Builds the co-op package for a player on patch 2.5 from the release build.
#
#   .\tools\friend-package\Build-FriendPackage.ps1 [-Out F:\Dev\releases] [-Deps F:\Dev\deps-2.5]
#
# Produces in -Out:
#   CyberpunkCoop-2.5-<date>-<commit>.zip          the package: unpack, run install.bat
#   CyberpunkCoop-2.5-<date>-<commit>-symbols\     PDBs and the exact DLLs that went into it, for
#                                                  tools\crash\Analyze-Crash.ps1. Not for players.
# Package layout:
#   install.bat, collect-logs.bat, ИНСТРУКЦИЯ.txt, ЧЕК-ЛИСТ.txt, LICENSES.txt, version.txt
#   data\Install-CyberpunkCoop.ps1, Uninstall-CyberpunkCoop.ps1, Collect-Logs.ps1
#   data\frameworks\*.zip    official framework releases (the set tools\Install-Frameworks.ps1 checks)
#   data\mod\...             game-relative: red4ext\plugins\zzzCyberpunkMP, CyberpunkCoopServer
param(
    [string]$Out = "F:\Dev\releases",
    [string]$Deps = "F:\Dev\deps-2.5"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$build = Join-Path $repo "build\windows\x64\release"

# zip, GitHub repository (for the licence)
$frameworks = @(
    @{ Zip = "red4ext-1.31.0.zip";            Name = "RED4ext 1.31.0";             Repo = "WopsS/RED4ext" },
    @{ Zip = "redscript-v0.5.32-windows.zip"; Name = "redscript 0.5.32";           Repo = "jac3km4/redscript" },
    @{ Zip = "ArchiveXL-1.28.0.zip";          Name = "ArchiveXL 1.28.0";           Repo = "psiberx/cp2077-archive-xl" },
    @{ Zip = "TweakXL-1.12.0.zip";            Name = "TweakXL 1.12.0";             Repo = "psiberx/cp2077-tweak-xl" },
    @{ Zip = "Codeware-1.21.1.zip";           Name = "Codeware 1.21.1";            Repo = "psiberx/cp2077-codeware" },
    @{ Zip = "input_loader_v0.2.6.zip";       Name = "Input Loader 0.2.6";         Repo = "jackhumbert/cyberpunk2077-input-loader" },
    @{ Zip = "cet_1_38_1.zip";                Name = "Cyber Engine Tweaks 1.38.1"; Repo = "maximegmd/CyberEngineTweaks" }
)

foreach ($f in $frameworks) {
    if (-not (Test-Path (Join-Path $Deps $f.Zip))) { throw "Missing $($f.Zip) in $Deps (tools\Install-Frameworks.ps1 in cp2077-coop downloads them)" }
}
if (-not (Test-Path (Join-Path $build "CyberpunkMP.dll"))) { throw "No release build in $build - run tools\Build.ps1" }
$gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
if (-not $gh) { $gh = Join-Path $env:ProgramFiles "GitHub CLI\gh.exe" }

$commit = (& git -C $repo rev-parse --short HEAD).Trim()
$dirty = [bool](& git -C $repo status --porcelain --untracked-files=no -- code vendor)
$name = "CyberpunkCoop-2.5-$(Get-Date -Format 'yyyyMMdd')-$commit$(if ($dirty) { '-dirty' })"

New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$stage = Join-Path $Out $name
$symbols = Join-Path $Out "$name-symbols"
foreach ($folder in $stage, $symbols) {
    if (Test-Path $folder) { Remove-Item $folder -Recurse -Force }
    New-Item -ItemType Directory -Force $folder | Out-Null
}
$data = Join-Path $stage "data"

# ---- scripts: UTF-8 with BOM, or Windows PowerShell 5.1 reads the Russian text as ANSI ----
$bom = New-Object Text.UTF8Encoding($true)
function Copy-Text($aFrom, $aTo) {
    New-Item -ItemType Directory -Force (Split-Path $aTo) | Out-Null
    $text = [IO.File]::ReadAllText($aFrom) -replace "(?<!\r)\n", "`r`n"
    [IO.File]::WriteAllText($aTo, $text, $bom)
}
Copy-Text (Join-Path $PSScriptRoot "Install-CyberpunkCoop.ps1") (Join-Path $data "Install-CyberpunkCoop.ps1")
Copy-Text (Join-Path $PSScriptRoot "Uninstall-CyberpunkCoop.ps1") (Join-Path $data "Uninstall-CyberpunkCoop.ps1")
Copy-Text (Join-Path $repo "tools\Collect-Logs.ps1") (Join-Path $data "Collect-Logs.ps1")
Copy-Text (Join-Path $PSScriptRoot "ИНСТРУКЦИЯ.txt") (Join-Path $stage "ИНСТРУКЦИЯ.txt")
Copy-Text (Join-Path $PSScriptRoot "ЧЕК-ЛИСТ.txt") (Join-Path $stage "ЧЕК-ЛИСТ.txt")

$ascii = New-Object Text.ASCIIEncoding
[IO.File]::WriteAllText((Join-Path $stage "install.bat"),
    ("@echo off`r`nrem Cyberpunk 2077 co-op - installer, see the instructions file next to it.`r`n" +
     "if not exist `"%~dp0data\Install-CyberpunkCoop.ps1`" (`r`n    echo Unpack the whole archive into a folder first, then run install.bat from that folder.`r`n    pause`r`n    exit /b 1`r`n)`r`n" +
     "powershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0data\Install-CyberpunkCoop.ps1`"`r`n" +
     "if errorlevel 1 pause`r`n"), $ascii)
[IO.File]::WriteAllText((Join-Path $stage "collect-logs.bat"),
    "@echo off`r`nrem Cyberpunk 2077 co-op - packs the logs into a zip on the Desktop.`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0data\Collect-Logs.ps1`"`r`npause`r`n", $ascii)

# ---- frameworks ----
$notices = @()
foreach ($f in $frameworks) {
    Copy-Item (Join-Path $Deps $f.Zip) (New-Item -ItemType Directory -Force (Join-Path $data "frameworks")) -Force
    # Under 'Stop', stderr from gh or a missing gh.exe would throw; the link is the fallback.
    $license = $null
    try { if (Test-Path -LiteralPath $gh) { $license = & $gh api "repos/$($f.Repo)/license" -q ".content" 2>$null } } catch { $license = $null }
    $text = if ($license) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($license -join ""))) } else { "See https://github.com/$($f.Repo)" }
    $notices += "==== $($f.Name) - https://github.com/$($f.Repo) ====`r`n$($text.Trim())`r`n"
}

# ---- the mod and its server ----
$mod = Join-Path $data "mod"
& (Join-Path $repo "tools\campaign\Install.ps1") -ModFolder (Join-Path $mod "red4ext\plugins\zzzCyberpunkMP") | Out-Null
foreach ($state in "config", "campaigns", "logs") {
    if (Test-Path (Join-Path $mod "CyberpunkCoopServer\$state")) { throw "Server state ($state) leaked into the package" }
}

# ---- licences and version ----
$cyberpunkMp = (Get-Content (Join-Path $repo "LICENSE.md") -Raw -Encoding UTF8).Trim()
$licenses = @(
    "Cyberpunk 2077 co-op package. Source: https://github.com/MrYar07/CyberpunkMP (branch coop-2.5), commit $commit.",
    "Based on CyberpunkMP by Tilted Phoques SRL, with fixes from Night City Online and the campaign-coop branch.",
    "The server's .NET libraries (EmbedIO, Swan, Newtonsoft.Json, Microsoft.Extensions.*) and the native",
    "libraries built into the mod are listed with their licences in the source repository.",
    "",
    "==== CyberpunkMP (Tilted Phoques SRL) - https://github.com/tiltedphoques/CyberpunkMP ====",
    $cyberpunkMp,
    ""
) + $notices
[IO.File]::WriteAllText((Join-Path $stage "LICENSES.txt"), ($licenses -join "`r`n"), $bom)

$dll = Join-Path $build "CyberpunkMP.dll"
$version = @(
    "Package:   $name",
    "Commit:    $commit$(if ($dirty) { ' (uncommitted changes in code/vendor)' })",
    "Built:     $((Get-Item $dll).LastWriteTime.ToString('yyyy-MM-dd HH:mm'))",
    "Game:      Cyberpunk 2077 2.5 (Steam) + Phantom Liberty",
    "CyberpunkMP.dll sha256 $((Get-FileHash $dll -Algorithm SHA256).Hash)",
    "Frameworks: $(($frameworks | ForEach-Object Name) -join ', ')"
)
[IO.File]::WriteAllText((Join-Path $stage "version.txt"), ($version -join "`r`n") + "`r`n", $bom)

# ---- symbols: the PDBs must match the shipped DLLs exactly, so keep both together ----
Get-ChildItem $build -File | Where-Object { $_.Extension -eq ".pdb" -and -not $_.Name.StartsWith("compile.") } | Copy-Item -Destination $symbols
foreach ($bin in "CyberpunkMP.dll", "Server.Native.dll", "Server.Loader.dll", "CyberpunkSdk.dll") {
    Copy-Item (Join-Path $build $bin) $symbols
}
Copy-Item (Join-Path $stage "version.txt") $symbols

# ---- zip ----
$zip = Join-Path $Out "$name.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
Remove-Item $stage -Recurse -Force

Write-Host "Built:"
Write-Host ("  {0} ({1:N1} MB)" -f $zip, ((Get-Item $zip).Length / 1MB))
Write-Host "  $symbols (keep: Analyze-Crash.ps1 needs these PDBs for crashes from this package)"
