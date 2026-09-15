#!/bin/sh
# Install libdagu-mutter-release.so and load it on the next gdm session.
# Does not flash. Requires session restart (AutomaticLogin=dagu).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${DAGU_SSH_HOST:-192.168.7.2}"
KEY="${DAGU_SSH_KEY:-$ROOT/out/id_dagu}"
SO="$ROOT/scripts/libdagu-mutter-release.so"
[ -f "$SO" ] || {
	echo "missing $SO" >&2
	exit 2
}
ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST" \
	'cat >/usr/local/lib/libdagu-mutter-release.so && chmod 755 /usr/local/lib/libdagu-mutter-release.so' <"$SO"
ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST" 'sh -s' <<'EOS'
set -eu
mkdir -p /home/dagu/.config/environment.d
cat >/home/dagu/.config/environment.d/50-dagu-mutter-release.conf <<'EOF'
LD_PRELOAD=/usr/local/lib/libdagu-mutter-release.so
EOF
chown -R dagu:dagu /home/dagu/.config/environment.d
# New UUID so GNOME 50 actually loads the is_maximized / clock-tick JS.
mkdir -p /home/dagu/.local/share/gnome-shell/extensions/dagu-scanout@local
EOS
scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	"$ROOT/scripts/dagu-scanout@local/extension.js" \
	"$ROOT/scripts/dagu-scanout@local/metadata.json" \
	"root@$HOST:/home/dagu/.local/share/gnome-shell/extensions/dagu-scanout@local/"
ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST" 'sh -s' <<'EOS'
chown -R dagu:dagu /home/dagu/.local/share/gnome-shell/extensions/dagu-scanout@local
sudo -u dagu env XDG_RUNTIME_DIR=/run/user/1001 \
	DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \
	gsettings set org.gnome.shell enabled-extensions \
	"['ding@rastersoft.com', 'ubuntu-dock@ubuntu.com', 'tiling-assistant@ubuntu.com', 'dagu-osk-focus@dagu', 'dagu-scanout@local']"
echo installed
ls -l /usr/local/lib/libdagu-mutter-release.so /home/dagu/.config/environment.d/50-dagu-mutter-release.conf
EOS
