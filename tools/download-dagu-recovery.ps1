#Requires -Version 5.1
<#
.SYNOPSIS
  Download MiFlash + dagu (Pad 5 Pro 12.4) official China Fastboot ROM for EDL recovery.

  Uses Xiaomi CDN for ROM (official). MiFlash from xiaomiflashtool.com mirror.

.EXAMPLE
  .\tools\download-dagu-recovery.ps1
  .\tools\download-dagu-recovery.ps1 -RomOnly
  .\tools\download-dagu-recovery.ps1 -FlashAfterDownload
#>
[CmdletBinding()]
param(
    [string] $DestRoot = "D:\rom\dagu-recovery",
    [switch] $RomOnly,
    [switch] $MiFlashOnly,
    [switch] $FlashAfterDownload
)

$ErrorActionPreference = "Stop"

$MiFlashUrl = "https://cdn.xiaomiflashtool.com/wp-content/uploads/MiFlash20220507.zip"
$MiFlashZip = Join-Path $DestRoot "MiFlash20220507.zip"
$MiFlashDir = Join-Path $DestRoot "MiFlash20220507"

# Latest stable China Fastboot ROM (HyperOS 2.0.10.0) — Xiaomi CDN (needs Referer)
$RomVersion = "OS2.0.10.0.ULZCNXM"
$RomFile = "dagu_images_${RomVersion}_20250701.0000.00_14.0_cn_8b79098f43.tgz"
$RomUrl = "https://bigota.d.miui.com/${RomVersion}/${RomFile}"
$RomReferer = "https://xiaomirom.com/"
$RomTgz = Join-Path $DestRoot $RomFile
$RomDir = Join-Path $DestRoot "dagu_images_${RomVersion}"

New-Item -ItemType Directory -Force -Path $DestRoot | Out-Null

function Format-Bytes([long]$n) {
    if ($n -ge 1GB) { return "{0:N2} GB" -f ($n / 1GB) }
    if ($n -ge 1MB) { return "{0:N2} MB" -f ($n / 1MB) }
    return "{0:N0} KB" -f ($n / 1KB)
}

function Download-File {
    param(
        [string]$Url,
        [string]$Out,
        [string]$Label,
        [string]$Referer = ""
    )
    if (Test-Path $Out) {
        $existing = (Get-Item $Out).Length
        Write-Host "[download] skip (exists): $Out ($(Format-Bytes $existing))" -ForegroundColor DarkGray
        return
    }
    Write-Host "[download] $Label" -ForegroundColor Cyan
    Write-Host "  URL: $Url"
    Write-Host "  ->  $Out"
    if ($Referer -and (Get-Command aria2c -ErrorAction SilentlyContinue)) {
        $outDir = Split-Path $Out -Parent
        $outName = Split-Path $Out -Leaf
        $ariaArgs = @(
            "-x", "16", "-s", "16", "-k", "1M",
            "--file-allocation=none",
            "--header=Referer: $Referer",
            "-d", $outDir,
            "-o", $outName,
            $Url
        )
        & aria2c @ariaArgs
        if ($LASTEXITCODE -ne 0) { throw "aria2 download failed ($LASTEXITCODE): $Url" }
    } elseif ($Referer -and (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        $args = @("-L", "--fail", "-o", $Out)
        if ($Referer) { $args += @("-H", "Referer: $Referer") }
        $args += $Url
        & curl.exe @args
        if ($LASTEXITCODE -ne 0) { throw "curl download failed ($LASTEXITCODE): $Url" }
    } else {
        $headers = @{}
        if ($Referer) { $headers["Referer"] = $Referer }
        try {
            if ($headers.Count -gt 0) {
                Invoke-WebRequest -Uri $Url -OutFile $Out -UseBasicParsing -Headers $headers
            } else {
                Start-BitsTransfer -Source $Url -Destination $Out -Description $Label -ErrorAction Stop
            }
        } catch {
            Write-Host "[download] fallback Invoke-WebRequest ..." -ForegroundColor Yellow
            Invoke-WebRequest -Uri $Url -OutFile $Out -UseBasicParsing -Headers $headers
        }
    }
    Write-Host "[download] OK: $(Format-Bytes (Get-Item $Out).Length)" -ForegroundColor Green
}

function Expand-ArchiveSafe {
    param([string]$Zip, [string]$OutDir)
    if (Test-Path (Join-Path $OutDir "XiaoMiFlash.exe")) {
        Write-Host "[extract] MiFlash already at $OutDir" -ForegroundColor DarkGray
        return (Join-Path $OutDir "XiaoMiFlash.exe")
    }
    Write-Host "[extract] $Zip -> $OutDir" -ForegroundColor Cyan
    Expand-Archive -Path $Zip -DestinationPath $OutDir -Force
    $exe = Get-ChildItem -Path $OutDir -Recurse -Filter "XiaoMiFlash.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exe) { throw "XiaoMiFlash.exe not found under $OutDir" }
    return $exe.FullName
}

function Expand-RomTgz {
    param([string]$Tgz, [string]$OutDir)
    if (Test-Path (Join-Path $OutDir "flash_all.bat")) {
        Write-Host "[extract] ROM already at $OutDir" -ForegroundColor DarkGray
        return $OutDir
    }
    Write-Host "[extract] $Tgz (tar.gz) -> $OutDir" -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    # Windows 10+ tar handles .tgz
    tar -xzf $Tgz -C $OutDir
    $bat = Get-ChildItem -Path $OutDir -Recurse -Filter "flash_all.bat" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $bat) { throw "flash_all.bat not found after extracting $Tgz" }
    return $bat.Directory.FullName
}

