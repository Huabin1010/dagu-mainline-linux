#!/bin/sh
# Enable Q6 SLIMBUS_7_RX as the A2DP playback backend (CAF bt-a2dp).
# PCM is MultiMedia4 (hw:0,3). Encoding stays on ADSP, not HCI SBC on the AP.
set -eu
CARD="${DAGU_ALSA_CARD:-0}"

cset() {
	if ! amixer -c "$CARD" cset "name=$1" "$2" >/dev/null 2>&1; then
		echo "dagu-bt-a2dp-route: cset FAIL '$1'=$2" >&2
		return 1
	fi
	return 0
}

cset "SLIMBUS_7_RX Audio Mixer MultiMedia4" on || true
echo "dagu-bt-a2dp-route: SLIMBUS_7_RX <- MultiMedia4 (hw:${CARD},3)"
exit 0
