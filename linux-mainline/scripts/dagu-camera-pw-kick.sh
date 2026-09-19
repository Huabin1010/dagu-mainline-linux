#!/bin/sh
# After loopback stamp, exclusive_caps+keep_format reports VIDEO_CAPTURE.
# WirePlumber spa-v4l2 caches QUERYCAP from before stamp (OUTPUT) and
# never creates Video/Source. GNOME Snapshot then shows No Camera Found.
# Restart the user session manager only when those sources are missing.
# Do not restart when Snapshot/Meeting already have a live node.
# Always exit 0: this is ExecStartPost; a non-zero status fails watch.

wait_capture() {
	dev=$1
	n=0
	while [ "$n" -lt 25 ]; do
		if v4l2-ctl -d "$dev" --all 2>/dev/null | grep -q "Video Capture"; then
			return 0
		fi
		n=$((n + 1))
		sleep 0.2
	done
	return 1
}

wait_capture /dev/video20 || exit 0
wait_capture /dev/video21 || exit 0

have_sources() {
	runtime=$1
	name=$2
	runuser -u "$name" -- env XDG_RUNTIME_DIR="$runtime" pw-dump 2>/dev/null |
		python3 -c '
import json, sys
try:
    dump = json.load(sys.stdin)
except Exception:
    sys.exit(1)
got = set()
lib = 0
for obj in dump:
    props = (obj.get("info") or {}).get("props") or {}
    if props.get("media.class") != "Video/Source":
        continue
    fac = props.get("factory.name") or ""
    if "libcamera" in fac:
        lib += 1
        continue
    path = props.get("api.v4l2.path")
    if path:
        got.add(path)
sys.exit(0 if ("/dev/video20" in got and "/dev/video21" in got and lib == 0) else 1)
'
}

for runtime in /run/user/*; do
	[ -d "$runtime" ] || continue
	uid=${runtime#/run/user/}
	case $uid in
	*[!0-9]*) continue ;;
	esac
	[ -S "$runtime/pipewire-0" ] || continue
	name=$(getent passwd "$uid" | cut -d: -f1)
	[ -n "$name" ] || continue
	if have_sources "$runtime" "$name"; then
		continue
	fi
	runuser -u "$name" -- env XDG_RUNTIME_DIR="$runtime" \
		DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" \
		systemctl --user try-restart wireplumber.service >/dev/null 2>&1 ||
		systemctl --machine="${name}@" --user try-restart wireplumber.service >/dev/null 2>&1 ||
		true
done
exit 0
