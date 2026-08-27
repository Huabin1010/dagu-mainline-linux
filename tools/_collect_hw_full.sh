#!/usr/bin/env bash
# One-shot comprehensive hardware dump for rooted dagu.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/dumps/dagu-${STAMP}-root"
mkdir -p "$OUT"
log() { printf '[dump] %s\n' "$*"; }
su_sh() { adb shell su -c "$*" 2>/dev/null || true; }
# binary-safe pull of a device file
pull_bin() {
  local src="$1" dst="$2"
  adb exec-out su -c "cat '$src'" > "$dst" 2>/dev/null || true
  local sz=0
  [[ -f "$dst" ]] && sz=$(stat -c%s "$dst" 2>/dev/null || echo 0)
  # drop empty / tiny error text
  if [[ "$sz" -lt 8 ]]; then rm -f "$dst"; return 1; fi
  return 0
}
pull_text() {
  local src="$1" dst="$2"
  adb shell su -c "cat '$src'" > "$dst" 2>/dev/null || true
}
save_cmd() {
  local dst="$1"; shift
  adb shell su -c "$*" > "$dst" 2>/dev/null || true
}

log "output $OUT"
save_cmd "$OUT/su-id.txt" "id; magisk -v; magisk -c"

# ---- identity ----
mkdir -p "$OUT/identity"
log "identity"
save_cmd "$OUT/identity/getprop-full.txt" "getprop"
save_cmd "$OUT/identity/uname.txt" "uname -a"
save_cmd "$OUT/identity/version.txt" "cat /proc/version"
save_cmd "$OUT/identity/cmdline.txt" "cat /proc/cmdline"
save_cmd "$OUT/identity/bootconfig.txt" "cat /proc/bootconfig"
save_cmd "$OUT/identity/cpuinfo.txt" "cat /proc/cpuinfo"
save_cmd "$OUT/identity/meminfo.txt" "cat /proc/meminfo"
save_cmd "$OUT/identity/misc.txt" "getprop ro.product.device; getprop ro.product.model; getprop ro.product.marketname; getprop ro.board.platform; getprop ro.soc.model; getprop ro.hardware; getprop ro.build.version.incremental; getprop ro.build.display.id; getprop ro.secureboot.lockstate; getprop ro.boot.slot_suffix; getprop ro.boot.verifiedbootstate"

# ---- kernel / modules ----
mkdir -p "$OUT/kernel"
log "kernel"
save_cmd "$OUT/kernel/modules.txt" "cat /proc/modules"
save_cmd "$OUT/kernel/kallsyms-head.txt" "head -c 200000 /proc/kallsyms"
save_cmd "$OUT/kernel/interrupts.txt" "cat /proc/interrupts"
save_cmd "$OUT/kernel/softirqs.txt" "cat /proc/softirqs"
save_cmd "$OUT/kernel/timer_list-head.txt" "head -c 200000 /proc/timer_list"
save_cmd "$OUT/kernel/zoneinfo.txt" "cat /proc/zoneinfo"
save_cmd "$OUT/kernel/vmallocinfo-head.txt" "head -c 500000 /proc/vmallocinfo"
save_cmd "$OUT/kernel/pagetypeinfo.txt" "cat /proc/pagetypeinfo"
save_cmd "$OUT/kernel/buddyinfo.txt" "cat /proc/buddyinfo"
save_cmd "$OUT/kernel/ioports.txt" "cat /proc/ioports"
save_cmd "$OUT/kernel/misc-devices.txt" "ls -l /dev /dev/block /proc/device-tree 2>/dev/null | head -c 200000"
pull_bin /proc/config.gz "$OUT/kernel/config.gz" && gzip -dc "$OUT/kernel/config.gz" > "$OUT/kernel/config.txt" 2>/dev/null || true
save_cmd "$OUT/kernel/lsmod.txt" "lsmod"
save_cmd "$OUT/kernel/sysctl.txt" "sysctl -a"

# ---- memory map (UEFI critical) ----
mkdir -p "$OUT/memory"
log "iomem"
save_cmd "$OUT/memory/iomem.txt" "cat /proc/iomem"
save_cmd "$OUT/memory/iomem-full.txt" "cat /proc/iomem"
save_cmd "$OUT/memory/reserved.txt" "ls -lR /proc/device-tree/reserved-memory 2>/dev/null; echo '---'; find /proc/device-tree/reserved-memory -type f 2>/dev/null | while read f; do echo \"# \$f\"; xxd -p \"\$f\" 2>/dev/null | tr -d '\n'; echo; done"

