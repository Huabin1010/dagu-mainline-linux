#!/bin/bash
# Run on tablet as user dagu. mpv V4L2 m2m + Wayland GPU VO.
set -euo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1001}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export HOME="${HOME:-/home/dagu}"
CLIP="${1:-/tmp/test-1080p-15s.mp4}"
# Ubuntu mpv 0.41 只有 v4l2m2m-copy（无零拷贝 v4l2m2m / drm hwdec）。
# 零拷贝走 GStreamer waylandsink，见 dagu-venus-waylandsink.sh。
exec mpv --hwdec=v4l2m2m-copy --vo=gpu --gpu-context=wayland \
  --log-file=/tmp/mpv-venus.log \
  --msg-level=vd=v,vo=v,hwdec=v \
  --force-window=yes \
  --keep-open=no \
  --osd-duration=12000 \
  --osd-playing-msg='hwdec=${hwdec-current}' \
  "${CLIP}"
