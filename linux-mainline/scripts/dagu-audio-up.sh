#!/bin/sh
# Bring desktop audio back after the CS35L41 card exists.
# Do NOT put hw:0,0 in pipewire context.objects: a missing card makes
# PipeWire exit 234, systemd hits start-limit, and the session stays silent.
# Mic linger is a PipeWire source on a live Q6 capture FE. Prefer
# MultiMedia3 hw:0,2. If OPEN_READ_V3 0x10db4 returns ADSP_EALREADY (9),
# that session leaked (kernel close skips CMD_CLOSE unless RUNNING) and
# spa.alsa stays SETUP / prepare EINVAL. Destroy linger, probe MM4 then
# MM2, republish. ACP (ALSA Card Profile) must not auto-port Slimbus.
# HiFi is Speaker-only.
#
# pcmC0D0p can exist tens of seconds before WCD mixer widgets. Wait for
# ADC4, then retry publish. --repair skips the long mixer wait and the
# Dummy PipeWire restart; the tester calls it when capture goes silent.
set -eu
CARD="${DAGU_ALSA_CARD:-0}"
PCM="/dev/snd/pcmC${CARD}D0p"
export XDG_RUNTIME_DIR=/run/user/1001
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
RUNDIR="${DAGU_RUNDIR:-$XDG_RUNTIME_DIR}"
MICDEV="${DAGU_MIC_PCM:-}"

REPAIR=0
[ "${1:-}" = "--repair" ] && REPAIR=1

LOCK="${XDG_RUNTIME_DIR}/dagu-audio-up.lock"
mkdir -p "$XDG_RUNTIME_DIR"
exec 9>"$LOCK"
flock 9

mixer_ready() {
	[ -e "$PCM" ] || return 1
	[ -e "/dev/snd/pcmC${CARD}D2c" ] || \
		[ -e "/dev/snd/pcmC${CARD}D3c" ] || \
		[ -e "/dev/snd/pcmC${CARD}D1c" ] || return 1
	amixer -c "$CARD" cget name="ADC4 Volume" >/dev/null 2>&1 || return 1
	amixer -c "$CARD" cget name="MultiMedia3 Mixer TX_CODEC_DMA_TX_3" >/dev/null 2>&1 || return 1
}

load_micdev() {
	if [ -z "${MICDEV}" ] && [ -f "${RUNDIR}/mic-pcm" ]; then
		MICDEV=$(cat "${RUNDIR}/mic-pcm")
	fi
	if [ -z "${MICDEV}" ] && [ -f /tmp/dagu-mic-pcm ]; then
		MICDEV=$(cat /tmp/dagu-mic-pcm)
	fi
	MICDEV="${MICDEV:-2}"
	MICPCM="/dev/snd/pcmC${CARD}D${MICDEV}c"
}

is_dummy() {
	wpctl status 2>/dev/null | grep -Eq 'Dummy Output|虚拟输出'
}

i=0
limit=180
[ "$REPAIR" = "1" ] && limit=8
while ! mixer_ready; do
	i=$((i + 1))
	[ "$i" -gt "$limit" ] && {
		echo "dagu-audio-up: no mixer (pcm=$PCM)" >&2
		exit 1
	}
	sleep 0.5
done

if [ -x /usr/local/sbin/dagu-speaker-route.sh ]; then
	/usr/local/sbin/dagu-speaker-route.sh || true
fi

if [ "$(id -u)" -eq 0 ]; then
	mkdir -p /run/dagu
	chown dagu:dagu /run/dagu 2>/dev/null || true
	chmod 775 /run/dagu 2>/dev/null || true
	exec sudo -u dagu env \
		XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
		DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
		HOME=/home/dagu USER=dagu LOGNAME=dagu \
		"$0" "$@"
fi

