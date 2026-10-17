# Campaign co-op: builds the player installer from a release build.
#
#   .\tools\campaign\BuildInstaller.ps1 -Out <folder>
#
# Produces in <folder>:
#   CyberpunkCoopSetup.exe       one file: unpacks itself and runs the installer (IExpress)
#   CyberpunkCoop-Installer.zip  the same as a zip: unpack, run install.bat
# The frameworks the mod needs are the official releases of the versions it is built and
# tested against on patch 2.31 (downloaded with gh into <folder>\deps, reused next time).

param(
    [Parameter(Mandatory = $true)][string]$Out
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$installer = Join-Path $PSScriptRoot "installer"

# name, GitHub repository, tag, asset, main file (for the installed version), version, payload paths
$deps = @(
    @{ Name = "RED4ext"; Repo = "WopsS/RED4ext"; Tag = "v1.30.0"; Asset = "red4ext-1.30.0.zip"; Main = "red4ext\RED4ext.dll"; Version = "1.30.0";
       Paths = "bin\x64\winmm.dll,red4ext\RED4ext.dll,red4ext\LICENSE.txt,red4ext\THIRD_PARTY_LICENSES.txt" },
    @{ Name = "ArchiveXL"; Repo = "psiberx/cp2077-archive-xl"; Tag = "v1.27.1"; Asset = "ArchiveXL-1.27.1.zip"; Main = "red4ext\plugins\ArchiveXL\ArchiveXL.dll"; Version = "1.27.1";
       Paths = "red4ext\plugins\ArchiveXL,r6\config\redsUserHints\ArchiveXL.toml" },
    @{ Name = "TweakXL"; Repo = "psiberx/cp2077-tweak-xl"; Tag = "v1.11.4"; Asset = "TweakXL-1.11.4.zip"; Main = "red4ext\plugins\TweakXL\TweakXL.dll"; Version = "1.11.4";
       Paths = "red4ext\plugins\TweakXL" },
    @{ Name = "Codeware"; Repo = "psiberx/cp2077-codeware"; Tag = "v1.20.5"; Asset = "Codeware-1.20.5.zip"; Main = "red4ext\plugins\Codeware\Codeware.dll"; Version = "1.20.5";
       Paths = "red4ext\plugins\Codeware" },
    @{ Name = "redscript"; Repo = "jac3km4/redscript"; Tag = "v0.5.31"; Asset = "redscript-v0.5.31-windows.zip"; Main = "engine\tools\scc.exe"; Version = "-";
       Paths = "engine\tools\scc.exe,engine\tools\scc_lib.dll,engine\config\base\scripts.ini,r6\config\cybercmd\scc.toml" },
    @{ Name = "Input Loader"; Repo = "jackhumbert/cyberpunk2077-input-loader"; Tag = "v0.2.3"; Asset = "input_loader_v0.2.3.zip"; Main = "red4ext\plugins\input_loader\input_loader.dll"; Version = "-";
       Paths = "red4ext\plugins\input_loader,r6\cache\inputContexts.xml,r6\cache\inputUserMappings.xml,engine\config\platform\pc\input_loader.ini" }
)

New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$depsFolder = Join-Path $Out "deps"
$stage = Join-Path $Out "stage"
$payload = Join-Path $Out "payload"
foreach ($folder in @($stage, $payload)) {
    if (Test-Path $folder) { Remove-Item $folder -Recurse -Force }
    New-Item -ItemType Directory -Force $folder | Out-Null
}
New-Item -ItemType Directory -Force $depsFolder | Out-Null

# ---- frameworks ----
$depsLines = @("# name|payload paths|main file|version ('-' = keep whatever is installed)")
$notices = @()
foreach ($dep in $deps) {
    $zip = Join-Path $depsFolder $dep.Asset
    if (-not (Test-Path $zip)) {
        Write-Host "Downloading $($dep.Name) $($dep.Tag)"
        & gh release download $dep.Tag -R $dep.Repo -p $dep.Asset -D $depsFolder
        if ($LASTEXITCODE -ne 0) { throw "Could not download $($dep.Asset)" }
    }
    Expand-Archive -Path $zip -DestinationPath $payload -Force
    $depsLines += "$($dep.Name)|$($dep.Paths)|$($dep.Main)|$($dep.Version)"

    $license = & gh api "repos/$($dep.Repo)/license" -q ".content" 2>$null
    $text = if ($license) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($license -join ""))) } else { "See https://github.com/$($dep.Repo)" }
    $notices += "==== $($dep.Name) $($dep.Tag) - https://github.com/$($dep.Repo) ====`r`n$text`r`n"
}

