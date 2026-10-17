# Cyberpunk 2077 Co-op Campaign - installer for players.
#
# Run through install.bat (or the setup exe that wraps it). Next to this script:
#   payload.zip   the game-folder layout to install: the mod, its server and the frameworks
#   deps.txt      which payload folders belong to which framework, and their versions
#
# What it does: finds the game, checks the patch and that the game is closed, copies the
# payload (keeping a backup of every file it replaces, and leaving frameworks that are
# already installed in the same or a newer version alone), checks the .NET 8 runtime that
# hosting needs, creates a desktop shortcut and installs the uninstaller.

param([string]$GamePath = "")

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$expectedPatch = "2.31"

function Say($text, $color = "Gray") { Write-Host $text -ForegroundColor $color }

function Ask($question) {
    $answer = Read-Host "$question [T/n]"
    return ($answer -eq "" -or $answer -match "^[TtYy]")
}

function Fail($text) {
    Say ""
    Say $text "Red"
    Say ""
    Read-Host "Nacisnij Enter, aby zamknac"
    exit 1
}

function Test-Game($folder) {
    return $folder -and (Test-Path (Join-Path $folder "bin\x64\Cyberpunk2077.exe"))
}

# Steam libraries (libraryfolders.vdf), then GOG, then ask.
function Find-Game {
    $candidates = @()
    try {
        $steam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction Stop).SteamPath
        if ($steam) {
            $steam = $steam -replace "/", "\"
            $candidates += Join-Path $steam "steamapps\common\Cyberpunk 2077"
            $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
            if (Test-Path $vdf) {
                foreach ($match in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                    $library = $match.Groups[1].Value -replace "\\\\", "\"
                    $candidates += Join-Path $library "steamapps\common\Cyberpunk 2077"
                }
            }
        }
    } catch {}
    foreach ($key in @("HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games\1423049311", "HKLM:\SOFTWARE\GOG.com\Games\1423049311")) {
        try { $candidates += (Get-ItemProperty $key -ErrorAction Stop).path } catch {}
    }
    foreach ($candidate in $candidates) {
        if (Test-Game $candidate) { return (Resolve-Path $candidate).Path }
    }

    Say "Nie znalazlem gry automatycznie. Wskaz folder Cyberpunk 2077 (ten z folderem bin)." "Yellow"
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Folder Cyberpunk 2077 (zawiera bin\x64\Cyberpunk2077.exe)"
    if ($dialog.ShowDialog() -eq "OK" -and (Test-Game $dialog.SelectedPath)) { return $dialog.SelectedPath }
    return $null
}

# The installed version of a framework, from its main DLL; $null when absent or unknown.
function Get-InstalledVersion($game, $file) {
    $path = Join-Path $game $file
    if (-not (Test-Path $path)) { return $null }
    $text = (Get-Item $path).VersionInfo.ProductVersion
    if (-not $text) { return [version]"0.0" }
    try { return [version](($text -split "[^0-9.]")[0]) } catch { return [version]"0.0" }
}

Say ""
Say "=== Cyberpunk 2077 Co-op Campaign - instalacja ===" "Cyan"
Say ""

$game = if (Test-Game $GamePath) { $GamePath } else { Find-Game }
if (-not $game) { Fail "Nie znaleziono gry. Instalacja przerwana." }
Say "Gra: $game" "Green"

# A game under Program Files may need administrator rights to write to: ask for them once
# and wait (the setup exe removes these files when this window closes).
$probe = Join-Path $game "red4ext_coop_write_test.tmp"
try {
    Set-Content -Path $probe -Value "" -ErrorAction Stop
    Remove-Item $probe -Force
} catch {
    Say "Folder gry wymaga uprawnien administratora - zaraz pojawi sie pytanie Windows." "Yellow"
    $script = $MyInvocation.MyCommand.Path
    Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -GamePath `"$game`""
    exit 0
}

$exe = Join-Path $game "bin\x64\Cyberpunk2077.exe"
$patch = (Get-Item $exe).VersionInfo.ProductVersion
if ($patch -ne $expectedPatch) {
    Say "Uwaga: gra ma patch $patch, mod jest zrobiony na $expectedPatch. Moze nie dzialac." "Yellow"
    if (-not (Ask "Instalowac mimo to?")) { Fail "Instalacja przerwana." }
}

if (Get-Process -Name "Cyberpunk2077" -ErrorAction SilentlyContinue) {
    Fail "Gra jest uruchomiona. Zamknij ja i uruchom instalator ponownie."
}
if (Get-Process -Name "Server.Loader" -ErrorAction SilentlyContinue) {
    Fail "Serwer co-op jest uruchomiony (Server.Loader). Zamknij go i uruchom instalator ponownie."
}

# ---- unpack ----
$work = Join-Path $env:TEMP ("CyberpunkCoop_" + [guid]::NewGuid().ToString("N"))
Say "Rozpakowywanie..."
Expand-Archive -Path (Join-Path $here "payload.zip") -DestinationPath $work -Force
$payload = (Get-Item $work).FullName

