#!/usr/bin/env bash
# Read-only HyperOS dump: CamX VERB + Display Full image dump.
# Serial 53dcc70 only. Never flash. Never talk to ab22268c / 18d1:d00d.
set -euo pipefail
SERIAL="${DAGU_ADB_SERIAL:-53dcc70}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${1:-$ROOT/out/camera/ife-android-verb-$STAMP}"
mkdir -p "$OUT"

if [[ "$SERIAL" == "ab22268c" ]]; then
	echo "refusing Linux pad $SERIAL" >&2
	exit 1
fi
if lsusb | grep -q '18d1:d00d'; then
	echo "fastboot 18d1:d00d present — stop" >&2
	exit 1
fi
got="$(adb -s "$SERIAL" get-serialno 2>/dev/null || true)"
if [[ "$got" != "$SERIAL" ]]; then
	echo "HyperOS $SERIAL not on adb (got ${got:-none}). Plug 18d1:4ee7." >&2
	exit 1
fi
dev="$(adb -s "$SERIAL" shell su -c 'getprop ro.product.device' | tr -d '\r')"
if [[ "$dev" != *dagu* ]]; then
	echo "device is not dagu: $dev" >&2
	exit 1
fi

SO_HOST="$ROOT/out/android/libdagu-cdm-dump.so"
if [[ -f "$SO_HOST" ]]; then
	adb -s "$SERIAL" push "$SO_HOST" /data/local/tmp/libdagu-cdm-dump.so >/dev/null
	echo "pushed libdagu-cdm-dump.so (LD_PRELOAD only if DAGU_CDM_PRELOAD=1)"
fi

su() { adb -s "$SERIAL" shell su -c "$1"; }

OV_DATA="/data/vendor/camera/camxoverridesettings.txt"
OV_BAK="/data/local/tmp/dagu-camxoverridesettings.bak"

restore_camx() {
	su "setprop persist.vendor.camera.autoImageDump 0" || true
	su "setprop persist.vendor.camera.logVerboseMask 0" || true
	su "setprop persist.vendor.camera.logInfoMask 0" || true
	# Restore data overlay so VERB does not stay on.
	su "if [ -f $OV_BAK ]; then cp $OV_BAK $OV_DATA; else rm -f $OV_DATA; fi" || true
	su "killall cameraserver android.hardware.camera.provider@2.4-service_64 2>/dev/null || true" || true
}
trap restore_camx EXIT

# persist props are often ignored; CamX reads data overlay over vendor.
su "mkdir -p /data/vendor/camera"
su "if [ -f $OV_DATA ]; then cp $OV_DATA $OV_BAK; else rm -f $OV_BAK; fi"
adb -s "$SERIAL" pull /vendor/etc/camera/camxoverridesettings.txt "$OUT/camxoverridesettings.vendor.txt" >/dev/null || true
python3 - <<PY
from pathlib import Path
src = Path("$OUT/camxoverridesettings.vendor.txt")
text = src.read_text(errors="replace") if src.exists() else ""
# Force VERB + Display Full image dump. Restore on EXIT.
for k in (
    "logInfoMask", "logVerboseMask", "logConfigMask", "logWarningMask",
    "overrideLogLevels", "enableTxtLogging", "FileMask", "logCtxMask",
    "logOutputMask", "autoImageDump", "autoImageDumpMask",
    "autoImageDumpIFEoutputPortMask", "autoImageDumpIFEInstanceMask",
):
    text = "\n".join(
        ln for ln in text.splitlines() if not ln.startswith(k + "=")
    ) + "\n"
text += """logInfoMask=0xffffffff
logVerboseMask=0xffffffff
logConfigMask=0xffffffff
overrideLogLevels=0xffffffff
enableTxtLogging=1
FileMask=0x7FFFFFFF
logCtxMask=0x7FFFFFFF
logOutputMask=2
autoImageDump=1
autoImageDumpMask=0x1
autoImageDumpIFEoutputPortMask=0x400000
autoImageDumpIFEInstanceMask=0x2
"""
Path("$OUT/camxoverridesettings.verb.txt").write_text(text)
print("wrote overlay", len(text), "bytes")
PY
adb -s "$SERIAL" push "$OUT/camxoverridesettings.verb.txt" /data/local/tmp/camxoverridesettings.verb.txt >/dev/null
su "cp /data/local/tmp/camxoverridesettings.verb.txt $OV_DATA && chmod 644 $OV_DATA"
su 'setprop persist.vendor.camera.logInfoMask 0xffffffff'
su 'setprop persist.vendor.camera.logVerboseMask 0xffffffff'
su 'setprop persist.vendor.camera.autoImageDump 1'
su 'setprop persist.vendor.camera.autoImageDumpMask 0x1'
su 'setprop persist.vendor.camera.autoImageDumpIFEoutputPortMask 0x400000'
su 'setprop persist.vendor.camera.autoImageDumpIFEInstanceMask 0x2'
su "killall cameraserver android.hardware.camera.provider@2.4-service_64 2>/dev/null || true"
sleep 2