destroy_mic() {
	ids=$(pw-dump 2>/dev/null | python3 -c '
import json, sys
try:
    objs = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for o in objs:
    info = o.get("info") or {}
    props = info.get("props") or {}
    if props.get("node.name") == "dagu-builtin-mic":
        i = o.get("id")
        if i is not None:
            print(i)
' 2>/dev/null || true)
	for id in $ids; do
		echo "dagu-audio-up: destroy linger node $id" >&2
		pw-cli destroy "$id" >/dev/null 2>&1 || true
	done
}

mic_listed() {
	wpctl status 2>/dev/null | awk '
		$0 ~ /Sources:/{s=1}
		s && /Filters:/{exit}
		s && /Streams:/{exit}
		s && /Video/{exit}
		s && /Microphone|dagu-builtin-mic/ { found=1 }
		END { exit found ? 0 : 1 }
	'
}

if [ "$REPAIR" != "1" ]; then
	systemctl --user reset-failed \
		pipewire.service pipewire.socket \
		pipewire-pulse.service pipewire-pulse.socket \
		wireplumber.service >/dev/null 2>&1 || true
	systemctl --user start \
		pipewire.socket pipewire.service \
		pipewire-pulse.socket pipewire-pulse.service \
		wireplumber.service
fi

j=0
while [ "$j" -lt 28 ]; do
	if wpctl status >/dev/null 2>&1; then
		break
	fi
	j=$((j + 1))
	sleep 0.25
done

# Dummy means ACP rejected HiFi. Restart PW+WP together so Speaker-only
# HiFi can probe with no leftover SETUP on pcm1c.
if [ "$REPAIR" != "1" ] && is_dummy; then
	systemctl --user try-restart \
		pipewire.service pipewire-pulse.service wireplumber.service \
		>/dev/null 2>&1 || true
	k=0
	while [ "$k" -lt 28 ]; do
		wpctl status >/dev/null 2>&1 && ! is_dummy && break
		k=$((k + 1))
		sleep 0.25
	done
fi

# Linger holds the PCM in SETUP forever (suspend-timeout 0). arecord
# cannot probe a live FE until that node is gone. Give Q6 a beat after
# destroy or MM4 still looks busy and the probe falls through to MM2.
destroy_mic
sleep 0.4
if [ -x /usr/local/sbin/dagu-mic-route.sh ]; then
	DAGU_MIC_PROBE=1 /usr/local/sbin/dagu-mic-route.sh || true
fi
load_micdev

publish_mic() {
	if [ ! -e "$MICPCM" ]; then
		echo "dagu-audio-up: no $MICPCM" >&2
		return 1
	fi
	# SPA JSON: commas in hw:0,N must be quoted. object.linger keeps
	# the node after pw-cli exits. Pin spa S16LE: Q6 S24_LE is not
	# spa S24_32LE (8-bit left shift) — that path was ~48 dB hot with
	# a 5.3 kHz carrier (破音 / 电流声). arecord S16 on this PCM is
	# clean. One channel: only AMIC5; FR was digital zero.
	# Never suspend (timeout 0). MICDEV is the live FE from /run/dagu/mic-pcm.
	pw-cli create-node adapter "{ factory.name=api.alsa.pcm.source node.name=dagu-builtin-mic node.nick=Microphone node.description=Microphone media.class=Audio/Source api.alsa.path=\"hw:${CARD},${MICDEV}\" audio.rate=48000 audio.channels=1 audio.format=S16LE alsa.resolution_bits=16 object.linger=true node.always-process=true priority.session=2000 api.alsa.disable-tsched=true session.suspend-timeout-seconds=0 }" \
		>/tmp/dagu-mic-pw-node.log 2>&1 || {
		echo "dagu-audio-up: pw-cli create-node mic failed" >&2
		cat /tmp/dagu-mic-pw-node.log >&2 || true
		return 1
	}
	m=0
	while [ "$m" -lt 20 ]; do
		mic_listed && return 0
		m=$((m + 1))
		sleep 0.25
	done
	echo "dagu-audio-up: mic node not in wpctl after create-node" >&2
	return 1
}

p=0
while [ "$p" -lt 15 ]; do
	publish_mic && break
	p=$((p + 1))
	sleep 2
done

# No pactl on this rootfs. UCM HiFi Speakers appear once PipeWire starts
# after /dev/snd/pcmC0D0p exists (do not use context.objects).
id=$(wpctl status 2>/dev/null | awk '
	$0 ~ /Sinks:/{s=1}
	s && /Audio\/Source/{exit}
	s && /\*/ && /Speakers|Speaker|扬声器/{
		for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}
	}
	s && /Speakers|Speaker|扬声器/ && $1 ~ /^[0-9]+/{print $1; exit}
')
if [ -z "${id:-}" ]; then
	id=$(pw-dump 2>/dev/null | python3 -c '
import json, sys
try:
    objs = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for o in objs:
    props = (o.get("info") or {}).get("props") or {}
    if props.get("node.name") == "alsa_output.platform-sound.HiFi__Speaker__sink":
        print(o.get("id", ""))
        break
' 2>/dev/null || true)
fi
if [ -n "${id:-}" ]; then
	wpctl set-default "$id" >/dev/null 2>&1 || true
	# Volume/mute live in WirePlumber default-routes. Do not slam 100%.
fi

src=$(wpctl status 2>/dev/null | awk '
	$0 ~ /Sources:/{s=1}
	s && /Filters:/{exit}
	s && /Streams:/{exit}
	s && /Video/{exit}
	s && /Microphone|dagu-builtin-mic/ {
		for (i=1;i<=NF;i++)
			if ($i ~ /^[0-9]+\.?$/) { gsub(/\./,"",$i); print $i; exit }
	}
')
if [ -n "${src:-}" ]; then
	wpctl set-default "$src" >/dev/null 2>&1 || true
	wpctl set-mute "$src" 0 >/dev/null 2>&1 || true
fi

wpctl status 2>/dev/null | sed -n '/Audio/,/Video/p' || true

if ! mic_listed; then
	echo "dagu-audio-up: Microphone source missing" >&2
	exit 1
fi
exit 0
