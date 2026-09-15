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
(cd "$OUT/fw/vendor" && md5sum ./* >"$OUT/fw/android.md5")
echo "wrote $OUT (no flash)"
