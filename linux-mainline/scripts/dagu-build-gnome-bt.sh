#!/bin/sh
# Rebuild Ubuntu gnome-bluetooth so GNOME Settings 未设置 pairs unnamed
# LE rows, treats AlreadyExists as Pair success, drains Discovering, and
# retries Connect for 25s after Pair. Installs libgnome-bluetooth-ui
# (settings widget) and libgnome-bluetooth (client Pair).
# Run on the tablet or in the arm64 rootfs chroot as root.
set -eu

SRC_HELPER="$(dirname "$(readlink -f "$0")")/dagu-gnome-bt-setup-unnamed.py"
WORKDIR="${DAGU_GNOMEBT_BUILD:-/usr/local/src/dagu-gnome-bt}"

if [ ! -f "$SRC_HELPER" ]; then
	echo "missing $SRC_HELPER" >&2
	exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
	echo "run as root" >&2
	exit 1
fi

export DEBIAN_FRONTEND=noninteractive

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
apt-get -y -qq -f install
apt-get install -y -qq --no-install-recommends \
	build-essential debhelper dpkg-dev fakeroot python3 \
	quilt pkg-config
# Ubuntu 24.04+ source is gnome-bluetooth. 22.04 used gnome-bluetooth3.
SRC_PKG=gnome-bluetooth
apt-get source -qq -s "$SRC_PKG" >/dev/null 2>&1 || SRC_PKG=gnome-bluetooth3
apt-get build-dep -y -qq "$SRC_PKG"

mkdir -p "$WORKDIR"
cd "$WORKDIR"
if ! ls -d gnome-bluetooth-*/ >/dev/null 2>&1; then
	apt-get source -qq "$SRC_PKG"
fi
SRC_DIR=$(ls -d gnome-bluetooth-*/ 2>/dev/null | head -n1)
[ -n "$SRC_DIR" ]
cd "$WORKDIR/$SRC_DIR"

WIDGET=$(find . -name bluetooth-settings-widget.c | head -n1)
CLIENT=$(find . -name bluetooth-client.c | head -n1)
[ -n "$WIDGET" ]
[ -n "$CLIENT" ]
python3 "$SRC_HELPER" "$WIDGET"
python3 "$SRC_HELPER" "$CLIENT"
grep -q 'dagu: GNOME' "$WIDGET"
grep -q 'AlreadyExists' "$CLIENT"

DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" dpkg-buildpackage -b -uc -us -j"$(nproc)"

UI_DEB=$(ls -1 "$WORKDIR"/libgnome-bluetooth-ui-3.0-*.deb 2>/dev/null | head -n1)
CLIENT_DEB=$(ls -1 "$WORKDIR"/libgnome-bluetooth-3.0-1*.deb 2>/dev/null | head -n1)
[ -n "$UI_DEB" ]
[ -n "$CLIENT_DEB" ]
dpkg -i "$CLIENT_DEB" "$UI_DEB" "$WORKDIR"/gnome-bluetooth-sendto_*.deb 2>/dev/null \
	|| dpkg -i "$CLIENT_DEB" "$UI_DEB"
apt-mark hold libgnome-bluetooth-3.0-13 2>/dev/null || true
apt-mark hold libgnome-bluetooth-ui-3.0-13 2>/dev/null || true
apt-mark hold libgnome-bluetooth-3.0-dev 2>/dev/null || true

echo "==> gnome-bluetooth patched (unnamed Pair + AlreadyExists + drain Discovering + CONNECT_TIMEOUT 25s)"
