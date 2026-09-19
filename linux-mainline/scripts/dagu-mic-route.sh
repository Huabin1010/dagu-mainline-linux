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
# the codec driver, not the XML).
# Capture FE: prefer MultiMedia3 (hw:0,2). Q6 ASM OPEN_READ_V3 0x10db4
# returns ADSP_EALREADY (9) if the previous session leaked (kernel
# close skips CMD_CLOSE unless RUNNING). Then probe MM4 (hw:0,3), MM2
# (hw:0,1). Speaker stays MM1 playback.
set -eu
CARD="${DAGU_ALSA_CARD:-0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1001}"
RUNDIR="${DAGU_RUNDIR:-$XDG_RUNTIME_DIR}"
# udev RUN must stay widgets-only. arecord probe needs a free PCM;
# audio-up --repair sets DAGU_MIC_PROBE=1 after destroying linger.
PROBE="${DAGU_MIC_PROBE:-0}"
if [ ! -d "$RUNDIR" ]; then
	if [ "$(id -u)" -eq 0 ]; then
		RUNDIR=/tmp
	else
		mkdir -p "$RUNDIR" 2>/dev/null || RUNDIR=/tmp
	fi
fi
PCMFILE="${RUNDIR}/mic-pcm"

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

mm_off_all() {
	n=1
	while [ "$n" -le 8 ]; do
		cset "MultiMedia${n} Mixer TX_CODEC_DMA_TX_3" off || true
		n=$((n + 1))
	done
}

probe_fe() {
	dev=$1
	mm=$2
	wav=/tmp/dagu-mic-probe.wav
	rm -f "$wav"
	cset "MultiMedia${mm} Mixer TX_CODEC_DMA_TX_3" on || true
	timeout -s INT 0.8 arecord -D "hw:${CARD},${dev}" -c 1 -r 48000 -f S16_LE \
		-d 1 "$wav" >/dev/null 2>&1 || true
	sz=0
	if [ -f "$wav" ]; then
		sz=$(wc -c <"$wav")
	fi
	if [ "$sz" -gt 2000 ]; then
		echo "$dev" >"$PCMFILE" 2>/dev/null || echo "$dev" >/tmp/dagu-mic-pcm
		echo "dagu-mic-route: capture hw:${CARD},${dev} MultiMedia${mm} (${sz} bytes)" >&2
		rm -f "$wav"
		return 0
	fi
	cset "MultiMedia${mm} Mixer TX_CODEC_DMA_TX_3" off || true
	rm -f "$wav"
	return 1
}

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

if [ "$PROBE" = "1" ]; then
	mm_off_all
	# MM3 first (product default). MM4 if OPEN_READ leaked. MM2 last.
	if probe_fe 2 3 || probe_fe 3 4 || probe_fe 1 2; then
		exit 0
	fi
	echo "dagu-mic-route: no live capture FE, leave MultiMedia3 armed" >&2
	cset "MultiMedia3 Mixer TX_CODEC_DMA_TX_3" on || true
	echo 2 >"$PCMFILE" 2>/dev/null || echo 2 >/tmp/dagu-mic-pcm || true
	exit 0
fi

# Widgets only: do not mm_off_all (that mutes a live linger). Arm the
# last known FE, or MultiMedia3 on first boot.
dev=2
if [ -f "$PCMFILE" ]; then
	dev=$(cat "$PCMFILE")
elif [ -f /tmp/dagu-mic-pcm ]; then
	dev=$(cat /tmp/dagu-mic-pcm)
fi
mm=$((dev + 1))
cset "MultiMedia${mm} Mixer TX_CODEC_DMA_TX_3" on || true
echo "$dev" >"$PCMFILE" 2>/dev/null || echo "$dev" >/tmp/dagu-mic-pcm || true
exit 0
