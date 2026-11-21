# Builds the distributable MOHAB Plus folder into .\dist\MOHABPlus
# Usage:  powershell -ExecutionPolicy Bypass -File build.ps1 [-Dev]
#   -Dev  also enables the MOHABDump development mod
param([switch]$Dev)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dist = Join-Path $root 'dist\MOHABPlus'

# Keep user data (configs, logs) of an existing dist folder.
$keep = @{}
foreach ($rel in @('ue4ss\Mods\MOHABPlus\config.ini', 'launcher.ini')) {
    $p = Join-Path $dist $rel
    if (Test-Path $p) { $keep[$rel] = Get-Content $p -Raw }
}

if (Test-Path $dist) {
    # Remove everything except logs/caches we might want to look at.
    Get-ChildItem $dist -Force | Where-Object { $_.Name -ne 'ue4ss' } | Remove-Item -Recurse -Force
    $ue = Join-Path $dist 'ue4ss'
    if (Test-Path $ue) {
        Get-ChildItem $ue -Force | Where-Object { $_.Name -notin @('UE4SS.log', 'cache', 'CXXHeaderDump') } | Remove-Item -Recurse -Force
    }
}
New-Item -ItemType Directory -Force $dist | Out-Null

Write-Host 'Publishing launcher...'
dotnet publish (Join-Path $root 'launcher\MOHABPlusLauncher.csproj') -c Release -o $dist --nologo -v q
if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }
Remove-Item (Join-Path $dist '*.pdb') -ErrorAction SilentlyContinue

Write-Host 'Copying UE4SS + mod payload...'
$ue4ss = Join-Path $dist 'ue4ss'
New-Item -ItemType Directory -Force $ue4ss | Out-Null
Copy-Item (Join-Path $root 'third_party\UE4SS\ue4ss\UE4SS.dll') $ue4ss -Force
Copy-Item (Join-Path $root 'third_party\UE4SS\ue4ss\LICENSE') (Join-Path $ue4ss 'UE4SS-LICENSE.txt') -Force
Copy-Item (Join-Path $root 'mod\ue4ss\*') $ue4ss -Recurse -Force

if ($Dev) {
    (Get-Content (Join-Path $ue4ss 'Mods\mods.txt')) -replace 'MOHABDump : 0', 'MOHABDump : 1' |
        Set-Content (Join-Path $ue4ss 'Mods\mods.txt') -Encoding ascii
} else {
    Remove-Item (Join-Path $ue4ss 'Mods\MOHABDump') -Recurse -Force -ErrorAction SilentlyContinue
}

foreach ($rel in $keep.Keys) { Set-Content (Join-Path $dist $rel) $keep[$rel] -NoNewline -Encoding ascii }
Copy-Item (Join-Path $root 'README.md') $dist -Force -ErrorAction SilentlyContinue

Write-Host "Done: $dist"
