# Downloads the official UE4SS release used by MOHAB Plus into third_party\UE4SS (needed by build.ps1).
# Usage:  powershell -ExecutionPolicy Bypass -File tools\get-ue4ss.ps1
param([string]$Version = 'v4.0.0')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dl = Join-Path $root 'third_party\dl'
$dest = Join-Path $root 'third_party\UE4SS'
New-Item -ItemType Directory -Force $dl | Out-Null

$zip = Join-Path $dl "UE4SS_$Version.zip"
if (-not (Test-Path $zip)) {
    $url = "https://github.com/UE4SS-RE/RE-UE4SS/releases/download/$Version/UE4SS_$Version.zip"
    Write-Host "Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $zip
}
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath $dest
Write-Host "UE4SS $Version extracted to $dest"
