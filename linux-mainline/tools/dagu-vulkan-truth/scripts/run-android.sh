#!/usr/bin/env bash
# Push binaries and run the LINEAR vs OPTIMAL capture on the attached dagu.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/out/android"
HOST_OUT="${ROOT}/out/captures"
DEV=/data/local/tmp/dagu-vulkan-truth
ADB="${ADB:-adb}"

[[ -x "${OUT}/dagu-vk-probe" ]] || { echo "run scripts/build.sh first" >&2; exit 1; }
mkdir -p "$HOST_OUT"

STAGE=/data/local/tmp/dvt-stage
$ADB shell "su -c 'setenforce 0; mkdir -p $DEV /data/vendor/gpu /data/misc/gpu'"
$ADB shell "mkdir -p $STAGE"
$ADB push "${OUT}/dagu-vk-probe" "${OUT}/libkgsl_wrap.so" \
  "${ROOT}/qgl_config.txt" "${ROOT}/qgl_config_force_gmem.txt" \
  "${ROOT}/scripts/run-on-device.sh" "$STAGE/"
$ADB shell "su -c 'cp -f $STAGE/* $DEV/; chmod 755 $DEV/dagu-vk-probe $DEV/libkgsl_wrap.so $DEV/run-on-device.sh; chown root:root $DEV/*'"

echo "---- device run ----"
$ADB shell "su -c 'sh $DEV/run-on-device.sh'" | tee "${HOST_OUT}/device-run.log"

echo "---- pull ----"
mkdir -p "${HOST_OUT}/linear" "${HOST_OUT}/optimal" "${HOST_OUT}/qgl"
$ADB shell "su -c 'ls -la $DEV /data/vendor/gpu /data/misc/gpu'" | tee "${HOST_OUT}/device-ls.log"
# pull what exists
for f in caps.log linear_run.log optimal_run.log \
         linear.report.txt optimal.report.txt \
         linear_store.rd optimal_store.rd \
         linear_wrap.log optimal_wrap.log \
         linear.direct.bgra linear.copy.rgba \
         optimal.copy.rgba; do
  $ADB pull "$DEV/$f" "$HOST_OUT/" 2>/dev/null || true
done
$ADB shell "su -c 'find /data/vendor/gpu /data/misc/gpu /data/local/tmp/vulkan -type f 2>/dev/null'" \
  | tee "${HOST_OUT}/qgl-files.txt" || true
while read -r p; do
  [[ -n "${p:-}" ]] || continue
  base=$(basename "$p")
  $ADB pull "$p" "${HOST_OUT}/qgl/$base" 2>/dev/null || true
done < "${HOST_OUT}/qgl-files.txt"

echo "captures in $HOST_OUT"
ls -la "$HOST_OUT"
