# Установщик кооператива Cyberpunk 2077 (CyberpunkMP + сюжетный кооп) для патча 2.5.
#
# Запускается через install.bat из корня пакета. Делает:
#   1. находит игру в Steam и проверяет: патч 2.5, Phantom Liberty, игра закрыта;
#   2. делает резервную копию сохранений в «Документы»;
#   3. ставит фреймворки (RED4ext, redscript, ArchiveXL, TweakXL, Codeware, Input Loader, CET),
#      не понижая уже установленные более новые версии;
#   4. ставит мод и сервер кооператива, кладёт в папку игры удаление и сбор логов;
#   5. каждый заменённый файл сохраняет в <игра>\_coop_backup, а список всего установленного —
#      в <игра>\_coop_installed.txt, чтобы удаление вернуло всё как было.
param([string]$GameDir = "", [switch]$SkipSavesBackup)

$ErrorActionPreference = 'Stop'
trap {
    Write-Host ''
    Write-Host "Ошибка: $_" -ForegroundColor Red
    Write-Host 'Запустите CyberpunkCoop-Logs.bat (или collect-logs.bat из пакета) и пришлите архив вместе с текстом ошибки.'
    Read-Host 'Нажмите Enter, чтобы закрыть'
    exit 1
}
Add-Type -AssemblyName System.IO.Compression.FileSystem

$here = Split-Path -Parent $PSScriptRoot
$expectedPatch = '2.5'

function Say($aText, $aColor = 'Gray') { Write-Host $aText -ForegroundColor $aColor }

function Fail($aText) {
    Say ''
    Say $aText 'Red'
    Say ''
    Read-Host 'Нажмите Enter, чтобы закрыть'
    exit 1
}

function Find-Game {
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) { return $null }
    $libraries = @($steam.Replace('/', '\'))
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
            $libraries += $m.Groups[1].Value.Replace('\\', '\')
        }
    }
    foreach ($lib in $libraries | Select-Object -Unique) {
        $dir = Join-Path $lib 'steamapps\common\Cyberpunk 2077'
        if (Test-Path (Join-Path $dir 'bin\x64\Cyberpunk2077.exe')) { return $dir }
    }
    return $null
}

function Get-FileVersion($aPath) {
    if (-not (Test-Path $aPath)) { return $null }
    $text = (Get-Item $aPath).VersionInfo.ProductVersion
    if (-not $text) { return $null }
    try { return [version](($text -split '[^0-9.]')[0]) } catch { return $null }
}

Say ''
Say '=== Кооператив Cyberpunk 2077 — установка ===' 'Cyan'
Say ''

# Файлы, скачанные из интернета, Windows помечает как чужие; снимаем пометку с пакета.
Get-ChildItem $here -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

