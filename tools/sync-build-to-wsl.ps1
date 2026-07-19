#Requires -Version 5.1
$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent
$Distro = "Ubuntu-22.04"
$Cfg = Join-Path $Root "wsl-layer.json"
if (Test-Path $Cfg) {
    $j = Get-Content $Cfg -Raw | ConvertFrom-Json
    if ($j.wsl_distro) { $Distro = $j.wsl_distro }
}
$Win = ($Root -replace '\\', '/')
if ($Win -match '^([A-Za-z]):/(.*)$') {
    $WslWin = "/mnt/$($Matches[1].ToLower())/$($Matches[2])"
} else { $WslWin = $Win }

wsl -d $Distro -e bash -lc "sed -i 's/\r$//' '$WslWin/tools/sync-build-to-wsl.sh' 2>/dev/null; bash '$WslWin/tools/sync-build-to-wsl.sh'"
