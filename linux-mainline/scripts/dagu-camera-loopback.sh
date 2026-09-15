#!/bin/sh
# Push libcamera SoftISP NV12 into v4l2loopback /dev/video20 (front) and
# /dev/video21 (rear) **on demand**. No app → no gst, no CAMSS STREAMON.
# PipeWire must not monitor spa-libcamera: Chrome would CPU-debayer 12MP
# on the session CPUs and starve mutter. Snapshot/Chromium open these
# V4L2 nodes. Not Spectra ISP.
set -eu

FRONT_DEV="${DAGU_LOOPBACK_FRONT:-/dev/video20}"
REAR_DEV="${DAGU_LOOPBACK_REAR:-/dev/video21}"
# libcamera simple IDs from sm8250-xiaomi-dagu.dts (cam --list).
FRONT_NAME="${DAGU_LIBCAMERA_FRONT:-/base/soc@0/cci@ac50000/i2c-bus@1/camera@10}"
REAR_NAME="${DAGU_LIBCAMERA_REAR:-/base/soc@0/cci@ac4f000/i2c-bus@0/camera@10}"
# Viewfinder skip: imx596 2592/2, s5kjn1 4080/4. Not 1280x720 (rear cannot).
FRONT_W="${DAGU_LOOPBACK_FRONT_WIDTH:-1296}"
FRONT_H="${DAGU_LOOPBACK_FRONT_HEIGHT:-976}"
REAR_W="${DAGU_LOOPBACK_REAR_WIDTH:-1020}"
REAR_H="${DAGU_LOOPBACK_REAR_HEIGHT:-764}"
POLL_S="${DAGU_LOOPBACK_POLL_S:-0.5}"
IDLE_S="${DAGU_LOOPBACK_IDLE_S:-1}"
RESET="${DAGU_CAMSS_RESET:-/usr/local/sbin/dagu-camss-graph-reset.sh}"

log() { printf 'dagu-camera-loopback: %s\n' "$*"; }

usage() {
	printf 'usage: %s [watch|front|rear|all]\n' "$0" >&2
	exit 2
}

cmd=${1:-watch}

resolve_names() {
	front_name="${DAGU_LIBCAMERA_FRONT:-$FRONT_NAME}"
	rear_name="${DAGU_LIBCAMERA_REAR:-$REAR_NAME}"
	list=$(cam --list 2>/dev/null || cam --list-cameras 2>/dev/null || true)
	parsed_front=$(printf '%s\n' "$list" | sed -n 's/.*Internal front camera (\([^)]*\)).*/\1/p' | head -1)
	parsed_rear=$(printf '%s\n' "$list" | sed -n 's/.*Internal back camera (\([^)]*\)).*/\1/p' | head -1)
	[ -z "${DAGU_LIBCAMERA_FRONT:-}" ] && [ -n "$parsed_front" ] && front_name=$parsed_front
	[ -z "${DAGU_LIBCAMERA_REAR:-}" ] && [ -n "$parsed_rear" ] && rear_name=$parsed_rear
}

pipe() {
	src_name=$1
	sink=$2
	w=$3
	h=$4
	if [ -z "$src_name" ]; then
		log "no camera id for $sink"
		exit 1
	fi
	if ! command -v gst-launch-1.0 >/dev/null; then
		log "gst-launch-1.0 missing"
		exit 1
	fi
	log "pipe $src_name -> $sink ${w}x${h} NV12"
	# libcamerasrc emits ABGR8888; NV12/size must come after videoconvert.
	exec gst-launch-1.0 \
		libcamerasrc camera-name="$src_name" \
		! videoconvert \
		! "video/x-raw,format=NV12,width=$w,height=$h" \
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
	front) pipe "$front_name" "$FRONT_DEV" "$FRONT_W" "$FRONT_H" ;;
	rear) pipe "$rear_name" "$REAR_DEV" "$REAR_W" "$REAR_H" ;;
	*) log "bad camera $which"; exit 2 ;;
	esac
}

run_all() {
	resolve_names
	log "all front=$front_name $FRONT_W x $FRONT_H rear=$rear_name $REAR_W x $REAR_H"
	pipe "$front_name" "$FRONT_DEV" "$FRONT_W" "$FRONT_H" &
	p1=$!
	pipe "$rear_name" "$REAR_DEV" "$REAR_W" "$REAR_H" &
	p2=$!
	trap 'kill $p1 $p2 2>/dev/null || true' INT TERM
	wait $p1 $p2
}