adb -s "$SERIAL" logcat -c || true
adb -s "$SERIAL" shell am force-stop com.android.camera || true
sleep 1
# kernel CAM_DBG has WM IMAGE_CFG; CamX VERB is userspace.
adb -s "$SERIAL" logcat -v threadtime -b main -b system -b kernel \
	> "$OUT/logcat-camx-raw.txt" &
LC_PID=$!
adb -s "$SERIAL" shell am start -a android.media.action.STILL_IMAGE_CAMERA \
	--ez android.intent.extra.USE_FRONT_CAMERA true || true
sleep 6
kill "$LC_PID" 2>/dev/null || true
wait "$LC_PID" 2>/dev/null || true
su 'dmesg | grep -E "WM:[0-9]+ (en_cfg|image height|image stride|frame_inc|h_init)" | tail -80' \
	> "$OUT/dmesg-wm.txt" || true

su 'ls -l /data/vendor/camera /data/misc/camera 2>/dev/null | head -80' \
	> "$OUT/vendor-camera-ls.txt" || true
mkdir -p "$OUT/images" "$OUT/tuned"
adb -s "$SERIAL" pull /data/vendor/camera "$OUT/images/" >/dev/null 2>&1 || true
su 'ls /vendor/lib64/camera/com.qti.tuned.*imx596* /vendor/lib64/camera/com.qti.tuned.*front* /vendor/lib64/camera/com.qti.tuned.*dagu* 2>/dev/null' \
	> "$OUT/tuned-ls.txt" || true
while IFS= read -r f; do
	[[ -z "$f" ]] && continue
	adb -s "$SERIAL" pull "$f" "$OUT/tuned/" >/dev/null 2>&1 || true
done < "$OUT/tuned-ls.txt"

python3 - <<PY
from pathlib import Path
import re, json
out = Path("$OUT")
raw = (out / "logcat-camx-raw.txt").read_text(errors="replace") if (out / "logcat-camx-raw.txt").exists() else ""
keep = []
pat = re.compile(
    r"DisplayFullpath|MNDS Disp Luma|MNDS Display Chroma|"
    r"MNDS Full Luma imageSize|MNDS output|IFEOutputPortDisplayFull|"
    r"horizontalStripe0|horizontalPhase|verticalPhase|PrepareIFEProperties|"
    r"RealTimeFeature|UBWC|NV12|2304|2314|2320|"
    r"WM:\d+|image height and width|frame_inc|plane_stride",
    re.I,
)
for line in raw.splitlines():
    if pat.search(line):
        keep.append(line)
(out / "logcat-verb.txt").write_text("\n".join(keep) + "\n")
facts = {
    "display_full_path": None,
    "mnds_output": None,
    "stripe0": None,
    "hphase": None,
    "vphase": None,
    "chroma_hsize": None,
    "chroma_stripe1": None,
}
text = "\n".join(keep)
m = re.search(r"DisplayFullpath\s+(\d+)\s+(\d+)\s+(\d+)x(\d+)", text)
if m:
    facts["display_full_path"] = {
        "x": int(m.group(1)), "y": int(m.group(2)),
        "w": int(m.group(3)), "h": int(m.group(4)),
    }
m = re.search(r"MNDS output\[(\d+)\s*\*\s*(\d+)\]", text)
if m:
    facts["mnds_output"] = {"w": int(m.group(1)), "h": int(m.group(2))}
for key, rx in (
    ("stripe0", r"MNDS Disp Luma horizontalStripe0\s+\[(0x[0-9a-fA-F]+)\]"),
    ("hphase", r"MNDS Disp Luma horizontalPhase\s+\[(0x[0-9a-fA-F]+)\]"),
    ("vphase", r"MNDS Disp Luma verticalPhase\s+\[(0x[0-9a-fA-F]+)\]"),
    ("chroma_hsize", r"MNDS Display Chroma horizontalSize\s+\[(0x[0-9a-fA-F]+)\]"),
    ("chroma_stripe1", r"MNDS Display Chroma horizontalStripe1\s+\[(0x[0-9a-fA-F]+)\]"),
):
    m = re.search(rx, text)
    if m:
        facts[key] = m.group(1).lower()
