#!/bin/sh
# Bring desktop audio back after the CS35L41 card exists.
# Do NOT put hw:0,0 in pipewire context.objects: a missing card makes
# PipeWire exit 234, systemd hits start-limit, and the session stays silent.
set -eu
CARD="${DAGU_ALSA_CARD:-0}"
PCM="/dev/snd/pcmC${CARD}D0p"
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
while [ "$j" -lt 20 ]; do
	if wpctl status >/dev/null 2>&1; then
		break
	fi
	j=$((j + 1))
	sleep 0.25
done

# No pactl on this rootfs. UCM HiFi appears once PipeWire starts
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
	s && /Microphone|Mic/ {
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
