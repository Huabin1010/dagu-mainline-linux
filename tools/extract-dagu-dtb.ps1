# Extract dagu DTB from boot.img (after root or offline ROM)
# Requires: magiskboot OR unpack_bootimg.py from aosp
param(
    [Parameter(Mandatory = $true)]
    [string]$BootImg,
    [string]$OutDtb = "E:\Projects\xiaomi-pad870-win11-arm\edk2-msm\Platform\Xiaomi\sm8250\FdtBlob_compat\dagu.dtb"
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path $BootImg)) { throw "boot.img not found: $BootImg" }

$work = Join-Path $env:TEMP "dagu-dtb-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $work | Out-Null

Write-Host "[extract-dagu-dtb] boot.img -> $work"
Write-Host "[extract-dagu-dtb] Install Android build-tools or use magiskboot manually."
Write-Host ""
Write-Host "Suggested steps (Linux with unpack_bootimg):"
Write-Host "  unpack_bootimg --boot_img $BootImg --out $work"
Write-Host "  # locate *.dtb in $work and copy to:"
Write-Host "  $OutDtb"
Write-Host ""
Write-Host "Or pull from device (root required):"
Write-Host "  adb shell su -c 'dd if=/dev/block/by-name/boot_b of=/sdcard/boot.img'"
Write-Host "  adb pull /sdcard/boot.img $BootImg"
