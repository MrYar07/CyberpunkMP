# Удаляет кооператив Cyberpunk 2077: файлы из <игра>\_coop_installed.txt, затем возвращает файлы,
# которые установка заменила (самые ранние копии из <игра>\_coop_backup).
# Кампании сервера (CyberpunkCoopServer\campaigns) и сохранения игры не трогаются.
# Лежит в <игра>\_coop_tools, запускается через <игра>\CyberpunkCoop-Uninstall.bat.
param([string]$GameDir = "")

$ErrorActionPreference = 'Stop'
trap {
    Write-Host ''
    Write-Host "Ошибка: $_" -ForegroundColor Red
    Write-Host 'Запустите CyberpunkCoop-Logs.bat (или collect-logs.bat из пакета) и пришлите архив вместе с текстом ошибки.'
    Read-Host 'Нажмите Enter, чтобы закрыть'
    exit 1
}

function Say($aText, $aColor = 'Gray') { Write-Host $aText -ForegroundColor $aColor }

function Finish($aCode) {
    Say ''
    Read-Host 'Нажмите Enter, чтобы закрыть'
    exit $aCode
}

if (-not $GameDir) {
    # Скрипт лежит в <игра>\_coop_tools.
    $GameDir = Split-Path -Parent $PSScriptRoot
}
$GameDir = [IO.Path]::GetFullPath($GameDir).TrimEnd('\')

Say ''
Say '=== Кооператив Cyberpunk 2077 — удаление ===' 'Cyan'
Say ''

$listPath = Join-Path $GameDir '_coop_installed.txt'
if (-not (Test-Path $listPath)) {
    Say "В '$GameDir' нет _coop_installed.txt — кооператив сюда этим установщиком не ставился." 'Yellow'
    Finish 0
}
if (Get-Process -Name Cyberpunk2077, Server.Loader -ErrorAction SilentlyContinue) {
    Say 'Закройте игру и запустите удаление снова.' 'Red'
    Finish 1
}

$answer = Read-Host "Удалить кооператив из '$GameDir'? (д/н)"
if ($answer -notmatch '^[дДyY]') { exit 0 }

$removed = 0
$emptied = @()
foreach ($relative in Get-Content $listPath -Encoding UTF8 | Where-Object { $_ -and -not $_.StartsWith('#') }) {
    $path = [IO.Path]::GetFullPath((Join-Path $GameDir $relative))
    if (-not $path.StartsWith($GameDir + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
    if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force; $removed++ }
    $emptied += Split-Path $path
}

# Самая ранняя копия каждого файла — то, что лежало до первой установки.
$restored = 0
$backupRoot = Join-Path $GameDir '_coop_backup'
if (Test-Path $backupRoot) {
    $seen = @{}
    foreach ($set in Get-ChildItem $backupRoot -Directory | Sort-Object Name) {
        foreach ($file in Get-ChildItem $set.FullName -Recurse -File) {
            $relative = $file.FullName.Substring($set.FullName.Length + 1)
            if ($seen.ContainsKey($relative.ToLower())) { continue }
            $seen[$relative.ToLower()] = $true
            $target = Join-Path $GameDir $relative
            New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $target -Force
            $restored++
        }
    }
    Remove-Item $backupRoot -Recurse -Force
}

# Папки, опустевшие после удаления, — от самых глубоких вверх. Трогаем только папки,
# где лежали наши файлы; папки с чужими файлами и кампании остаются.
$dirs = @{}
foreach ($dir in $emptied) {
    while ($dir.Length -gt $GameDir.Length) { $dirs[$dir] = $true; $dir = Split-Path $dir }
}
foreach ($dir in $dirs.Keys | Sort-Object Length -Descending) {
    if ((Test-Path -LiteralPath $dir) -and -not (Get-ChildItem -LiteralPath $dir -Force)) { Remove-Item -LiteralPath $dir -Force }
}

Remove-Item $listPath -Force
Remove-Item (Join-Path $GameDir 'CyberpunkCoop-Logs.bat') -Force -ErrorAction SilentlyContinue

Say ''
Say "Удалено файлов: $removed, возвращено из резервной копии: $restored." 'Green'
if (Test-Path (Join-Path $GameDir 'CyberpunkCoopServer\campaigns')) {
    Say 'Кампании сервера остались в CyberpunkCoopServer\campaigns.'
}
Say 'Параметр запуска --online в Steam уберите сами.'
Say ''
Read-Host 'Нажмите Enter, чтобы закрыть'

# Этот скрипт и его bat ещё открыты; удаляем их после выхода.
$self = Join-Path $GameDir '_coop_tools'
$bat = Join-Path $GameDir 'CyberpunkCoop-Uninstall.bat'
Start-Process cmd.exe -WindowStyle Hidden -ArgumentList "/c timeout /t 2 /nobreak >nul & rd /s /q `"$self`" & del /f /q `"$bat`""
