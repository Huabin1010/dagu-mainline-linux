#Requires -Version 5.1
<#
.SYNOPSIS
  Fix Qualcomm HS-USB QDLoader 9008 Code 52 (unsigned driver) and install signed driver.

.EXAMPLE
  .\tools\install-qdloader9008-driver.ps1
  .\tools\install-qdloader9008-driver.ps1 -FixCode52Only
#>
[CmdletBinding()]
param(
    [string] $DestRoot = "D:\rom\dagu-recovery\qdloader9008-driver",
    [switch] $SkipDownload,
    [switch] $FixCode52Only
)

$ErrorActionPreference = "Stop"

function Get-QdLoaderDevices {
    Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -match 'VID_05C6&PID_9008' -or $_.FriendlyName -match '9008|QDLoader'
    }
}

function Fix-UnsignedQdLoaderDriver {
    $devices = Get-QdLoaderDevices
    if (-not $devices) {
        Write-Host "[driver] No 9008 device connected (plug tablet in EDL, then rerun if needed)." -ForegroundColor Yellow
    }

    $badDrivers = @()
    foreach ($dev in $devices) {
        $detail = pnputil /enum-devices /instanceid $dev.InstanceId /drivers 2>&1 | Out-String
        if ($detail -match 'Driver Name:\s+(\S+)' -or $detail -match '驱动程序名称:\s+(\S+)') {
            # parse active driver from output lines containing oem*.inf with error state
        }
        if ($dev.ConfigManagerErrorCode -eq 52 -or $dev.Problem -match 'UNSIGNED') {
            Write-Host "[driver] Code 52 on: $($dev.FriendlyName)" -ForegroundColor Yellow
        }
    }

    # Remove unsigned qcser packages (Test003 signer), keep Microsoft-signed oem48
    $enum = pnputil /enum-drivers 2>&1 | Out-String
    $toDelete = @()
    foreach ($block in ($enum -split '(?=发布名称:)')) {
        if ($block -notmatch 'qcser\.inf') { continue }
        if ($block -match 'USBHostDriver\(Test003\)' -and $block -match '发布名称:\s+(\S+)') {
            $toDelete += $Matches[1]
        }
    }
    $toDelete = $toDelete | Select-Object -Unique
    foreach ($oem in $toDelete) {
        Write-Host "[driver] Removing unsigned package: $oem" -ForegroundColor Cyan
        pnputil /delete-driver $oem /uninstall /force 2>&1 | Out-Null
    }

    foreach ($dev in $devices) {
        Write-Host "[driver] Rebind device: $($dev.InstanceId)" -ForegroundColor Cyan
        pnputil /remove-device $dev.InstanceId /force 2>&1 | Out-Null
    }

    Start-Sleep -Seconds 2
    if (Test-Path "C:\Windows\INF\oem48.inf") {
        pnputil /add-driver "C:\Windows\INF\oem48.inf" /install 2>&1 | Out-Null
    }
    pnputil /scan-devices 2>&1 | Out-Null
    Start-Sleep -Seconds 2

    $after = Get-QdLoaderDevices
    if ($after) {
        $after | ForEach-Object {
            $color = if ($_.Status -eq 'OK') { 'Green' } else { 'Yellow' }
            Write-Host "[driver] $($_.FriendlyName) status=$($_.Status) error=$($_.ConfigManagerErrorCode)" -ForegroundColor $color
        }
    } else {
        Write-Host "[driver] Unplug/replug USB to re-enumerate 9008 device." -ForegroundColor Yellow
    }
}

Write-Host "[driver] MiFlash 'Install Driver' flashes: Driver\ folder only has .url links, no installer." -ForegroundColor DarkGray

Fix-UnsignedQdLoaderDriver

if ($FixCode52Only) { exit 0 }

if (-not $SkipDownload) {
    $DriverZipUrl = "https://raw.githubusercontent.com/AzimsTech/Android_Hacking/master/Drivers/QDLoader-HS-USB-Driver.zip"
    $DriverZip = Join-Path $DestRoot "QDLoader-HS-USB-Driver.zip"
    $DriverDir = Join-Path $DestRoot "extracted"
    New-Item -ItemType Directory -Force -Path $DestRoot | Out-Null

    if (-not (Test-Path $DriverZip) -or (Get-Item $DriverZip).Length -lt 100000) {
        Write-Host "[driver] Downloading signed driver installer..." -ForegroundColor Cyan
        & curl.exe -L --fail -o $DriverZip $DriverZipUrl
        if ($LASTEXITCODE -ne 0) { throw "Download failed: $DriverZipUrl" }
    }

    if (Test-Path $DriverDir) { Remove-Item $DriverDir -Recurse -Force }
    Expand-Archive -Path $DriverZip -DestinationPath $DriverDir -Force
    $setupExe = Get-ChildItem -Path $DriverDir -Recurse -Filter "*64bit*Setup*.exe" | Select-Object -First 1
    if ($setupExe) {
        Write-Host "[driver] Running: $($setupExe.Name)" -ForegroundColor Cyan
        Start-Process -FilePath $setupExe.FullName -ArgumentList "/S" -Wait
        Fix-UnsignedQdLoaderDriver
    }
}

Write-Host ""
Write-Host "[driver] Done. Device Manager should show 9008 with NO yellow triangle." -ForegroundColor Green
Write-Host "[driver] Then MiFlash -> Refresh -> clean all -> Flash" -ForegroundColor Green
