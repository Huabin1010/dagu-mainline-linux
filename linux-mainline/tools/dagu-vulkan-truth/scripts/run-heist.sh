#!/usr/bin/env bash
# Host orchestrator for dagu-event-store-heist.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/out/android"
HOST_OUT="${HEIST_OUT:-${ROOT}/out/captures/pass5-input-att}"
DEV=/data/local/tmp/dagu-vulkan-truth
ADB="${ADB:-adb}"

[[ -x "${OUT}/dagu-vk-probe" ]] || { echo "run scripts/build.sh first" >&2; exit 1; }
[[ -x "${OUT}/kgsl_spy" ]] || { echo "missing kgsl_spy; run scripts/build.sh" >&2; exit 1; }
mkdir -p "$HOST_OUT"

STAGE=/data/local/tmp/dvt-stage
$ADB shell "su -c 'setenforce 0; mkdir -p $DEV /data/vendor/gpu /data/misc/gpu'"
$ADB shell "mkdir -p $STAGE"
$ADB push "${OUT}/dagu-vk-probe" "${OUT}/libkgsl_wrap.so" "${OUT}/kgsl_spy" \
  "${ROOT}/qgl_config.txt" "${ROOT}/qgl_config_force_gmem.txt" \
  "${ROOT}/adreno_icd.json" \
  "${ROOT}/scripts/run-heist-on-device.sh" "$STAGE/"
$ADB shell "su -c 'cp -f $STAGE/* $DEV/; chmod 755 $DEV/dagu-vk-probe $DEV/libkgsl_wrap.so $DEV/kgsl_spy $DEV/run-heist-on-device.sh; chown root:root $DEV/*'"

echo "---- device heist ----"
$ADB shell "su -c 'HEIST_PASSES=${HEIST_PASSES:-D} sh $DEV/run-heist-on-device.sh'" | tee "${HOST_OUT}/device-heist.log"

echo "---- pull ----"
$ADB shell "su -c 'ls -la $DEV /data/vendor/gpu /data/misc/gpu'" | tee "${HOST_OUT}/device-ls.log"
for f in heist_icd_linear.rd heist_icd_linear.wrap.log heist_icd_linear.run.log \
         heist_spy_linear.rd heist_spy_linear.wrap.log heist_spy_linear.run.log \
         heist_spy_load.rd heist_spy_load.wrap.log heist_spy_load.run.log \
         heist_spy_input.rd heist_spy_input.wrap.log heist_spy_input.run.log \
         linear.report.txt linear.direct.bgra linear.copy.rgba \
         linear_input.report.txt linear_input.direct.bgra linear_input.copy.rgba \
         caps.log; do
  $ADB pull "$DEV/$f" "$HOST_OUT/" 2>/dev/null || true
done

mkdir -p "${HOST_OUT}/qgl"
$ADB shell "su -c 'find /data/vendor/gpu /data/misc/gpu -type f 2>/dev/null'" \
  | tee "${HOST_OUT}/qgl-files.txt" || true
while read -r p; do
  [[ -n "${p:-}" ]] || continue
  base=$(basename "$p")
  $ADB pull "$p" "${HOST_OUT}/qgl/$base" 2>/dev/null || true
done < "${HOST_OUT}/qgl-files.txt"

echo "captures in $HOST_OUT"
ls -la "$HOST_OUT"
