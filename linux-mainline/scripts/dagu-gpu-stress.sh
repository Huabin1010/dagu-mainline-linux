#!/usr/bin/env bash
# Push a650 + 1600x2560@120: several glass pages plus optional software
# video. Venus is off on this kernel, so decode is CPU/ffmpeg, composite is GPU.
#
#   ./scripts/dagu-gpu-stress.sh              # 90s, 3 glass windows
#   DAGU_STRESS_SECS=180 DAGU_STRESS_WINDOWS=4 ./scripts/dagu-gpu-stress.sh
#
# Starts linux-mainline/scripts/dagu-gpu-hangwatch.sh --host so the next
# 00800005 lands in /var/log/dagu-gpu/ on the tablet.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${DAGU_SSH_HOST:-192.168.7.2}"
KEY="${DAGU_SSH_KEY:-$ROOT/out/id_dagu}"
OUT="${DAGU_STRESS_OUT:-$ROOT/out/gpu-stress}"
SECS="${DAGU_STRESS_SECS:-90}"
WINDOWS="${DAGU_STRESS_WINDOWS:-3}"
GLASS="file:///home/dagu/dagu-glass-probe.html"

SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o ConnectTimeout=12 "root@$HOST")

remote() { "${SSH[@]}" "$@"; }

mkdir -p "$OUT"
echo "==> hangwatch"
"$ROOT/scripts/dagu-gpu-hangwatch.sh" --host

echo "==> baseline"
remote 'bash -s' <<'R' > "$OUT/baseline.txt"
set +e
date -Is
echo -n hangcheck_recover=; dmesg | grep -c "hangcheck recover"
echo -n gpu_fault=; dmesg | grep -c "gpu fault"
echo -n modifier=; grep -m1 modifier= /sys/kernel/debug/dri/0/state
echo -n cur_freq=; cat /sys/class/devfreq/3d00000.gpu/cur_freq
echo -n min_freq=; cat /sys/class/devfreq/3d00000.gpu/min_freq
echo -n governor=; cat /sys/class/devfreq/3d00000.gpu/governor
echo -n tz15=; cat /sys/class/thermal/thermal_zone15/temp
echo -n tz24=; cat /sys/class/thermal/thermal_zone24/temp
R
cat "$OUT/baseline.txt"

echo "==> wake + $WINDOWS glass windows for ${SECS}s"
remote "bash -s" <<R
set +e
export XDG_RUNTIME_DIR=/run/user/1001
export WAYLAND_DISPLAY=wayland-0
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus
sudo -u dagu XDG_RUNTIME_DIR=/run/user/1001 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \\
  gdbus call --session -d org.gnome.SettingsDaemon.Power -o /org/gnome/SettingsDaemon/Power \\
  -m org.freedesktop.DBus.Properties.Set org.gnome.SettingsDaemon.Power.Screen PowerSaveMode "<uint32 0>" >/dev/null 2>&1
sudo -u dagu XDG_RUNTIME_DIR=/run/user/1001 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \\
  gdbus call --session -d org.gnome.ScreenSaver -o /org/gnome/ScreenSaver \\
  -m org.gnome.ScreenSaver.SetActive false >/dev/null 2>&1
if ! pgrep -u dagu -f "/opt/google/chrome/chrome --ozone" >/dev/null; then
  sudo -u dagu env XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY=wayland-0 \\
    HOME=/home/dagu USER=dagu LOGNAME=dagu \\
    /usr/local/bin/dagu-chrome --new-window $GLASS >/tmp/dagu-chrome-stress.log 2>&1 &
  sleep 4
fi
i=1
while [ \$i -le $WINDOWS ]; do
  sudo -u dagu env XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY=wayland-0 \\
    HOME=/home/dagu USER=dagu LOGNAME=dagu \\
    /usr/local/bin/dagu-chrome --new-window $GLASS >/tmp/dagu-chrome-stress-\$i.log 2>&1 &
  i=\$((i + 1))
  sleep 1
done
if command -v gst-launch-1.0 >/dev/null; then
  sudo -u dagu env XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY=wayland-0 \\
    timeout $SECS gst-launch-1.0 -q videotestsrc is-live=true \\
      ! video/x-raw,width=1280,height=720,framerate=30/1 \\
      ! videoconvert ! waylandsink fullscreen=false >/tmp/dagu-gst-stress.log 2>&1 &
  echo gst_pid=\$!
fi
R

echo "==> sample GPU for ${SECS}s"
remote "bash -s" <<R > "$OUT/samples.txt"
set +e
end=\$((SECONDS + $SECS))
while [ \$SECONDS -lt \$end ]; do
  echo "\$(date +%s) freq=\$(cat /sys/class/devfreq/3d00000.gpu/cur_freq) tz15=\$(cat /sys/class/thermal/thermal_zone15/temp) tz24=\$(cat /sys/class/thermal/thermal_zone24/temp) hang=\$(dmesg | grep -c "hangcheck recover")"
  sleep 5
done
R
cat "$OUT/samples.txt"

echo "==> after"
remote 'bash -s' <<'R' > "$OUT/after.txt"
set +e
date -Is
echo -n hangcheck_recover=; dmesg | grep -c "hangcheck recover"
echo -n gpu_fault=; dmesg | grep -c "gpu fault"
echo -n modifier=; grep -m1 modifier= /sys/kernel/debug/dri/0/state
echo -n cur_freq=; cat /sys/class/devfreq/3d00000.gpu/cur_freq
echo -n tz15=; cat /sys/class/thermal/thermal_zone15/temp
echo -n tz24=; cat /sys/class/thermal/thermal_zone24/temp
dmesg | grep -E "gpu fault status|hangcheck" | tail -n 15
ls -l /var/log/dagu-gpu 2>/dev/null | tail
R
cat "$OUT/after.txt"
echo "logs: $OUT"
echo "hang dumps on tablet: /var/log/dagu-gpu  (pull with linux-mainline/scripts/dagu-gpu-hangwatch.sh --pull)"
