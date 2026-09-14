#!/bin/bash
# Snapshot audio / display / Venus around one S2Idle cycle.
# Wake sources: PMIC pwrkey (enabled) and optional USB. No RTC on this board.
set -euo pipefail
TAG="${1:-pre}"
OUT="${2:-/tmp/dagu-s2idle-${TAG}.txt}"
{
  echo "===== $TAG $(date -Iseconds) ====="
  echo -n "uptime="; uptime
  echo -n "adsp_name="; cat /sys/class/remoteproc/remoteproc0/name
  echo -n "adsp_state="; cat /sys/class/remoteproc/remoteproc0/state
  echo -n "adsp_fw="; cat /sys/class/remoteproc/remoteproc0/firmware
  echo "--- video ---"
  ls -l /dev/video14 /dev/video15 2>&1 || true
  lsmod | grep venus || true
  echo "--- drm ---"
  grep -E "modifier=|format=" /sys/kernel/debug/dri/0/state 2>/dev/null | head -8 || true
  echo -n "card0="; ls /dev/dri/card0 /dev/dri/renderD128 2>&1
  echo "--- hangcheck ---"
  dmesg | grep -c "hangcheck recover" || true
  dmesg | grep -iE "gpu fault|hangcheck|qcom-venus: SSR|Unhandled context" | tail -15 || true
  echo "--- power ---"
  echo -n "mem_sleep="; cat /sys/power/mem_sleep
  echo -n "suspend_success="; cat /sys/power/suspend_stats/success
  echo -n "suspend_fail="; cat /sys/power/suspend_stats/fail
  echo -n "last_failed_dev="; cat /sys/power/suspend_stats/failed_dev 2>/dev/null || true
  echo -n "last_failed_errno="; cat /sys/power/suspend_stats/last_failed_errno 2>/dev/null || true
  echo "--- alsa ---"
  aplay -l 2>&1 | head -20
} >"$OUT"
chmod 644 "$OUT"
echo "wrote $OUT"
