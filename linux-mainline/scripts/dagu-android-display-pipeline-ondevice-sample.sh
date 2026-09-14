#!/system/bin/sh
# 8s dirty-window sample at whatever fps SF currently chose. Root.
set -e
OUT=/data/local/tmp/dagu-disp-pipeline/sample
rm -rf "$OUT"
mkdir -p "$OUT"

cat /sys/class/drm/card0-DSI-1/hw_vsync_info >"$OUT/hw_vsync_before.txt"
cat /sys/class/drm/card0-DSI-1/dynamic_fps >"$OUT/dynamic_fps_before.txt"
cat /sys/class/drm/card0-DSI-1/disp_count >"$OUT/disp_count_before.txt"
cat /sys/class/drm/sde-crtc-0/measured_fps >"$OUT/measured_fps_before.txt"

(
	n=0
	while [ "$n" -lt 16 ]
	do
		input swipe 800 2200 800 400 400
		n=$((n + 1))
	done
) >/dev/null 2>&1 &
SWIPE=$!

i=0
: >"$OUT/poll.txt"
while [ "$i" -lt 900 ]
do
	echo "$(cat /proc/uptime) $(cat /sys/class/drm/sde-crtc-0/vsync_event) $(cat /sys/class/drm/sde-crtc-0/retire_frame_event)" >>"$OUT/poll.txt"
	i=$((i + 1))
done

wait "$SWIPE" || true

cat /sys/class/drm/card0-DSI-1/hw_vsync_info >"$OUT/hw_vsync_after.txt"
cat /sys/class/drm/card0-DSI-1/dynamic_fps >"$OUT/dynamic_fps_after.txt"
cat /sys/class/drm/card0-DSI-1/disp_count >"$OUT/disp_count_after.txt"
cat /sys/class/drm/sde-crtc-0/measured_fps >"$OUT/measured_fps_after.txt"
echo done >"$OUT/DONE"
