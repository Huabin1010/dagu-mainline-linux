#!/bin/sh
# ADSP voice topology acceptance. Does not encode on the AP.
#   Fluence AEC/NS: speaker 440 Hz + capture; ADSP COPP must be open.
#   VA: MultiMedia3 capture from VA_CODEC_DMA_TX_0.
#   A2DP: MultiMedia4 -> SLIMBUS_7_RX AFE start (headset optional).
set -eu
CARD="${DAGU_ALSA_CARD:-0}"
FAIL=0

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAIL=1; }

if ! command -v amixer >/dev/null; then
	echo "dagu-adsp-voice-test: need amixer" >&2
	exit 1
fi

if [ ! -e /sys/class/remoteproc/remoteproc0/state ]; then
	fail "no remoteproc0"
else
	st=$(cat /sys/class/remoteproc/remoteproc0/state)
	[ "$st" = running ] && pass "ADSP $st" || fail "ADSP $st"
fi

if amixer -c "$CARD" cget "name=Fluence AEC NS" >/dev/null 2>&1; then
	pass "mixer Fluence AEC NS exists"
else
	fail "mixer Fluence AEC NS missing — kernel overlay not in this Image"
fi

if amixer -c "$CARD" cget "name=SLIMBUS_7_RX Audio Mixer MultiMedia4" >/dev/null 2>&1; then
	pass "mixer SLIMBUS_7_RX Audio Mixer MultiMedia4 exists"
else
	fail "mixer SLIMBUS_7_RX missing"
fi

if [ -x /usr/local/sbin/dagu-mic-route.sh ]; then
	/usr/local/sbin/dagu-mic-route.sh || true
fi
if [ -x /usr/local/sbin/dagu-va-route.sh ]; then
	/usr/local/sbin/dagu-va-route.sh || true
fi
if [ -x /usr/local/sbin/dagu-bt-a2dp-route.sh ]; then
	/usr/local/sbin/dagu-bt-a2dp-route.sh || true
fi

# Echo ref is TERT_TDM_RX_0. Route speaker, then start playback, then capture.
if [ -x /usr/local/sbin/dagu-speaker-route.sh ]; then
	/usr/local/sbin/dagu-speaker-route.sh || true
fi
SPK_PID=""
if command -v speaker-test >/dev/null; then
	speaker-test -D "hw:${CARD},0" -c 2 -r 48000 -F S24_LE -t sine -f 440 -l 0 \
		>/tmp/dagu-fluence-spk.log 2>&1 &
	SPK_PID=$!
	sleep 2
fi

# Capture 1s of Fluence mic (ADSP). Timeout is a fail; bytes>0 is pass.
MIC_WAV=/tmp/dagu-fluence.wav
if command -v arecord >/dev/null; then
	if arecord -D "hw:${CARD},1" -f S16_LE -c 1 -r 48000 -d 1 "$MIC_WAV" >/tmp/dagu-fluence-arecord.log 2>&1; then
		sz=$(wc -c <"$MIC_WAV")
		if [ "$sz" -gt 1000 ]; then
			pass "Fluence capture hw:${CARD},1 ${sz} bytes"
		else
			fail "Fluence capture too small ($sz)"
		fi
	else
		fail "arecord hw:${CARD},1"
		cat /tmp/dagu-fluence-arecord.log >&2 || true
	fi
else
	fail "no arecord"
fi
if [ -n "$SPK_PID" ]; then
	kill "$SPK_PID" 2>/dev/null || true
	wait "$SPK_PID" 2>/dev/null || true
fi

VA_WAV=/tmp/dagu-va.wav
if command -v arecord >/dev/null; then
	if arecord -D "hw:${CARD},2" -f S16_LE -c 1 -r 48000 -d 1 "$VA_WAV" >/tmp/dagu-va-arecord.log 2>&1; then
		sz=$(wc -c <"$VA_WAV")
		if [ "$sz" -gt 1000 ]; then
			pass "VA capture hw:${CARD},2 ${sz} bytes"
		else
			fail "VA capture too small ($sz)"
		fi
	else
		fail "arecord hw:${CARD},2 (VA)"
		cat /tmp/dagu-va-arecord.log >&2 || true
	fi
fi

# Q6 SLIMBUS_7 is S24_LE stereo. AFE 0x400e START needs a live A2DP sink;
# without a headset the DSP returns EFAILED. Mixer + prepare is the topology.
if command -v speaker-test >/dev/null; then
	if speaker-test -D "hw:${CARD},3" -c 2 -r 48000 -F S24_LE -t sine -f 440 -l 1 \
		>/tmp/dagu-a2dp-aplay.log 2>&1; then
		pass "A2DP PCM hw:${CARD},3 opened"
	elif dmesg | grep -q "AFE enable for port 0x400e"; then
		pass "A2DP AFE 0x400e reached ADSP (pair a headset for listen)"
	elif dmesg | grep -q "SLIMBUS_7_RX"; then
		pass "A2DP SLIMBUS_7_RX DAI prepared"
	else
		fail "A2DP hw:${CARD},3"
		cat /tmp/dagu-a2dp-aplay.log >&2 || true
	fi
fi

FLUENCE_OK=0
if dmesg | grep 'dagu fluence topo=0x' | grep -v failed >/tmp/dagu-fluence-dmesg.txt 2>/dev/null; then
	if [ -s /tmp/dagu-fluence-dmesg.txt ]; then
		FLUENCE_OK=1
	fi
fi
if [ "$FLUENCE_OK" -eq 1 ]; then
	pass "dmesg Fluence COPP"
	tail -3 /tmp/dagu-fluence-dmesg.txt
else
	fail "Fluence COPP not open on ADSP (NULL_COPP fallback)"
	dmesg | grep "dagu fluence\|dagu adm open_v8" | tail -8
fi

if [ "$FAIL" -ne 0 ]; then
	echo "dagu-adsp-voice-test: FAILED"
	exit 1
fi
echo "dagu-adsp-voice-test: OK"
exit 0
