# Replace QCA6390 firmware and reopen the adapter so the miniport
# downloads it again. Windows stays up. BDFileName is not touched.
#
# The accept/reject rules match tools/winarm/wifi-fw-reload/fw_candidate.py.
#
#   powershell -ExecutionPolicy Bypass -File reload.ps1 -Role fw -Path D:\lab\wlanfw20.mbn
#   powershell -ExecutionPolicy Bypass -File reload.ps1 -Role m3 -Path D:\lab\m3.bin
#   powershell -ExecutionPolicy Bypass -File reload.ps1 -RestartOnly
#   powershell -ExecutionPolicy Bypass -File reload.ps1 -Restore
param(
    [ValidateSet('fw', 'm3')][string]$Role,
    [string]$Path,
    [switch]$RestartOnly,
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'
$KnownId = 'PCI\VEN_17CB&DEV_1101&SUBSYS_010817CB&REV_01\4&354dc085&0&0000'
$Drivers = Join-Path $env:SystemRoot 'System32\drivers'
$BackupRoot = Join-Path $Drivers 'dagu-fw-backup'
$LinuxSha = @('8ab2a06422e39890', '1921d25edb52f90a')
$Forbidden = @(
    'amss.bin', 'amss20.bin', 'board.bin', 'board-2.bin',
    'bdwlan.elf', 'bdwlan.e11', 'bdwlan.eff', 'bd_l81a.elf'
)
$ReportPaths = @(
    (Join-Path $PSScriptRoot 'reload-report.txt'),
    (Join-Path $env:SystemRoot 'Temp\dagu-wifi-fw-reload.txt')
)

function Write-Report([string]$Text) {
    foreach ($p in $ReportPaths) {
        try {
            $dir = Split-Path $p -Parent
            if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
            Set-Content -Path $p -Value $Text -Encoding utf8
        } catch {
            Write-Host "report write failed: $p $_"
        }
    }
    Write-Host $Text
}

function Fail([string]$Why, [int]$Code) {
    Write-Report ("REJECT {0}`r`n{1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Why)
    exit $Code
}

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Fail 'Run from an elevated PowerShell prompt.' 1 }

$modes = @()
if ($Role -or $Path) { $modes += 'load' }
if ($RestartOnly) { $modes += 'restart' }
if ($Restore) { $modes += 'restore' }
if ($modes.Count -ne 1) {
    Fail "Choose one of: -Role fw|m3 -Path <file>, -RestartOnly, -Restore." 2
}
if ($modes[0] -eq 'load' -and (-not $Role -or -not $Path)) {
    Fail '-Role and -Path are both required.' 2
}

function Test-Candidate([string]$RoleName, [string]$FilePath) {
    $full = [IO.Path]::GetFullPath($FilePath)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { Fail "file not found: $full" 2 }
    $parts = $full -split '[\\/]' | Where-Object { $_ -and $_ -ne '.' }
    foreach ($p in $parts) {
        if ($p -eq 'ath11k') { Fail "path is the Linux ath11k firmware directory: $full" 2 }
    }
    $base = [IO.Path]::GetFileName($full).ToLowerInvariant()
    if ($Forbidden -contains $base) { Fail "refusing Linux or board file name $base" 2 }
    if ($RoleName -eq 'fw' -and $base -eq 'm3.bin') { Fail 'm3.bin is not the WLAN firmware' 2 }
    if ($RoleName -eq 'm3' -and ($base -eq 'wlanfw.mbn' -or $base -eq 'wlanfw20.mbn')) {
        Fail 'WLAN firmware is not the M3 image' 2
    }
    $fs = [IO.File]::Open($full, 'Open', 'Read', 'Read')
    try {
        $magic = New-Object byte[] 4
        $n = $fs.Read($magic, 0, 4)
    } finally { $fs.Dispose() }
    if ($n -lt 4 -or $magic[0] -ne 0x7f -or $magic[1] -ne 0x45 -or $magic[2] -ne 0x4c -or $magic[3] -ne 0x46) {
        Fail "file does not start with ELF magic: $full" 2
    }
    $size = (Get-Item -LiteralPath $full).Length
    if ($RoleName -eq 'fw') { $low = 1000000; $high = 8000000 } else { $low = 64000; $high = 1000000 }
    if ($size -lt $low -or $size -gt $high) { Fail "$RoleName size $size is outside $low..$high" 2 }
    $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $full).Hash.ToLowerInvariant()
    foreach ($prefix in $LinuxSha) {
        if ($sha.StartsWith($prefix)) {
            Fail 'sha256 matches the Linux ath11k image measured 2026-11-09' 2
        }
    }
    return @{ Path = $full; Sha = $sha; Size = $size }
}