# ---- the mod and its server ----
& (Join-Path $PSScriptRoot "Install.ps1") -ModFolder (Join-Path $payload "red4ext\plugins\zzzCyberpunkMP") -ServerFolder (Join-Path $payload "CyberpunkCoopServer")

# ---- the package ----
Compress-Archive -Path (Join-Path $payload "*") -DestinationPath (Join-Path $stage "payload.zip") -CompressionLevel Optimal
Copy-Item (Join-Path $installer "install.bat") $stage
Copy-Item (Join-Path $installer "Install-CyberpunkCoop.ps1") $stage
Copy-Item (Join-Path $installer "Uninstall-CyberpunkCoop.ps1") $stage
Copy-Item (Join-Path $installer "CZYTAJ.txt") $stage
Set-Content -Path (Join-Path $stage "deps.txt") -Value $depsLines -Encoding ASCII

$cyberpunkMpLicense = Get-Content (Join-Path $repo "LICENSE.md") -Raw
Set-Content -Path (Join-Path $stage "LICENSES.txt") -Encoding UTF8 -Value (
    "==== CyberpunkMP (Tilted Phoques) - https://github.com/tiltedphoques/CyberpunkMP ====`r`n$cyberpunkMpLicense`r`n" + ($notices -join "`r`n"))

$zipOut = Join-Path $Out "CyberpunkCoop-Installer.zip"
if (Test-Path $zipOut) { Remove-Item $zipOut -Force }
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zipOut -CompressionLevel NoCompression

# ---- one-file setup (IExpress, part of Windows) ----
$exeOut = Join-Path $Out "CyberpunkCoopSetup.exe"
$files = Get-ChildItem $stage -File
$sed = @(
    "[Version]", "Class=IEXPRESS", "SEDVersion=3",
    "[Options]", "PackagePurpose=InstallApp", "ShowInstallProgramWindow=1", "HideExtractAnimation=0",
    "UseLongFileName=1", "InsideCompressed=0", "CAB_FixedSize=0", "CAB_ResvCodeSigning=0", "RebootMode=N",
    "InstallPrompt=%InstallPrompt%", "DisplayLicense=%DisplayLicense%", "FinishMessage=%FinishMessage%",
    "TargetName=%TargetName%", "FriendlyName=%FriendlyName%", "AppLaunched=%AppLaunched%",
    "PostInstallCmd=%PostInstallCmd%", "AdminQuietInstCmd=%AdminQuietInstCmd%", "UserQuietInstCmd=%UserQuietInstCmd%",
    "SourceFiles=SourceFiles",
    "[Strings]", "InstallPrompt=", "DisplayLicense=", "FinishMessage=",
    "TargetName=$exeOut", "FriendlyName=Cyberpunk 2077 Co-op", "AppLaunched=cmd.exe /c install.bat",
    "PostInstallCmd=<None>", "AdminQuietInstCmd=", "UserQuietInstCmd="
)
for ($i = 0; $i -lt $files.Count; $i++) { $sed += "FILE$i=`"$($files[$i].Name)`"" }
$sed += "[SourceFiles]", "SourceFiles0=$stage\", "[SourceFiles0]"
for ($i = 0; $i -lt $files.Count; $i++) { $sed += "%FILE$i%=" }
$sedPath = Join-Path $Out "setup.sed"
Set-Content -Path $sedPath -Value $sed -Encoding ASCII
if (Test-Path $exeOut) { Remove-Item $exeOut -Force }
& "$env:SystemRoot\System32\iexpress.exe" /N /Q $sedPath | Out-Null
$deadline = (Get-Date).AddMinutes(5)
while (-not (Test-Path $exeOut) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }

Remove-Item $payload -Recurse -Force
Write-Host "Built:"
Get-Item $exeOut, $zipOut -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ("  {0} ({1:N1} MB)" -f $_.FullName, ($_.Length / 1MB)) }
