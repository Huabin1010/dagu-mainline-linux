#!/bin/sh
# Wait for the detached official-152 ninja to finish, then deploy and
# probe Venus encode. Do not install a half-linked chrome.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
LOG="${DAGU_NINJA_LOG:-$ROOT/out/chromium-v4l2-src/ninja-chrome.log}"
TREE="${DAGU_CHROMIUM_TREE:-$ROOT/out/chromium-v4l2-src/official-152/out/dagu}"
MARKER="${DAGU_NINJA_MARKER:-sandbox-log}"

echo "==> waiting on $LOG after $MARKER"
while :; do
	if [ -f "$LOG" ]; then
		after=$(awk -v m="$MARKER" 'index($0,m){p=1} p' "$LOG" || true)
		exit_line=$(printf '%s\n' "$after" | grep -E '^NINJA_EXIT=' | tail -n1 || true)
		if [ -n "$exit_line" ]; then
			code=${exit_line#NINJA_EXIT=}
			if [ "$code" = "0" ]; then
				echo "==> ninja finished 0"
				break
			fi
			echo "==> ninja failed after $MARKER ($exit_line)"
			echo "$after" | tail -30
			exit 1
		fi
	fi
	sleep 20
done

# First ninja may have linked before sandbox/v4l2 source edits.
# Incremental rebuild is a no-op if objects are already current.
echo "==> incremental ninja for V4L2 sandbox / device-path dirty objects"
command -v ninja >/dev/null || PATH="$HOME/.local/bin:$PATH"
ninja -C "$TREE" -j8 chrome chrome_sandbox

chrome="$TREE/chrome"
[ -x "$chrome" ] || { echo "no $chrome after ninja 0"; exit 1; }
file "$chrome" | grep -q aarch64 || { echo "not aarch64: $(file "$chrome")"; exit 1; }
grep -a -q V4L2VideoEncodeAccelerator "$chrome" || {
	echo "binary missing V4L2VideoEncodeAccelerator"
	exit 1
}

"$ROOT/scripts/dagu-chromium-v4l2-encode-deploy.sh"
# Never dump official google-chrome (USE_V4L2=0) after this swap.
DAGU_CHROME_BIN=/usr/local/bin/dagu-chromium \
	python3 "$ROOT/scripts/dagu-chrome-gpu-dump.py" --host
python3 "$ROOT/scripts/dagu-chrome-encode-probe.py" --host --codec h264
python3 "$ROOT/scripts/dagu-chrome-encode-probe.py" --host --codec vp8
python3 "$ROOT/scripts/dagu-chrome-encode-probe.py" --host --codec hevc
# Decode must still hit Venus after swapping the binary.
for codec in h264 vp9 hevc; do
	python3 "$ROOT/scripts/dagu-video-jank.py" --host --fresh --codec "$codec" || true
done
python3 - "$ROOT/out/display-stress" <<'PY'
import json, sys
from pathlib import Path
d = Path(sys.argv[1])
gpu = json.loads((d / "chrome-gpu.json").read_text()) if (d / "chrome-gpu.json").exists() else {}
enc = json.loads((d / "chrome-encode-probe.json").read_text()) if (d / "chrome-encode-probe.json").exists() else {}
accp = d / "chrome-gpu-accept.json"
acc = json.loads(accp.read_text()) if accp.exists() else {}
feats = gpu.get("features") or {}
acc["date"] = "2026-09-13"
acc["browser"] = "Chromium official-152 V4L2 encode /usr/local/bin/dagu-chromium"
cg = acc.setdefault("chrome_gpu", {})
for k, v in feats.items():
    if k == "Video Encode":
        ok = bool(enc.get("has_video15") and enc.get("irq_delta"))
        cg[k] = ("Hardware; Encoding table + /dev/video15 + venus_irq" if ok
                 else f"chrome://gpu={v}; encode_profiles={gpu.get('encode_profiles')}; probe={enc}")
    elif k == "Video Decode":
        cg[k] = v
    elif k not in cg:
        cg[k] = v
acc["video_acceleration_decode"] = gpu.get("decode_profiles") or acc.get("video_acceleration_decode") or []
acc["video_acceleration_encode"] = gpu.get("encode_profiles") or []
acc["encode_probe"] = enc
acc["webgpu"] = gpu.get("webgpu")
html = acc.setdefault("html5_venus", {})
for codec in ("h264", "vp9", "hevc", "vp8"):
    p = d / f"video-jank-{codec}.json"
    if not p.exists():
        continue
    j = json.loads(p.read_text())
    fds = [x for x in (j.get("venus_fds") or []) if "/dev/video" in str(x)]
    page = j.get("page") or {}
    html[codec] = {
        "irq_delta": j.get("venus_irq_delta"),
        "fd": fds[0] if fds else None,
        "drop_pct": page.get("drop_pct"),
        "file": p.name,
    }
accp.write_text(json.dumps(acc, indent=2, ensure_ascii=False) + "\n")
print("wrote", accp)
print("encode_profiles", acc.get("video_acceleration_encode"))
print("has_video15", enc.get("has_video15"), "irq", enc.get("irq_delta"))
PY
echo "==> wait/deploy/probe done"