function Find-Instance {
    $known = Get-PnpDevice -InstanceId $KnownId -ErrorAction SilentlyContinue
    if ($known) { return $KnownId }
    $hits = @(Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'PCI\VEN_17CB&DEV_1101*' })
    if ($hits.Count -eq 1) { return $hits[0].InstanceId }
    if ($hits.Count -gt 1) { Fail 'more than one DEV_1101 device' 3 }
    Fail 'QCA6390 device is not in the device tree' 3
}

function Dest-Names([string]$RoleName) {
    if ($RoleName -eq 'fw') { return @('wlanfw20.mbn', 'wlanfw.mbn') }
    return @('m3.bin')
}

function Backup-Files([string[]]$Names) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Join-Path $BackupRoot $stamp
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    foreach ($name in $Names) {
        $src = Join-Path $Drivers $name
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $dir $name)
        }
    }
    return $dir
}

function Invoke-Reopen([string]$InstanceId) {
    $before = & pnputil.exe /enum-devices /instanceid "$InstanceId" 2>&1 | Out-String
    Write-Host "reopening $InstanceId"
    $restart = & pnputil.exe /restart-device "$InstanceId" 2>&1 | Out-String
    $code = $LASTEXITCODE
    Start-Sleep -Seconds 20
    $after = & pnputil.exe /enum-devices /instanceid "$InstanceId" 2>&1 | Out-String
    return @{ Before = $before.Trim(); Restart = $restart.Trim(); Code = $code; After = $after.Trim() }
}

$pending = $null
if (-not $Restore -and -not $RestartOnly) {
    $pending = Test-Candidate $Role $Path
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add((Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$id = Find-Instance
$lines.Add("instance: $id")

if ($Restore) {
    if (-not (Test-Path $BackupRoot)) { Fail 'no backup directory' 2 }
    $latest = Get-ChildItem $BackupRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $latest) { Fail 'no backup to restore' 2 }
    $saved = @(Get-ChildItem $latest.FullName -File)
    if ($saved.Count -eq 0) { Fail 'latest backup is empty' 2 }
    foreach ($f in $saved) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $Drivers $f.Name) -Force
        $lines.Add("restored: $($f.Name) from $($latest.FullName)")
    }
    $lines.Add('action: restore')
} elseif ($RestartOnly) {
    $lines.Add('action: restart-only')
} else {
    $info = $pending
    $names = Dest-Names $Role
    $backup = Backup-Files $names
    foreach ($name in $names) {
        Copy-Item -LiteralPath $info.Path -Destination (Join-Path $Drivers $name) -Force
        $lines.Add("wrote: $name <= $($info.Path)")
    }
    $lines.Add("sha256: $($info.Sha)")
    $lines.Add("size: $($info.Size)")
    $lines.Add("backup: $backup")
    $lines.Add("action: $Role")
}

$re = Invoke-Reopen $id
$lines.Add("restart_exit: $($re.Code)")
$lines.Add('--- enum before ---')
$lines.Add($re.Before)
$lines.Add('--- restart ---')
$lines.Add($re.Restart)
$lines.Add('--- enum after ---')
$lines.Add($re.After)
Write-Report ($lines -join "`r`n")
if ($re.Code -ne 0) { exit 4 }
exit 0
