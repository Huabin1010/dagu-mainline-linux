#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DTB="${1:-${ROOT}/edk2-msm/Platform/Xiaomi/sm8250/FdtBlob_compat/dagu.dtb}"
OUT="/tmp/dagu-usb.dts"
dtc -I dtb -O dts "$DTB" 2>/dev/null > "$OUT"
echo "=== matches ==="
grep -nE 'dwc3@|usb@|ssphy@|maximum-speed|dr_mode|88e8000|a600000|qcom,dwc' "$OUT" | head -80
echo "=== dwc3@a600000 ==="
awk '/dwc3@a600000/,/^		};/' "$OUT" | head -50
echo "=== ssphy@88e8000 ==="
awk '/phy@88e8000|ssphy@88e8000/,/^		};/' "$OUT" | head -40
echo "=== elish dwc3 speed ==="
ELISH="$(dirname "$DTB")/elish.dtb"
dtc -I dtb -O dts "$ELISH" 2>/dev/null | grep -nE 'maximum-speed|ssphy@88e8000|status' | head -40
