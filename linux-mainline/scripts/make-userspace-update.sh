#!/usr/bin/env bash
# Pack the userspace pieces a release changes, for tablets that keep their
# existing userdata (no rootfs reflash). The camera producer links against
# the tablet's libcamera, so it is built on the tablet; pass that binary.
#
#   ./scripts/make-userspace-update.sh v0.1.5 /path/to/dagu-camera-loopback
#
# Writes out/dagu-userspace-<version>.tar.gz. On the tablet:
#   tar xzf dagu-userspace-<version>.tar.gz && sudo ./dagu-userspace-<version>/install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VER="${1:?version, e.g. v0.1.5}"
CAM="${2:?aarch64 dagu-camera-loopback built on the tablet}"
NAME="dagu-userspace-$VER"
STAGE="$ROOT/out/$NAME"

[[ "$(head -c 4 "$CAM")" == $'\x7fELF' ]] || { echo "$CAM is not an ELF" >&2; exit 1; }
rm -rf "$STAGE"
mkdir -p "$STAGE/files/usr/local/sbin" "$STAGE/files/etc/systemd/logind.conf.d" \
	"$STAGE/files/etc/systemd/system"

install -m755 "$ROOT/scripts/dagu_offmode_charger.py" "$STAGE/files/usr/local/sbin/dagu-offmode-charger"
install -m755 "$CAM" "$STAGE/files/usr/local/sbin/dagu-camera-loopback"
install -m755 "$ROOT/scripts/dagu_boot_success.py" "$STAGE/files/usr/local/sbin/dagu-boot-success"
install -m644 "$ROOT/systemd/dagu-boot-success.service" \
	"$STAGE/files/etc/systemd/system/dagu-boot-success.service"
install -m644 "$ROOT/systemd/logind-dagu-power.conf" "$STAGE/files/etc/systemd/logind.conf.d/dagu-power.conf"
install -m644 "$ROOT/systemd/dagu-camera-loopback-watch.service" \
	"$STAGE/files/etc/systemd/system/dagu-camera-loopback-watch.service"
# Shutdown: text console stays lit until / is read-only, then dark.
mkdir -p "$STAGE/files/usr/lib/systemd/system-shutdown"
install -m755 "$ROOT/systemd/dagu-shutdown-final" \
	"$STAGE/files/usr/lib/systemd/system-shutdown/dagu-shutdown-final"
# s2idle: SEE client stop/start around sleep, magic-packet-only WoWLAN.
mkdir -p "$STAGE/files/usr/lib/systemd/system-sleep" \
	"$STAGE/files/etc/NetworkManager/conf.d"
install -m755 "$ROOT/systemd/dagu-folio-resume" \
	"$STAGE/files/usr/lib/systemd/system-sleep/dagu-folio-resume"
install -m644 "$ROOT/systemd/20-dagu-wifi-wowlan.conf" \
	"$STAGE/files/etc/NetworkManager/conf.d/20-dagu-wifi-wowlan.conf"
install -m755 "$ROOT/scripts/dagu-wifi-wowlan-apply.sh" \
	"$STAGE/files/usr/local/sbin/dagu-wifi-wowlan-apply"
# Daily fstrim keeps the UFS WriteBooster buffer from shrinking to 0.
mkdir -p "$STAGE/files/etc/systemd/system/fstrim.timer.d"
install -m644 "$ROOT/systemd/fstrim-dagu-daily.conf" \
	"$STAGE/files/etc/systemd/system/fstrim.timer.d/dagu-daily.conf"
# Wi-Fi power save follows the charger.
mkdir -p "$STAGE/files/etc/udev/rules.d" "$STAGE/files/etc/NetworkManager/dispatcher.d"
install -m755 "$ROOT/scripts/dagu-wifi-powersave.sh" \
	"$STAGE/files/usr/local/sbin/dagu-wifi-powersave"
install -m644 "$ROOT/systemd/71-dagu-wifi-powersave.rules" \
	"$STAGE/files/etc/udev/rules.d/71-dagu-wifi-powersave.rules"
install -m755 "$ROOT/systemd/60-dagu-wifi-powersave.dispatcher" \
	"$STAGE/files/etc/NetworkManager/dispatcher.d/60-dagu-wifi-powersave"
# Bluetooth: BlueZ +dagu (GATT after LE bonding) from the pinned set, the
# archive gnome-bluetooth to replace the patched one older images held,
# and the Wi-Fi-only shell overlay generator.
PINNED_DIR="${PINNED_DIR:-$ROOT/out/dagu-pinned}"
STOCK_DIR="${STOCK_DIR:-$ROOT/out/dagu-stock-restore}"
mkdir -p "$STAGE/debs/pinned" "$STAGE/debs/stock"
for pkg in bluez libbluetooth3 bluez-obexd; do
	set -- "$PINNED_DIR/${pkg}_"*+dagu*.deb
	[ -f "$1" ] || { echo "no $pkg +dagu deb in $PINNED_DIR (dagu-repack-pinned.sh)" >&2; exit 1; }
	cp "$1" "$STAGE/debs/pinned/"
done
# V4L2 Chromium: hardware WebCodecs encode and seek-while-paused
# (8df8b99) are in the binary, so upgrades need the new build too.
for pkg in chromium chromium-common chromium-sandbox; do
	set -- "$PINNED_DIR/${pkg}_"*.deb
	[ -f "$1" ] || { echo "no $pkg deb in $PINNED_DIR (dagu-repack-pinned.sh)" >&2; exit 1; }
	cp "$1" "$STAGE/debs/pinned/"
