#Requires -Version 5.1
<#
.SYNOPSIS
  Flash dagu via Qualcomm EDL tools (QSaharaServer + fh_loader), bypassing MiFlash GUI.

  MiFlash internally uses the same Qualcomm stack. This script exposes it directly.
  Does NOT lock bootloader (no flash_all_lock.bat).

  IMPORTANT (Xiaomi SM8250 / dagu):
  - Stock firehose in official ROM often requires Mi account EDL auth.
  - If Sahara/hello fails, power-cycle EDL first (unplug, hold power 30s, replug USB2).
  - If firehose auth fails, you need an unlocked sm8250 firehose (see docs below).

.EXAMPLE
  .\tools\flash-dagu-edl.ps1
  .\tools\flash-dagu-edl.ps1 -RomDir "D:\Download\Edge\小米平板5Pro12.4降级小包"
  .\tools\flash-dagu-edl.ps1 -ComPort COM20 -SaharaOnly
  .\tools\flash-dagu-edl.ps1 -SkipSahara
#>
[CmdletBinding()]
param(
    [string] $RomDir = "D:\rom\dagu-recovery\dagu_images_OS2.0.10.0.ULZCNXM\dagu_images_OS2.0.10.0.ULZCNXM_14.0",
    [string] $ToolsDir = "D:\rom\dagu-recovery\MiFlash20220507\MiFlash20220507",
    [string] $ComPort = "",
    [string] $Firehose = "prog_ufs_firehose_sm8250_ddr_5.elf",
    [switch] $SaharaOnly,
    [switch] $SkipSahara
)

$ErrorActionPreference = "Stop"

$Images = Join-Path $RomDir "images"
$QSahara = Join-Path $ToolsDir "QSaharaServer.exe"
$FhLoader = Join-Path $ToolsDir "fh_loader.exe"

foreach ($p in @($RomDir, $Images, $QSahara, $FhLoader)) {
    if (-not (Test-Path $p)) { throw "Missing: $p" }
}
$FirehosePath = Join-Path $Images $Firehose
if (-not (Test-Path $FirehosePath)) { throw "Firehose not found: $FirehosePath" }

if (-not $ComPort) {
    $edl = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
        $_.FriendlyName -match '9008|QDLoader'
    } | Select-Object -First 1
    if (-not $edl) { throw "No 9008 device. Plug tablet in EDL (Qualcomm HS-USB QDLoader 9008)." }
    if ($edl.FriendlyName -match 'COM(\d+)') { $ComPort = "COM$($Matches[1])" }
    else {
        $ports = [System.IO.Ports.SerialPort]::GetPortNames()
        if ($ports.Count -eq 1) { $ComPort = $ports[0] }
        else { throw "Specify -ComPort (detected EDL: $($edl.FriendlyName), ports: $($ports -join ', '))" }
    }
}
$PortArg = "\\.\$ComPort"

$superBytes = (Get-Item (Join-Path $Images "super.img") -ErrorAction SilentlyContinue).Length
$isSmallPack = $superBytes -lt 10MB

Write-Host "=== dagu EDL flash (Qualcomm fh_loader) ===" -ForegroundColor Cyan
Write-Host "COM port:     $PortArg"
Write-Host "Firehose:     $FirehosePath"
Write-Host "ROM images:   $Images"
if ($isSmallPack) {
    Write-Host "Package type: DOWNGRADE small pack (super ~$([math]::Round($superBytes/1KB,1)) KB)" -ForegroundColor Yellow
    Write-Host "  -> Restores GPT + boot chain only. Run again with full HyperOS ROM after this." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "If Sahara fails: unplug USB, hold POWER 30s, plug USB2 rear port, rerun." -ForegroundColor Yellow
Write-Host "If auth fails: use MiFlash logged into Mi account (EDL signature popup)." -ForegroundColor Yellow
Write-Host ""

if (-not $SkipSahara) {
    Write-Host "[1/2] Sahara: upload firehose programmer ..." -ForegroundColor Cyan
    Push-Location $ToolsDir
    try {
        & $QSahara -p $PortArg -s "13:$FirehosePath"
        if ($LASTEXITCODE -ne 0) {
            throw "QSaharaServer failed ($LASTEXITCODE). EDL hello timeout — power-cycle device and retry."
        }
    } finally {
        Pop-Location
    }
    Write-Host "[1/2] Sahara OK" -ForegroundColor Green
    if ($SaharaOnly) { return }
    Start-Sleep -Seconds 3
}

$rawPrograms = Get-ChildItem $Images -Filter "rawprogram*.xml" | Sort-Object Name
$patchFiles = Get-ChildItem $Images -Filter "patch*.xml" | Sort-Object Name

Write-Host "[2/2] Firehose: flash rawprogram XML ($($rawPrograms.Count) files) ..." -ForegroundColor Cyan
Write-Host "  (super.img ~8GB — total time 15-40 min, do not unplug)" -ForegroundColor DarkGray

Push-Location $ToolsDir
try {
    foreach ($rp in $rawPrograms) {
        $lun = if ($rp.Name -match 'rawprogram(\d+)') { $Matches[1] } else { "0" }
        Write-Host "  -> $($rp.Name) (lun=$lun)" -ForegroundColor Cyan
        $args = @(
            "--port=$PortArg",
            "--memoryname=UFS",
            "--search_path=$Images",
            "--sendxml=$($rp.FullName)",
            "--showpercentagecomplete",
            "--noprompt",
            "--zlpawarehost=1",
            "--skipstorageinit=0"
        )
        $patch = Join-Path $Images ("patch$lun.xml")
        if (Test-Path $patch) {
            $args += "--patchxml=$patch"
        }
        & $FhLoader @args
        if ($LASTEXITCODE -ne 0) {
            throw "fh_loader failed on $($rp.Name) exit=$LASTEXITCODE (auth? wrong firehose? USB drop?)"
        }
    }
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "=== EDL flash finished ===" -ForegroundColor Green
Write-Host "Device should reboot. Then verify: fastboot getvar unlocked  ->  yes"
