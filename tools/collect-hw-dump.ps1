# Golden Baseline collector for dagu (Xiaomi Pad 5 Pro 12.4)
# Usage: .\tools\collect-hw-dump.ps1

$ErrorActionPreference = "Stop"
$Device = if ($env:DEVICE) { $env:DEVICE } else { "dagu" }
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$Out = Join-Path "dumps" "${Device}-${Stamp}"
New-Item -ItemType Directory -Force -Path $Out | Out-Null

function Log($msg) { Write-Host "[collect] $msg" }

if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
    throw "adb not found in PATH"
}

try {
    adb get-state 2>$null | Out-Null
} catch {
    throw "No adb device. Enable USB debugging and authorize this PC."
}

Log "Output -> $Out"

function Adb-Shell([string]$cmd) {
    try { adb shell $cmd 2>$null } catch { "" }
}

function Adb-ShellSu([string]$cmd) {
    $escaped = $cmd -replace "'", "'\\''"
    $r = Adb-Shell "su -c '$escaped'"
    if (-not $r) { $r = Adb-Shell $cmd }
    return $r
}

Log "device properties"
$props = @(
    @{n="ro.product.device"; k="device"},
    @{n="ro.product.model"; k="model"},
    @{n="ro.product.name"; k="name"},
    @{n="ro.product.marketname"; k="marketname"},
    @{n="ro.board.platform"; k="board_platform"},
    @{n="ro.soc.model"; k="soc_model"},
    @{n="ro.hardware"; k="hardware"},
    @{n="ro.build.version.release"; k="android_release"},
    @{n="ro.build.display.id"; k="build_display"},
    @{n="ro.build.version.incremental"; k="build_incremental"},
    @{n="ro.boot.serialno"; k="serial"},
    @{n="ro.secureboot.lockstate"; k="bootloader_lock"},
    @{n="ro.boot.verifiedbootstate"; k="verified_boot"},
    @{n="sys.oem_unlock_allowed"; k="oem_unlock_allowed"}
)
$propOut = "=== getprop (selected) ===`n"
foreach ($p in $props) {
    $v = (adb shell getprop $p.n 2>$null).Trim()
    $propOut += "$($p.k)=$v`n"
}
$propOut | Set-Content (Join-Path $Out "getprop.txt") -Encoding UTF8
adb shell getprop | Set-Content (Join-Path $Out "getprop-full.txt") -Encoding UTF8

(Adb-Shell "uname -a") | Set-Content (Join-Path $Out "uname.txt") -Encoding UTF8
(Adb-Shell "cat /proc/cpuinfo") | Set-Content (Join-Path $Out "cpuinfo.txt") -Encoding UTF8
(Adb-Shell "cat /proc/meminfo") | Set-Content (Join-Path $Out "meminfo.txt") -Encoding UTF8

Log "partitions"
(Adb-ShellSu "ls -l /dev/block/by-name/") | Set-Content (Join-Path $Out "partition-by-name.txt") -Encoding UTF8
(Adb-Shell "df -h") | Set-Content (Join-Path $Out "df.txt") -Encoding UTF8
(Adb-ShellSu "cat /proc/partitions") | Set-Content (Join-Path $Out "partitions.txt") -Encoding UTF8

Log "iomem"
(Adb-ShellSu "cat /proc/iomem") | Set-Content (Join-Path $Out "iomem.txt") -Encoding UTF8

Log "fdt"
$fdtPath = Join-Path $Out "fdt.dtb"
Adb-ShellSu "cat /sys/firmware/fdt" | Set-Content $fdtPath -Encoding Byte -ErrorAction SilentlyContinue
if (-not (Test-Path $fdtPath) -or (Get-Item $fdtPath).Length -lt 100) {
    Log "WARN: fdt not collected (root required?)"
    Remove-Item $fdtPath -ErrorAction SilentlyContinue
}

Log "dmesg"
(Adb-ShellSu "dmesg") | Set-Content (Join-Path $Out "dmesg.txt") -Encoding UTF8

Log "display / input / audio"
(Adb-Shell "ls -R /sys/class/drm/") | Set-Content (Join-Path $Out "drm-sysfs.txt") -Encoding UTF8
(Adb-Shell "dumpsys display") | Set-Content (Join-Path $Out "dumpsys-display.txt") -Encoding UTF8
(Adb-Shell "getevent -lp") | Set-Content (Join-Path $Out "getevent-lp.txt") -Encoding UTF8
(Adb-Shell "cat /proc/asound/cards") | Set-Content (Join-Path $Out "asound-cards.txt") -Encoding UTF8
(Adb-Shell "ls /sys/class/block/") | Set-Content (Join-Path $Out "block-sysfs.txt") -Encoding UTF8
(Adb-Shell "ls /sys/bus/iio/devices/") | Set-Content (Join-Path $Out "iio-devices.txt") -Encoding UTF8
(Adb-Shell "ls -R /sys/class/kgsl/") | Set-Content (Join-Path $Out "kgsl-sysfs.txt") -Encoding UTF8

@(
    "device=$Device",
    "stamp=$Stamp",
    "host=$([Environment]::OSVersion.VersionString)",
    "adb_serial=$(adb get-serialno 2>$null)",
    "notes=Golden Baseline for WoA bring-up. Redact serial before publishing."
) | Set-Content (Join-Path $Out "MANIFEST.txt") -Encoding UTF8

Log "Done. Review $Out and fill docs/hardware-inventory.md"
