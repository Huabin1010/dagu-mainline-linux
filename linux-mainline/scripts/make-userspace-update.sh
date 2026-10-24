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
install -m644 "$ROOT/systemd/logind-dagu-power.conf" "$STAGE/files/etc/systemd/logind.conf.d/dagu-power.conf"
install -m644 "$ROOT/systemd/dagu-camera-loopback-watch.service" \
	"$STAGE/files/etc/systemd/system/dagu-camera-loopback-watch.service"
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
systemctl reload systemd-logind 2>/dev/null || systemctl kill -s HUP systemd-logind
systemctl restart dagu-camera-loopback-watch.service
echo "installed; reboot once so the new kernel and these files meet"
EOF
chmod 755 "$STAGE/install.sh"
(cd "$STAGE" && find files -type f -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
tar -C "$ROOT/out" -czf "$ROOT/out/$NAME.tar.gz" "$NAME"
ls -l "$ROOT/out/$NAME.tar.gz"
