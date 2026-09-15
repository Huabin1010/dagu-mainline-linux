#Requires -Version 5.1
<#
.SYNOPSIS
  Chain-boot the verified artifacts/boot-dagu-latest.img (never repo root).
.EXAMPLE
  .\tools\boot-dagu.ps1
  .\tools\boot-dagu.ps1 -Device <android-serial>
#>
[CmdletBinding()]
param(
    [string] $Device = "",
    [switch] $SkipVerify,
    [switch] $NoReboot
)

$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $Root "tools/test-lab/TestLab.psm1") -Force

$img = Get-CanonicalUefiImagePath
if (-not $SkipVerify) {
    Assert-UefiArtifactPublished -ImagePath $img | Out-Null
}
Remove-StaleBootImageCopies | Out-Null

$fastboot = Get-PlatformTool "fastboot"
$adb = Get-PlatformTool "adb"

$devArgs = @()
if ($Device) { $devArgs = @("-s", $Device) }

Write-Host "[boot-dagu] image: $img ($((Get-Item $img).Length) bytes)" -ForegroundColor Cyan

if (-not $NoReboot) {
    Write-Host "[boot-dagu] reboot -> bootloader" -ForegroundColor DarkGray
    & $adb @devArgs reboot bootloader
    $deadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Seconds 2
        $fb = & $fastboot @devArgs devices 2>&1 | Out-String
        if ($fb -match 'fastboot') { break }
    } while ((Get-Date) -lt $deadline)
    if ($fb -notmatch 'fastboot') {
        throw "Device did not enter fastboot within 30s"
    }
}

Write-Host "[boot-dagu] fastboot boot ..." -ForegroundColor Cyan
& $fastboot @devArgs boot $img
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "[boot-dagu] OK" -ForegroundColor Green
