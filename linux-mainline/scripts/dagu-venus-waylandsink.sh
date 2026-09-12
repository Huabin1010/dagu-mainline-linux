#!/bin/bash
# Run on tablet as user dagu. Venus dmabuf + waylandsink (H.264 or HEVC).
set -euo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1001}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export HOME="${HOME:-/home/dagu}"
CLIP="${1:-/tmp/test-1080p-15s.mp4}"
SYNC="${SYNC:-true}"
# h265 / hevc in the filename or probe via ffprobe-less heuristic
case "${CLIP}" in
  *4k*|*hevc*|*h265*|*265*) PARSE=h265parse; DEC=v4l2h265dec ;;
  *) PARSE=h264parse; DEC=v4l2h264dec ;;
esac
exec gst-launch-1.0 \
  filesrc "location=${CLIP}" \
  ! qtdemux ! "${PARSE}" \
  ! "${DEC}" capture-io-mode=dmabuf \
  ! waylandsink "sync=${SYNC}" fullscreen=false
