#!/bin/sh
# Match stock Android speaker path (mixer_paths_overlay_static.xml):
#   DSP1 Firmware=Protection, Preload on, PCM Source=DSP, DRE on,
#   AMP PCM Gain=18, Digital PCM=0 dB, Soft Ramp=4ms,
#   ASP TX1/TX2 = VMON/IMON (Android ASPTX Ref=Ref).
# Factory ReDC (CAL_R) is applied by the kernel after preload — do not try
# to write it from ALSA (wm_adsp flags those coeffs SYS).
# Mainline control names drop "Volume" / "Switch" (Android tinymix keeps them).
# Mainline wm_adsp only auto-loads cirrus/cs35l41-dsp1-spk-prot.bin (no
# prefix). Stage each amp's Xiaomi *.bin there, then preload that amp.
set -eu
CARD="${DAGU_ALSA_CARD:-0}"
FWDIR=/lib/firmware/cirrus
STAMP=/run/dagu/speaker-dsp-loaded

cset() {
	if ! amixer -c "$CARD" cset "name=$1" "$2" >/dev/null 2>&1; then
		echo "dagu-speaker-route: cset FAIL '$1'=$2" >&2
		return 1
	fi
	return 0
}

cset_any() {
	val=$1
	shift
	for n in "$@"; do
		if amixer -c "$CARD" cset "name=$n" "$val" >/dev/null 2>&1; then
			return 0
		fi
	done
	echo "dagu-speaker-route: cset_any FAIL $* = $val" >&2
	return 1
}

cset "TERT_TDM_RX_0 Audio Mixer MultiMedia1" on || true

mkdir -p /run/dagu
if [ ! -f "$STAMP" ]; then
	for p in TL TR BL BR; do
		cset_any off "$p DSP1 Preload" "$p DSP1 Preload Switch" || true
	done
	# 0 dB on mainline TLV (Android tinymix Digital=0 writes the same HW 0 dB).
	# Analog 18 = Android AMP PCM Gain 18.
	for p in TL TR BL BR; do
		bin="$FWDIR/${p}-cs35l41-dsp1-spk-prot.bin"
		if [ -f "$bin" ]; then
			cp -f "$bin" "$FWDIR/cs35l41-dsp1-spk-prot.bin"
		fi
		cset "$p DSP1 Firmware" Protection || true
		cset "$p DSP RX1 Source" ASPRX1 || true
		cset "$p DSP RX2 Source" ASPRX2 || true
		cset "$p ASP TX1 Source" VMON || true
		cset "$p ASP TX2 Source" IMON || true
		cset_any on "$p DSP1 Preload" "$p DSP1 Preload Switch" || true
	done
	date -u +%s >"$STAMP"
fi

for p in TL TR BL BR; do
	cset "$p DSP1 Firmware" Protection || true
	cset "$p DSP RX1 Source" ASPRX1 || true
	cset "$p DSP RX2 Source" ASPRX2 || true
	cset "$p ASP TX1 Source" VMON || true
	cset "$p ASP TX2 Source" IMON || true
	cset "$p PCM Soft Ramp" 4ms || true
	cset_any on "$p DRE" "$p DRE Switch" || true
	cset_any 18 "$p Analog PCM" "$p Analog PCM Volume" || true
	cset_any 817 "$p Digital PCM" "$p Digital PCM Volume" || true
	cset "$p PCM Source" DSP || true
done
exit 0