watch() {
	log "watch $FRONT_DEV $REAR_DEV idle=${IDLE_S}s (SoftISP off until a client streams)"
	exec python3 - "$FRONT_DEV" "$REAR_DEV" "$0" "$POLL_S" "$IDLE_S" "$RESET" <<'PY'
import os, signal, sys, time, subprocess

front, rear, script, poll_s, idle_s, reset = (
    sys.argv[1], sys.argv[2], sys.argv[3],
    float(sys.argv[4]), float(sys.argv[5]), sys.argv[6],
)
GST = {"gst-launch-1.0", "gst-laun"}
MONITOR = {"pipewire", "wireplumber", "pipewire-pulse"}
POLL = {"dagu-camera-loop", "dagu-camera-lo"}


def comm_of(pid: str) -> str:
    try:
        return open(f"/proc/{pid}/comm", encoding="utf-8", errors="ignore").read().strip()
    except OSError:
        return ""


def holders(dev: str) -> dict[int, str]:
    found: dict[int, str] = {}
    try:
        pids = os.listdir("/proc")
    except OSError:
        return found
    for pid in pids:
        if not pid.isdigit():
            continue
        comm = comm_of(pid)
        if comm in GST or comm.startswith("gst-launch") or comm in POLL:
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
                found[int(pid)] = comm
                break
    return found


def buf_count(dev: str) -> int:
    name = os.path.basename(dev)
    for path in (
        f"/sys/devices/virtual/video4linux/{name}/buffers",
        f"/sys/class/video4linux/{name}/device/buffers",
    ):
        try:
            return int(open(path, encoding="utf-8").read().strip() or "0")
        except (OSError, ValueError):
            continue
    return 0


def client_wants(dev: str) -> bool:
    if not os.path.exists(dev):
        return False
    found = holders(dev)
    if not found:
        return False
    if all(c in MONITOR for c in found.values()) and buf_count(dev) == 0:
        return False
    return True


procs: dict[str, subprocess.Popen] = {}
started_at: dict[str, float] = {}
fail_until: dict[str, float] = {}
idle_since: dict[str, float] = {}
hw_held = False


def release_hw() -> None:
    global hw_held
    if procs:
        return
    if not hw_held:
        return
    if os.path.isfile(reset) and os.access(reset, os.X_OK):
        subprocess.run([reset], check=False)
    print("dagu-camera-loopback: idle, CAMSS graph reset", flush=True)
    hw_held = False


def stop(name: str) -> None:
    p = procs.pop(name, None)
    started_at.pop(name, None)
    idle_since.pop(name, None)
    if p is None:
        return
    print(f"dagu-camera-loopback: stop {name}", flush=True)
    try:
        os.killpg(p.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError, OSError):
        p.terminate()
    try:
        p.wait(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError, OSError):
            p.kill()
        p.wait(timeout=2)


def start(name: str) -> None:
    global hw_held
    now = time.monotonic()
    if name in procs and procs[name].poll() is None:
        return
    if now < fail_until.get(name, 0):
        return
    print(f"dagu-camera-loopback: start {name}", flush=True)
    procs[name] = subprocess.Popen(
        [script, name],
        start_new_session=True,
    )
    started_at[name] = now
    idle_since.pop(name, None)
    hw_held = True


try:
    while True:
        now = time.monotonic()
        want = {"front": client_wants(front), "rear": client_wants(rear)}
        for name, needed in want.items():
            if needed:
                idle_since.pop(name, None)
                start(name)
                continue
            if name not in procs:
                continue
            since = idle_since.setdefault(name, now)
            if now - since >= idle_s:
                stop(name)
        dead = [n for n, p in procs.items() if p.poll() is not None]
        for n in dead:
            rc = procs[n].returncode
            age = now - started_at.get(n, now)
            procs.pop(n, None)
            started_at.pop(n, None)
            print(f"dagu-camera-loopback: {n} exited rc={rc}", flush=True)
            if age < 2.0:
                fail_until[n] = now + 8.0
        release_hw()
        time.sleep(poll_s)
finally:
    for n in list(procs):
        stop(n)
    hw_held = True
    release_hw()
PY
}

case "$cmd" in
watch) watch ;;
front|rear) run_one "$cmd" ;;
all) run_all ;;
-h|--help) usage ;;
*) usage ;;
esac
