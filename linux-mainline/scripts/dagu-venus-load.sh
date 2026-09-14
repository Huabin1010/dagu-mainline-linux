#!/bin/sh
# Load qcom-venus so /dev/video14 exists. Modules live in extra/, not autoload.
# Do not hide insmod errors: leftover userdata .ko from an older Image
# fail with ".gnu.linkonce.this_module section size must match".
set -eu
KVER=$(uname -r)

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

# This 7.0.0-dirty vmlinux rejects some rebuilt .ko BTF ("Invalid name", -22).
# The text/data still match; drop .BTF and retry so userdata venus-new can
# boot without a reflash.
insmod_ko() {
	ko=$1
	insmod_one "$ko" && return 0
	objcopy=$(command -v objcopy 2>/dev/null || command -v llvm-objcopy 2>/dev/null || true)
	[ -n "$objcopy" ] || return 1
	mkdir -p /run/dagu-venus
	tmp=/run/dagu-venus/$(basename "$ko")
	if "$objcopy" --remove-section=.BTF --remove-section=.BTF.ext "$ko" "$tmp" 2>/dev/null \
		|| "$objcopy" --remove-section=.BTF "$ko" "$tmp" 2>/dev/null; then
		log "retry stripped BTF $ko"
		insmod_one "$tmp"
		return $?
	fi
	return 1
}

core_loaded() {
	lsmod | grep -q '^venus_core '
}

load_dir() {
	dir=$1
	[ -f "$dir/venus-core.ko" ] || return 1
	if core_loaded; then
		return 1
	fi
	log "using $dir"
	insmod_ko "$dir/venus-core.ko" || return 1
	insmod_ko "$dir/venus-dec.ko" || true
	insmod_ko "$dir/venus-enc.ko" || true
	[ -e /dev/video14 ]
}

modprobe videobuf2-v4l2 2>/dev/null || true
modprobe v4l2-mem2mem 2>/dev/null || true
if [ ! -e /dev/video14 ]; then
	# venus-new: iterate without reflashing boot.img. extra/: ramdisk copy
	# that matches this Image. Must fall back — preferring venus-new alone
	# left /dev/video14 missing after every reboot (BTF -22).
	for dir in /root/venus-new /lib/modules/$KVER/extra /root/venus-ko; do
		if load_dir "$dir"; then
			break
		fi
	done
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