# ---- device tree ----
mkdir -p "$OUT/dt"
log "device tree / fdt"
if pull_bin /sys/firmware/fdt "$OUT/dt/fdt.dtb"; then
  if command -v dtc >/dev/null; then
    dtc -I dtb -O dts -o "$OUT/dt/fdt.dts" "$OUT/dt/fdt.dtb" 2>"$OUT/dt/dtc.log" || true
  fi
fi
save_cmd "$OUT/dt/compatible.txt" "find /proc/device-tree -name compatible -exec sh -c 'echo === \$1 ===; cat \"\$1\"; echo' _ {} \\;"
save_cmd "$OUT/dt/model.txt" "cat /proc/device-tree/model; echo; cat /proc/device-tree/compatible"
log "tarring /proc/device-tree"
adb shell su -c 'tar -C /proc -cf - device-tree' > "$OUT/dt/proc-device-tree.tar" 2>/dev/null || true
save_cmd "$OUT/dt/of-nodes-ls.txt" "find /sys/firmware/devicetree /proc/device-tree -maxdepth 3 -type d 2>/dev/null | head -5000"

# ---- partitions / GPT ----
mkdir -p "$OUT/partitions" "$OUT/images"
log "partitions"
save_cmd "$OUT/partitions/by-name.txt" "ls -l /dev/block/by-name/"
save_cmd "$OUT/partitions/by-name-realpath.txt" "ls -l /dev/block/bootdevice/by-name/"
save_cmd "$OUT/partitions/proc-partitions.txt" "cat /proc/partitions"
save_cmd "$OUT/partitions/df.txt" "df -h"
save_cmd "$OUT/partitions/mounts.txt" "cat /proc/mounts"
save_cmd "$OUT/partitions/fstab.txt" "cat /vendor/etc/fstab* /odm/etc/fstab* /vendor/etc/fstab.qcom 2>/dev/null"
save_cmd "$OUT/partitions/block-sysfs.txt" "ls -l /sys/class/block/"
save_cmd "$OUT/partitions/disk-luns.txt" "ls -l /dev/block/sd* /dev/block/mmcblk* 2>/dev/null; for d in /sys/class/block/sd* /sys/class/block/mmcblk*; do echo === \$d ===; cat \$d/size 2>/dev/null; cat \$d/device/model 2>/dev/null; done"

# GPT print for each UFS LUN
save_cmd "$OUT/partitions/sgdisk.txt" '
for d in /dev/block/sda /dev/block/sdb /dev/block/sdc /dev/block/sdd /dev/block/sde /dev/block/sdf /dev/block/sdg; do
  [ -b "$d" ] || continue
  echo "======== $d ========"
  sgdisk --print "$d" 2>/dev/null || parted "$d" print 2>/dev/null || fdisk -l "$d" 2>/dev/null
done
'
save_cmd "$OUT/partitions/parted.txt" '
for d in /dev/block/sda /dev/block/sdb /dev/block/sdc /dev/block/sdd /dev/block/sde /dev/block/sdf /dev/block/sdg; do
  [ -b "$d" ] || continue
  echo "======== $d ========"
  parted -s "$d" unit s print 2>/dev/null || true
  parted -s "$d" unit B print 2>/dev/null || true
