#Requires -Version 5.1
<#
.SYNOPSIS
  One-command recovery for dagu test lab.

.PARAMETER Mode
  quick         - fastboot reboot to Android (boot partition untouched; default after chain boot)
  slot-other    - switch A/B slot and reboot
  restore-boot  - flash boot+vendor_boot for current slot from golden backup
  restore-all   - flash all backed-up partitions from golden backup
  edl           - print EDL / Mi Flash recovery instructions

.EXAMPLE
  .\tools\test-lab\lab.ps1 recover
  .\tools\test-lab\lab.ps1 recover restore-boot
#>
[CmdletBinding()]
param(
    [ValidateSet("quick", "slot-other", "restore-boot", "restore-all", "edl")]
    [string] $Mode = "quick",

    [string] $GoldenDir = ""
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "TestLab.psm1") -Force

$cfg = Get-TestLabConfig
$fastboot = Get-PlatformTool "fastboot"
$session = New-TestLabSession -Kind "recover-$Mode"
Write-Host "[recover] session -> $($session.Dir)" -ForegroundColor DarkGray

if ($Mode -eq "edl") {
    @"
[recover] EDL / 线刷救砖（fastboot 无响应时）

1. 关机，按住 电源 + 音量+ + 音量- 约 10 秒进入 EDL（或工具箱进 9008）
2. 设备管理器应出现 Qualcomm HS-USB QDLoader 9008
3. 使用小米官方线刷包（与当前 HyperOS 版本匹配）全量刷入
4. 线刷完成后重新解锁 BL（若需继续 WoA 实验）

Mi Flash ROM 路径（如已配置）: $($cfg.mi_flash_rom_path)
$($cfg.edl_note)
"@ | Tee-Object -FilePath (Join-Path $session.Dir "edl-instructions.txt")
    exit 0
}

try {
    Assert-FastbootReady
} catch {
    Write-Host $_ -ForegroundColor Red
    Write-Host "[recover] Device not in fastboot. Try: lab.ps1 recover edl" -ForegroundColor Yellow
    exit 1
}

Save-FastbootSnapshot -OutDir $session.Dir

switch ($Mode) {
    "quick" {
        Write-Host "[recover] fastboot reboot -> Android" -ForegroundColor Cyan
        $r = Invoke-LoggedCommand -FilePath $fastboot -ArgumentList @("reboot") -LogPath (Join-Path $session.Dir "fastboot-reboot.log")
        if ($r.ExitCode -ne 0) { throw "fastboot reboot failed" }
        Write-Host "[recover] OK. Device should boot Android." -ForegroundColor Green
    }
    "slot-other" {
        $cur = Get-FastbootVar "current-slot"
        $other = if ($cur -eq "a") { "b" } else { "a" }
        Write-Host "[recover] set_active $other + reboot" -ForegroundColor Cyan
        Invoke-LoggedCommand -FilePath $fastboot -ArgumentList @("set_active", $other) -LogPath (Join-Path $session.Dir "set_active.log") | Out-Null
        Invoke-LoggedCommand -FilePath $fastboot -ArgumentList @("reboot") -LogPath (Join-Path $session.Dir "fastboot-reboot.log") | Out-Null
        Write-Host "[recover] OK. Switched to slot $other" -ForegroundColor Green
    }
    "restore-boot" {
        $golden = if ($GoldenDir) { @{ Dir = (Resolve-Path $GoldenDir).Path } } else { Get-LatestGoldenBackup }
        if (-not $golden) { throw "No golden backup. Run: lab.ps1 backup" }
        $slot = Get-FastbootVar "current-slot"
        if (-not $slot) { $slot = "b" }
        $parts = @("boot_$slot", "vendor_boot_$slot", "vbmeta_$slot")
        foreach ($p in $parts) {
            $img = Join-Path $golden.Dir "$p.img"
            if (-not (Test-Path $img)) {
                Write-Host "[recover] WARN: missing $img, skip" -ForegroundColor Yellow
                continue
            }
            Write-Host "[recover] flash $p ..."
            $r = Invoke-LoggedCommand -FilePath $fastboot -ArgumentList @("flash", $p, $img) -LogPath (Join-Path $session.Dir "flash-$p.log")
            if ($r.ExitCode -ne 0) { throw "flash $p failed" }
        }
        Invoke-LoggedCommand -FilePath $fastboot -ArgumentList @("reboot") -LogPath (Join-Path $session.Dir "fastboot-reboot.log") | Out-Null
        Write-Host "[recover] OK. Boot partitions restored for slot $slot" -ForegroundColor Green
    }
    "restore-all" {
        $golden = if ($GoldenDir) { @{ Dir = (Resolve-Path $GoldenDir).Path } } else { Get-LatestGoldenBackup }
        if (-not $golden) { throw "No golden backup. Run: lab.ps1 backup" }
        $manifestPath = Join-Path $golden.Dir "manifest.json"
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        foreach ($entry in $manifest.partitions) {
            if (-not $entry.ok) { continue }
            $p = $entry.partition
            $img = Join-Path $golden.Dir "$p.img"
            if (-not (Test-Path $img)) { continue }
            Write-Host "[recover] flash $p ..."
            $r = Invoke-LoggedCommand -FilePath $fastboot -ArgumentList @("flash", $p, $img) -LogPath (Join-Path $session.Dir "flash-$p.log")
            if ($r.ExitCode -ne 0) { throw "flash $p failed" }
        }
        Invoke-LoggedCommand -FilePath $fastboot -ArgumentList @("reboot") -LogPath (Join-Path $session.Dir "fastboot-reboot.log") | Out-Null
        Write-Host "[recover] OK. All backed-up partitions restored" -ForegroundColor Green
    }
}

Write-SessionManifest -Session $session -Data @{ mode = $Mode; success = $true }
