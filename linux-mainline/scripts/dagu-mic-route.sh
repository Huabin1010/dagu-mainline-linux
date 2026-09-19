#!/bin/sh
# Match stock Android speaker-mic (mixer_paths_overlay_static.xml):
#   TX DEC0=SWR_MIC, SMIC MUX0=ADC3, ADC4 MIXER, ADC4 MUX=INP5.
#   That is WCD9385 AMIC5 on MIC BIAS3, SoundWire TX_CODEC_DMA_TX_3.
#   Headset is AMIC2; do not steal that path.
# Android analog 6 assumes Fluence. Analog 12 (18 dB). AEC_NS without
# speaker RX is digital zero; desktop leaves Fluence Off. Meeting AEC
# is in-app. Not CPU echo cancellation.
# Mainline extra vs CAF tinymix: ADC4 Switch + TX3 MODE open the
# WCD938x SoundWire ADC port (Android audio kernel does this inside
# the codec driver, not the XML). Capture FE is MultiMedia3 (hw:0,2):
# MultiMedia2 leaks the Q6 ASM session when PipeWire suspends (kernel
# close skips CMD_CLOSE unless state is RUNNING). Speaker stays MM1.
set -eu
CARD="${DAGU_ALSA_CARD:-0}"

cset() {
	if ! amixer -c "$CARD" cset "name=$1" "$2" >/dev/null 2>&1; then
		echo "dagu-mic-route: cset FAIL '$1'=$2" >&2
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
	echo "dagu-mic-route: cset_any FAIL $* = $val" >&2
	return 1
}

cset "MultiMedia2 Mixer TX_CODEC_DMA_TX_3" off || true
cset "MultiMedia3 Mixer TX_CODEC_DMA_TX_3" on || true
cset "TX DEC0 MUX" SWR_MIC || true
cset "TX SMIC MUX0" ADC3 || true
cset "TX_AIF1_CAP Mixer DEC0" 1 || true
cset "ADC4_MIXER Switch" 1 || true
cset "ADC4 MUX" INP5 || true
cset "ADC4 Switch" 1 || true
cset "TX3 MODE" ADC_HIFI || true
cset "DEC0 MODE" ADC_HIGH_PERF || true
# Analog 12 + TX_DEC0 84 (0 dB) is the Fluence path. Without AEC_NS,
# native S16 speech peak is ~170 — inaudible on playback / Meeting.
# ADC4 16 = 24 dB analog (TLV 0..30 dB, 1.5 dB/step). TX_DEC0 108 =
# +24 dB (TLV -84..+40, 84 = 0 dB). Makeup for Fluence Off, not
# spa S24_32LE (that was the 破音 / 电流声).
cset_any 16 "ADC4 Volume" || true
cset_any 108 "TX_DEC0 Volume" "DEC0 Volume" || true
cset "Fluence AEC NS" Off || true
exit 0