done
'
save_cmd "$OUT/partitions/sizes.txt" '
for n in /dev/block/by-name/*; do
  b=$(basename "$n")
  real=$(readlink -f "$n")
  sz=$(blockdev --getsize64 "$n" 2>/dev/null || echo "?")
  echo "$sz $b $real"
done | sort -n
'

dump_part() {
  local name="$1"
  local dest="$OUT/images/${name}.img"
  log "dd $name"
  adb exec-out su -c "dd if=/dev/block/by-name/$name bs=4M 2>/dev/null" > "$dest" || true
  local sz
  sz=$(stat -c%s "$dest" 2>/dev/null || echo 0)
  if [[ "$sz" -lt 1024 ]]; then
    log "skip empty $name"
    rm -f "$dest"
  else
    log "  $name = $sz bytes"
  fi
}

# firmware-critical, skip super/userdata/metadata huge
for p in boot_a boot_b vendor_boot_a vendor_boot_b dtbo_a dtbo_b vbmeta_a vbmeta_b \
         vbmeta_system_a vbmeta_system_b recovery_a recovery_b init_boot_a init_boot_b \
         persist modem_a modem_b bluetooth_a bluetooth_b dsp_a dsp_b \
         xbl_a xbl_b xbl_config_a xbl_config_b abl_a abl_b \
         tz_a tz_b hyp_a hyp_b keymaster_a keymaster_b \
         cmnlib_a cmnlib_b cmnlib64_a cmnlib64_b \
         devinfo misc fsc fsg modemst1 modemst2 \
         imagefv_a imagefv_b uefisecapp_a uefisecapp_b \
         qupfw_a qupfw_b aop_a aop_b featenabler_a featenabler_b \
         logfs splash; do
  dump_part "$p"
done

# ---- dmesg / pstore ----
mkdir -p "$OUT/logs"
log "dmesg"
save_cmd "$OUT/logs/dmesg.txt" "dmesg -T"
save_cmd "$OUT/logs/dmesg-raw.txt" "dmesg"
save_cmd "$OUT/logs/last_kmsg.txt" "cat /proc/last_kmsg /sys/fs/pstore/console-ramoops 2>/dev/null"
save_cmd "$OUT/logs/pstore-ls.txt" "ls -lR /sys/fs/pstore /proc/pstore 2>/dev/null"
save_cmd "$OUT/logs/logcat-crash.txt" "logcat -d -b crash -t 500"
save_cmd "$OUT/logs/logcat-kernel.txt" "logcat -d -b kernel -t 800"
save_cmd "$OUT/logs/logcat-system-hw.txt" "logcat -d -t 400 | grep -iE 'wifi|wlan|cnss|ufs|display|dsi|touch|himax|audio|usb|dwc|gpu|kgsl|adreno|bluetooth|sensor'"

# ---- display ----
mkdir -p "$OUT/display"
log "display"
save_cmd "$OUT/display/drm-ls.txt" "ls -lR /sys/class/drm /sys/class/graphics /sys/class/backlight /sys/class/leds 2>/dev/null"
save_cmd "$OUT/display/dumpsys-display.txt" "dumpsys display"
save_cmd "$OUT/display/dumpsys-SurfaceFlinger.txt" "dumpsys SurfaceFlinger"
save_cmd "$OUT/display/fb.txt" "for f in /sys/class/graphics/fb0/*; do echo === \$f ===; cat \$f 2>/dev/null; echo; done"
save_cmd "$OUT/display/backlight.txt" "for f in /sys/class/backlight/*/*; do echo === \$f ===; cat \$f 2>/dev/null; echo; done"
save_cmd "$OUT/display/dmesg-panel.txt" "dmesg | grep -iE 'dsi|mdp|mdss|sde|panel|drm|ltpo|l81|refresh'"

# ---- GPU ----
mkdir -p "$OUT/gpu"
log "gpu"
save_cmd "$OUT/gpu/kgsl-ls.txt" "ls -lR /sys/class/kgsl /sys/devices/platform/*kgsl* 2>/dev/null"
save_cmd "$OUT/gpu/kgsl-attrs.txt" "for f in /sys/class/kgsl/kgsl-3d0/*; do [ -f \$f ] || continue; echo === \$f ===; cat \$f 2>/dev/null; echo; done"
save_cmd "$OUT/gpu/dmesg-gpu.txt" "dmesg | grep -iE 'kgsl|adreno|gpu|a650'"

# ---- storage UFS ----
mkdir -p "$OUT/ufs"
log "ufs"
save_cmd "$OUT/ufs/sysfs.txt" "ls -lR /sys/class/scsi_host /sys/class/scsi_disk /sys/bus/platform/devices/*.ufshc /sys/devices/platform/*.ufshc 2>/dev/null | head -c 400000"
save_cmd "$OUT/ufs/attrs.txt" "for d in /sys/devices/platform/*.ufshc /sys/class/scsi_host/host*; do echo ===== \$d =====; ls \$d; for f in \$d/*; do [ -f \$f ] || continue; echo -- \$f; cat \$f 2>/dev/null; echo; done; done"
save_cmd "$OUT/ufs/dmesg.txt" "dmesg | grep -iE 'ufs|ufshcd|scsi'"

# ---- USB ----
mkdir -p "$OUT/usb"
log "usb"
save_cmd "$OUT/usb/udc.txt" "ls -lR /sys/class/udc /sys/bus/usb /sys/class/typec /sys/class/power_supply 2>/dev/null | head -c 400000"
save_cmd "$OUT/usb/dwc3.txt" "find /sys -iname '*dwc3*' -o -iname '*usb_qmp*' -o -iname '*typec*' 2>/dev/null | head -400"
save_cmd "$OUT/usb/dmesg.txt" "dmesg | grep -iE 'usb|dwc3|xhci|gadget|typec|ucsi|pmic_glink|qmp'"
save_cmd "$OUT/usb/dumpsys-usb.txt" "dumpsys usb"
save_cmd "$OUT/usb/dumpsys-usb-device.txt" "dumpsys UsbDeviceManager"
save_cmd "$OUT/usb/configfs.txt" "ls -lR /config/usb_gadget 2>/dev/null | head -c 200000"

