#Requires -Version 5.1
Set-StrictMode -Version Latest

function Get-TestLabRoot {
    if ($env:TEST_LAB_ROOT) { return (Resolve-Path $env:TEST_LAB_ROOT).Path }
    return (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
}

function Get-TestLabConfig {
    $root = Get-TestLabRoot
    $cfgPath = Join-Path $root "test-lab.json"
    if (-not (Test-Path $cfgPath)) {
        throw "Missing test-lab.json at repo root"
    }
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg | Add-Member -NotePropertyName RepoRoot -NotePropertyValue $root -Force
    return $cfg
}

function Get-PlatformTool([string]$Name) {
    $root = Get-TestLabRoot
    $local = Join-Path $root "tools/platform-tools/$Name.exe"
    if (Test-Path $local) { return $local }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "$Name not found. Install platform-tools or use tools/platform-tools/"
}

function Resolve-RepoPath([string]$RelativePath) {
    $root = Get-TestLabRoot
    return (Join-Path $root $RelativePath)
}

function Assert-UefiArtifactPublished {
    param(
        [Parameter(Mandatory)][string]$ImagePath
    )
    $stampPath = [System.IO.Path]::ChangeExtension($ImagePath, ".stamp")
    if (-not (Test-Path $ImagePath)) {
        throw "UEFI image not found: $ImagePath"
    }
    $imgBytes = (Get-Item $ImagePath).Length
    if ($imgBytes -lt 1MB) {
        throw "UEFI image invalid ($imgBytes bytes): $ImagePath"
    }
    if (-not (Test-Path $stampPath)) {
        throw @(
            "UEFI artifact missing stamp: $ImagePath ($imgBytes bytes)",
            "Rebuild:  ./tools/build-dagu-uefi.sh"
        ) -join "`n"
    }
    $stamp = Get-Content $stampPath -Raw
    if ($stamp -match 'bytes=(\d+)') {
        $publishedBytes = [int64]$Matches[1]
        if ($publishedBytes -ne $imgBytes) {
            throw "Artifact size mismatch: file=$imgBytes stamp=$publishedBytes — rebuild"
        }
    }
    if ($stamp -match 'sha256=([0-9a-f]{64})') {
        $expectedSha = $Matches[1]
        $actualSha = (Get-FileHash -Algorithm SHA256 -Path $ImagePath).Hash.ToLower()
        if ($actualSha -ne $expectedSha) {
            throw "Artifact SHA256 mismatch — file may be stale or corrupt. Rebuild."
        }
    }
    return $imgBytes
}

function Get-CanonicalUefiImagePath {
    $cfg = Get-TestLabConfig
    $img = Resolve-RepoPath $cfg.uefi_test_image
    if (-not (Test-Path $img)) {
        throw @(
            "Canonical UEFI image not found: $img",
            "Build first:  ./tools/build-dagu-uefi.sh"
        ) -join "`n"
    }
    return (Resolve-Path $img).Path
}

function Remove-StaleBootImageCopies {
    $root = Get-TestLabRoot
    $stale = Join-Path $root "boot-dagu-latest.img"
    $removed = @()
    if (Test-Path $stale) {
        $len = (Get-Item $stale).Length
        if ($len -lt 1MB) {
            Remove-Item -Force $stale -ErrorAction SilentlyContinue
            $removed += $stale
            Write-Host "[artifact-guard] removed stale root image ($len bytes): $stale" -ForegroundColor Yellow
        } else {
            Write-Host "[artifact-guard] WARN: non-canonical boot image at repo root ($len bytes). Use artifacts\boot-dagu-latest.img" -ForegroundColor Yellow
        }
    }
    return $removed
}

function New-TestLabSession {
    param(
        [string]$Kind = "session"
    )
    $cfg = Get-TestLabConfig
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $dir = Join-Path (Resolve-RepoPath $cfg.sessions_dir) "${stamp}-${Kind}"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return @{
        Dir = $dir
        Id  = "${stamp}-${Kind}"
        StartedAt = (Get-Date).ToUniversalTime().ToString("o")
    }
}

function Write-SessionManifest {
    param(
        [hashtable]$Session,
        [hashtable]$Data
    )
    $manifest = @{
        session_id = $Session.Id
        started_at = $Session.StartedAt
        finished_at = (Get-Date).ToUniversalTime().ToString("o")
    }
    foreach ($k in $Data.Keys) { $manifest[$k] = $Data[$k] }
    $path = Join-Path $Session.Dir "manifest.json"
    $manifest | ConvertTo-Json -Depth 6 | Set-Content $path -Encoding UTF8
    return $path
}

function Invoke-LoggedCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$LogPath,
        [string]$ErrPath = ""
    )
    if (-not $ErrPath) { $ErrPath = ($LogPath -replace '\.([^.]+)$', '.err.$1') }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($ArgumentList -join " ")
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    $stdout | Set-Content $LogPath -Encoding UTF8
    $stderr | Set-Content $ErrPath -Encoding UTF8
    return @{
        ExitCode = $proc.ExitCode
        StdOutPath = $LogPath
        StdErrPath = $ErrPath
        StdOut = $stdout
        StdErr = $stderr
        Combined = ($stdout + $stderr)
    }
}

