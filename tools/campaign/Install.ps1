# Campaign co-op: copies a release build into the game's mod folder.
#
#   .\tools\campaign\Install.ps1                     # the Steam game, red4ext\plugins\zzzCyberpunkMP
#   .\tools\campaign\Install.ps1 -ModFolder <dir>    # anywhere else (a test copy)
#
# What goes where:
#   <mod>\CyberpunkMP.dll            the client
#   <mod>\assets\redscript\...       the scripts
#   <game>\CyberpunkCoopServer\...   the server the host's game starts (HOST CAMPAIGN): the
#                                    loader, native server, .NET plugins and web assets. Its
#                                    config\, campaigns\ and logs\ are left alone if present.
#                                    Not under red4ext\plugins: RED4ext would load its DLLs.
# The game and the hosted server must be closed (they lock the DLLs).

param(
    [string]$ModFolder = "C:\Program Files (x86)\Steam\steamapps\common\Cyberpunk 2077\red4ext\plugins\zzzCyberpunkMP",
    [string]$ServerFolder = "",
    [switch]$ServerOnly
)

$ErrorActionPreference = "Stop"
$repo = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$build = Join-Path $repo "build\windows\x64\release"

if (-not (Test-Path (Join-Path $build "Server.Loader.exe"))) {
    throw "No release build in $build - run xmake first"
}

New-Item -ItemType Directory -Force $ModFolder | Out-Null

if (-not $ServerOnly) {
    Copy-Item (Join-Path $build "CyberpunkMP.dll") $ModFolder -Force

    $scripts = Join-Path $repo "code\assets\redscript"
    Get-ChildItem $scripts -Recurse -Filter *.reds | ForEach-Object {
        $target = Join-Path (Join-Path $ModFolder "assets\redscript") $_.FullName.Substring($scripts.Length + 1)
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        Copy-Item $_.FullName $target -Force
    }

    # Tweaks (records, nameplates), archives (UI, the guest start) and input bindings.
    $assets = Join-Path $repo "code\assets"
    $copies = @(
        @{ From = Join-Path $assets "Tweaks"; Filter = "*.tweak"; To = "assets\Tweaks" },
        @{ From = Join-Path $assets "Archives\packed\archive\pc\mod"; Filter = "*.archive"; To = "assets\Archives" },
        @{ From = Join-Path $assets "Inputs"; Filter = "*.xml"; To = "assets\Inputs" }
    )
    foreach ($copy in $copies) {
        $target = Join-Path $ModFolder $copy.To
        New-Item -ItemType Directory -Force $target | Out-Null
        Get-ChildItem $copy.From -Filter $copy.Filter -File | ForEach-Object { Copy-Item $_.FullName $target -Force }
    }
}

# The server: everything the release folder holds for it, without build leftovers, the
# client, or this machine's own server state.
$server = $ServerFolder
if ($server -eq "") {
    # <game>\red4ext\plugins\<mod> -> <game>\CyberpunkCoopServer
    $server = Join-Path (Split-Path (Split-Path (Split-Path $ModFolder))) "CyberpunkCoopServer"
}
New-Item -ItemType Directory -Force $server | Out-Null
$skipNames = @("CyberpunkMP.dll", "NetPack.exe")
$skipExtensions = @(".pdb", ".lib", ".exp")
$skipFolders = @("config", "campaigns", "logs")

Get-ChildItem $build -Recurse -File | ForEach-Object {
    $relative = $_.FullName.Substring($build.Length + 1)
    $top = $relative.Split([IO.Path]::DirectorySeparatorChar)[0]
    if ($skipNames -contains $_.Name -or $skipExtensions -contains $_.Extension -or $skipFolders -contains $top -or $_.Name.StartsWith("compile.")) {
        return
    }
    $target = Join-Path $server $relative
    New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
    Copy-Item $_.FullName $target -Force
}

Write-Host "Installed to $ModFolder, server to $server"
