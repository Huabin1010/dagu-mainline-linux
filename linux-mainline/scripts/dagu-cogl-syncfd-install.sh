#!/bin/sh
# Install libdagu-cogl-syncfd.so into gnome-shell via the existing
# org.gnome.Shell@.service.d drop-in. Does not wrap /usr/bin/gnome-shell
# and does not call dec_use_count.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${DAGU_SSH_HOST:-192.168.7.2}"
KEY="${DAGU_SSH_KEY:-$ROOT/out/id_dagu}"
SO="$ROOT/scripts/libdagu-cogl-syncfd.so"
[ -f "$SO" ] || {
	echo "missing $SO" >&2
	exit 2
}
ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST" \
	'cat >/usr/local/lib/libdagu-cogl-syncfd.so && chmod 755 /usr/local/lib/libdagu-cogl-syncfd.so' <"$SO"
ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST" 'sh -s' <<'EOS'
set -eu
mkdir -p /etc/systemd/user/org.gnome.Shell@.service.d
cat >/etc/systemd/user/org.gnome.Shell@.service.d/dagu-cogl-syncfd.conf <<'EOF'
[Service]
Environment=LD_PRELOAD=/usr/local/lib/libdagu-cogl-syncfd.so
EOF
echo installed
ls -l /usr/local/lib/libdagu-cogl-syncfd.so /etc/systemd/user/org.gnome.Shell@.service.d/dagu-cogl-syncfd.conf
EOS