function Wait-FastbootDevice {
    param([int]$TimeoutSec = 60)
    $fastboot = Get-PlatformTool "fastboot"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-LoggedCommand -FilePath $fastboot -ArgumentList @("devices") -LogPath ([System.IO.Path]::GetTempFileName())
        if ($r.StdOut -match "(?m)fastboot\s*$" -or $r.Combined -match "(?m)fastboot\s*$") { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Invoke-Fastboot {
    param([Parameter(Mandatory)][string[]]$ArgumentList)
    $fastboot = Get-PlatformTool "fastboot"
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        return (& $fastboot @ArgumentList 2>&1 | ForEach-Object { "$_" }) -join "`n"
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Assert-FastbootReady {
    if (-not (Wait-FastbootDevice -TimeoutSec 15)) {
        throw "No fastboot device. Power off -> hold VolDown+Power for fastboot mode."
    }
    $out = Invoke-Fastboot @("getvar", "unlocked")
    if ($out -notmatch "unlocked:\s*yes") {
        throw "Bootloader not unlocked (unlocked != yes). Abort for safety."
    }
}

function Get-FastbootVar([string]$Name) {
    $out = Invoke-Fastboot @("getvar", $Name)
    if ($out -match "(?m)^${Name}:\s*(.+)") { return $Matches[1].Trim() }
    return $null
}

function Save-FastbootSnapshot {
    param([Parameter(Mandatory)][string]$OutDir)
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    (Invoke-Fastboot @("getvar", "all")) | Set-Content (Join-Path $OutDir "fastboot-getvar-all.txt") -Encoding UTF8
    foreach ($v in @("product", "current-slot", "slot-count", "unlocked", "secure", "variant", "slot-successful")) {
        (Invoke-Fastboot @("getvar", $v)) | Set-Content (Join-Path $OutDir "fastboot-$v.txt") -Encoding UTF8
    }
}

function Get-LatestGoldenBackup {
    $cfg = Get-TestLabConfig
    $base = Resolve-RepoPath $cfg.golden_backup_dir
    if (-not (Test-Path $base)) { return $null }
    $latestTxt = Join-Path $base "latest.txt"
    if (Test-Path $latestTxt) {
        $dir = (Get-Content $latestTxt -Raw).Trim()
        if (Test-Path $dir) {
            $manifest = Join-Path $dir "manifest.json"
            if (Test-Path $manifest) {
                return @{ Dir = $dir; Manifest = (Get-Content $manifest -Raw | ConvertFrom-Json) }
            }
        }
    }
    $latest = Get-ChildItem $base -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}$' } | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $latest) { return $null }
    $manifest = Join-Path $latest.FullName "manifest.json"
    if (-not (Test-Path $manifest)) { return $null }
    return @{
        Dir = $latest.FullName
        Manifest = (Get-Content $manifest -Raw | ConvertFrom-Json)
    }
}

function Get-LastTestSession {
    $cfg = Get-TestLabConfig
    $base = Resolve-RepoPath $cfg.sessions_dir
    if (-not (Test-Path $base)) { return $null }
    $latest = Get-ChildItem $base -Directory | Sort-Object Name -Descending | Select-Object -First 1
    return $latest
}

Export-ModuleMember -Function *
