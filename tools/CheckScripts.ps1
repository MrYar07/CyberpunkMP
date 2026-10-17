# Compile-check code/assets/redscript against the installed game without deploying anything.
#
# One bad .reds aborts the whole redscript compilation and the game then starts with no mod
# scripts at all, so run this before installing a build.
#
#   .\tools\CheckScripts.ps1 -GameDir "C:\Program Files (x86)\Steam\steamapps\common\Cyberpunk 2077"
#
# scc.exe shows a blocking "REDScript compilation has failed" dialog on errors, so it runs
# hidden and is killed as soon as an error reaches stdout. Approach taken from Night City
# Online's tools/CheckScripts.ps1.
[CmdletBinding()]
param(
    [string]$GameDir = "C:\Program Files (x86)\Steam\steamapps\common\Cyberpunk 2077",
    [switch]$Full
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

$scc = Join-Path $GameDir "engine\tools\scc.exe"
if (-not (Test-Path $scc)) { Write-Host "no scc.exe at $scc - install redscript" -ForegroundColor Red; exit 2 }

$scratch = Join-Path $env:TEMP "cpmp_campaign_scc"
if (Test-Path $scratch) { Remove-Item $scratch -Recurse -Force }
$staged = Join-Path $scratch "redscript"
New-Item -ItemType Directory -Force -Path $staged | Out-Null
Copy-Item (Join-Path $repo "code\assets\redscript\*") $staged -Recurse -Force

# With -compilePathsFile scc compiles only the listed paths, so the other RED4ext plugins'
# scripts (Codeware, ...) must be listed too. Skip installed copies of this mod.
$scriptPaths = @($staged)
$scriptPaths += Get-ChildItem (Join-Path $GameDir "red4ext\plugins") -Directory |
    Where-Object { $_.Name -notmatch 'CyberpunkMP' -and (Test-Path (Join-Path $_.FullName 'Scripts')) } |
    ForEach-Object { Join-Path $_.FullName 'Scripts' }

# No BOM: scc misreads the first path of a BOM-prefixed file and reports a false success.
$pathsFile = Join-Path $scratch "paths.txt"
[System.IO.File]::WriteAllLines($pathsFile, $scriptPaths, (New-Object System.Text.UTF8Encoding($false)))

$stdout = Join-Path $scratch "scc.out"
$stderr = Join-Path $scratch "scc.err"
$proc = Start-Process -FilePath $scc -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
    -ArgumentList @(
        '-compile', ('"{0}"' -f (Join-Path $GameDir "r6\scripts")),
        ('"{0}"' -f (Join-Path $GameDir "r6\cache\final.redscripts")),
        '-compilePathsFile', ('"{0}"' -f $pathsFile),
        '-outputCacheFile', ('"{0}"' -f (Join-Path $scratch "final.redscripts"))
    )

$blocked = $false
$deadline = (Get-Date).AddSeconds(120)
while (-not $proc.HasExited) {
    if ((Get-Date) -gt $deadline) { $blocked = $true; break }
    $seen = if (Test-Path $stdout) { Get-Content $stdout -Raw } else { $null }
    if ($seen -and $seen -match '\[ERROR') {
        Start-Sleep -Milliseconds 750
        $blocked = $true
        break
    }
    Start-Sleep -Milliseconds 250
}
if ($blocked) {
    try { $proc | Stop-Process -Force } catch {}
    Start-Sleep -Milliseconds 250
}

$out = @()
if (Test-Path $stdout) { $out += Get-Content $stdout }
if (Test-Path $stderr) { $out += Get-Content $stderr }
if ($Full) { $out | ForEach-Object { Write-Host $_ } }

# Judge by what scc printed; the exit code of a Start-Process handle is unreliable.
$text = ($out -join "`n")
if ($blocked -or ($text -match '\[ERROR') -or ($text -notmatch 'Compilation complete')) {
    if (-not $Full) {
        $out | Where-Object { $_ -match '(?i)error|warn' } | Select-Object -First 40 |
            ForEach-Object { Write-Host $_ -ForegroundColor Red }
    }
    Write-Host "FAIL" -ForegroundColor Red
    exit 1
}

$out | Where-Object { $_ -match '(?i)warn' } | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
Write-Host "OK - redscript compiles" -ForegroundColor Green
exit 0
