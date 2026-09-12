#!/bin/bash
# Daily-driver path: gst-play-1.0 + waylandsink (playbin autoplugs v4l2h26xdec).
set -euo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1001}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export HOME="${HOME:-/home/dagu}"
CLIP="${1:-/tmp/test-1080p.mp4}"
exec gst-play-1.0 --videosink=waylandsink --no-interactive "${CLIP}"
