# Names the code behind a game crash dump: faulting module and offset, the module+offset
# candidates on the faulting thread's stack, and CyberpunkMP.dll frames resolved to
# function/file/line with the build's PDB.
#
#   .\tools\crash\Analyze-Crash.ps1 <crash folder or Cyberpunk2077.dmp> [-Build <folder with CyberpunkMP.dll + .pdb>]
#
# The PDB must be the one built with the DLL that crashed - keep build\...\release (or the
# copy shipped with a package) for every build handed out. Needs uv (minidump reader) and the
# VS Build Tools' llvm-symbolizer.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Dump,
    [string]$Build = (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'build\windows\x64\release')
)

$ErrorActionPreference = 'Stop'
if (Test-Path $Dump -PathType Container) { $Dump = Join-Path $Dump 'Cyberpunk2077.dmp' }
if (-not (Test-Path $Dump)) { throw "No dump at $Dump" }

$folder = Split-Path $Dump
if (Test-Path (Join-Path $folder 'stacktrace.txt')) { Get-Content (Join-Path $folder 'stacktrace.txt') | Select-Object -First 4 }

$report = & uv run --quiet --no-project --with minidump python -I (Join-Path $PSScriptRoot 'minidump_info.py') $Dump 2>&1
$report

$symbolizer = Get-ChildItem 'F:\VS\BuildTools\VC\Tools\MSVC' -Recurse -Filter llvm-symbolizer.exe -ErrorAction SilentlyContinue | Select-Object -First 1
$dll = Join-Path $Build 'CyberpunkMP.dll'
if (-not $symbolizer -or -not (Test-Path $dll)) {
    Write-Warning 'No llvm-symbolizer or no CyberpunkMP.dll+pdb to resolve the mod frames.'
    return
}

$offsets = @($report | Select-String -Pattern 'CyberpunkMP\.dll\+0x([0-9A-F]+)' -AllMatches |
    ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
if (-not $offsets) { Write-Host 'No CyberpunkMP.dll frames in this dump.'; return }

$dumpbin = Get-ChildItem 'F:\VS\BuildTools\VC\Tools\MSVC' -Recurse -Filter dumpbin.exe -ErrorAction SilentlyContinue | Select-Object -First 1
$base = [Convert]::ToUInt64(((& $dumpbin.FullName /headers $dll | Select-String 'image base').Line.Trim() -split '\s+')[0], 16)
Write-Host "`nCyberpunkMP.dll frames:"
foreach ($o in $offsets) {
    $va = '0x{0:X}' -f ($base + [Convert]::ToUInt64($o, 16))
    Write-Host "  +0x$o"
    & $symbolizer.FullName --obj=$dll --inlines --pretty-print $va | ForEach-Object { if ($_) { Write-Host "      $_" } }
}