# ---- 1. игра ----
if (-not $GameDir) { $GameDir = Find-Game }
if (-not $GameDir) {
    $GameDir = Read-Host 'Игра не найдена автоматически. Вставьте путь к папке игры (где лежит bin\x64\Cyberpunk2077.exe)'
}
$GameDir = $GameDir.Trim().Trim('"')
$exe = Join-Path $GameDir 'bin\x64\Cyberpunk2077.exe'
if (-not (Test-Path $exe)) { Fail "В папке '$GameDir' нет bin\x64\Cyberpunk2077.exe." }
$GameDir = [IO.Path]::GetFullPath($GameDir).TrimEnd('\')
Say "Игра: $GameDir"

$patch = (Get-Item $exe).VersionInfo.ProductVersion
if ($patch -ne $expectedPatch) {
    Fail "Установлен патч $patch, а этот кооператив собран для $expectedPatch. Обновите игру в Steam (публичная ветка, без бета-версий)."
}
Say "Патч: $patch — подходит" 'Green'

if (-not (Test-Path (Join-Path $GameDir 'archive\pc\ep1'))) {
    Fail 'Не найден Phantom Liberty (папка archive\pc\ep1). Он нужен кооперативу: гость входит в мир через старт дополнения.'
}
Say 'Phantom Liberty: установлен' 'Green'

if (Get-Process -Name Cyberpunk2077 -ErrorAction SilentlyContinue) { Fail 'Закройте игру и запустите установку снова.' }
if (Get-Process -Name Server.Loader -ErrorAction SilentlyContinue) { Fail 'Работает сервер кооператива. Закройте игру и запустите установку снова.' }

$probe = Join-Path $GameDir '_coop_write_test.tmp'
try { [IO.File]::WriteAllText($probe, 'x'); Remove-Item $probe -Force }
catch { Fail 'Нет прав на запись в папку игры. Запустите install.bat от имени администратора.' }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $GameDir "_coop_backup\$stamp"
$listPath = Join-Path $GameDir '_coop_installed.txt'
$previous = @()
if (Test-Path $listPath) { $previous = @(Get-Content $listPath -Encoding UTF8 | Where-Object { $_ -and -not $_.StartsWith('#') }) }
$ours = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($p in $previous) { [void]$ours.Add($p) }
$installed = New-Object System.Collections.Generic.List[string]

# Пишет файл в игру. Чужой файл, который там уже лежал, сначала копируется в бэкап;
# свои файлы от прошлой установки в бэкап не идут, иначе удаление вернуло бы их назад.
function Write-GameFile($aRelative, [scriptblock]$aWrite) {
    $target = [IO.Path]::GetFullPath((Join-Path $GameDir $aRelative))
    if (-not $target.StartsWith($GameDir + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Попытка записи вне папки игры: $aRelative"
    }
    if ((Test-Path $target) -and $ours.Add($aRelative)) {
        $copy = Join-Path $backupRoot $aRelative
        New-Item -ItemType Directory -Force (Split-Path $copy) | Out-Null
        Copy-Item $target $copy -Force
    }
    [void]$ours.Add($aRelative)
    New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
    & $aWrite $target
    $installed.Add($aRelative)
}

# ---- 2. сохранения ----
$saves = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Saved Games\CD Projekt Red\Cyberpunk 2077'
if (-not $SkipSavesBackup -and (Test-Path $saves) -and (Get-ChildItem $saves -Recurse -File | Select-Object -First 1)) {
    $savesZip = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "CyberpunkCoop_сохранения_$stamp.zip"
    Say ''
    Say 'Делаю резервную копию сохранений...'
    [IO.Compression.ZipFile]::CreateFromDirectory($saves, $savesZip)
    Say "Сохранения скопированы: $savesZip" 'Green'
}

# ---- 3. фреймворки ----
# Архив, главный файл (по нему смотрим версию) и версия в пакете. Без главного файла —
# ставится всегда: у этих архивов нет версии в файлах, а на 2.5 нужны именно эти или новее.
$frameworks = @(
    @{ Name = 'RED4ext';             Zip = 'red4ext-1.31.0.zip';            Main = 'red4ext\RED4ext.dll';                     Version = '1.31.0' },
    @{ Name = 'redscript';           Zip = 'redscript-v0.5.32-windows.zip'; Main = $null;                                     Version = $null },
    @{ Name = 'ArchiveXL';           Zip = 'ArchiveXL-1.28.0.zip';          Main = 'red4ext\plugins\ArchiveXL\ArchiveXL.dll'; Version = '1.28.0' },
    @{ Name = 'TweakXL';             Zip = 'TweakXL-1.12.0.zip';            Main = 'red4ext\plugins\TweakXL\TweakXL.dll';     Version = '1.12.0' },
    @{ Name = 'Codeware';            Zip = 'Codeware-1.21.1.zip';           Main = 'red4ext\plugins\Codeware\Codeware.dll';   Version = '1.21.1' },
    @{ Name = 'Input Loader';        Zip = 'input_loader_v0.2.6.zip';       Main = $null;                                     Version = $null },
    @{ Name = 'Cyber Engine Tweaks'; Zip = 'cet_1_38_1.zip';                Main = $null;                                     Version = $null }
)

Say ''
Say 'Фреймворки:' 'Cyan'
foreach ($fw in $frameworks) {
    $zip = Join-Path $here "data\frameworks\$($fw.Zip)"
    if (-not (Test-Path $zip)) { Fail "В пакете нет $($fw.Zip). Распакуйте архив целиком и запустите снова." }

    if ($fw.Main) {
        $current = Get-FileVersion (Join-Path $GameDir $fw.Main)
        if ($current -and $current -gt [version]$fw.Version) {
            Say "  $($fw.Name): уже стоит более новая $current — оставляю"
            continue
        }
    }

    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) { continue }
            $relative = $entry.FullName -replace '/', '\'
            Write-GameFile $relative { param($t) [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $t, $true) }
        }
    }
    finally { $archive.Dispose() }
    Say "  $($fw.Name): установлен" 'Green'
}

