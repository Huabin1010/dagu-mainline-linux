#!/usr/bin/env bash
# Probe dual-cell FG, GPU, flash, hall, haptic, USB role on a running dagu.
# OTG host drops g_serial — run this over Wi-Fi SSH, not ttyGS0.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${DAGU_SSH_HOST:-192.168.7.2}"
KEY="${DAGU_SSH_KEY:-$ROOT/out/id_dagu}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=8 "root@$HOST")

remote() { "${SSH[@]}" "$@"; }

echo "==> $HOST uname / GPU / USB role / dual-FG / flash / hall / haptic"
remote 'set -e
uname -r
echo ===gpu===
ls /dev/dri 2>/dev/null || true
dmesg | grep -iE "adreno|gmu|zap" | tail -8
if command -v eglinfo >/dev/null; then EGL_PLATFORM=gbm eglinfo -B 2>/dev/null | head -20; fi
if command -v vulkaninfo >/dev/null; then vulkaninfo --summary 2>/dev/null | head -20; fi
echo ===usb===
ls /sys/class/usb_role 2>/dev/null || true
cat /sys/class/usb_role/*/role 2>/dev/null || true
ls /sys/class/udc 2>/dev/null || true
ls /sys/devices/platform/otg-vbus-export/state 2>/dev/null || echo "no otg-vbus-export"
echo ===psy===
for p in /sys/class/power_supply/*; do
  printf "%s type=%s status=%s cap=%s volt=%s curr=%s now=%s full=%s design=%s\n" \
    "$(basename "$p")" \
    "$(cat "$p/type" 2>/dev/null || echo -)" \
    "$(cat "$p/status" 2>/dev/null || echo -)" \
    "$(cat "$p/capacity" 2>/dev/null || echo -)" \
    "$(cat "$p/voltage_now" 2>/dev/null || echo -)" \
    "$(cat "$p/current_now" 2>/dev/null || echo -)" \
    "$(cat "$p/charge_now" 2>/dev/null || echo -)" \
    "$(cat "$p/charge_full" 2>/dev/null || echo -)" \
    "$(cat "$p/charge_full_design" 2>/dev/null || echo -)"
done
echo ===upower===
upower -e 2>/dev/null || true
echo ===flash===
ls /sys/class/leds 2>/dev/null || true
echo ===hall===
grep -A6 -E "hall_key|gpio-keys" /proc/bus/input/devices || true
echo ===haptic===
dmesg | grep -iE "vib|haptic|pmi632" | tail -8
echo ===i2c-fg===
dmesg | grep -iE "bq27|bq259|p9418|i2c-gpio|dual-fg|xiaomi-dual|smb5|pm8150b-charger|typec" | tail -40
echo ===charger===
for f in online status usb_type input_current_limit constant_charge_current constant_charge_voltage; do
  printf "pm8150b-charger %s=%s\n" "$f" "$(cat /sys/class/power_supply/pm8150b-charger/$f 2>/dev/null || echo -)"
done
ls /sys/class/typec 2>/dev/null || echo "no typec class"

echo ===iio-sensors===
ls /sys/bus/iio/devices 2>/dev/null || echo none
echo ===slpi===
dmesg | grep -i slpi | tail -5 || true
'
echo "==> done"
echo "OTG VBUS (Wi-Fi SSH only):"
echo "  echo host > /sys/class/usb_role/a600000.usb-role-switch/role"
echo "  echo enabled > /sys/devices/platform/otg-vbus-export/state"
echo "  lsusb; ls /dev/sda /dev/input/event*"
echo "  echo disabled > /sys/devices/platform/otg-vbus-export/state"
echo "  echo device > /sys/class/usb_role/a600000.usb-role-switch/role"
echo "Torch: echo 64 > /sys/class/leds/white:flash/brightness ; echo 0 > ..."
