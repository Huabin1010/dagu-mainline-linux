#!/bin/sh
# Push libcamera SoftISP NV12 into v4l2loopback /dev/video20 (front) and
# /dev/video21 (rear) **on demand**. PipeWire must not monitor spa-libcamera:
# Chrome would CPU-debayer 12MP on the session CPUs and starve mutter.
# Snapshot/Chromium open these V4L2 nodes. Not Spectra ISP.
set -eu

FRONT_DEV="${DAGU_LOOPBACK_FRONT:-/dev/video20}"
REAR_DEV="${DAGU_LOOPBACK_REAR:-/dev/video21}"
WIDTH="${DAGU_LOOPBACK_WIDTH:-1280}"
HEIGHT="${DAGU_LOOPBACK_HEIGHT:-720}"
POLL_S="${DAGU_LOOPBACK_POLL_S:-0.5}"

log() { printf 'dagu-camera-loopback: %s\n' "$*"; }

usage() {
	printf 'usage: %s [watch|front|rear|all]\n' "$0" >&2
	exit 2
}

cmd=${1:-watch}

resolve_names() {
	front_name="${DAGU_LIBCAMERA_FRONT:-}"
	rear_name="${DAGU_LIBCAMERA_REAR:-}"
	if [ -z "$front_name" ] || [ -z "$rear_name" ]; then
		list=$(cam --list-cameras 2>/dev/null || true)
		if [ -z "$front_name" ]; then
			front_name=$(printf '%s\n' "$list" | sed -n "s/.*'\\(imx596[^']*\\)'.*/\\1/p" | head -1)
		fi
		if [ -z "$rear_name" ]; then
			rear_name=$(printf '%s\n' "$list" | sed -n "s/.*'\\(s5kjn1[^']*\\)'.*/\\1/p" | head -1)
		fi
	fi
}

pipe() {
	src_name=$1
	sink=$2
	if [ -z "$src_name" ]; then
		log "skip $sink (no camera name)"
		return 0
	fi
	if ! command -v gst-launch-1.0 >/dev/null; then
		log "gst-launch-1.0 missing"
		exit 1
	fi
	exec gst-launch-1.0 -q \
		libcamerasrc camera-name="$src_name" \
		! video/x-raw,format=NV12,width="$WIDTH",height="$HEIGHT" \
		! videoconvert \
		! v4l2sink device="$sink" sync=false
}

run_one() {
	which=$1
	i=0
	dev=$FRONT_DEV
	[ "$which" = rear ] && dev=$REAR_DEV
	while [ ! -e "$dev" ]; do
		i=$((i + 1))
		[ "$i" -gt 60 ] && { log "no $dev"; exit 1; }
		sleep 0.5
	done
	resolve_names
	case "$which" in
	front) pipe "$front_name" "$FRONT_DEV" ;;
	rear) pipe "$rear_name" "$REAR_DEV" ;;
	*) log "bad camera $which"; exit 2 ;;
	esac
}

run_all() {
	resolve_names
	log "front=$front_name -> $FRONT_DEV rear=$rear_name -> $REAR_DEV ${WIDTH}x${HEIGHT}"
	pipe "$front_name" "$FRONT_DEV" &
	p1=$!
	pipe "$rear_name" "$REAR_DEV" &
	p2=$!
	trap 'kill $p1 $p2 2>/dev/null || true' INT TERM
	wait $p1 $p2
}

watch() {
	log "watch $FRONT_DEV $REAR_DEV (no STREAMON until a V4L2 client opens the node)"
	exec python3 - "$FRONT_DEV" "$REAR_DEV" "$0" "$POLL_S" <<'PY'
import os, sys, time, subprocess

front, rear, script, poll_s = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
GST = {"gst-launch-1.0", "gst-laun"}


def holders(dev: str) -> set[int]:
    found: set[int] = set()
    try:
        pids = os.listdir("/proc")
    except OSError:
        return found
    for pid in pids:
        if not pid.isdigit():
            continue
        try:
            comm = open(f"/proc/{pid}/comm", encoding="utf-8", errors="ignore").read().strip()
        except OSError:
            continue
        if comm in GST or comm.startswith("gst-launch"):
            continue
        fd_dir = f"/proc/{pid}/fd"
        try:
            fds = os.listdir(fd_dir)
        except OSError:
            continue
        for fd in fds:
            try:
                target = os.readlink(f"{fd_dir}/{fd}")
            except OSError:
                continue
            if target == dev:
                found.add(int(pid))
                break
    return found


procs: dict[str, subprocess.Popen] = {}


def stop(name: str) -> None:
    p = procs.pop(name, None)
    if p is None:
        return
    p.terminate()
    try:
        p.wait(timeout=3)
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait(timeout=2)


def start(name: str) -> None:
    if name in procs and procs[name].poll() is None:
        return
    print(f"dagu-camera-loopback: start {name}", flush=True)
    procs[name] = subprocess.Popen([script, name])


try:
    while True:
        if not os.path.exists(front) and not os.path.exists(rear):
            time.sleep(max(poll_s, 5.0))
            continue
        want_front = os.path.exists(front) and bool(holders(front))
        want_rear = os.path.exists(rear) and bool(holders(rear))
        if want_front:
            start("front")
        else:
            stop("front")
        if want_rear:
            start("rear")
        else:
            stop("rear")
        dead = [n for n, p in procs.items() if p.poll() is not None]
        for n in dead:
            procs.pop(n, None)
        time.sleep(poll_s)
finally:
    for n in list(procs):
        stop(n)
PY
}

case "$cmd" in
watch) watch ;;
front|rear) run_one "$cmd" ;;
all) run_all ;;
-h|--help) usage ;;
*) usage ;;
esac
