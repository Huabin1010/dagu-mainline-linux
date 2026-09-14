#!/bin/sh
# 120fps identity lab without Chrome: Mutter transform 0 / scale 1.0 + GTK4 twin.
# Same compositor contract as dagu-lab-identity-120.sh, no Ozone / Viz.
#
# On tablet as root:
#   /usr/local/sbin/dagu-lab-identity-native.sh
# Daily restore:
#   pkill -u dagu -f '/usr/local/sbin/dagu-native-lab.py'
#   rm -f /run/user/1001/dagu-identity
#   python3 /usr/local/sbin/dagu-mutter-orientation.py set-daily-temp
set -eu

export XDG_RUNTIME_DIR=/run/user/1001
export WAYLAND_DISPLAY=wayland-0
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus

sudo -u dagu env \
	XDG_RUNTIME_DIR=/run/user/1001 \
	DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \
	gnome-extensions disable dagu-scanout@local 2>/dev/null || true

# Do not pkill this script's ssh parent. Match the binary only.
pkill -u dagu -f '/usr/lib/chromium/chromium' 2>/dev/null || true
pkill -u dagu -f '/usr/local/sbin/dagu-native-lab.py' 2>/dev/null || true
pkill -u dagu -f '/tmp/dagu-native-lab.py' 2>/dev/null || true

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

install -d -m755 /run/user/1001
touch /run/user/1001/dagu-identity
chown dagu:dagu /run/user/1001/dagu-identity
python3 /usr/local/sbin/dagu-mutter-orientation.py set-normal-1-temp

rm -f /tmp/dagu-native-lab-dump.json
VIDEO_ARG=""
if [ "${DAGU_NATIVE_VIDEO:-0}" = "1" ]; then
	VIDEO_ARG="--video"
fi

# GTK 4.22: ngl was renamed to gl. Do not leave GSK unset (cairo).
sudo -u dagu env \
	XDG_RUNTIME_DIR=/run/user/1001 \
	WAYLAND_DISPLAY=wayland-0 \
	DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \
	HOME=/home/dagu \
	GDK_BACKEND=wayland \
	GSK_RENDERER=gl \
	python3 /usr/local/sbin/dagu-native-lab.py $VIDEO_ARG \
	>/tmp/dagu-native-lab.log 2>&1 &
echo "native lab pid $!  mutter transform 0  no chrome"
echo "dump: cat /tmp/dagu-native-lab-dump.json"

# Arm DPU kickoff trace before the 8s window so measure does not flip tracing_on.
if [ -d /sys/kernel/debug/tracing ]; then
	echo 0 >/sys/kernel/debug/tracing/tracing_on
	echo >/sys/kernel/debug/tracing/trace
	echo 8192 >/sys/kernel/debug/tracing/buffer_size_kb
	echo 1 >/sys/kernel/debug/tracing/events/dpu/dpu_enc_kickoff/enable
	echo 1 >/sys/kernel/debug/tracing/events/dpu/dpu_crtc_vblank_cb/enable 2>/dev/null || true
	echo 1 >/sys/kernel/debug/tracing/tracing_on
fi
