# Packs everything needed to diagnose a co-op session into one zip on the Desktop.
#
#   powershell -ExecutionPolicy Bypass -File Collect-Logs.ps1            # last 24 hours of crashes
#   powershell -ExecutionPolicy Bypass -File Collect-Logs.ps1 -Hours 4
#
# Collected: the mod's log, RED4ext and plugin logs, redscript and CET logs, the hosted
# server's logs and campaign files, and the game's own crash reports (with their memory dumps)
# from the last -Hours. Plus info.txt: game build, mod build, installed plugins and versions.
# Not collected: saves, settings, anything outside the game folder and the crash report folder.
# The logs do contain the Steam name and Windows user paths.
[CmdletBinding()]
param(
    [string]$GameDir = "",
    [int]$Hours = 24
)

$ErrorActionPreference = 'Stop'

function Find-Game {
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) { return $null }
    $libraries = @($steam.Replace('/', '\'))
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        foreach ($m in [regex]::Matches([IO.File]::ReadAllText($vdf, [Text.Encoding]::UTF8), '"path"\s+"([^"]+)"')) {
            $libraries += $m.Groups[1].Value.Replace('\\', '\')
        }
    }
    foreach ($lib in $libraries | Select-Object -Unique) {
        $dir = Join-Path $lib 'steamapps\common\Cyberpunk 2077'
        if (Test-Path (Join-Path $dir 'bin\x64\Cyberpunk2077.exe')) { return $dir }
    }
    return $null
}

if (-not $GameDir) { $GameDir = Find-Game }
if (-not $GameDir -or -not (Test-Path (Join-Path $GameDir 'bin\x64\Cyberpunk2077.exe'))) {
    throw 'Cyberpunk 2077 не найден. Укажите папку игры: -GameDir "<папка игры>".'
}
$GameDir = [IO.Path]::GetFullPath($GameDir).TrimEnd('\')

$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$stage = Join-Path $env:TEMP "cyberpunk-coop-logs-$stamp"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null

function Copy-Into($aFiles, $aTarget) {
    $dest = Join-Path $stage $aTarget
    New-Item -ItemType Directory -Force $dest | Out-Null
    foreach ($f in $aFiles) { if ($f -and (Test-Path $f)) { Copy-Item $f $dest -Force } }
}

function Latest($aPattern, $aCount = 1) {
    Get-ChildItem $aPattern -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending |
        Select-Object -First $aCount | ForEach-Object FullName
}

# Mod, loader and plugins
Copy-Into (Latest (Join-Path $GameDir 'red4ext\plugins\zzzCyberpunkMP\*.log') 3) 'mod'
Copy-Into (Latest (Join-Path $GameDir 'red4ext\logs\red4ext-*.log') 3) 'red4ext'
Copy-Into (Get-ChildItem (Join-Path $GameDir 'red4ext\logs') -File -Filter *.log -ErrorAction SilentlyContinue |
    Where-Object Name -notlike 'red4ext-*' | ForEach-Object FullName) 'red4ext'
foreach ($plugin in Get-ChildItem (Join-Path $GameDir 'red4ext\plugins') -Directory -ErrorAction SilentlyContinue) {
    if ($plugin.Name -eq 'zzzCyberpunkMP') { continue }
    Copy-Into (Latest (Join-Path $plugin.FullName '*.log') 2) "plugins\$($plugin.Name)"
}
Copy-Into (Latest (Join-Path $GameDir 'r6\logs\redscript_r*.log') 2) 'redscript'
Copy-Into (Get-ChildItem (Join-Path $GameDir 'bin\x64\plugins\cyber_engine_tweaks') -File -Filter *.log -ErrorAction SilentlyContinue |
    ForEach-Object FullName) 'cet'

# Hosted server (only on the host's machine)
$server = Join-Path $GameDir 'CyberpunkCoopServer'
if (Test-Path $server) {
    Copy-Into (Get-ChildItem (Join-Path $server 'logs') -File -ErrorAction SilentlyContinue | ForEach-Object FullName) 'server\logs'
    Copy-Into (Get-ChildItem (Join-Path $server 'campaigns') -File -ErrorAction SilentlyContinue | ForEach-Object FullName) 'server\campaigns'
    Copy-Into (Get-ChildItem (Join-Path $server 'config') -File -Filter *.json -ErrorAction SilentlyContinue |
        Where-Object Name -ne 'server.json' | ForEach-Object FullName) 'server\config'
}

# The game's own crash reports, with dumps, from the window asked for
$since = (Get-Date).AddHours(-$Hours)
$reports = Join-Path $env:LOCALAPPDATA 'REDEngine\ReportQueue'
$crashes = @(Get-ChildItem $reports -Directory -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $since)
foreach ($c in $crashes) {
    $dest = Join-Path $stage "crashes\$($c.Name)"
    New-Item -ItemType Directory -Force $dest | Out-Null
    Copy-Item (Join-Path $c.FullName '*') $dest -Recurse -Force
}

# Versions
$exe = Get-Item (Join-Path $GameDir 'bin\x64\Cyberpunk2077.exe')
$manifest = Get-ChildItem (Split-Path (Split-Path $GameDir)) -Filter 'appmanifest_1091500.acf' -ErrorAction SilentlyContinue | Select-Object -First 1
$build = '?'
$branch = $null
if ($manifest) {
    $text = Get-Content $manifest.FullName -Raw
    if ($text -match '"buildid"\s+"(\d+)"') { $build = $Matches[1] }
    if ($text -match '"BetaKey"\s+"([^"]+)"') { $branch = $Matches[1] }
}
$dll = Join-Path $GameDir 'red4ext\plugins\zzzCyberpunkMP\CyberpunkMP.dll'
$info = @(
    "Collected:      $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
    "Computer user:  $env:USERNAME"
    "Windows:        $([Environment]::OSVersion.VersionString)"
    "Game:           $($exe.VersionInfo.ProductVersion) ($($exe.VersionInfo.FileVersion)), Steam build $build, branch $(if ($branch) { $branch } else { 'public' })"
    "Game folder:    $GameDir"
    "Mod DLL:        $(if (Test-Path $dll) { "$((Get-Item $dll).LastWriteTime.ToString('yyyy-MM-dd HH:mm')) sha256 $((Get-FileHash $dll -Algorithm SHA256).Hash)" } else { 'NOT INSTALLED' })"
    "Crash reports:  $($crashes.Count) in the last $Hours h"
    ''
    'RED4ext plugins:'
)
foreach ($p in Get-ChildItem (Join-Path $GameDir 'red4ext\plugins') -Directory -ErrorAction SilentlyContinue) {
    $main = Get-ChildItem $p.FullName -Filter *.dll -File | Select-Object -First 1
    $info += "  {0,-20} {1}" -f $p.Name, $(if ($main) { $main.VersionInfo.ProductVersion } else { '(no dll)' })
}
$info += "  RED4ext loader       $((Get-Item (Join-Path $GameDir 'red4ext\RED4ext.dll') -ErrorAction SilentlyContinue).VersionInfo.ProductVersion)"
$info += "  CET                  $(if (Test-Path (Join-Path $GameDir 'bin\x64\plugins\cyber_engine_tweaks.asi')) { 'installed' } else { 'not installed' })"
$info | Set-Content (Join-Path $stage 'info.txt') -Encoding UTF8
Copy-Into @((Join-Path $GameDir '_coop_installed.txt')) '.'

$desktop = [Environment]::GetFolderPath('Desktop')
$zip = Join-Path $desktop "cyberpunk-coop-logs-$env:USERNAME-$stamp.zip"
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal -Force
Remove-Item $stage -Recurse -Force

Write-Host "Логи сохранены: $zip ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) МБ, отчётов о вылетах: $($crashes.Count))." -ForegroundColor Green
Write-Host "Отправьте этот файл тому, кто собирает кооператив."
