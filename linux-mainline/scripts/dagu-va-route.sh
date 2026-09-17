#!/bin/sh
# VA_CODEC_DMA_TX_0 is the ADSP Voice Activation capture port (KWS frontend).
# Capture PCM is MultiMedia3 (hw:0,2). Do not run a CPU keyword spotter.
set -eu
CARD="${DAGU_ALSA_CARD:-0}"

cset() {
	if ! amixer -c "$CARD" cset "name=$1" "$2" >/dev/null 2>&1; then
		echo "dagu-va-route: cset FAIL '$1'=$2" >&2
		return 1
	fi
	return 0
}

cset "MultiMedia3 Mixer VA_CODEC_DMA_TX_0" on || true
# VA analog/DMIC widgets if the VA macro exported them this boot.
cset "VA DEC0 MUX" VA_DMIC || true
cset "VA_AIF1_CAP Mixer DEC0" 1 || true
echo "dagu-va-route: VA_CODEC_DMA_TX_0 -> MultiMedia3 (hw:${CARD},2)"
exit 0