# ---- input / touch ----
mkdir -p "$OUT/input"
log "input"
save_cmd "$OUT/input/getevent-lp.txt" "getevent -lp"
save_cmd "$OUT/input/getevent-t-5s.txt" "timeout 5 getevent -lt"
save_cmd "$OUT/input/input-sysfs.txt" "ls -lR /sys/class/input /sys/class/leds /proc/bus/input 2>/dev/null"
save_cmd "$OUT/input/dmesg-touch.txt" "dmesg | grep -iE 'himax|touch|i2c|spi|goodix|synaptics|fts|nanosic|keyboard'"

# ---- audio ----
mkdir -p "$OUT/audio"
log "audio"
save_cmd "$OUT/audio/asound.txt" "cat /proc/asound/cards; echo ---; ls -lR /proc/asound /sys/class/sound 2>/dev/null | head -c 200000"
save_cmd "$OUT/audio/dmesg.txt" "dmesg | grep -iE 'wcd|audio|bolero|kona-mtp|q6|apr|snd'"
save_cmd "$OUT/audio/mixer.txt" "ls -l /vendor/etc/audio /vendor/etc/mixer_paths* /vendor/etc/audio_platform_info* /odm/etc/audio 2>/dev/null"
adb shell su -c 'tar -C /vendor/etc -cf - audio mixer_paths.xml mixer_paths_*.xml audio_platform_info*.xml audio_policy*.xml 2>/dev/null' > "$OUT/audio/vendor-etc-audio.tar" 2>/dev/null || true

# ---- wifi / bt ----
mkdir -p "$OUT/wireless"
log "wireless"
save_cmd "$OUT/wireless/dmesg.txt" "dmesg | grep -iE 'wlan|cnss|qca|wcn|wifi|bluetooth|btfm|hci'"
save_cmd "$OUT/wireless/iw.txt" "iw dev; iw list; ip link; cat /sys/class/net/wlan0/address 2>/dev/null"
save_cmd "$OUT/wireless/dumpsys-wifi.txt" "dumpsys wifi | head -c 400000"
save_cmd "$OUT/wireless/dumpsys-bluetooth.txt" "dumpsys bluetooth_manager | head -c 200000"
save_cmd "$OUT/wireless/firmware-ls.txt" "ls -lR /vendor/firmware /vendor/firmware_mnt /odm/firmware 2>/dev/null | head -c 800000"
save_cmd "$OUT/wireless/wlan-etc.txt" "ls -lR /vendor/etc/wifi /odm/etc/wifi /vendor/firmware/wlan 2>/dev/null"

# ---- sensors ----
mkdir -p "$OUT/sensors"
log "sensors"
save_cmd "$OUT/sensors/iio.txt" "ls -lR /sys/bus/iio /sys/class/iio 2>/dev/null"
save_cmd "$OUT/sensors/dumpsys.txt" "dumpsys sensorservice"
save_cmd "$OUT/sensors/dmesg.txt" "dmesg | grep -iE 'sensor|lsm6|tcs3701|bu27030|imu|accel|gyro|als|light|prox'"

# ---- power / pmic / thermal ----
mkdir -p "$OUT/power"
log "power"
save_cmd "$OUT/power/power_supply.txt" "ls -lR /sys/class/power_supply; echo; for d in /sys/class/power_supply/*; do echo ===== \$d =====; for f in \$d/*; do [ -f \$f ] || continue; echo -- \$(basename \$f); cat \$f 2>/dev/null; echo; done; done"
save_cmd "$OUT/power/thermal.txt" "ls /sys/class/thermal; cat /sys/class/thermal/thermal_zone*/type /sys/class/thermal/thermal_zone*/temp 2>/dev/null"
save_cmd "$OUT/power/dumpsys-battery.txt" "dumpsys battery"
save_cmd "$OUT/power/dmesg.txt" "dmesg | grep -iE 'pmic|smb|bq259|charger|qcom,qpnp|rpmh|regulator'"
save_cmd "$OUT/power/regulator-ls.txt" "ls /sys/class/regulator 2>/dev/null | head"
save_cmd "$OUT/power/regulator-names.txt" "for d in /sys/class/regulator/regulator.*; do echo \$d \$(cat \$d/name 2>/dev/null) \$(cat \$d/microvolts 2>/dev/null); done"