# --- download ---
if (-not $RomOnly) {
    Download-File -Url $MiFlashUrl -Out $MiFlashZip -Label "MiFlash 20220507"
}

if (-not $MiFlashOnly) {
    Download-File -Url $RomUrl -Out $RomTgz -Label "dagu Fastboot ROM $RomVersion (~5.1 GB)" -Referer $RomReferer
}

# --- extract ---
$MiFlashExe = $null
$RomFlashDir = $null

if (-not $RomOnly) {
    $MiFlashExe = Expand-ArchiveSafe -Zip $MiFlashZip -OutDir $MiFlashDir
}

if (-not $MiFlashOnly) {
    $RomFlashDir = Expand-RomTgz -Tgz $RomTgz -OutDir $RomDir
}

# --- write paths file ---
$pathsFile = Join-Path $DestRoot "PATHS.txt"
@(
    "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    ""
    "MiFlash.exe:"
    "  $MiFlashExe"
    ""
    "ROM folder (contains flash_all.bat):"
    "  $RomFlashDir"
    ""
    "MiFlash settings for UNLOCKED bootloader:"
    "  - Select: $RomFlashDir"
    "  - Choose: clean all  (NOT clean all and lock)"
    "  - Do NOT use flash_all_lock.bat"
    ""
    "Device: EDL 9008 or Fastboot"
    "After flash verify: fastboot getvar unlocked  ->  yes"
) | Set-Content -Path $pathsFile -Encoding UTF8

Write-Host ""
Write-Host "=== READY ===" -ForegroundColor Green
Write-Host "Paths saved: $pathsFile"
if ($MiFlashExe) { Write-Host "MiFlash:     $MiFlashExe" }
if ($RomFlashDir) { Write-Host "ROM folder:  $RomFlashDir" }

# Update test-lab.json if in repo
$TestLabJson = Join-Path (Split-Path $PSScriptRoot -Parent) "test-lab.json"
if ((Test-Path $TestLabJson) -and $RomFlashDir) {
    $j = Get-Content $TestLabJson -Raw | ConvertFrom-Json
    $j.mi_flash_rom_path = $RomFlashDir.Replace('\', '/')
    $j | ConvertTo-Json -Depth 5 | Set-Content $TestLabJson -Encoding UTF8
    Write-Host "Updated:     test-lab.json mi_flash_rom_path" -ForegroundColor DarkGray
}

if ($FlashAfterDownload) {
    & (Join-Path $PSScriptRoot "flash-dagu-recovery.ps1") -RomDir $RomFlashDir -MiFlashExe $MiFlashExe
}
