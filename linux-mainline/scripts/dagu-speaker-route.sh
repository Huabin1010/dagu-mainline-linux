#!/bin/sh
# Open the Q6 TDM playback path that ACP/UCM may miss after boot.
# Safe to run repeatedly; CS35L41 controls appear after codec probe.
set -eu
CARD="${DAGU_ALSA_CARD:-0}"

cset() {
	amixer -c "$CARD" cset "name=$1" "$2" >/dev/null 2>&1 || true
}

cset "TERT_TDM_RX_0 Audio Mixer MultiMedia1" on
for p in TL TR BL BR; do
	cset "$p PCM Source" ASP
	cset "$p Analog PCM Volume" 20
	cset "$p Digital PCM Volume" 850
done
exit 0
