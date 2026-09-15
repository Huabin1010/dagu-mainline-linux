#!/usr/bin/env bash
# Read-only display-pipeline extract from the Android dagu tablet.
# NEVER flash that machine. Set DAGU_ADB_SERIAL to the extract tablet.
#
# Optional 8s 120 Hz swipe sample (restores miui_refresh_rate):
#   DAGU_ANDROID_120HZ_SAMPLE=1 ./scripts/dagu-android-display-pipeline.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL="${DAGU_ADB_SERIAL:?set DAGU_ADB_SERIAL to the Android tablet serial}"
OUT="${DAGU_ANDROID_DISPLAY_OUT:-$ROOT/out/android-extract/display-pipeline}"
REMOTE="/data/local/tmp/dagu-disp-pipeline"
SAMPLE="${DAGU_ANDROID_120HZ_SAMPLE:-1}"

die() { echo "dagu-android-display-pipeline: $*" >&2; exit 1; }

serial=$(adb -s "$SERIAL" get-serialno)
[ "$serial" = "$SERIAL" ] || die "adb serial is '$serial', expected $SERIAL (will not touch the other tablet)"
echo "extract-only $SERIAL -> $OUT"

rm -rf "$OUT"
mkdir -p "$OUT"/{prop,sf,sys,dt,proc,vendor,sample,fdt}

adb -s "$SERIAL" shell su -c "rm -rf $REMOTE; mkdir -p $REMOTE"

# Device-side dump (no loops with broken su quoting on the host).
adb -s "$SERIAL" push "$ROOT/scripts/dagu-android-display-pipeline-ondevice.sh" \
	/data/local/tmp/dagu-android-display-pipeline-ondevice.sh >/dev/null
adb -s "$SERIAL" shell su -c 'sh /data/local/tmp/dagu-android-display-pipeline-ondevice.sh'

adb -s "$SERIAL" pull "$REMOTE" "$OUT/device" >/dev/null

# Vendor files used by SF / HWC / Xiaomi displayfeature.
for f in \
	/vendor/etc/display/advanced_sf_offsets.xml \
	/vendor/etc/ltm_config_xiaomi_42_04_0a_video_mode_dual_dsi_dphy_panel.xml \
	/vendor/etc/qdcm_calib_data_xiaomi_42_04_0a_video_mode_dual_dsi_dphy_panel.xml \
	/vendor/etc/init/init.qti.display_boot.rc \
	/vendor/etc/init/vendor.qti.hardware.display.composer-service.rc \
	/vendor/etc/init/vendor.xiaomi.hardware.displayfeature@1.0-service.rc \
	/vendor/etc/init/vendor.display.color@1.0-service.rc \
	/vendor/etc/init/vendor.qti.hardware.display.allocator-service.rc \
	/vendor/bin/init.qti.display_boot.sh
do
	base=$(basename "$f")
	adb -s "$SERIAL" exec-out su -c "cat $f" >"$OUT/vendor/$base" 2>/dev/null || true
done

# Host-side dumpsys (can be large; keep full for SF scheduler).
adb -s "$SERIAL" shell dumpsys SurfaceFlinger >"$OUT/sf/sf_now.txt"
adb -s "$SERIAL" shell dumpsys display >"$OUT/sf/dumpsys-display.txt"
adb -s "$SERIAL" shell dumpsys displayfeature >"$OUT/sf/dumpsys-displayfeature.txt" || true
adb -s "$SERIAL" shell settings list system >"$OUT/prop/settings-system.txt" || true
adb -s "$SERIAL" shell settings list secure >"$OUT/prop/settings-secure.txt" || true
adb -s "$SERIAL" shell settings list global >"$OUT/prop/settings-global.txt" || true

# CAF live FDT excerpt already decompiled on the host dump machine.
REPO="$(cd "$ROOT/.." && pwd)"
FDT="$REPO/dumps/dagu-20260826-210700-root/dt/fdt.dts"
if [ -f "$FDT" ]; then
	awk '/qcom,mdss_dsi_l81a_42_04_0a_dual_dphy_video \{/,/qcom,mdss_dsi_m82_36_02_0a_dual_dphy_video \{/' "$FDT" \
		| grep -vE 'command =|command-state' \
		> "$OUT/fdt/l81a-panel-excerpt.dts" || true
	sed -n '21928,22080p' "$FDT" >"$OUT/fdt/sde-kms-excerpt.dts" || true
fi

if [ "$SAMPLE" = 1 ]; then
	echo "120 Hz swipe sample (will restore miui_refresh_rate)"
	python3 "$ROOT/scripts/dagu-android-display-pipeline-sample.py" \
		--serial "$SERIAL" --out "$OUT/sample" \
		--script-dir "$ROOT/scripts"
fi

echo "wrote $OUT (no flash)"
