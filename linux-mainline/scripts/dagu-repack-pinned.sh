#!/usr/bin/env bash
# Repack the builds a running tablet uses, for the desktop image.
#
#   DAGU_HOST=192.168.1.158 ./scripts/dagu-repack-pinned.sh
#
# Writes out/dagu-pinned/*.deb (dpkg-repack of the installed packages, so
# the patched files the tablet runs are inside) and out/dagu-dsp-userspace.tar
# (hexagonrpcd, libhexagonrpc, HexagonFS tree without the per-device
# sensor registry). build-rootfs-desktop.sh picks both up.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${DAGU_HOST:-192.168.1.158}"
SSH=(ssh -o ConnectTimeout=10 "root@$HOST")
PKGS=(
	# V4L2 Chromium (binary and its paks replace the XtraDeb build)
	chromium chromium-common chromium-sandbox
	# dagu libmutter and the gnome-shell built against it
	libmutter-18-0 mutter-common mutter-common-bin gir1.2-mutter-18
	gnome-shell gnome-shell-common
	# PipeWire stack with the patched spa-v4l2
	pipewire pipewire-bin pipewire-alsa pipewire-audio pipewire-pulse
	libpipewire-0.3-0t64 libpipewire-0.3-modules libspa-0.2-modules
	libspa-0.2-bluetooth libspa-0.2-libcamera gstreamer1.0-pipewire
	# patched libgallium and libcamera soft IPA
	mesa-libgallium libcamera-ipa
)
"${SSH[@]}" "command -v dpkg-repack >/dev/null || apt-get install -y -qq dpkg-repack
rm -rf /var/tmp/dagu-pinned && mkdir -p /var/tmp/dagu-pinned
cd /var/tmp/dagu-pinned && dpkg-repack ${PKGS[*]} >/dev/null
cd / && tar -cf /var/tmp/dagu-dsp-userspace.tar \
	--exclude='usr/share/qcom/sm8250/Xiaomi/dagu/sensors/registry/*' \
	--exclude='usr/share/qcom/sm8250/Xiaomi/dagu/sensors/persist-registry/*' \
	usr/local/bin/hexagonrpcd usr/local/lib/libhexagonrpc.so \
	usr/local/lib/libhexagonrpc.so.0.5 usr/share/qcom/sm8250/Xiaomi/dagu" </dev/null
rm -rf "$ROOT/out/dagu-pinned"
mkdir -p "$ROOT/out/dagu-pinned"
scp -q "root@$HOST:/var/tmp/dagu-pinned/*.deb" "$ROOT/out/dagu-pinned/"
scp -q "root@$HOST:/var/tmp/dagu-dsp-userspace.tar" "$ROOT/out/"
ls -l "$ROOT/out/dagu-pinned" "$ROOT/out/dagu-dsp-userspace.tar"
