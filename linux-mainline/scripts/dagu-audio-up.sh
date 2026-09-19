#!/bin/sh
# Bring desktop audio back after the CS35L41 card exists.
# Do NOT put hw:0,0 in pipewire context.objects: a missing card makes
# PipeWire exit 234, systemd hits start-limit, and the session stays silent.
# Mic is MultiMedia3 hw:0,2. ACP (ALSA Card Profile) probes every UCM
# device while Speaker PCM is held; Mic hw_params then EINVAL and HiFi
# is dropped (Dummy, no speakers, no mic). HiFi is Speaker-only; this
# script publishes the capture PCM as a linger PipeWire source.
set -eu
CARD="${DAGU_ALSA_CARD:-0}"
PCM="/dev/snd/pcmC${CARD}D0p"
MICPCM="/dev/snd/pcmC${CARD}D2c"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1001}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

i=0
while [ ! -e "$PCM" ]; do
	i=$((i + 1))
	[ "$i" -gt 60 ] && {
		echo "dagu-audio-up: no $PCM" >&2
		exit 1
	}
	sleep 0.5
done

if [ -x /usr/local/sbin/dagu-speaker-route.sh ]; then
	/usr/local/sbin/dagu-speaker-route.sh || true
fi
if [ -x /usr/local/sbin/dagu-mic-route.sh ]; then
	/usr/local/sbin/dagu-mic-route.sh || true
fi

if [ "$(id -u)" -eq 0 ]; then
	exec sudo -u dagu env \
		XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
		DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
		HOME=/home/dagu USER=dagu LOGNAME=dagu \
		"$0" "$@"
fi

systemctl --user reset-failed \
	pipewire.service pipewire.socket \
	pipewire-pulse.service pipewire-pulse.socket \
	wireplumber.service >/dev/null 2>&1 || true
systemctl --user start \
	pipewire.socket pipewire.service \
	pipewire-pulse.socket pipewire-pulse.service \
	wireplumber.service

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
if wpctl status 2>/dev/null | grep -q 'Dummy Output'; then
	systemctl --user try-restart \
		pipewire.service pipewire-pulse.service wireplumber.service \
		>/dev/null 2>&1 || true
	k=0
	while [ "$k" -lt 28 ]; do
		wpctl status >/dev/null 2>&1 && \
			! wpctl status 2>/dev/null | grep -q 'Dummy Output' && break
		k=$((k + 1))
		sleep 0.25
	done
fi

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

publish_mic() {
	if mic_listed; then
		return 0
	fi
	n=0
	while [ ! -e "$MICPCM" ]; do
		n=$((n + 1))
		[ "$n" -gt 20 ] && {
			echo "dagu-audio-up: no $MICPCM" >&2
			return 1
		}
		sleep 0.25
	done
	# SPA JSON: commas in hw:0,2 must be quoted. object.linger keeps
	# the node after pw-cli exits. Pin spa S16LE: Q6 S24_LE is not
	# spa S24_32LE (8-bit left shift) — that path was ~48 dB hot with
	# a 5.3 kHz carrier (破音 / 电流声). arecord S16 on this PCM is
	# clean. One channel: only AMIC5; FR was digital zero.
	# hw:0,2 is MultiMedia3. Never suspend (timeout 0).
	pw-cli create-node adapter "{ factory.name=api.alsa.pcm.source node.name=dagu-builtin-mic node.nick=Microphone node.description=Microphone media.class=Audio/Source api.alsa.path=\"hw:${CARD},2\" audio.rate=48000 audio.channels=1 audio.format=S16LE alsa.resolution_bits=16 object.linger=true priority.session=2000 api.alsa.disable-tsched=true session.suspend-timeout-seconds=0 }" \
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

publish_mic || true

# No pactl on this rootfs. UCM HiFi Speakers appear once PipeWire starts
# after /dev/snd/pcmC0D0p exists (do not use context.objects).
id=$(wpctl status 2>/dev/null | awk '
	$0 ~ /Sinks:/{s=1}
	s && /Audio\/Source/{exit}
	s && /\*/ && /Speakers|Speaker/{
		for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}
	}
	s && /Speakers|Speaker/ && $1 ~ /^[0-9]+/{print $1; exit}
')
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
exit 0
