#Requires -Version 5.1
<#
.SYNOPSIS
  Automated UEFI chain-boot test with USB/serial logging.

.EXAMPLE
  .\tools\test-lab\lab.ps1 test-uefi -AttachUsb
  .\tools\test-lab\lab.ps1 test-uefi -AttachUsb -AttachSerial -SerialPort COM5
#>
[CmdletBinding()]
param(
    [string] $Image = "",
    [switch] $AutoRecover,
    [switch] $SkipGoldenCheck,
    [switch] $AttachUsb,
    [switch] $AttachSerial,
    [Alias("AttachRemote")]
    [switch] $LegacyAttachRemote,
    [string] $SerialPort = "",
    [int] $ObserveSeconds = 60,
    [switch] $AllowNoSerial
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "TestLab.psm1") -Force

if ($LegacyAttachRemote) {
    Write-Host "[test-uefi] WARN: -AttachRemote -> -AttachUsb (USB v2)" -ForegroundColor Yellow
    $AttachUsb = $true
}

function Get-AvailableSerialPorts {
    param([string]$SerialPy)
    $lines = & python $SerialPy list 2>&1
    @($lines | ForEach-Object { "$_".Trim() } | Where-Object { $_ -and $_ -notmatch '^\(no serial' })
}

function Show-FullLogFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Title)
    if (-not (Test-Path $Path)) {
        Write-Host "[test-uefi] ERROR: log missing: $Path" -ForegroundColor Red
        return
    }
    $bytes = (Get-Item $Path).Length
    Write-Host "[test-uefi] $Title : $Path ($bytes bytes)" -ForegroundColor Cyan
    if ($bytes -eq 0) {
        Write-Host "[test-uefi] WARN: log file empty" -ForegroundColor Yellow
        return
    }
    Write-Host "`n========== $Title (full) ==========" -ForegroundColor Yellow
    Get-Content $Path -Encoding UTF8
    Write-Host "========== END $Title ==========" -ForegroundColor Yellow
}

$cfg = Get-TestLabConfig
$fastboot = Get-PlatformTool "fastboot"
$session = New-TestLabSession -Kind "uefi-boot"
$logDir = $session.Dir
$usbPy = Join-Path $PSScriptRoot "usb_log.py"
$serialPy = Join-Path $PSScriptRoot "serial_log.py"
$usbLog = Join-Path $logDir "uefi-usb-boot.log"
$serialLog = Join-Path $logDir "uefi-serial.log"
$usbProc = $null
$serialProc = $null
$serialPortUsed = ""

Write-Host "[test-uefi] session -> $logDir" -ForegroundColor DarkGray

if (-not $SkipGoldenCheck) {
    if (-not (Get-LatestGoldenBackup)) {
        Write-Host "[test-uefi] WARN: No golden backup. Recommend: lab.ps1 backup" -ForegroundColor Yellow
    }
}

try { Assert-FastbootReady } catch {
    Write-SessionManifest -Session $session -Data @{ success = $false; error = $_.Exception.Message }
    throw
}

$imgPath = if ($Image) { Resolve-RepoPath $Image } else { Get-CanonicalUefiImagePath }
try {
    $imgBytes = Assert-UefiArtifactPublished -ImagePath $imgPath
} catch {
    Write-SessionManifest -Session $session -Data @{ success = $false; error = $_.Exception.Message }
    throw
}
Write-Host "[test-uefi] image: $imgPath ($imgBytes bytes, published)" -ForegroundColor DarkGray

Save-FastbootSnapshot -OutDir $logDir
Copy-Item $imgPath (Join-Path $logDir (Split-Path $imgPath -Leaf))

if ($AttachUsb) {
    Write-Host "[test-uefi] AttachUsb -> usb_log watch (Type-C TESTLAB volume)" -ForegroundColor Cyan
    & python $usbPy preflight
    $usbArgs = @(
        $usbPy, "watch",
        "--log", $usbLog,
        "--timeout", [string]($cfg.usb_log_timeout_sec),
        "--poll", [string]$cfg.usb_log_poll_sec
    )
    $usbProc = Start-Process -FilePath "python" -ArgumentList $usbArgs -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 1
}

if ($AttachSerial) {
    & python $serialPy preflight
    $ports = Get-AvailableSerialPorts -SerialPy $serialPy
    if ($SerialPort) { $serialPortUsed = $SerialPort }
    elseif ($cfg.serial_port) { $serialPortUsed = [string]$cfg.serial_port }
    elseif ($ports.Count -eq 1) { $serialPortUsed = $ports[0] }
    elseif ($ports.Count -gt 1) { throw "Multiple COM ports; use -SerialPort" }
    elseif (-not $AllowNoSerial) {
        Write-Host "[test-uefi] WARN: no COM port; continuing USB-only" -ForegroundColor Yellow
    }
    if ($serialPortUsed) {
        New-Item -ItemType File -Force -Path $serialLog | Out-Null
        $serialArgs = @(
            $serialPy, "watch", "--port", $serialPortUsed,
            "--baud", [string]$cfg.serial_baud,
            "--log", $serialLog, "--quiet",
            "--duration", [string]($ObserveSeconds + 120)
        )
        $serialProc = Start-Process -FilePath "python" -ArgumentList $serialArgs -PassThru -WindowStyle Hidden
    }
}

Write-Host "[test-uefi] fastboot boot $(Split-Path $imgPath -Leaf)" -ForegroundColor Cyan
$bootLog = Join-Path $logDir "fastboot-boot.log"
$r = Invoke-LoggedCommand -FilePath $fastboot -ArgumentList @("boot", $imgPath) -LogPath $bootLog
$success = ($r.ExitCode -eq 0)

if ($success) {
    Write-Host "[test-uefi] Waiting ${ObserveSeconds}s for UEFI + USB MSC ..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $ObserveSeconds
    if ($AttachUsb) { Show-FullLogFile -Path $usbLog -Title "UEFI USB BOOT LOG" }
    if ($AttachSerial -and $serialPortUsed) { Show-FullLogFile -Path $serialLog -Title "UEFI UART LOG" }
} else {
    Write-Host "[test-uefi] FAILED exit $($r.ExitCode)" -ForegroundColor Red
    if ($AutoRecover) { & (Join-Path $PSScriptRoot "recover.ps1") -Mode quick }
}

foreach ($p in @($usbProc, $serialProc)) {
    if ($p -and -not $p.HasExited) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
}

Write-SessionManifest -Session $session -Data @{
    success = $success
    image = $imgPath
    fastboot_exit = $r.ExitCode
    observe_seconds = $ObserveSeconds
    attach_usb = [bool]$AttachUsb
    attach_serial = [bool]$AttachSerial
    usb_log = $usbLog
    usb_log_bytes = if (Test-Path $usbLog) { (Get-Item $usbLog).Length } else { 0 }
    serial_log = $serialLog
    serial_port = $serialPortUsed
}

Write-Host "[test-uefi] Logs: $logDir" -ForegroundColor Cyan
if (-not $success) { exit 1 }
