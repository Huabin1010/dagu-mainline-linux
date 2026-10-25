#!/bin/sh
# Rebuild Ubuntu's BlueZ with linux-mainline/patches/bluez-*.patch as Debian
# quilt patches and a +dagu local version, then install bluez, libbluetooth3
# and bluez-obexd. Run on the tablet as root (native arm64).
#
#   sudo ./dagu-build-bluez.sh
#
# The image build takes the result from dagu-repack-pinned.sh; this script
# is how that package is made.
set -eu
HERE="$(dirname "$(readlink -f "$0")")"
PATCH_DIR="${DAGU_BLUEZ_PATCHES:-$HERE/../patches}"
WORKDIR="${DAGU_BLUEZ_BUILD:-/usr/local/src/bluez-dagu}"
LOCAL_SUFFIX="${DAGU_BLUEZ_SUFFIX:-+dagu1}"
if [ "$(id -u)" -ne 0 ]; then
	echo "run as root" >&2
	exit 1
fi
set -- "$PATCH_DIR"/bluez-*.patch
[ -f "$1" ] || { echo "no bluez-*.patch in $PATCH_DIR" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
# apt-cache policy is parsed below; keep its labels in English.
export LC_ALL=C
# apt-get source needs deb-src.
for f in /etc/apt/sources.list.d/*.sources; do
	[ -f "$f" ] || continue
	grep -q '^Types: deb$' "$f" && sed -i 's/^Types: deb$/Types: deb deb-src/' "$f"
done
apt-get update -qq
apt-get install -y -qq --no-install-recommends build-essential dpkg-dev \
	devscripts fakeroot quilt
apt-get build-dep -y -qq bluez
VER=$(apt-cache policy bluez | awk '/Candidate:/ {print $2}' | sed "s/$LOCAL_SUFFIX\$//")
[ -n "$VER" ] || { echo "no bluez candidate version" >&2; exit 1; }
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
apt-get source -qq "bluez=$VER"
cd bluez-*/
for p in "$@"; do
	name="dagu-$(basename "$p" .patch | sed 's/^bluez-[0-9.]*-//').patch"
	cp "$p" "debian/patches/$name"
	echo "$name" >>debian/patches/series
done
QUILT_PATCHES=debian/patches quilt push -a
# This libcups2-dev reports cups_serverbin /usr/lib/cups; the package's
# bluez-cups.install expects the multiarch path.
cat >>debian/rules <<'EOF'

execute_after_dh_auto_install:
	if [ -e debian/tmp/usr/lib/cups/backend/bluetooth ]; then \
		mkdir -p debian/tmp/usr/lib/$(DEB_HOST_MULTIARCH)/cups/backend; \
		mv debian/tmp/usr/lib/cups/backend/bluetooth debian/tmp/usr/lib/$(DEB_HOST_MULTIARCH)/cups/backend/; \
	fi
EOF
DEBEMAIL=dagu@localhost DEBFULLNAME=dagu dch -v "$VER$LOCAL_SUFFIX" \
	-D "$(lsb_release -cs)" "dagu: $(cd debian/patches && ls dagu-*.patch | tr '\n' ' ')"
DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" dpkg-buildpackage -b -uc -us -j"$(nproc)"
cd "$WORKDIR"
dpkg -i "bluez_$VER${LOCAL_SUFFIX}_"*.deb "libbluetooth3_$VER${LOCAL_SUFFIX}_"*.deb \
	"bluez-obexd_$VER${LOCAL_SUFFIX}_"*.deb
apt-mark hold bluez libbluetooth3 bluez-obexd >/dev/null
systemctl restart bluetooth.service
systemctl is-active bluetooth.service
echo "installed bluez $VER$LOCAL_SUFFIX"