# Image dump names: w[2304]_h[1296] vs w[2592]
names = []
img = out / "images"
if img.exists():
    for p in img.rglob("*"):
        if p.is_file():
            names.append(p.name)
facts["dump_files"] = names[:80]
facts["has_w2592"] = any("2592" in n for n in names)
facts["has_w2304"] = any("2304" in n for n in names)
facts["has_w2320"] = any("2320" in n for n in names)
wm_txt = ""
if (out / "dmesg-wm.txt").exists():
    wm_txt = (out / "dmesg-wm.txt").read_text(errors="replace")
wm_txt += "\n" + text
wm4 = re.findall(r"WM:4 image height and width (0x[0-9a-fA-F]+)", wm_txt)
wm5 = re.findall(r"WM:5 image height and width (0x[0-9a-fA-F]+)", wm_txt)
fi4 = re.findall(r"WM:4 frame_inc (\d+)", wm_txt)
fi5 = re.findall(r"WM:5 frame_inc (\d+)", wm_txt)
facts["wm4_image_cfg0"] = wm4[-1].lower() if wm4 else None
facts["wm5_image_cfg0"] = wm5[-1].lower() if wm5 else None
facts["wm4_frame_inc"] = int(fi4[-1]) if fi4 else None
facts["wm5_frame_inc"] = int(fi5[-1]) if fi5 else None

def cfg0_wh(h):
    if not h:
        return None
    v = int(h, 16)
    return {"h": (v >> 16) & 0xffff, "w": v & 0xffff}

facts["wm4_wh"] = cfg0_wh(facts["wm4_image_cfg0"])
facts["wm5_wh"] = cfg0_wh(facts["wm5_image_cfg0"])
(out / "FACTS.json").write_text(json.dumps(facts, indent=2) + "\n")
lines = ["# VERB dest pin", ""]
if facts["display_full_path"]:
    d = facts["display_full_path"]
    lines.append(f"- DisplayFullpath {d['w']}x{d['h']} at ({d['x']},{d['y']})")
if facts["mnds_output"]:
    lines.append(f"- MNDS output {facts['mnds_output']['w']}x{facts['mnds_output']['h']}")
for k in ("stripe0", "hphase", "vphase", "chroma_hsize", "chroma_stripe1"):
    lines.append(f"- {k} {facts[k]}")
lines.append(f"- dump w2592={facts['has_w2592']} w2304={facts['has_w2304']} w2320={facts['has_w2320']}")
if facts.get("wm4_wh"):
    w4, w5 = facts["wm4_wh"], facts["wm5_wh"]
    lines.append(
        f"- kernel WM（Write Master，AXI 写通道）4 IMAGE_CFG_0 {facts['wm4_image_cfg0']} {w4['w']}x{w4['h']} "
        f"FRAME_INCR={facts['wm4_frame_inc']}"
    )
    if w5:
        lines.append(
            f"- kernel WM（Write Master，AXI 写通道）5 IMAGE_CFG_0 {facts['wm5_image_cfg0']} {w5['w']}x{w5['h']} "
            f"FRAME_INCR={facts['wm5_frame_inc']}"
        )
    if w4["w"] in (2304, 2314, 2320) and facts["wm4_image_cfg0"] != "0x7a00a20":
        lines.append("- linear Display Full IMAGE_CFG_0 pinned — this is the Linux dest original")
    else:
        lines.append("- WM（Write Master，AXI 写通道）4 still identity 2592 or missing — not Linux linear dest")
else:
    lines.append("- kernel WM（Write Master，AXI 写通道） IMAGE_CFG_0 missing (need CAM_DBG)")
lines.append("- Throw w[2592] UBWC. w[2304] is Android Display Full contrast, not Linux linear unless IMAGE_CFG_0 matches.")
lines.append("- No w[2320] means 2320 is Linux pad.")
(out / "FACTS.md").write_text("\n".join(lines) + "\n")
print(f"verb lines {len(keep)}")
print("\n".join(lines))
PY

# Always turn dump/log off. Overlay restore is trap EXIT.
echo "==> $OUT"
