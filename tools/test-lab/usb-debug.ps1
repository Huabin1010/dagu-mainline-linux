#Requires -Version 5.1
<#
.SYNOPSIS
  Wait for dagu USB connection (fastboot/adb) and capture debug state.

.EXAMPLE
  .\tools\test-lab\usb-debug.ps1
  .\tools\test-lab\usb-debug.ps1 -Mode adb -TimeoutSec 120
  .\tools\test-lab\lab.ps1 usb-debug
#>
[CmdletBinding()]
param(
    [ValidateSet("auto", "adb", "fastboot")]
    [string] $Mode = "auto",
    [int] $TimeoutSec = 90,
    [switch] $ListUsb
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "TestLab.psm1") -Force

$adb = Get-PlatformTool "adb"
$fastboot = Get-PlatformTool "fastboot"
$session = New-TestLabSession -Kind "usb-debug"
$logDir = $session.Dir

function Get-DeviceState {
    $adbOut = & $adb devices 2>&1 | Out-String
    $fbOut = & $fastboot devices 2>&1 | Out-String
    $state = @{
        adb = ($adbOut -match "`tdevice")
        fastboot = ($fbOut -match "`tfastboot")
        adb_raw = $adbOut.Trim()
        fastboot_raw = $fbOut.Trim()
    }
    return $state
}

function Save-UsbSnapshot {
    param([hashtable]$State)
    $State | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $logDir "usb-state.json") -Encoding UTF8
    try {
        Get-PnpDevice -Class USB -Status OK -ErrorAction SilentlyContinue |
            Select-Object FriendlyName, InstanceId |
            ConvertTo-Json | Set-Content (Join-Path $logDir "usb-pnp.json") -Encoding UTF8
    } catch {
        "pnp unavailable: $($_.Exception.Message)" | Set-Content (Join-Path $logDir "usb-pnp.json")
    }
}

if ($ListUsb) {
    Write-Host "[usb-debug] Current USB devices:" -ForegroundColor Cyan
    Get-PnpDevice -Class USB -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq "OK" } |
        ForEach-Object { Write-Host "  $($_.FriendlyName)" }
}

Write-Host "[usb-debug] session -> $logDir" -ForegroundColor DarkGray
Write-Host "[usb-debug] waiting up to ${TimeoutSec}s for mode=$Mode" -ForegroundColor Cyan

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$found = $false
$last = $null

while ((Get-Date) -lt $deadline) {
    $last = Get-DeviceState
    $ok = switch ($Mode) {
        "adb" { $last.adb }
        "fastboot" { $last.fastboot }
        default { $last.adb -or $last.fastboot }
    }
    if ($ok) {
        $found = $true
        break
    }
    Start-Sleep -Seconds 2
}

Save-UsbSnapshot -State $last

if (-not $found) {
    Write-Host "[usb-debug] TIMEOUT - no device in requested mode" -ForegroundColor Yellow
    Write-Host "[usb-debug] adb:`n$($last.adb_raw)" -ForegroundColor DarkGray
    Write-Host "[usb-debug] fastboot:`n$($last.fastboot_raw)" -ForegroundColor DarkGray
    Write-SessionManifest -Session $session -Data @{ success = $false; mode = $Mode }
    exit 1
}

if ($last.fastboot) {
    Write-Host "[usb-debug] fastboot connected" -ForegroundColor Green
    & $fastboot getvar product 2>&1 | Tee-Object (Join-Path $logDir "fastboot-getvar.log")
} elseif ($last.adb) {
    Write-Host "[usb-debug] adb connected" -ForegroundColor Green
    & $adb shell getprop ro.product.device 2>&1 | Tee-Object (Join-Path $logDir "adb-device.log")
}

Write-Host "[usb-debug] UEFI USB tips:" -ForegroundColor DarkGray
Write-Host "  - Boot Simple Init or UEFI Shell from the menu (Mass Storage / LSMS removed)" -ForegroundColor DarkGray
Write-Host "  - Serial debug: UART (if wired); USB serial depends on UsbfnDwc3 + host driver" -ForegroundColor DarkGray

Write-SessionManifest -Session $session -Data @{
    success = $true
    mode = $Mode
    adb = $last.adb
    fastboot = $last.fastboot
}
Write-Host "[usb-debug] logs -> $logDir" -ForegroundColor Green
