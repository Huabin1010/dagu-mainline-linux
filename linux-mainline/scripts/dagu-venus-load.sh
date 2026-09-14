#!/bin/sh
# Load qcom-venus so /dev/video14 exists. Modules live in extra/, not autoload.
# Do not hide insmod errors: leftover userdata .ko from an older Image
# fail with ".gnu.linkonce.this_module section size must match".
set -eu
KVER=$(uname -r)
EXTRA=/lib/modules/$KVER/extra
[ -f "$EXTRA/venus-core.ko" ] || EXTRA=/root/venus-ko

log() {
	echo "dagu-venus-load: $*"
	echo "dagu-venus-load: $*" >/dev/kmsg 2>/dev/null || true
}

insmod_one() {
	ko=$1
	if [ ! -f "$ko" ]; then
		log "missing $ko"
		return 1
	fi
	if insmod "$ko"; then
		log "insmod $ko"
		return 0
	fi
	log "insmod failed $ko"
	return 1
}

modprobe videobuf2-v4l2 2>/dev/null || true
modprobe v4l2-mem2mem 2>/dev/null || true
if [ ! -e /dev/video14 ]; then
	insmod_one "$EXTRA/venus-core.ko" || true
	insmod_one "$EXTRA/venus-dec.ko" || true
	insmod_one "$EXTRA/venus-enc.ko" || true
fi
# Chrome / gst as dagu need rw on the decoder.
if [ -e /dev/video14 ]; then
	chgrp video /dev/video14 /dev/video15 2>/dev/null || true
	chmod 660 /dev/video14 /dev/video15 2>/dev/null || true
	# Chromium V4L2 (CrOS pattern + Armbian SM8250). Official
	# google-chrome does not have USE_V4L2_CODEC; V4L2 Chromium does.
	ln -sfn video14 /dev/video-dec0
	ln -sfn video15 /dev/video-enc0
	log "ready /dev/video14 /dev/video15"
	exit 0
fi
log "no /dev/video14 — need matching venus-*.ko for $KVER"
exit 1
