#Requires -Version 5.1
<#
.SYNOPSIS
  SpaceX-style gate tests for dagu UEFI boot UX (pre-flash / post-build).

  These are deterministic static + artifact gates. They catch the regressions
  that previously shipped: Shell auto-boot, missing BootManagerMenuApp,
  volume keys only on ConIn, Misc Device spam, stale Windows artifacts.

.EXAMPLE
  .\tools\test-lab\test-dagu-boot-gates.ps1
  .\tools\test-lab\test-dagu-boot-gates.ps1 -RequireArtifact
#>
[CmdletBinding()]
param(
    [switch] $RequireArtifact
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$Failed = New-Object System.Collections.Generic.List[string]
$Passed = 0

function Gate {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    try {
        & $Body
        Write-Host "  PASS  $Name" -ForegroundColor Green
        $script:Passed++
    } catch {
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor DarkRed
        $script:Failed.Add("$Name :: $($_.Exception.Message)") | Out-Null
    }
}

function Assert-FileContains {
    param([string]$Path, [string]$Pattern, [string]$Hint)
    if (-not (Test-Path $Path)) { throw "missing file: $Path" }
    $text = Get-Content $Path -Raw
    if ($text -notmatch $Pattern) {
        throw "pattern /$Pattern/ not found in $Path — $Hint"
    }
}

function Assert-FileNotContains {
    param([string]$Path, [string]$Pattern, [string]$Hint)
    if (-not (Test-Path $Path)) { throw "missing file: $Path" }
    $text = Get-Content $Path -Raw
    if ($text -match $Pattern) {
        throw "forbidden pattern /$Pattern/ in $Path — $Hint"
    }
}

Write-Host "`n=== dagu boot gates (repo=$Root) ===" -ForegroundColor Cyan

# --- A. Boot policy / PlatformBm ---
Gate "A1 PlatformBm forces interactive BootManagerMenu loop" {
    Assert-FileContains (Join-Path $Root "port/dagu/Platform/RenegadePkg/Library/PlatformBootManagerLib/PlatformBm.c") `
        "PlatformDaguEnterInteractiveBootMenu" "menu loop missing"
}
Gate "A2 PlatformBm does not call RefreshAllBootOption (Misc Device source)" {
    $p = Join-Path $Root "port/dagu/Platform/RenegadePkg/Library/PlatformBootManagerLib/PlatformBm.c"
    $text = Get-Content $p -Raw
    if ($text -match '(?m)^\s*EfiBootManagerRefreshAllBootOption\s*\(') {
        throw "live RefreshAll call still present — creates Misc Device spam"
    }
}
Gate "A3 PlatformBm prunes non-firmware boot options" {
    Assert-FileContains (Join-Path $Root "port/dagu/Platform/RenegadePkg/Library/PlatformBootManagerLib/PlatformBm.c") `
        "PlatformDaguPruneNonFirmwareBootOptions" "prune helper missing"
}
Gate "A4 PlatformBm does not register USB Mass Storage" {
    Assert-FileNotContains (Join-Path $Root "port/dagu/Platform/RenegadePkg/Library/PlatformBootManagerLib/PlatformBm.c") `
        "USB Mass Storage" "Mass Storage boot option must stay removed"
    Assert-FileNotContains (Join-Path $Root "port/dagu/Platform/Xiaomi/sm8250/dagu.dsc") `
        "ENABLE_LINUX_SIMPLE_MASS_STORAGE" "LSMS compile flag must stay off"
}
Gate "A5 PlatformBm connects ALL TextInEx as ConIn" {
    Assert-FileContains (Join-Path $Root "port/dagu/Platform/RenegadePkg/Library/PlatformBootManagerLib/PlatformBm.c") `
        "register ALL TextInEx" "ConIn multi-handle fix missing"
}
Gate "A6 No BootNext trap to APP menu" {
    Assert-FileNotContains (Join-Path $Root "port/dagu/Platform/RenegadePkg/Library/PlatformBootManagerLib/PlatformBm.c") `
        "BootNext -> Boot Manager" "legacy BootNext path returned"
}

# --- B. BootManagerMenu key path ---
$Bm = Join-Path $Root "port/dagu/Common/edk2/MdeModulePkg/Application/BootManagerMenuApp/BootManagerMenu.c"
Gate "B1 BootManagerMenu multi-ConIn poll exists" {
    Assert-FileContains $Bm "DaguReadAnyKey" "multi-device key poll missing"
}
Gate "B2 BootManagerMenu maps volume + brightness + arrows to navigate" {
    Assert-FileContains $Bm "SCAN_VOLUME_UP" "volume up missing"
    Assert-FileContains $Bm "SCAN_VOLUME_DOWN" "volume down missing"
    Assert-FileContains $Bm "DaguKeyIsUp" "up classifier missing"
    Assert-FileContains $Bm "DaguKeyIsDown" "down classifier missing"
}
Gate "B3 BootManagerMenu power/suspend confirms selection" {
    Assert-FileContains $Bm "SCAN_SUSPEND" "power/suspend confirm missing"
    Assert-FileContains $Bm "DaguKeyIsConfirm" "confirm classifier missing"
}
Gate "B4 BootManagerMenu does not WaitForEvent only on ConIn" {
    Assert-FileNotContains $Bm "WaitForEvent \(1, &gST->ConIn->WaitForKey" `
        "blocking solely on ConIn regresses volume keys"
}
Gate "B5 BootManagerMenuApp.inf consumes SimpleTextIn protocol" {
    Assert-FileContains (Join-Path $Root "port/dagu/Common/edk2/MdeModulePkg/Application/BootManagerMenuApp/BootManagerMenuApp.inf") `
        "gEfiSimpleTextInProtocolGuid" "INF must declare SimpleTextIn for link"
}
Gate "B6 BootManagerMenu must not RefreshAllBootOption (Misc Device re-inject)" {
    Assert-FileNotContains $Bm "EfiBootManagerRefreshAllBootOption\s*\(" `
        "menu app RefreshAll recreates Misc Device spam after PlatformBm prune"
}
Gate "B7 BootManagerMenu ignores non-firmware-volume boot options" {
    Assert-FileContains $Bm "MEDIA_PIWG_FW_FILE_DP" "FV-only menu filter missing"
}
Gate "B8 BootManagerMenu polls SimpleTextInEx (ButtonsDxe)" {
    Assert-FileContains $Bm "ReadKeyStrokeEx" "TextInEx poll missing"
    Assert-FileContains $Bm "gEfiSimpleTextInputExProtocolGuid" "TextInEx GUID missing"
}
Gate "B9 dagu uses HOME-skip patched elish ButtonsDxe" {
    Assert-FileContains (Join-Path $Root "port/dagu/Platform/Xiaomi/sm8250/dagu.fdf.inc") `
        "ButtonsDxe.dagu.efi" "dagu-patched ButtonsDxe required (HOME GPIO skip)"
    Assert-FileContains (Join-Path $Root "tools/patch-buttons-skip-home.py") `
        "force platform type MTP" "MTP key-map force patch missing"
    Assert-FileContains (Join-Path $Root "port/dagu/Common/edk2/MdeModulePkg/Application/BootManagerMenuApp/BootManagerMenu.c") `
        "UEFI-ONLY" "popup title fingerprint missing — user cannot verify image"
}
Gate "B8 Mass Storage / LSMS hacks removed" {
    Assert-FileNotContains (Join-Path $Root "port/dagu/Platform/RenegadePkg/Library/PlatformBootManagerLib/PlatformBm.c") `
        "PlatformDaguEnsureFdtConfigurationTable" "FDT-for-MSC helper must be gone"
    Assert-FileNotContains (Join-Path $Root "port/dagu/Platform/RenegadePkg/Library/PlatformBootManagerLib/PlatformBm.c") `
        "PlatformDaguReleaseUsbForLinuxMassStorage" "USB-release-for-MSC helper must be gone"
    Assert-FileNotContains (Join-Path $Root "port/dagu/Platform/Xiaomi/sm8250/dagu.fdf.inc") `
        "sm8250-generic-msd.dtb" "LSMS DTB must not be in FDF"
    Assert-FileNotContains $Bm "DaguReleaseUsbForMassStorage" "menu USB release must be gone"
    Assert-FileNotContains (Join-Path $Root "port/dagu/Silicon/Qualcomm/QcomPkg/Drivers/TestLabBridgeDxe/TestLabBridgeDxe.c") `
        "gLinuxSimpleMassStorageGuid" "TestLab must not StartImage LSMS"
    Assert-FileNotContains (Join-Path $Root "port/dagu/Silicon/Qualcomm/QcomPkg/Drivers/TestLabBridgeDxe/TestLabBridgeDxe.inf") `
        "gLinuxSimpleMassStorageGuid" "TestLab INF must not reference LSMS GUID"
    if (Test-Path (Join-Path $Root "tools/lsms/build-lsms.sh")) {
        throw "tools/lsms/build-lsms.sh still present — LSMS tooling should be removed"
    }
    Assert-FileContains (Join-Path $Root "tools/apply-dagu-port.sh") `
        "strip LinuxSimpleMassStorage" "apply-dagu-port must drop stock LSMS from sm8250 FV"
}
Gate "B8b TestLab bridge hard-disabled" {
    Assert-FileContains (Join-Path $Root "port/dagu/Silicon/Qualcomm/QcomPkg/Include/Guid/TestLabBridgeGuid.h") `
        "TESTLAB_ENABLE_BRIDGE       0" "TestLab bridge must stay off"
}
Gate "B10 apply-dagu-port patches Apriori ButtonsDxe to dagu binary" {
    Assert-FileContains (Join-Path $Root "tools/apply-dagu-port.sh") `
        "ButtonsDxe.dagu.efi" "Apriori ButtonsDxe dagu patch missing"
    Assert-FileContains (Join-Path $Root "tools/apply-dagu-port.sh") `
        "strip LinuxSimpleMassStorage" "must drop stock LSMS from sm8250 FV"
}

# --- C. DSC / FDF product config ---
$Dsc = Join-Path $Root "port/dagu/Platform/Xiaomi/sm8250/dagu.dsc"
$Fdf = Join-Path $Root "port/dagu/Platform/Xiaomi/sm8250/dagu.fdf.inc"
Gate "C1 ENABLE_SIMPLE_INIT compile flag" {
    Assert-FileContains $Dsc "ENABLE_SIMPLE_INIT" "Simple Init flag missing"
}
Gate "C1b ENABLE_LINUX_SIMPLE_MASS_STORAGE must stay off" {
    Assert-FileNotContains $Dsc "ENABLE_LINUX_SIMPLE_MASS_STORAGE" "LSMS must not be compiled in"
}
Gate "C3 PcdBootManagerMenuFile is BootManagerMenuApp (not UiApp)" {
    Assert-FileContains $Dsc "0xdc, 0x5b, 0xc2, 0xee" "PCD must be BootManagerMenuApp GUID"
    Assert-FileNotContains $Dsc "0x21, 0xaa, 0x2c, 0x46, 0x14, 0x76, 0x03, 0x45" `
        "UiApp GUID must not be BootManagerMenuFile"
}
Gate "C4 FDF includes BootManagerMenuApp" {
    Assert-FileContains $Fdf "BootManagerMenuApp.inf" "BootManagerMenuApp not in FV"
}
Gate "C5 Boot timeout disabled (no 3s auto-Shell)" {
    Assert-FileContains $Dsc "PcdPlatformBootTimeOut\|0" "timeout must be 0"
}
Gate "C6 Landscape + 150% scale PCDs present" {
    Assert-FileContains $Dsc "PcdMipiFrameBufferRotation\|90" "rotation missing"
    Assert-FileContains $Dsc "PcdMipiFrameBufferConsoleScale\|150" "scale missing"
}

# --- D. Artifact reliability ---
Gate "D1 build writes sha256 stamp" {
    Assert-FileContains (Join-Path $Root "tools/build-dagu-uefi.sh") `
        "write_boot_artifact_stamp" "build must stamp artifacts locally"
    Assert-FileContains (Join-Path $Root "tools/build-dagu-uefi.sh") `
        "sha256=" "sha256 stamp missing"
}
Gate "D2 verify-boot-artifact.sh checks stamp" {
    Assert-FileContains (Join-Path $Root "tools/verify-boot-artifact.sh") `
        "missing stamp" "verify must require stamp"
}
Gate "D3 bootstrap-workspace.sh clones edk2-msm" {
    if (-not (Test-Path (Join-Path $Root "tools/bootstrap-workspace.sh"))) {
        throw "tools/bootstrap-workspace.sh missing"
    }
}
Gate "D4 boot-dagu.ps1 uses canonical artifacts path only" {
    Assert-FileContains (Join-Path $Root "tools/boot-dagu.ps1") `
        "Get-CanonicalUefiImagePath" "boot script must not accept root boot-dagu-latest.img"
}
Gate "D5 no stale zero-byte root boot image" {
    $stale = Join-Path $Root "boot-dagu-latest.img"
    if (Test-Path $stale) {
        $len = (Get-Item $stale).Length
        if ($len -lt 1MB) { throw "stale root image present ($len bytes)" }
    }
}

# --- E. Optional live artifact ---
if ($RequireArtifact -or (Test-Path (Join-Path $Root "artifacts/boot-dagu-latest.img"))) {
    Import-Module (Join-Path $Root "tools/test-lab/TestLab.psm1") -Force
    Gate "E1 artifacts/boot-dagu-latest.img published + stamp/sha256" {
        $img = Get-CanonicalUefiImagePath
        Assert-UefiArtifactPublished -ImagePath $img | Out-Null
    }
}

Write-Host "`n=== summary: $Passed passed, $($Failed.Count) failed ===" -ForegroundColor Cyan
if ($Failed.Count -gt 0) {
    Write-Host "Failed gates:" -ForegroundColor Red
    $Failed | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "All gates green." -ForegroundColor Green
exit 0
