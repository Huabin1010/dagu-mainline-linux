#!/bin/sh
# Match stock Android speaker path (mixer_paths_overlay_static.xml):
#   DSP1 Firmware=Protection, Preload on, PCM Source=DSP, DRE on,
#   AMP PCM Gain=18, Digital PCM=0 dB, Soft Ramp=4ms.
# Mainline wm_adsp only auto-loads cirrus/cs35l41-dsp1-spk-prot.bin (no
# prefix). Stage each amp's Xiaomi *.bin there, then preload that amp.
set -eu
CARD="${DAGU_ALSA_CARD:-0}"
FWDIR=/lib/firmware/cirrus
STAMP=/run/dagu/speaker-dsp-loaded

cset() {
	amixer -c "$CARD" cset "name=$1" "$2" >/dev/null 2>&1 || true
}

cset "TERT_TDM_RX_0 Audio Mixer MultiMedia1" on

mkdir -p /run/dagu
if [ ! -f "$STAMP" ]; then
	for p in TL TR BL BR; do
		cset "$p DSP1 Preload Switch" off
	done
	# 0 dB on mainline TLV (Android tinymix Digital=0 writes the same HW 0 dB).
	# Analog 18 = Android AMP PCM Gain 18.
	for p in TL TR BL BR; do
		bin="$FWDIR/${p}-cs35l41-dsp1-spk-prot.bin"
		if [ -f "$bin" ]; then
			cp -f "$bin" "$FWDIR/cs35l41-dsp1-spk-prot.bin"
		fi
		cset "$p DSP1 Firmware" Protection
		cset "$p DSP RX1 Source" ASPRX1
		cset "$p DSP RX2 Source" ASPRX2
		cset "$p DSP1 Preload Switch" on
	done
	date -u +%s >"$STAMP"
fi

for p in TL TR BL BR; do
	cset "$p DSP1 Firmware" Protection
	cset "$p DSP RX1 Source" ASPRX1
	cset "$p DSP RX2 Source" ASPRX2
	cset "$p PCM Soft Ramp" 4ms
	cset "$p DRE Switch" on
	cset "$p Analog PCM Volume" 18
	cset "$p Digital PCM Volume" 817
	cset "$p PCM Source" DSP
done
exit 0
