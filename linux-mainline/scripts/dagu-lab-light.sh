#!/bin/sh
# Low-pressure lab: one clean Chrome profile, 2×720 Venus, no scanout, no Bilibili.
# Results: curl http://127.0.0.1:8770/api/dump   (do not screenshot)
set -eu

# Root SSH inherits /run/user/0. Force the dagu session.
export XDG_RUNTIME_DIR=/run/user/1001
export WAYLAND_DISPLAY=wayland-0
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus

# Do not match this ssh/script command line.
pkill -u dagu -f '/usr/lib/chromium/chromium' 2>/dev/null || true
sleep 1

rm -rf /tmp/dagu-lab-profile
install -d -o dagu -g dagu /tmp/dagu-lab-profile

ss -ltn | grep -q ':8770 ' || {
	echo "start lab first: python3 /usr/local/sbin/dagu-pipeline-lab.py --serve" >&2
	exit 1
}

# Keep daily 1.25 / transform 3. Do not GPU-pre-rotate here (would double-spin).
rm -f /run/user/1001/dagu-identity
sudo -u dagu env \
	XDG_RUNTIME_DIR=/run/user/1001 \
	WAYLAND_DISPLAY=wayland-0 \
	DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \
	/usr/local/bin/dagu-chromium \
	--user-data-dir=/tmp/dagu-lab-profile \
	--no-first-run \
	--start-maximized \
	http://127.0.0.1:8770/dagu-pipeline-tab.html \
	>/tmp/dagu-lab-light.chrome.log 2>&1 &
echo "light chrome pid $!  dump: curl -s http://127.0.0.1:8770/api/dump"
