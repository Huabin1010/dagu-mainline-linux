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
# s2idle: SEE client stop/start around sleep, magic-packet-only WoWLAN.
mkdir -p "$STAGE/files/usr/lib/systemd/system-sleep" \
	"$STAGE/files/etc/NetworkManager/conf.d"
install -m755 "$ROOT/systemd/dagu-folio-resume" \
	"$STAGE/files/usr/lib/systemd/system-sleep/dagu-folio-resume"
install -m644 "$ROOT/systemd/20-dagu-wifi-wowlan.conf" \
	"$STAGE/files/etc/NetworkManager/conf.d/20-dagu-wifi-wowlan.conf"
install -m755 "$ROOT/scripts/dagu-wifi-wowlan-apply.sh" \
	"$STAGE/files/usr/local/sbin/dagu-wifi-wowlan-apply"
# Upstream QCA6390 amss/m3 (stage-firmware.sh). The kernel loads them from
# the boot ramdisk; the rootfs copy is what a Wi-Fi restart reloads.
FWQ="$ROOT/firmware/dagu/lib/firmware/ath11k/QCA6390/hw2.0"
if grep -aq 'QCAHSTSWPLZ_V2_TO_X86' "$FWQ/amss.bin" 2>/dev/null; then
	mkdir -p "$STAGE/files/lib/firmware/ath11k/QCA6390/hw2.0"
	install -m644 "$FWQ/amss.bin" "$FWQ/m3.bin" \
		"$STAGE/files/lib/firmware/ath11k/QCA6390/hw2.0/"
else
	echo "warning: $FWQ is not the upstream QCA6390 build; run stage-firmware.sh" >&2
fi
# Same text the rootfs build writes; keep one source of truth.
sed -n '/^cat >\/usr\/local\/sbin\/dagu-shutdown-display <<.EOF.$/,/^EOF$/p' \
	"$ROOT/scripts/rootfs-desktop-setup.sh" | sed '1d;$d' \
	>"$STAGE/files/usr/local/sbin/dagu-shutdown-display"
chmod 755 "$STAGE/files/usr/local/sbin/dagu-shutdown-display"
grep -q bl_power "$STAGE/files/usr/local/sbin/dagu-shutdown-display" || {
	echo "dagu-shutdown-display extract failed" >&2
	exit 1
}

cat >"$STAGE/install.sh" <<'EOF'
#!/bin/sh
# Install this release's userspace on a running dagu tablet (as root).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
cp -a "$here/files/." /
# Power-off is a real power-off now; the shutdown-diverting daemon held
# logind for 20 s on every shutdown. Remove it.
systemctl disable --now dagu-offmode-daemon.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/dagu-offmode-daemon.service \
	/etc/systemd/system/multi-user.target.wants/dagu-offmode-daemon.service
systemctl daemon-reload
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
(cd "$STAGE" && find files -type f -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
tar -C "$ROOT/out" -czf "$ROOT/out/$NAME.tar.gz" "$NAME"
ls -l "$ROOT/out/$NAME.tar.gz"