done
for pkg in libgnome-bluetooth-3.0-13 libgnome-bluetooth-ui-3.0-13; do
	set -- "$STOCK_DIR/${pkg}_"*.deb
	[ -f "$1" ] || { echo "no archive $pkg deb in $STOCK_DIR (dagu-repack-pinned.sh)" >&2; exit 1; }
	cp "$1" "$STAGE/debs/stock/"
done
install -m755 "$ROOT/scripts/dagu-gnome-status-spinner.py" \
	"$STAGE/files/usr/local/sbin/dagu-gnome-status-spinner.py"
# Upstream QCA6390 amss/m3 (stage-firmware.sh). The kernel loads them from
# the boot ramdisk; the rootfs copy is what a Wi-Fi restart reloads.
FWQ="$ROOT/firmware/dagu/lib/firmware/ath11k/QCA6390/hw2.0"
if grep -aq 'QCAHSTSWPLZ_V2_TO_X86' "$FWQ/amss.bin" 2>/dev/null; then
	mkdir -p "$STAGE/files/usr/lib/firmware/ath11k/QCA6390/hw2.0"
	install -m644 "$FWQ/amss.bin" "$FWQ/m3.bin" \
		"$STAGE/files/usr/lib/firmware/ath11k/QCA6390/hw2.0/"
else
	echo "warning: $FWQ is not the upstream QCA6390 build; run stage-firmware.sh" >&2
fi
# Same text the rootfs build writes; keep one source of truth.
sed -n '/^cat >\/usr\/local\/sbin\/dagu-shutdown-display <<.EOF.$/,/^EOF$/p' \
	"$ROOT/scripts/rootfs-desktop-setup.sh" | sed '1d;$d' \
	>"$STAGE/files/usr/local/sbin/dagu-shutdown-display"
chmod 755 "$STAGE/files/usr/local/sbin/dagu-shutdown-display"
grep -q VT_ACTIVATE "$STAGE/files/usr/local/sbin/dagu-shutdown-display" || {
	echo "dagu-shutdown-display extract failed" >&2
	exit 1
}

cat >"$STAGE/install.sh" <<'EOF'
#!/bin/sh
# Install this release's userspace on a running dagu tablet (as root).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
# /lib is a symlink to usr/lib (usrmerge), so files/ only uses usr/lib.
# --remove-destination: running binaries (camera producer) are replaced,
# not opened for writing ("Text file busy").
cp -a --remove-destination "$here/files/." /
# Power-off is a real power-off now; the shutdown-diverting daemon held
# logind for 20 s on every shutdown. Remove it.
systemctl disable --now dagu-offmode-daemon.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/dagu-offmode-daemon.service \
	/etc/systemd/system/multi-user.target.wants/dagu-offmode-daemon.service
# Bluetooth: drop the helpers that rewrote pairable / page scan / sniff
# behind bluetoothd, go back to the packaged main.conf and input.conf,
# install BlueZ +dagu and the archive gnome-bluetooth.
systemctl disable --now dagu-bt-hid-host.timer dagu-bt-hid-host.service >/dev/null 2>&1 || true
rm -f /usr/local/sbin/dagu-bt-hid-host.sh \
	/usr/local/sbin/dagu-bluez-hid-wait-incoming.py \
	/usr/local/sbin/dagu-build-bluez-hid.sh \
	/usr/local/sbin/dagu-gnome-bt-setup-unnamed.py \
	/usr/local/sbin/dagu-build-gnome-bt.sh \
	/etc/systemd/system/dagu-bt-hid-host.service \
	/etc/systemd/system/dagu-bt-hid-host.timer \
	/etc/systemd/system/bluetooth.service.d/dagu-hid-host.conf \
	/etc/udev/rules.d/90-dagu-bt-hid-host.rules \
	/etc/bluetooth/main.conf /etc/bluetooth/input.conf
apt-mark unhold bluez libbluetooth3 bluez-obexd \
	libgnome-bluetooth-3.0-13 libgnome-bluetooth-ui-3.0-13 \
	chromium chromium-common chromium-sandbox >/dev/null 2>&1 || true
dpkg -i --force-confmiss "$here"/debs/pinned/*.deb
dpkg -i "$here"/debs/stock/*.deb
apt-mark hold bluez libbluetooth3 bluez-obexd \
	chromium chromium-common chromium-sandbox >/dev/null
/usr/local/sbin/dagu-gnome-status-spinner.py || true
systemctl daemon-reload
udevadm control --reload || true
/usr/local/sbin/dagu-wifi-powersave || true
systemctl restart fstrim.timer >/dev/null 2>&1 || true
fstrim / >/dev/null 2>&1 || true
# Mark the booted A/B slot successful on every boot. Without it ABL's
# retry counter (7 per set_active) runs out and the tablet stops in fastboot.
systemctl enable --now dagu-boot-success.service
# Re-stamp Wi-Fi profiles: disconnect / GTK triggers woke the tablet and
# nothing put it back to sleep with the cover open.
nmcli general reload conf >/dev/null 2>&1 || true
/usr/local/sbin/dagu-wifi-wowlan-apply || true
systemctl reload systemd-logind 2>/dev/null || systemctl kill -s HUP systemd-logind
systemctl restart dagu-camera-loopback-watch.service
echo "installed; reboot once so the new kernel and these files meet"
EOF
chmod 755 "$STAGE/install.sh"
(cd "$STAGE" && find files debs -type f -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
tar -C "$ROOT/out" -czf "$ROOT/out/$NAME.tar.gz" "$NAME"
ls -l "$ROOT/out/$NAME.tar.gz"
