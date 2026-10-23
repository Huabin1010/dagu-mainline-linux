#!/bin/sh
# Rebuild gnome-control-center so the Wi-Fi header spinner follows the
# scan, a failed RequestScan clears the scanning flag, and the connection
# row hears NMActiveConnection notify::state. A secured network asks for
# its password before the current network is dropped. Hold the package so
# apt does not restore the old panel. Run on the tablet or in the rootfs
# chroot as root.
set -eu

SRC_HELPER="$(dirname "$(readlink -f "$0")")/dagu-gnome-cc-wifi-spinner.py"
DIALOG_HELPER="$(dirname "$(readlink -f "$0")")/dagu-gnome-cc-wifi-dialog.py"
WORKDIR="${DAGU_GCC_BUILD:-/usr/local/src/dagu-gnome-cc}"

if [ ! -f "$SRC_HELPER" ] || [ ! -f "$DIALOG_HELPER" ]; then
	echo "missing $SRC_HELPER or $DIALOG_HELPER" >&2
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
apt-get install -y -qq --no-install-recommends \
	build-essential debhelper dpkg-dev fakeroot python3 quilt pkg-config
apt-get build-dep -y -qq gnome-control-center

mkdir -p "$WORKDIR"
cd "$WORKDIR"
if ! ls -d gnome-control-center-*/ >/dev/null 2>&1; then
	apt-get source -qq gnome-control-center
fi
SRC_DIR=$(ls -d gnome-control-center-*/ | head -n1)
cd "$WORKDIR/$SRC_DIR"

PANEL=$(find . -path '*/cc-wifi-panel.c' | head -n1)
DEVICE=$(find . -path '*/net-device-wifi.c' | head -n1)
LIST=$(find . -path '*/cc-wifi-connection-list.c' | head -n1)
DIALOGS=$(find . -path '*/network-dialogs.c' | head -n1)
DIALOG_H=$(find . -path '*/network-dialogs.h' | head -n1)
[ -n "$PANEL" ]
[ -n "$DEVICE" ]
[ -n "$LIST" ]
[ -n "$DIALOGS" ]
[ -n "$DIALOG_H" ]
python3 "$SRC_HELPER" "$PANEL"
python3 "$SRC_HELPER" "$DEVICE"
python3 "$SRC_HELPER" "$LIST"
python3 "$DIALOG_HELPER" "$DIALOG_H"
python3 "$DIALOG_HELPER" "$DIALOGS"
python3 "$DIALOG_HELPER" "$DEVICE"
grep -q 'scanning binding owns visibility' "$PANEL"
grep -q 'scan_deadline_us' "$DEVICE"
grep -q 'watched_ac' "$LIST"
grep -q 'ask for the Wi-Fi password before activating' "$DEVICE"
grep -q 'cc_network_panel_connect_to_wifi_ap' "$DIALOGS"

DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" dpkg-buildpackage -b -uc -us -j"$(nproc)"

DEB=$(ls -1 "$WORKDIR"/gnome-control-center_[0-9]*.deb | head -n1)
[ -n "$DEB" ]
dpkg -i "$DEB"
apt-mark hold gnome-control-center

echo "==> gnome-control-center Wi-Fi spinner follows scan and active-connection state"
