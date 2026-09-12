#!/bin/bash
# Generate 4K60 HEVC testsrc on the tablet. ultrafast: default medium is hours on Kryo.
set -euo pipefail
OUT="${1:-/tmp/test-4k.mp4}"
# 10s * 60fps = 600 frames. Main 8-bit 4:2:0 — Venus HEVC INPUT.
exec ffmpeg -y -f lavfi -i testsrc=duration=10:size=3840x2160:rate=60 \
  -c:v libx265 -preset ultrafast -pix_fmt yuv420p -tag:v hvc1 \
  "${OUT}"