# ---- 4. мод, сервер, удаление и сбор логов ----
Say ''
Say 'Мод кооператива:' 'Cyan'
$modRoot = Join-Path $here 'data\mod'
foreach ($file in Get-ChildItem $modRoot -Recurse -File) {
    $relative = $file.FullName.Substring($modRoot.Length + 1)
    # Настройки, кампании и логи уже установленного сервера не трогаем.
    if ($relative -match '^CyberpunkCoopServer\\(config|campaigns|logs)\\') { continue }
    Write-GameFile $relative { param($t) Copy-Item -LiteralPath $file.FullName -Destination $t -Force }
}
Say '  CyberpunkMP и сервер кооператива: установлены' 'Green'

# Удаление и сбор логов — копии в папке игры, чтобы работали и без этого пакета.
$tools = Join-Path $GameDir '_coop_tools'
New-Item -ItemType Directory -Force $tools | Out-Null
foreach ($name in 'Uninstall-CyberpunkCoop.ps1', 'Collect-Logs.ps1') {
    Copy-Item (Join-Path $here "data\$name") $tools -Force
}
$bat = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0_coop_tools\{0}`" -GameDir `"%~dp0.`"`r`n{1}"
[IO.File]::WriteAllText((Join-Path $GameDir 'CyberpunkCoop-Uninstall.bat'), ($bat -f 'Uninstall-CyberpunkCoop.ps1', ''))
[IO.File]::WriteAllText((Join-Path $GameDir 'CyberpunkCoop-Logs.bat'), ($bat -f 'Collect-Logs.ps1', "pause`r`n"))

# ---- 5. список для удаления ----
$all = @($previous) + @($installed) | Select-Object -Unique
$header = @("# Установлено кооперативом Cyberpunk 2077. Последняя установка: $stamp", '# Копии заменённых файлов: _coop_backup\<дата>')
[IO.File]::WriteAllLines($listPath, [string[]]($header + $all), (New-Object System.Text.UTF8Encoding($true)))

# ---- .NET 8: нужен только хосту ----
$hasNet8 = $false
try { $hasNet8 = [bool]((& dotnet --list-runtimes 2>$null) -match '^Microsoft\.NETCore\.App 8\.') } catch {}
if (-not $hasNet8) {
    Say ''
    Say 'Для ХОСТИНГА (кнопка HOST CAMPAIGN) нужен .NET 8 Runtime — его нет.' 'Yellow'
    Say 'Чтобы только подключаться к другу, он не нужен.'
    $answer = Read-Host 'Установить .NET 8 Runtime сейчас? (д/н)'
    if ($answer -match '^[дДyY]') {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            & winget install --id Microsoft.DotNet.Runtime.8 -e --accept-source-agreements --accept-package-agreements
        }
        else {
            Start-Process 'https://dotnet.microsoft.com/download/dotnet/8.0'
            Say 'Открыл страницу загрузки: выберите .NET Runtime 8, Windows x64.'
        }
    }
}

Say ''
Say '=== Готово ===' 'Cyan'
Say ''
Say 'Осталось один раз настроить запуск в Steam:' 'Yellow'
Say '  Библиотека → правый клик по Cyberpunk 2077 → Свойства → Общие → Параметры запуска:'
Say '      --online' 'White'
Say '  Без этого параметра игра запускается обычной, без кооператива.'
Say ''
Say 'В папке игры появились:'
Say '  CyberpunkCoop-Logs.bat       — собрать логи, если что-то сломалось (архив появится на рабочем столе)'
Say '  CyberpunkCoop-Uninstall.bat  — удалить кооператив и вернуть всё как было'
Say ''
Say 'Подробности — в ИНСТРУКЦИЯ.txt.'
Say ''
Read-Host 'Нажмите Enter, чтобы закрыть'
