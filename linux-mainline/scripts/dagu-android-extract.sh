#!/usr/bin/env bash
# Read-only extract from the Android dagu tablet. NEVER flash that machine.
# Set DAGU_ADB_SERIAL to the extract tablet. Do not hardcode a unit serial.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL="${DAGU_ADB_SERIAL:?set DAGU_ADB_SERIAL to the Android tablet serial}"
OUT="${DAGU_ANDROID_OUT:-$ROOT/out/android-extract}"

die() { echo "dagu-android-extract: $*" >&2; exit 1; }

serial=$(adb -s "$SERIAL" get-serialno)
[ "$serial" = "$SERIAL" ] || die "adb serial is '$serial', expected $SERIAL (will not touch the other tablet)"
echo "extract-only $SERIAL -> $OUT"

mkdir -p "$OUT/sf" "$OUT/audio" "$OUT/fw/vendor"

adb -s "$SERIAL" shell dumpsys SurfaceFlinger >"$OUT/sf/sf_now.txt"
adb -s "$SERIAL" shell su -c tinymix >"$OUT/audio/android_tinymix_now.txt" || true

for f in mixer_paths_overlay_static.xml mixer_paths_overlay_dynamic.xml \
	mixer_paths.xml audio_platform_info.xml audio_tuning_mixer.txt; do
	adb -s "$SERIAL" pull "/vendor/etc/$f" "$OUT/audio/$f" >/dev/null
done

for f in \
	cs35l41-dsp1-spk-prot.wmfw \
	TL-cs35l41-dsp1-spk-prot.bin TR-cs35l41-dsp1-spk-prot.bin \
	BL-cs35l41-dsp1-spk-prot.bin BR-cs35l41-dsp1-spk-prot.bin \
	TL-music.txt TR-music.txt BL-music.txt BR-music.txt \
	TL-voice.txt TR-voice.txt BL-voice.txt BR-voice.txt; do
	adb -s "$SERIAL" exec-out su -c "cat /vendor/firmware/$f" >"$OUT/fw/vendor/$f"
done
adb -s "$SERIAL" exec-out su -c "cat /vendor/etc/cirrus.cfg" >"$OUT/fw/vendor/cirrus.cfg"
mkdir -p "$OUT/fw/dsp"
# DSP blobs are on firmware_mnt (vfat). dd via Magisk, then tar.
adb -s "$SERIAL" shell "su -c 'mkdir -p /data/local/tmp/dagu-dsp
for f in cdsp.mdt cdsp.b00 cdsp.b01 cdsp.b02 cdsp.b03 cdsp.b04 cdsp.b05 cdsp.b06 cdsp.b08 cdsp.b09 cdsp.b11 cdspr.jsn slpi.mdt slpi.b00 slpi.b01 slpi.b02 slpi.b03 slpi.b04 slpi.b05 slpi.b06 slpi.b07 slpi.b08 slpi.b09 slpi.b10 slpi.b11 slpi.b12 slpi.b13 slpi.b14 slpi.b15 slpi.b16 slpi.b17 slpi.b18 slpi.b19 slpi.b20 slpir.jsn slpius.jsn; do
  dd if=/vendor/firmware_mnt/image/\$f of=/data/local/tmp/dagu-dsp/\$f bs=1M 2>/dev/null
done
tar -C /data/local/tmp/dagu-dsp -cf - .'" | tar --no-same-permissions --no-same-owner -xf - -C "$OUT/fw/dsp"
(cd "$OUT/fw/vendor" && md5sum ./* >"$OUT/fw/android.md5")
echo "wrote $OUT (no flash)"
