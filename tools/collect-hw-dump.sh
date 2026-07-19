#!/usr/bin/env bash
# Golden Baseline collector for dagu (Xiaomi Pad 5 Pro 12.4)
# Usage: ./tools/collect-hw-dump.sh
set -euo pipefail

DEVICE="${DEVICE:-dagu}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="dumps/${DEVICE}-${STAMP}"
mkdir -p "$OUT"

log() { echo "[collect] $*"; }

if ! command -v adb >/dev/null 2>&1; then
  echo "adb not found in PATH" >&2
  exit 1
fi

if ! adb get-state >/dev/null 2>&1; then
  echo "No adb device. Enable USB debugging and authorize this PC." >&2
  exit 1
fi

log "Output -> $OUT"

adb_shell() {
  adb shell "$@" 2>/dev/null || true
}

adb_shell_su() {
  adb shell "su -c '$*'" 2>/dev/null || adb shell "$@" 2>/dev/null || true
}

# --- identity ---
log "device properties"
{
  echo "=== getprop (selected) ==="
  adb_shell getprop ro.product.device
  adb_shell getprop ro.product.model
  adb_shell getprop ro.product.name
  adb_shell getprop ro.board.platform
  adb_shell getprop ro.hardware
  adb_shell getprop ro.build.version.release
  adb_shell getprop ro.build.display.id
  adb_shell getprop ro.boot.serialno
} | tee "$OUT/getprop.txt"

adb_shell uname -a > "$OUT/uname.txt"
adb_shell cat /proc/cpuinfo > "$OUT/cpuinfo.txt"
adb_shell cat /proc/meminfo > "$OUT/meminfo.txt"

# --- partitions ---
log "block devices"
adb_shell_su "ls -l /dev/block/by-name/" > "$OUT/partition-by-name.txt"
adb_shell df -h > "$OUT/df.txt"
adb_shell_su "cat /proc/partitions" > "$OUT/partitions.txt"

# --- memory map (critical for UEFI) ---
log "iomem"
adb_shell_su "cat /proc/iomem" > "$OUT/iomem.txt"

# --- device tree ---
log "fdt"
if adb_shell_su "test -r /sys/firmware/fdt && echo ok" | grep -q ok; then
  adb_shell_su "cat /sys/firmware/fdt" > "$OUT/fdt.dtb"
  if command -v dtc >/dev/null 2>&1; then
    dtc -I dtb -O dts -o "$OUT/fdt.dts" "$OUT/fdt.dtb" 2>/dev/null || true
  fi
else
  log "WARN: /sys/firmware/fdt not readable (root required?)"
fi

# --- dmesg / logs ---
log "dmesg"
adb_shell_su "dmesg" > "$OUT/dmesg.txt"

# --- display / drm ---
log "display"
adb_shell ls -R /sys/class/drm/ > "$OUT/drm-sysfs.txt" 2>/dev/null || true
adb_shell dumpsys display > "$OUT/dumpsys-display.txt" 2>/dev/null || true

# --- input / touch ---
log "input"
adb_shell getevent -lp > "$OUT/getevent-lp.txt" 2>/dev/null || true

# --- audio ---
log "audio"
adb_shell cat /proc/asound/cards > "$OUT/asound-cards.txt" 2>/dev/null || true

# --- storage ---
log "block class"
adb_shell ls -l /sys/class/block/ > "$OUT/block-sysfs.txt" 2>/dev/null || true

# --- sensors ---
log "sensors"
adb_shell ls /sys/bus/iio/devices/ > "$OUT/iio-devices.txt" 2>/dev/null || true

# --- GPU ---
log "gpu"
adb_shell ls -R /sys/class/kgsl/ > "$OUT/kgsl-sysfs.txt" 2>/dev/null || true

# --- manifest ---
cat > "$OUT/MANIFEST.txt" <<EOF
device=$DEVICE
stamp=$STAMP
host=$(uname -a 2>/dev/null || echo unknown)
adb_serial=$(adb get-serialno 2>/dev/null || echo unknown)
notes=Golden Baseline for WoA bring-up. Redact serial before publishing.
EOF

log "Done. Review $OUT and fill docs/hardware-inventory.md"
