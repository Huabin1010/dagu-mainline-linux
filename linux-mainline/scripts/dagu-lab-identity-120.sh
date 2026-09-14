#!/bin/sh
# 120fps lab: Mutter identity destile + Chrome GPU-rotate 270°.
# Venus stays on (/dev/video14). Do not enable software decode.
#
# On tablet as root:
#   /usr/local/sbin/dagu-lab-identity-120.sh
# Daily restore:
#   rm -f /run/user/1001/dagu-identity
#   python3 /usr/local/sbin/dagu-mutter-orientation.py set-daily-temp
#   restart dagu-chromium without DAGU_CHROME_PANEL_ROTATE.
set -eu

export XDG_RUNTIME_DIR=/run/user/1001
export WAYLAND_DISPLAY=wayland-0
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus

# 8ms scanout pump destiles stale Chrome buffers. Identity does not need it.
sudo -u dagu env \
	XDG_RUNTIME_DIR=/run/user/1001 \
	DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \
	gnome-extensions disable dagu-scanout@local 2>/dev/null || true

# Do not pkill this script's ssh parent. Match the binary only.
pkill -u dagu -f '/usr/lib/chromium/chromium' 2>/dev/null || true

# Destile shmem can take a few seconds to drop after Chrome exits.
i=0
while [ "$i" -lt 20 ]; do
	avail=$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
	shmem=$(awk '/^Shmem:/ {print int($2/1024)}' /proc/meminfo)
	if [ "$avail" -ge 1100 ] && [ "$shmem" -le 1600 ]; then
		break
	fi
	i=$((i + 1))
	sleep 1
done
avail=$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
shmem=$(awk '/^Shmem:/ {print int($2/1024)}' /proc/meminfo)
echo "mem after chrome-exit: avail=${avail}M shmem=${shmem}M"
if [ "$avail" -lt 800 ]; then
	echo "MemAvailable ${avail}M < 800M; refuse identity (OOM/hang risk)" >&2
	exit 2
fi

# Flag survives Debian chromium wrapper env sanitizing.
install -d -m755 /run/user/1001
touch /run/user/1001/dagu-identity
chown dagu:dagu /run/user/1001/dagu-identity
python3 /usr/local/sbin/dagu-mutter-orientation.py set-normal-1-temp

rm -rf /tmp/dagu-lab-profile
install -d -o dagu -g dagu /tmp/dagu-lab-profile

ss -ltn | grep -q ':8770 ' || {
	echo "start lab first: python3 /usr/local/sbin/dagu-pipeline-lab.py --serve" >&2
	exit 1
}

# DAGU_WAYLAND_DEBUG=1 → libwayland WAYLAND_DEBUG=1 on Chrome stderr.
# Extremely verbose; identity capture only. Not a daily default.
WD_ENV=""
if [ "${DAGU_WAYLAND_DEBUG:-0}" = "1" ]; then
	WD_ENV="WAYLAND_DEBUG=1"
fi

sudo -u dagu env \
	XDG_RUNTIME_DIR=/run/user/1001 \
	WAYLAND_DISPLAY=wayland-0 \
	DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \
	DAGU_CHROME_PANEL_ROTATE=270 \
	$WD_ENV \
	/usr/local/bin/dagu-chromium \
	--user-data-dir=/tmp/dagu-lab-profile \
	--no-first-run \
	--start-fullscreen \
	--window-size=1600,2560 \
	--enable-logging=stderr \
	http://127.0.0.1:8770/dagu-pipeline-tab.html \
	>/tmp/dagu-lab-identity.chrome.log 2>&1 &
echo "lab chrome pid $!  DAGU_CHROME_PANEL_ROTATE=270  mutter transform 0"
echo "dump: python3 -c 'import urllib.request; print(urllib.request.urlopen(\"http://127.0.0.1:8770/api/dump\").read().decode())'"
