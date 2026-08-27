#Requires -Version 5.1
<#
.SYNOPSIS
  dagu 可恢复测试实验室 — 统一入口

.EXAMPLE
  .\tools\test-lab\lab.ps1 status
  .\tools\test-lab\lab.ps1 backup          # 首次必做：黄金备份
  .\tools\test-lab\lab.ps1 test-uefi       # 链式引导 UEFI（不写分区）
  .\tools\test-lab\lab.ps1 recover         # 快速回 Android
  .\tools\test-lab\lab.ps1 recover restore-boot
  .\tools\test-lab\lab.ps1 logs            # 查看最近一次测试日志
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("status", "backup", "test-uefi", "recover", "logs", "usb-debug", "usb-log", "serial-log", "help")]
    [string] $Action = "status",

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $ScriptArgs
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "TestLab.psm1") -Force

function Show-Status {
    $cfg = Get-TestLabConfig
    Write-Host "=== dagu Test Lab ===" -ForegroundColor Cyan
    Write-Host "Repo:    $($cfg.RepoRoot)"
    Write-Host "UEFI img: $($cfg.uefi_test_image)"

    $golden = Get-LatestGoldenBackup
    if ($golden) {
        Write-Host "Golden:  $($golden.Dir)" -ForegroundColor Green
    } else {
        Write-Host "Golden:  (none) -> run: lab.ps1 backup" -ForegroundColor Yellow
    }

    $last = Get-LastTestSession
    if ($last) {
        Write-Host "Last log: $($last.FullName)" -ForegroundColor Green
        $mf = Join-Path $last.FullName "manifest.json"
        if (Test-Path $mf) {
            $m = Get-Content $mf -Raw | ConvertFrom-Json
            Write-Host "  success=$($m.success) id=$($m.session_id)"
        }
    }

    try {
        $fb = Get-PlatformTool "fastboot"
        $tmp = [System.IO.Path]::GetTempFileName()
        $r = Invoke-LoggedCommand -FilePath $fb -ArgumentList @("devices") -LogPath $tmp
        if ($r.StdOut -match "fastboot") {
            Write-Host "Fastboot: connected" -ForegroundColor Green
            $prod = Get-FastbootVar "product"
            $slot = Get-FastbootVar "current-slot"
            Write-Host "  product=$prod slot=$slot"
        } else {
            Write-Host "Fastboot: not connected" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "Fastboot: tools not ready" -ForegroundColor DarkGray
    }
}

function Show-Logs {
    $last = Get-LastTestSession
    if (-not $last) {
        Write-Host "No test sessions yet."
        return
    }
    Write-Host "Session: $($last.FullName)" -ForegroundColor Cyan
    Get-ChildItem $last.FullName -File | Sort-Object Name | ForEach-Object {
        Write-Host "  $($_.Name) ($($_.Length) bytes)"
    }
    $bootLog = Join-Path $last.FullName "fastboot-boot.log"
    if (Test-Path $bootLog) {
        Write-Host "`n--- fastboot boot (tail) ---" -ForegroundColor DarkGray
        Get-Content $bootLog -Tail 20
    }
    $mf = Join-Path $last.FullName "manifest.json"
    if (Test-Path $mf) {
        Write-Host "`n--- manifest ---" -ForegroundColor DarkGray
        Get-Content $mf
    }
}

function Show-Help {
    @"
dagu Test Lab — 可恢复 UEFI 测试

  首次 setup:
    1. 平板进 fastboot（电源 + 音量下）
    2. .\tools\test-lab\lab.ps1 backup      # 备份 boot/vbmeta 等
    3. .\tools\test-lab\lab.ps1 test-uefi   # 链式引导（不 flash）

  日常:
    lab.ps1 status
    lab.ps1 test-uefi [-AutoRecover]
    lab.ps1 usb-debug [-Mode adb|fastboot|auto]
    lab.ps1 test-uefi [-AttachUsb] [-AttachSerial]
    lab.ps1 usb-log preflight|discover|watch|dump|status|send
    lab.ps1 serial-log list|preflight|watch [--log path] [--port COMx]
    lab.ps1 logs

  救砖（由轻到重）:
    lab.ps1 recover                 # reboot 回 Android（链式引导后首选）
    lab.ps1 recover slot-other      # 切换 A/B slot
    lab.ps1 recover restore-boot    # 从 golden 恢复当前 slot boot
    lab.ps1 recover restore-all     # 恢复所有已备份分区
    lab.ps1 recover edl             # fastboot 无响应 → EDL 线刷说明

  文档: docs/test-lab-workflow.md
"@
}

function Invoke-ChildScript {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$ForwardArgs = @()
    )
    if (-not $ForwardArgs -or $ForwardArgs.Count -eq 0) {
        & $ScriptPath
        return
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @ForwardArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

switch ($Action) {
    "status" { Show-Status }
    "backup" { & (Join-Path $PSScriptRoot "backup-golden.ps1") }
    "test-uefi" { Invoke-ChildScript -ScriptPath (Join-Path $PSScriptRoot "test-uefi-boot.ps1") -ForwardArgs $ScriptArgs }
    "recover" {
        $mode = if ($ScriptArgs.Count -gt 0) { $ScriptArgs[0] } else { "quick" }
        $rest = if ($ScriptArgs.Count -gt 1) { $ScriptArgs[1..($ScriptArgs.Count - 1)] } else { @() }
        & (Join-Path $PSScriptRoot "recover.ps1") -Mode $mode @rest
    }
    "logs" { Show-Logs }
    "usb-debug" { Invoke-ChildScript -ScriptPath (Join-Path $PSScriptRoot "usb-debug.ps1") -ForwardArgs $ScriptArgs }
    "usb-log" {
        $sub = if ($ScriptArgs.Count -gt 0) { $ScriptArgs[0] } else { "watch" }
        $rest = if ($ScriptArgs.Count -gt 1) { $ScriptArgs[1..($ScriptArgs.Count - 1)] } else { @() }
        & (Join-Path $PSScriptRoot "usb-log.ps1") -Action $sub @rest
    }
    "serial-log" {
        $sub = if ($ScriptArgs.Count -gt 0) { $ScriptArgs[0] } else { "watch" }
        $rest = if ($ScriptArgs.Count -gt 1) { $ScriptArgs[1..($ScriptArgs.Count - 1)] } else { @() }
        & (Join-Path $PSScriptRoot "serial-log.ps1") -Action $sub @rest
    }
    "help" { Show-Help }
}
