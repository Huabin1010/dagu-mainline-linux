#!/usr/bin/env bash
# Stress dagu's 1600x2560@120 UBWC scanout, grim compositor buffers, dump DPU.
# Run from the host. Copies PNGs/logs to linux-mainline/out/display-stress/.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${DAGU_SSH_HOST:-192.168.7.2}"
KEY="${DAGU_SSH_KEY:-$ROOT/out/id_dagu}"
OUT="${DAGU_STRESS_OUT:-$ROOT/out/display-stress}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o ConnectTimeout=12 "root@$HOST")
SCP=(scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

remote() { "${SSH[@]}" "$@"; }

mkdir -p "$OUT"
echo "==> push test assets to $HOST"
"${SCP[@]}" "$ROOT/scripts/dagu-refresh-test.py" "root@$HOST:/tmp/dagu-refresh-test.py"
if [[ -f "$OUT/dagu-refresh-test.mp4" ]]; then
	"${SCP[@]}" "$OUT/dagu-refresh-test.mp4" "root@$HOST:/tmp/dagu-refresh-test.mp4"
fi

echo "==> wake session + capture rest / refresh / after"
remote 'set +e
export XDG_RUNTIME_DIR=/run/user/1001
export WAYLAND_DISPLAY=wayland-0
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus
dump_disp() {
  tag=$1
  {
    echo "==== $tag $(date -Is) ===="
    echo -n "DSI enabled="; cat /sys/class/drm/card0-DSI-1/enabled
    echo -n "DSI dpms="; cat /sys/class/drm/card0-DSI-1/dpms 2>/dev/null
    echo -n "mdp_rate="; cat /sys/kernel/debug/clk/disp_cc_mdss_mdp_clk/clk_rate
    echo -n "mdp_en="; cat /sys/kernel/debug/clk/disp_cc_mdss_mdp_clk/clk_enable_count
    echo -n "pclk0="; cat /sys/kernel/debug/clk/disp_cc_mdss_pclk0_clk/clk_rate
    echo -n "byte0="; cat /sys/kernel/debug/clk/disp_cc_mdss_byte0_clk/clk_rate
    echo -n "virtual_planes="; cat /sys/module/msm/parameters/dpu_use_virtual_planes 2>/dev/null
    echo "--- core_perf ---"
    cat /sys/kernel/debug/dri/0/debug/core_perf 2>/dev/null
    echo "--- danger ---"
    cat /sys/kernel/debug/dri/0/debug/danger 2>/dev/null
    echo "--- disable_err_irq ---"
    cat /sys/kernel/debug/dri/0/disable_err_irq 2>/dev/null
    echo "--- plane/crtc ---"
    awk "
      /^plane\\[/ {p=1}
      /^crtc\\[/ {c=1}
      p && /^(plane|crtc|	crtc=|	fb=|	format=|	modifier=|	size=|	pitch|	crtc-pos=|	src-pos=|	sspp|	multirect|	src\\[|	dst\\[)/ {print}
      /^crtc\\[/ {print}
      c && /^(crtc|	enable=|	active=|	planes=|	mode:)/ {print}
      /^connector/ {p=0;c=0}
    " /sys/kernel/debug/dri/0/state
    echo "--- dmesg ---"
    dmesg | grep -iE "underrun|dpu|mdss|l81a|ubwc|dsc" | tail -30
  } > /tmp/dagu-disp-$tag.txt
}

sudo -u dagu XDG_RUNTIME_DIR=/run/user/1001 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \
  gdbus call --session -d org.gnome.ScreenSaver -o /org/gnome/ScreenSaver \
  -m org.gnome.ScreenSaver.SetActive false >/dev/null 2>&1
loginctl unlock-session 2 >/dev/null 2>&1
sleep 1

dump_disp rest
sudo -u dagu XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY=wayland-0 grim /tmp/dagu-shot-rest.png
ls -l /tmp/dagu-shot-rest.png

pkill -f dagu-refresh-test.py >/dev/null 2>&1
sudo -u dagu env XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY=wayland-0 \
  python3 /tmp/dagu-refresh-test.py >/tmp/dagu-refresh-test.log 2>&1 &
echo $! > /tmp/dagu-refresh-test.pid
sleep 3
dump_disp refresh
sudo -u dagu XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY=wayland-0 grim /tmp/dagu-shot-refresh.png
ls -l /tmp/dagu-shot-refresh.png /tmp/dagu-refresh-test.log
head -c 400 /tmp/dagu-refresh-test.log; echo

if command -v ffmpeg >/dev/null && [ -f /tmp/dagu-refresh-test.mp4 ]; then
  sudo -u dagu env XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY=wayland-0 \
    timeout 6 gst-launch-1.0 -q filesrc location=/tmp/dagu-refresh-test.mp4 ! \
    decodebin ! videoconvert ! gtk4paintablesink  >/tmp/dagu-vid.log 2>&1 &
  sleep 2
  sudo -u dagu XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY=wayland-0 grim /tmp/dagu-shot-video.png || true
fi

kill $(cat /tmp/dagu-refresh-test.pid) >/dev/null 2>&1
pkill -f dagu-refresh-test.py >/dev/null 2>&1
sleep 1
dump_disp after
sudo -u dagu XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY=wayland-0 grim /tmp/dagu-shot-after.png
ls -l /tmp/dagu-shot-*.png /tmp/dagu-disp-*.txt
'

echo "==> pull captures to $OUT"
"${SCP[@]}" "root@$HOST:/tmp/dagu-shot-rest.png" "root@$HOST:/tmp/dagu-shot-refresh.png" \
  "root@$HOST:/tmp/dagu-shot-after.png" "root@$HOST:/tmp/dagu-shot-video.png" \
  "root@$HOST:/tmp/dagu-disp-rest.txt" "root@$HOST:/tmp/dagu-disp-refresh.txt" \
  "root@$HOST:/tmp/dagu-disp-after.txt" "root@$HOST:/tmp/dagu-refresh-test.log" \
  "$OUT/" 2>/dev/null || true
ls -l "$OUT"
echo "==> done"
