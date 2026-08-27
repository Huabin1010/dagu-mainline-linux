#Requires -Version 5.1
<#
.SYNOPSIS
  Create golden fastboot backup (boot/vbmeta/vendor_boot slots).

.EXAMPLE
  .\tools\test-lab\lab.ps1 backup
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "TestLab.psm1") -Force

$cfg = Get-TestLabConfig
$fastboot = Get-PlatformTool "fastboot"
Assert-FastbootReady

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$out = Join-Path (Resolve-RepoPath $cfg.golden_backup_dir) $stamp
New-Item -ItemType Directory -Force -Path $out | Out-Null

Write-Host "[backup] Golden backup -> $out" -ForegroundColor Cyan
Save-FastbootSnapshot -OutDir $out

$results = @()
foreach ($part in $cfg.partitions_to_backup) {
    $dest = Join-Path $out "$part.img"
    Write-Host "[backup] fetch $part ..."
    $r = Invoke-LoggedCommand -FilePath $fastboot -ArgumentList @("fetch", $part, $dest) -LogPath (Join-Path $out "fetch-$part.log")
    $ok = ($r.ExitCode -eq 0) -and (Test-Path $dest) -and ((Get-Item $dest).Length -gt 0)
    $bytes = 0
    if ($ok) { $bytes = (Get-Item $dest).Length }
    $results += [pscustomobject]@{ partition = $part; ok = $ok; bytes = $bytes }
    if (-not $ok) {
        Write-Host "[backup] WARN: fetch $part failed (see fetch-$part.log). You may need root dd or Mi Flash ROM." -ForegroundColor Yellow
        Remove-Item $dest -ErrorAction SilentlyContinue
    }
}

$manifest = @{
    kind = "golden-backup"
    created_at = (Get-Date).ToUniversalTime().ToString("o")
    device = $cfg.device_codename
    product = (Get-FastbootVar "product")
    current_slot = (Get-FastbootVar "current-slot")
    partitions = $results
    note = "Use lab.ps1 recover restore-all if boot partitions were flashed."
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out "manifest.json") -Encoding UTF8

$link = Join-Path (Resolve-RepoPath $cfg.golden_backup_dir) "latest"
$linkTxt = Join-Path (Resolve-RepoPath $cfg.golden_backup_dir) "latest.txt"
Set-Content $linkTxt $out -Encoding UTF8
if (Test-Path $link) { Remove-Item $link -Force -Recurse -ErrorAction SilentlyContinue }
New-Item -ItemType Junction -Path $link -Target $out -ErrorAction SilentlyContinue | Out-Null
if (-not (Test-Path $link)) {
    cmd /c mklink /J "$link" "$out" 2>$null | Out-Null
}

Write-Host "[backup] Done. Latest -> backups/golden/latest (see latest.txt)" -ForegroundColor Green
$okCount = ($results | Where-Object { $_.ok }).Count
Write-Host "[backup] Fetched $okCount / $($results.Count) partitions"
