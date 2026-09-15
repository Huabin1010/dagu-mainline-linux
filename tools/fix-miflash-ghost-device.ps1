#Requires -Version 5.1
<#
.SYNOPSIS
  Fix MiFlash showing a permanent ghost device (20170726905923).

  Root cause: MiFlash PDL/factory USB scan picks up Intel BT/USB
  (USB\VID_8087&PID_1024\20170726905923) as a flash target.
  Real dagu EDL shows as: Qualcomm HS-USB QDLoader 9008 (COMx)

.EXAMPLE
  .\tools\fix-miflash-ghost-device.ps1
  .\tools\fix-miflash-ghost-device.ps1 -Launch
#>
[CmdletBinding()]
param(
    [string] $MiFlashRoot = "",
    [string] $RomDir = "D:\rom\dagu-recovery\dagu_images_OS2.0.10.0.ULZCNXM\dagu_images_OS2.0.10.0.ULZCNXM_14.0",
    [switch] $Launch
)

$ErrorActionPreference = "Stop"

if (-not $MiFlashRoot) {
    $candidates = @(
        "E:\Download\Chrome\MiFlash20220218",
        "D:\rom\dagu-recovery\MiFlash20220507\MiFlash20220507"
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c "XiaoMiFlash.exe")) { $MiFlashRoot = $c; break }
    }
}
if (-not $MiFlashRoot) {
    throw "MiFlash not found. Pass -MiFlashRoot path to XiaoMiFlash.exe folder."
}
$MiFlashExe = Join-Path $MiFlashRoot "XiaoMiFlash.exe"
$MiFlashConfig = Join-Path $MiFlashRoot "XiaoMiFlash.exe.Config"
$LsUsb = Join-Path $MiFlashRoot "Source\ThirdParty\Qualcomm\fh_loader\lsusb.exe"

if (-not (Test-Path $MiFlashExe)) {
    throw "MiFlash not found: $MiFlashExe"
}

foreach ($sub in @("log", "restore", "tmp")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $MiFlashRoot $sub) | Out-Null
}

# Disable factory/PDL slot scan (adds Intel USB 8087:1024 as fake device)
[xml]$cfg = Get-Content $MiFlashConfig
$settings = @{}
foreach ($node in $cfg.configuration.appSettings.add) {
    $settings[$node.key] = $node
}
function Set-ConfigKey([string]$Key, [string]$Value) {
    if ($settings.ContainsKey($Key)) {
        $settings[$Key].value = $Value
    } else {
        $new = $cfg.CreateElement("add")
        $new.SetAttribute("key", $Key) | Out-Null
        $new.SetAttribute("value", $Value) | Out-Null
        [void]$cfg.configuration.appSettings.AppendChild($new)
        $settings[$Key] = $new
    }
}
Set-ConfigKey "EQPID" ""
Set-ConfigKey "isFactory" "0"
Set-ConfigKey "factory" "0"
Set-ConfigKey "firstinstall" "0"
Set-ConfigKey "pdlMaxNum" "0"
Set-ConfigKey "pdlWateTime" "0"
Set-ConfigKey "script" "flash_all.bat"
if ($RomDir -and (Test-Path (Join-Path $RomDir "flash_all.bat"))) {
    Set-ConfigKey "swPath" $RomDir
}
$cfg.Save($MiFlashConfig)

Write-Host "[fix] MiFlash root: $MiFlashRoot" -ForegroundColor Cyan
Write-Host "[fix] Created log/restore/tmp; script=flash_all.bat" -ForegroundColor Green
if ($RomDir) { Write-Host "[fix] ROM path: $RomDir" -ForegroundColor Green }

foreach ($debugIni in @(
    (Join-Path $MiFlashRoot "Debug.ini"),
    (Join-Path $MiFlashRoot "Source\ThirdParty\Inventec\Debug.ini")
)) {
    if (Test-Path $debugIni) {
        $bak = "$debugIni.disabled"
        if (-not (Test-Path $bak)) {
            Rename-Item $debugIni $bak
            Write-Host "[fix] disabled factory Debug.ini -> $(Split-Path $bak -Leaf)" -ForegroundColor Yellow
        }
    }
}

# Remove stale MiFlash logs (optional fresh session)
Get-ChildItem (Join-Path $MiFlashRoot "log") -Filter "miflash@*.txt" -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host "[fix] MiFlash config patched (PDL/factory scan off)" -ForegroundColor Green

# Show what is actually connected for EDL flash
Write-Host ""
Write-Host "USB scan (real EDL targets only):" -ForegroundColor Cyan
if (Test-Path $LsUsb) {
    $lsusbOut = & $LsUsb 2>&1 | Out-String
    if ($lsusbOut.Trim()) {
        Write-Host $lsusbOut.TrimEnd()
    } else {
        Write-Host "  (none — plug tablet in 9008 mode, then Refresh in MiFlash)"
    }
} else {
    Write-Host "  lsusb.exe not found"
}

$intelGhost = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
    $_.InstanceId -match 'VID_8087&PID_1024\\20170726905923'
}
if ($intelGhost) {
    Write-Host ""
    Write-Host "Ghost ID source (NOT your tablet — ignore in MiFlash if it still appears):" -ForegroundColor Yellow
    Write-Host "  $($intelGhost.FriendlyName) [$($intelGhost.InstanceId)]"
}

$edl = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
    $_.FriendlyName -match '9008|QDLoader'
}
Write-Host ""
if ($edl) {
    Write-Host "Real EDL device:" -ForegroundColor Green
    $edl | ForEach-Object { Write-Host "  $($_.FriendlyName)" }
    Write-Host "  -> Safe to Flash when MiFlash also shows COM port after Refresh"
} else {
    Write-Host "No 9008 EDL device connected right now." -ForegroundColor DarkGray
}

if ($Launch) {
    Start-Process -FilePath $MiFlashExe -WorkingDirectory $MiFlashRoot -Verb RunAs
    Write-Host ""
    Write-Host "MiFlash launched. Use Refresh; only flash if 9008/COM appears." -ForegroundColor Green
}