# ---- frameworks already installed in the same or a newer version stay ----
# deps.txt: <name>|<payload folder or file>|<main file for the version>|<version>
$skip = @()
foreach ($line in Get-Content (Join-Path $here "deps.txt")) {
    if (-not $line -or $line.StartsWith("#")) { continue }
    $name, $paths, $main, $version = $line.Split("|")
    $installed = Get-InstalledVersion $game $main
    if ($null -eq $installed) {
        if ($version -eq "-") { Say "  $name - instaluje" } else { Say "  $name $version - instaluje" }
        continue
    }
    if ($version -eq "-" -or $installed -ge [version]$version) {
        if ($installed -eq [version]"0.0") { Say "  $name - juz zainstalowany, zostawiam" } else { Say "  $name - juz zainstalowany ($installed), zostawiam" }
        $skip += $paths.Split(",")
    } else {
        Say "  $name $installed -> $version - aktualizuje"
    }
}

function Test-Skipped($relative) {
    foreach ($prefix in $skip) {
        if ($relative -eq $prefix -or $relative.StartsWith($prefix.TrimEnd("\") + "\")) { return $true }
    }
    return $false
}

# ---- copy, with a backup of everything replaced ----
$backup = Join-Path $game "CyberpunkCoop_backup"
$listPath = Join-Path $game "CyberpunkCoop_installed.txt"
$installed = New-Object System.Collections.Generic.List[string]
if (Test-Path $listPath) { $installed.AddRange([string[]](Get-Content $listPath)) }

Say "Kopiowanie plikow..."
$count = 0
foreach ($file in Get-ChildItem $payload -Recurse -File) {
    $relative = $file.FullName.Substring($payload.Length + 1)
    if (Test-Skipped $relative) { continue }
    $target = Join-Path $game $relative

    # The hosted server's own state (settings, campaign saves, logs) is never replaced.
    if ($relative -match "^CyberpunkCoopServer\\(config|campaigns|logs)\\" -and (Test-Path $target)) { continue }

    if ((Test-Path $target) -and -not $installed.Contains($relative)) {
        $saved = Join-Path $backup $relative
        if (-not (Test-Path $saved)) {
            New-Item -ItemType Directory -Force (Split-Path $saved) | Out-Null
            Copy-Item $target $saved -Force
        }
    }
    New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
    Copy-Item $file.FullName $target -Force
    if (-not $installed.Contains($relative)) { $installed.Add($relative) }
    $count++
}
Set-Content -Path $listPath -Value $installed -Encoding UTF8
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
Say "Skopiowano $count plikow." "Green"

# ---- uninstaller ----
Copy-Item (Join-Path $here "Uninstall-CyberpunkCoop.ps1") $game -Force
$uninstallBat = Join-Path $game "Odinstaluj-CyberpunkCoop.bat"
Set-Content -Path $uninstallBat -Encoding ASCII -Value "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Uninstall-CyberpunkCoop.ps1`"`r`n"

# ---- .NET 8 (hosting only) ----
$hasDotnet = $false
try { $hasDotnet = [bool]((& dotnet --list-runtimes 2>$null) -match "^Microsoft\.NETCore\.App 8\.") } catch {}
if ($hasDotnet) {
    Say ".NET 8 Runtime: jest." "Green"
} else {
    Say ""
    Say ".NET 8 Runtime nie jest zainstalowany. Potrzebny tylko do HOSTOWANIA kampanii" "Yellow"
    Say "(dolaczanie do kolegi dziala bez niego)."
    if (Ask "Zainstalowac teraz?") {
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget) {
            & winget install --id Microsoft.DotNet.Runtime.8 -e --accept-source-agreements --accept-package-agreements
        } else {
            Start-Process "https://dotnet.microsoft.com/download/dotnet/8.0"
            Say "Otworzylem strone pobierania - wybierz .NET Runtime 8, Windows x64."
        }
    }
}

# ---- desktop shortcut: the game with the mod switched on ----
$desktop = [Environment]::GetFolderPath("Desktop")
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut((Join-Path $desktop "Cyberpunk 2077 Co-op.lnk"))
$shortcut.TargetPath = $exe
$shortcut.Arguments = "--online"
$shortcut.WorkingDirectory = Split-Path $exe
$shortcut.IconLocation = "$exe,0"
$shortcut.Save()

Say ""
Say "=== Gotowe! ===" "Cyan"
Say ""
Say "Jak grac:"
Say "  - Uruchamiaj gre skrotem 'Cyberpunk 2077 Co-op' z pulpitu (Steam musi byc wlaczony)."
Say "  - Dolaczanie: kolega hostujacy wysyla Ci zaproszenie przez Steam - po prostu je przyjmij."
Say "    Mozesz tez kliknac 'Dolacz do gry' przy jego nicku na liscie znajomych."
Say "  - Hostowanie: w menu glownym CO-OP: HOST CAMPAIGN, potem CO-OP: INVITE STEAM FRIEND."
Say "  - Zeby 'Dolacz do gry' dzialalo tez przy wlaczonej grze, uruchamiaj ja skrotem z pulpitu"
Say "    albo dopisz --online w Steam: Cyberpunk 2077 > Wlasciwosci > Opcje uruchamiania."
Say ""
Say "Odinstalowanie: Odinstaluj-CyberpunkCoop.bat w folderze gry."
Say "Jesli uzywasz Vortexa: moze zglosic zmiany w folderze gry - to te pliki, mozna je zostawic."
Say ""
Read-Host "Nacisnij Enter, aby zamknac"
