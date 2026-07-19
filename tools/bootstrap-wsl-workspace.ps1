#Requires -Version 5.1
param(
    [Parameter(Mandatory = $true)]
    [string] $RepoUrl,
    [switch] $RestartLayer
)

$ErrorActionPreference = "Stop"
$Distro = "Ubuntu-22.04"
$Cfg = Join-Path (Split-Path $PSScriptRoot -Parent) "wsl-layer.json"
if (Test-Path $Cfg) {
    $j = Get-Content $Cfg -Raw | ConvertFrom-Json
    if ($j.wsl_distro) { $Distro = $j.wsl_distro }
}

Write-Host "[bootstrap] git clone -> WSL ~/projects/... (no /mnt rsync)" -ForegroundColor Cyan
$cmd = "export PROJECT_REPO_URL='$RepoUrl'; WS=`$HOME/projects/xiaomi-pad870-win11-arm; rm -rf `"`$WS`"; git clone `"`$PROJECT_REPO_URL`" `"`$WS`"; bash `"`$WS/tools/bootstrap-wsl-workspace.sh`""
wsl -d $Distro -e bash -lc $cmd

if ($RestartLayer) {
    $Layer = Join-Path (Split-Path $PSScriptRoot -Parent) "tools/wsl-layer/layer.ps1"
    if (Test-Path $Layer) { & $Layer stop; & $Layer start; & $Layer status }
}

Write-Host "Open in Cursor: \\wsl$\$Distro\home\$(wsl -d $Distro whoami)\projects\xiaomi-pad870-win11-arm" -ForegroundColor Green
