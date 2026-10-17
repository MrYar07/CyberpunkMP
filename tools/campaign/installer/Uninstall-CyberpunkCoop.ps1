# Cyberpunk 2077 Co-op Campaign - uninstaller (installed into the game folder).
#
# Removes every file the installer copied (CyberpunkCoop_installed.txt) and puts back the
# files it had replaced (CyberpunkCoop_backup). Campaign saves of a hosted server are kept
# in CyberpunkCoop_saved_campaigns.

$ErrorActionPreference = "Stop"
$game = Split-Path -Parent $MyInvocation.MyCommand.Path
$listPath = Join-Path $game "CyberpunkCoop_installed.txt"
$backup = Join-Path $game "CyberpunkCoop_backup"

Write-Host ""
Write-Host "=== Cyberpunk 2077 Co-op Campaign - odinstalowanie ===" -ForegroundColor Cyan
Write-Host ""

if (Get-Process -Name "Cyberpunk2077", "Server.Loader" -ErrorAction SilentlyContinue) {
    Write-Host "Gra albo serwer co-op sa uruchomione. Zamknij je i sprobuj ponownie." -ForegroundColor Red
    Read-Host "Nacisnij Enter, aby zamknac"
    exit 1
}
if (-not (Test-Path $listPath)) {
    Write-Host "Nie znaleziono listy zainstalowanych plikow - nic do zrobienia." -ForegroundColor Yellow
    Read-Host "Nacisnij Enter, aby zamknac"
    exit 0
}

$answer = Read-Host "Usunac mod co-op i przywrocic poprzednie pliki? [T/n]"
if (-not ($answer -eq "" -or $answer -match "^[TtYy]")) { exit 0 }

# Campaign saves are the players' progress: kept aside, not deleted.
$campaigns = Join-Path $game "CyberpunkCoopServer\campaigns"
if (Test-Path $campaigns) {
    $kept = Join-Path $game "CyberpunkCoop_saved_campaigns"
    New-Item -ItemType Directory -Force $kept | Out-Null
    Copy-Item (Join-Path $campaigns "*") $kept -Recurse -Force
    Write-Host "Zapisy kampanii skopiowane do CyberpunkCoop_saved_campaigns."
}

$removed = 0
foreach ($relative in Get-Content $listPath) {
    if (-not $relative) { continue }
    $target = Join-Path $game $relative
    if (Test-Path $target) {
        Remove-Item $target -Force
        $removed++
    }
    $saved = Join-Path $backup $relative
    if (Test-Path $saved) {
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        Copy-Item $saved $target -Force
    }
}

# The mod's own folders go entirely, with what it wrote there (logs, server settings).
foreach ($folder in @("CyberpunkCoopServer", "red4ext\plugins\zzzCyberpunkMP")) {
    $path = Join-Path $game $folder
    if (Test-Path $path) { Remove-Item $path -Recurse -Force }
}
# Folders that held only the mod's files and are empty now; never the game folder itself.
foreach ($relative in Get-Content $listPath) {
    $folder = Split-Path (Join-Path $game $relative)
    while ($folder.Length -gt $game.Length -and (Test-Path $folder) -and -not (Get-ChildItem $folder -Force)) {
        Remove-Item $folder -Force
        $folder = Split-Path $folder
    }
}

Remove-Item $listPath -Force
if (Test-Path $backup) { Remove-Item $backup -Recurse -Force }
$shortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "Cyberpunk 2077 Co-op.lnk"
if (Test-Path $shortcut) { Remove-Item $shortcut -Force }

Write-Host ""
Write-Host "Usunieto $removed plikow, poprzednie wersje przywrocone." -ForegroundColor Green
Write-Host "(Ten skrypt i Odinstaluj-CyberpunkCoop.bat mozesz usunac recznie.)"
Read-Host "Nacisnij Enter, aby zamknac"
