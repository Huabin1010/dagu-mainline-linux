#Requires -Version 5.1
<#
.SYNOPSIS
  Flash dagu via MiFlash in EDL (9008) or Fastboot. Uses clean all — never locks BL.

.EXAMPLE
  .\tools\flash-dagu-recovery.ps1
  .\tools\flash-dagu-recovery.ps1 -RomDir D:\rom\dagu-recovery\dagu_images_OS2.0.10.0.ULZCNXM
#>
[CmdletBinding()]
param(
    [string] $DestRoot = "D:\rom\dagu-recovery",
    [string] $RomDir = "",
    [string] $MiFlashExe = ""
)

$ErrorActionPreference = "Stop"

if (-not $RomDir) {
    $RomDir = Join-Path $DestRoot "dagu_images_OS2.0.10.0.ULZCNXM\dagu_images_OS2.0.10.0.ULZCNXM_14.0"
    if (-not (Test-Path (Join-Path $RomDir "flash_all.bat"))) {
        $found = Get-ChildItem -Path $DestRoot -Recurse -Filter "flash_all.bat" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $RomDir = $found.Directory.FullName }
    }
}
if (-not $MiFlashExe) {
    $found = Get-ChildItem -Path (Join-Path $DestRoot "MiFlash20220507") -Recurse -Filter "XiaoMiFlash.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $MiFlashExe = $found.FullName }
}
$MiFlashConfig = Join-Path (Split-Path $MiFlashExe -Parent) "XiaoMiFlash.exe.Config"
$MiFlashRoot = Split-Path $MiFlashExe -Parent
foreach ($sub in @("log", "restore", "tmp")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $MiFlashRoot $sub) | Out-Null
}
$LockBat = Join-Path $RomDir "flash_all_lock.bat"
$LockBatDisabled = Join-Path $RomDir "flash_all_lock.bat.DISABLED"

if (-not (Test-Path (Join-Path $RomDir "flash_all.bat"))) {
    throw "flash_all.bat not found under $RomDir"
}
if (-not (Test-Path $MiFlashExe)) {
    throw "XiaoMiFlash.exe not found at $MiFlashExe"
}

& (Join-Path $PSScriptRoot "fix-miflash-ghost-device.ps1") -MiFlashRoot (Split-Path $MiFlashExe -Parent)

# MiFlash default config uses flash_all_lock.bat — force unlock-safe script
[xml]$cfg = Get-Content $MiFlashConfig
$cfg.configuration.appSettings.add | ForEach-Object {
    if ($_.key -eq "swPath") { $_.value = $RomDir }
    if ($_.key -eq "script") { $_.value = "flash_all.bat" }
}
$cfg.Save($MiFlashConfig)

# Disable lock script so even wrong MiFlash option cannot run `fastboot oem lock`
if ((Test-Path $LockBat) -and -not (Test-Path $LockBatDisabled)) {
    Rename-Item $LockBat $LockBatDisabled
    Write-Host "[flash-recovery] Renamed flash_all_lock.bat -> .DISABLED" -ForegroundColor Yellow
}

Write-Host "[flash-recovery] MiFlash: $MiFlashExe" -ForegroundColor Cyan
Write-Host "[flash-recovery] ROM dir: $RomDir" -ForegroundColor Cyan
Write-Host ""
Write-Host "IMPORTANT:" -ForegroundColor Yellow
Write-Host "  1. Device in EDL (9008) or Fastboot"
Write-Host "  2. In MiFlash select folder: $RomDir"
Write-Host "  3. Set option to: clean all  (NOT 'clean all and lock')"
Write-Host "  4. Click Refresh, then Flash"
Write-Host ""
Write-Host "Safety: flash_all_lock.bat disabled; MiFlash config script=flash_all.bat"
Write-Host ""
Write-Host "After success, verify BL still unlocked:"
Write-Host "  fastboot getvar unlocked"
Write-Host ""

# Check 9008
$edl = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
    $_.FriendlyName -match '9008|QDLoader'
}
if ($edl) {
    Write-Host "[flash-recovery] Detected EDL: $($edl.FriendlyName)" -ForegroundColor Green
} else {
    Write-Host "[flash-recovery] No EDL device — plug tablet in 9008 or enter fastboot" -ForegroundColor Yellow
}

# Launch MiFlash GUI as admin (user: Refresh + Flash with clean all)
Start-Process -FilePath $MiFlashExe -WorkingDirectory (Split-Path $MiFlashExe -Parent) -Verb RunAs
Write-Host "[flash-recovery] MiFlash launched (admin). ROM path pre-set in config." -ForegroundColor Green
