#!/bin/sh
# Rebuild Ubuntu bluetoothd so GNOME Connect on device-initiated HID
# (K380) waits for the keypress page instead of outgoing Create Connection.
# Run on the tablet or in the arm64 rootfs chroot as root.
set -eu

SRC_HELPER="$(dirname "$(readlink -f "$0")")/dagu-bluez-hid-wait-incoming.py"
WORKDIR="${DAGU_BLUEZ_BUILD:-/usr/local/src/dagu-bluez-hid}"
PREFIX="${DAGU_BLUEZ_PREFIX:-/usr/libexec/bluetooth}"

if [ ! -f "$SRC_HELPER" ]; then
	echo "missing $SRC_HELPER" >&2
	exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
	echo "run as root" >&2
	exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# Enable deb-src so apt-get source can fetch bluez.
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
	[ -f "$f" ] || continue
	if grep -q '^Types: deb$' "$f"; then
		sed -i 's/^Types: deb$/Types: deb deb-src/' "$f"
	fi
	if grep -qE '^deb ' "$f" && ! grep -qE '^deb-src ' "$f"; then
		sed -n 's/^deb /deb-src /p' "$f" >>"$f"
	fi
done

apt-get update -qq
apt-get install -y -qq --no-install-recommends \
	build-essential debhelper dpkg-dev fakeroot python3 \
	quilt pkg-config
apt-get build-dep -y -qq bluez

mkdir -p "$WORKDIR"
cd "$WORKDIR"
if [ ! -d bluez-* ] && ! ls -d bluez-*/ >/dev/null 2>&1; then
	apt-get source -qq bluez
fi
cd "$WORKDIR"/bluez-*

python3 "$SRC_HELPER" profiles/input/device.c
grep -q input_device_wait_incoming_timeout profiles/input/device.c

DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" dpkg-buildpackage -b -uc -us -j"$(nproc)"

DEB=$(ls -1 "$WORKDIR"/bluez_*.deb | head -n1)
[ -n "$DEB" ]
dpkg -i "$DEB"

install -d "$PREFIX"
if [ ! -f "$PREFIX/bluetoothd.pre-dagu-hid" ]; then
	cp -a /usr/libexec/bluetooth/bluetoothd "$PREFIX/bluetoothd.pre-dagu-hid" || true
fi

systemctl daemon-reload
systemctl restart bluetooth.service
sleep 1
systemctl is-active bluetooth.service
echo "installed $DEB"
