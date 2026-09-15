#!/bin/sh
# Load libdagu-mutter-frame-flush.so into gnome-shell. Does not destile
# and does not call dec_use_count. Unsets only the listed Mesa debug
# vars — LD_PRELOAD must stay set or the hook never lands.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${DAGU_SSH_HOST:-192.168.7.2}"
KEY="${DAGU_SSH_KEY:-$ROOT/out/id_dagu}"
SO="$ROOT/scripts/libdagu-mutter-frame-flush.so"
[ -f "$SO" ] || {
	echo "missing $SO — compile first" >&2
	exit 2
}
ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST" \
	'cat >/usr/local/lib/libdagu-mutter-frame-flush.so && chmod 755 /usr/local/lib/libdagu-mutter-frame-flush.so' <"$SO"
ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST" 'sh -s' <<'EOS'
set -eu
rm -f /etc/systemd/user/org.gnome.Shell@.service.d/dagu-cogl-syncfd.conf \
      /etc/systemd/user/org.gnome.Shell@.service.d/zz-dagu-*.conf \
      /etc/systemd/user/org.gnome.Shell@.service.d/dagu-attach.conf
mkdir -p /etc/systemd/user/org.gnome.Shell@.service.d
# Keep hardware-cursor / modifier flags; allow this one preload.
cat >/etc/systemd/user/org.gnome.Shell@.service.d/dagu-frame-flush.conf <<'EOF'
[Service]
Environment=LD_PRELOAD=/usr/local/lib/libdagu-mutter-frame-flush.so
EOF
# Stop UnsetEnvironment from wiping the hook.
if [ -f /etc/systemd/user/org.gnome.Shell@.service.d/dagu-kms.conf ]; then
	sed -i 's/UnsetEnvironment=FD_MESA_DEBUG TU_DEBUG LD_PRELOAD /UnsetEnvironment=FD_MESA_DEBUG TU_DEBUG /' \
		/etc/systemd/user/org.gnome.Shell@.service.d/dagu-kms.conf
fi
echo installed
ls -l /usr/local/lib/libdagu-mutter-frame-flush.so \
	/etc/systemd/user/org.gnome.Shell@.service.d/dagu-frame-flush.conf
EOS