# ---- clocks / debugfs ----
mkdir -p "$OUT/debugfs"
log "debugfs"
save_cmd "$OUT/debugfs/mount.txt" "mount -t debugfs none /sys/kernel/debug 2>/dev/null; ls /sys/kernel/debug | head -200"
save_cmd "$OUT/debugfs/clk-summary.txt" "cat /sys/kernel/debug/clk/clk_summary"
save_cmd "$OUT/debugfs/gpio.txt" "cat /sys/kernel/debug/gpio"
save_cmd "$OUT/debugfs/pinctrl.txt" "cat /sys/kernel/debug/pinctrl/*/pinmux-pins 2>/dev/null | head -c 800000"
save_cmd "$OUT/debugfs/interconnect.txt" "ls -lR /sys/kernel/debug/interconnect 2>/dev/null | head -c 200000"
save_cmd "$OUT/debugfs/rpmh.txt" "ls -lR /sys/kernel/debug/rpmh 2>/dev/null | head"
save_cmd "$OUT/debugfs/dma.txt" "ls /sys/kernel/debug/dma_buf 2>/dev/null; cat /sys/kernel/debug/dma_buf/bufinfo 2>/dev/null | head -c 200000"

# ---- buses ----
mkdir -p "$OUT/buses"
log "buses"
save_cmd "$OUT/buses/i2c.txt" "ls -lR /sys/bus/i2c/devices 2>/dev/null"
save_cmd "$OUT/buses/spi.txt" "ls -lR /sys/bus/spi/devices 2>/dev/null"
save_cmd "$OUT/buses/spi-board.txt" "ls -l /sys/bus/spi/devices/*/of_node /sys/bus/i2c/devices/*/of_node 2>/dev/null"
save_cmd "$OUT/buses/pci.txt" "ls -lR /sys/bus/pci/devices 2>/dev/null; cat /proc/bus/pci/devices 2>/dev/null"
save_cmd "$OUT/buses/platform.txt" "ls /sys/bus/platform/devices | head -500"
save_cmd "$OUT/buses/soc.txt" "ls /sys/devices/soc0; cat /sys/devices/soc0/* 2>/dev/null"

# ---- firmware / vendor blobs listing ----
mkdir -p "$OUT/firmware"
log "firmware listing"
save_cmd "$OUT/firmware/vendor-firmware.txt" "find /vendor/firmware /vendor/firmware_mnt /odm/firmware -type f 2>/dev/null"
save_cmd "$OUT/firmware/modalias.txt" "find /sys -name modalias -exec cat {} \\; 2>/dev/null | sort -u"
# copy key wifi bdf / board files if small
adb shell su -c 'tar -C / -cf - vendor/firmware/wlan vendor/etc/wifi odm/etc/wifi vendor/firmware/tfa98xx.cnt 2>/dev/null' > "$OUT/firmware/wifi-etc.tar" 2>/dev/null || true

# ---- HAL / android services ----
mkdir -p "$OUT/android"
log "android HALs"
save_cmd "$OUT/android/lshal.txt" "lshal --types=all 2>/dev/null | head -c 800000"
save_cmd "$OUT/android/service-list.txt" "service list"
save_cmd "$OUT/android/pm-features.txt" "pm list features"
save_cmd "$OUT/android/hardware-features.txt" "pm list features | grep -iE 'touch|wifi|bluetooth|camera|audio|usb|opengles|vulkan|nfc'"
save_cmd "$OUT/android/dumpsys-window.txt" "dumpsys window policy | head -c 200000"
save_cmd "$OUT/android/build-prop.txt" "cat /system/build.prop /vendor/build.prop /odm/etc/build.prop 2>/dev/null"

# ---- extra sysfs snapshots useful for ACPI ----
mkdir -p "$OUT/sysfs"
log "sysfs snapshots"
save_cmd "$OUT/sysfs/class.txt" "ls /sys/class"
save_cmd "$OUT/sysfs/firmware.txt" "ls -lR /sys/firmware 2>/dev/null | head -c 400000"
save_cmd "$OUT/sysfs/qcom-ls.txt" "ls /sys/devices/platform | grep -iE 'qcom|soc|pm8150|pm8008|pm8150b'"

# sizes summary
log "writing MANIFEST"
{
  echo "device=dagu"
  echo "stamp=$STAMP"
  echo "serial=$(adb get-serialno)"
  echo "build=$(adb shell getprop ro.build.version.incremental | tr -d '\r')"
  echo "kernel=$(adb shell uname -r | tr -d '\r')"
  echo "root=magisk"
  echo "host=$(uname -a)"
  echo
  echo "=== files ==="
  find "$OUT" -type f -printf '%s\t%p\n' | sort -n
} > "$OUT/MANIFEST.txt"

log "DONE $OUT"
echo "$OUT"
