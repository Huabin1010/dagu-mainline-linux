#!/bin/sh
# Push libcamera SoftISP NV12 into v4l2loopback /dev/video20 (front) and
# /dev/video21 (rear). Apps that only open classic V4L2 capture use these
# nodes. This is not Spectra ISP.
set -eu

FRONT_DEV="${DAGU_LOOPBACK_FRONT:-/dev/video20}"
REAR_DEV="${DAGU_LOOPBACK_REAR:-/dev/video21}"
WIDTH="${DAGU_LOOPBACK_WIDTH:-1280}"
HEIGHT="${DAGU_LOOPBACK_HEIGHT:-720}"

log() { printf 'dagu-camera-loopback: %s\n' "$*"; }

if ! command -v gst-launch-1.0 >/dev/null; then
	log "gst-launch-1.0 missing"
	exit 1
fi

i=0
while [ ! -e "$FRONT_DEV" ] || [ ! -e "$REAR_DEV" ]; do
	i=$((i + 1))
	[ "$i" -gt 60 ] && { log "no $FRONT_DEV / $REAR_DEV"; exit 1; }
	sleep 0.5
done

# Prefer libcamerasrc (SoftISP NV12). Fall back is not RAW RDI.
names=$(gst-inspect-1.0 libcamerasrc 2>/dev/null | head -1 || true)
if [ -z "$names" ]; then
	log "libcamerasrc missing; install gstreamer1.0-libcamera"
	exit 1
fi

front_name="${DAGU_LIBCAMERA_FRONT:-}"
rear_name="${DAGU_LIBCAMERA_REAR:-}"
if [ -z "$front_name" ] || [ -z "$rear_name" ]; then
	list=$(cam --list-cameras 2>/dev/null || true)
	# cam -l: "1: 'imx596' (...)" / "2: 's5kjn1' (...)"
	if [ -z "$front_name" ]; then
		front_name=$(printf '%s\n' "$list" | sed -n "s/.*'\\(imx596[^']*\\)'.*/\\1/p" | head -1)
	fi
	if [ -z "$rear_name" ]; then
		rear_name=$(printf '%s\n' "$list" | sed -n "s/.*'\\(s5kjn1[^']*\\)'.*/\\1/p" | head -1)
	fi
fi

log "front=$front_name -> $FRONT_DEV rear=$rear_name -> $REAR_DEV ${WIDTH}x${HEIGHT}"

pipe() {
	src_name=$1
	sink=$2
	if [ -z "$src_name" ]; then
		log "skip $sink (no camera name)"
		return 0
	fi
	exec gst-launch-1.0 -q \
		libcamerasrc camera-name="$src_name" \
		! video/x-raw,format=NV12,width="$WIDTH",height="$HEIGHT" \
		! videoconvert \
		! v4l2sink device="$sink" sync=false
}

# Two processes: one per node. systemd can run this script as Type=simple
# with a wait; we start both and wait.
pipe "$front_name" "$FRONT_DEV" &
p1=$!
pipe "$rear_name" "$REAR_DEV" &
p2=$!
trap 'kill $p1 $p2 2>/dev/null || true' INT TERM
wait $p1 $p2
