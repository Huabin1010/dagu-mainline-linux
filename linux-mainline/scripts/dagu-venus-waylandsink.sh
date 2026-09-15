#!/bin/bash
# Run on tablet as user dagu. Venus dmabuf + waylandsink.
set -euo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1001}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export HOME="${HOME:-/home/dagu}"
CLIP="${1:-/tmp/test-1080p-15s.mp4}"
SYNC="${SYNC:-true}"
case "${CLIP}" in
  *mpeg2*|*mpg2*|*.ts)
    exec gst-launch-1.0 filesrc "location=${CLIP}" \
      ! tsdemux ! mpegvideoparse \
      ! v4l2mpeg2dec capture-io-mode=dmabuf \
      ! waylandsink "sync=${SYNC}" fullscreen=false
    ;;
  *vp8*|*.webm)
    case "${CLIP}" in
      *vp9*)
        exec gst-launch-1.0 filesrc "location=${CLIP}" \
          ! matroskademux ! vp9parse \
          ! v4l2vp9dec capture-io-mode=dmabuf \
          ! waylandsink "sync=${SYNC}" fullscreen=false
        ;;
      *)
        exec gst-launch-1.0 filesrc "location=${CLIP}" \
          ! matroskademux \
          ! v4l2vp8dec capture-io-mode=dmabuf \
          ! waylandsink "sync=${SYNC}" fullscreen=false
        ;;
    esac
    ;;
  *4k*|*hevc*|*h265*|*265*|*.mkv)
    exec gst-launch-1.0 filesrc "location=${CLIP}" \
      ! matroskademux ! h265parse \
      ! v4l2h265dec capture-io-mode=dmabuf \
      ! waylandsink "sync=${SYNC}" fullscreen=false
    ;;
  *)
    exec gst-launch-1.0 filesrc "location=${CLIP}" \
      ! qtdemux ! h264parse \
      ! v4l2h264dec capture-io-mode=dmabuf \
      ! waylandsink "sync=${SYNC}" fullscreen=false
    ;;
esac
