#!/usr/bin/env python3
"""4K playback contract for SM8250 Venus and a Netflix-class smoothness gate.

Bilibili picks av01 when canPlayType is non-empty. This SoC's Venus
decoder has no AV1, so both browsers fall into dav1d, the picture runs
late, and the audio clock pulls ahead.

Venus also sizes a compressed input buffer as
ALIGN(h,32)*ALIGN(w,32)*3/4 (helpers.c venus_helper_get_framesz).
3840x2160 is 6266880 bytes. Chromium used to request 4 MiB with an
empty S_FMT size, so the driver kept 4 MiB, firmware reported
insufficient buffers, and an access unit larger than the plane
CHECK-crashed the GPU process.

The smoothness bar follows ITU-R BT.1359-1 (audio more than about 45 ms
early is detectable). This gate uses 40 ms. One dropped frame in a
12 s 30 fps clip fails the 0.1% ratio.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

SZ_4K = 4096
MIB = 1024 * 1024

# ITU-R BT.1359-1 detectable threshold is ~45 ms audio-early.
# One 30 fps frame is 33 ms; 50 ms is a visible stall.
MAX_DROP_RATIO = 0.001
MAX_ABS_AV_SKEW_MS = 40.0
MAX_STALL_MS = 50.0
MIN_4K_FRAMES = 240


def align_up(value: int, align: int) -> int:
    return (value + align - 1) & ~(align - 1)


def venus_compressed_bitstream_bytes(width: int, height: int) -> int:
    """Match venus_helper_get_framesz() for a compressed codec."""
    sz = align_up(height, 32) * align_up(width, 32) * 3 // 2 // 2
    if width < 1280 or height < 720:
        sz *= 8
    return align_up(sz, SZ_4K)


def chrome_output_buffer_bytes(width: int, height: int) -> int:
    """Bytes Chromium must pass to OUTPUT S_FMT for this coded size.

    The driver clamps a request to 8 MiB, then raises it to the Venus
    size. Asking for 8 MiB on 4K leaves room for a large IDR without
    going under the firmware requirement.
    """
    if width <= 0 or height <= 0:
        width, height = 3840, 2160
    venus = venus_compressed_bitstream_bytes(width, height)
    area = width * height
    if venus > 4 * MIB:
        return max(venus, 8 * MIB)
    if area > 1920 * 1080:
        return max(venus, 4 * MIB)
    return max(venus, 2 * MIB)


def above_hd(width: int, height: int) -> bool:
    if width <= 0 or height <= 0:
        return True
    return width * height > 1920 * 1080


def output_buffer_count(codec: str, width: int, height: int) -> int:
    if codec == "h264":
        return 16
    if above_hd(width, height):
        return 8
    return 2


def max_decode_requests(codec: str, width: int, height: int) -> int:
    count = output_buffer_count(codec, width, height)
    cap = 8 if above_hd(width, height) else 4
    return min(cap, count)


def bilibili_codec(can_play: dict) -> str | None:
    """Web player order: AV1, then HEVC, then H.264."""
    if (can_play.get("av1") or "").strip():
        return "av1"
    if (can_play.get("hevc") or "").strip():
        return "hevc"
    if (can_play.get("h264") or "").strip():
        return "h264"
    return None


def dagu_can_play() -> dict:
    """What the Venus browser must advertise. AV1 is intentionally empty."""
    return {"av1": "", "hevc": "probably", "h264": "probably", "vp9": "probably"}


def stock_chrome_can_play() -> dict:
    """Google Chrome is compiled without V4L2. It still advertises dav1d."""
    return {"av1": "probably", "hevc": "", "h264": "probably", "vp9": "probably"}


def netflix_gate(sample: dict) -> tuple[bool, list[str]]:
    """Return (ok, reasons). Empty reasons means the clip is in bar."""
    reasons: list[str] = []
    profile = sample.get("profile", "4k")
    width = int(sample.get("w") or 0)
    height = int(sample.get("h") or 0)
    dropped = int(sample.get("dropped") or 0)
    total = int(sample.get("total") or 0)
    skew = float(sample.get("max_av_skew_ms") or 0)
    stall = float(sample.get("max_frame_gap_ms") or 0)
    decoder = str(sample.get("decoder") or "")
    log = str(sample.get("decoder_log") or "")
    blob = decoder + "\n" + log
    can = sample.get("can_play") or {}

    if profile == "4k":
        if width < 3840 or height < 2160:
            reasons.append(f"not 4k ({width}x{height})")
        if total < MIN_4K_FRAMES:
            reasons.append(f"too few frames ({total} < {MIN_4K_FRAMES})")
        if (can.get("av1") or "").strip():
            reasons.append("av1 still advertised")
        if not (can.get("hevc") or "").strip() and sample.get("codec") == "hevc":
            reasons.append("hevc not advertised")

    if total <= 0:
        reasons.append("no presented frames")
    else:
        ratio = dropped / total
        if ratio > MAX_DROP_RATIO:
            reasons.append(f"drop ratio {ratio:.4f} > {MAX_DROP_RATIO}")
    if skew > MAX_ABS_AV_SKEW_MS:
        reasons.append(f"a/v skew {skew:.1f} ms > {MAX_ABS_AV_SKEW_MS:.0f} ms")
    if stall > MAX_STALL_MS:
        reasons.append(f"frame gap {stall:.1f} ms > {MAX_STALL_MS:.0f} ms")
    hardware = (
        "V4L2StatefulVideoDecoder" in blob
        or "v4l2_stateful_video_decoder.cc" in blob
    )
    if not hardware:
        reasons.append("decoder is not V4L2StatefulVideoDecoder")
    if "FFmpegVideoDecoder" in blob or "dav1d" in blob.lower():
        reasons.append("software decoder still in the log")
    if not sample.get("video14"):
        reasons.append("/dev/video14 was not opened")
    irq = sample.get("venus_irq_delta")
    if irq is None or int(irq) < max(1, total // 2):
        reasons.append(f"venus irq delta {irq} did not track frames")
    if sample.get("codec") == "av1":
        reasons.append("playback codec is av1")
    return (not reasons, reasons)


# --- Chromium source patch (idempotent) ---------------------------------

_AV1_OLD = """\
bool IsDecoderAV1Supported(const VideoType& type) {
  // If the AV1 decoder is enabled, or if we're on Q or later, yes.
#if BUILDFLAG(ENABLE_AV1_DECODER)
  return IsColorSpaceSupported(type.color_space);
#elif BUILDFLAG(IS_ANDROID)
  return base::android::android_info::sdk_int() >=
             base::android::android_info::SDK_VERSION_Q &&
         IsColorSpaceSupported(type.color_space);
#else
  return false;
#endif
}
"""

_AV1_NEW = """\
bool IsDecoderAV1Supported(const VideoType& type) {
  // dagu SM8250: Venus has no AV1. dav1d cannot hold 4K, and Bilibili
  // prefers av01 whenever canPlayType is non-empty, so the audio clock
  // runs ahead of the picture. HEVC / H.264 / VP9 stay advertised.
  (void)type;
  return false;
}
"""

_HELPER = """\
// dagu: keep in sync with dagu_playback_gate.py. Venus compressed
// input size is ALIGN(h,32)*ALIGN(w,32)*3/2/2, then *8 below 720p,
// then ALIGN 4096. 3840x2160 is 6266880, above the old 4 MiB guess.
constexpr size_t kVenusBitstreamAlign = 4096;
constexpr size_t kMiB = 1024 * 1024;

size_t AlignUpSize(size_t value, size_t align) {
  return (value + align - 1) & ~(align - 1);
}

size_t VenusCompressedBitstreamBytes(int width, int height) {
  const size_t w = AlignUpSize(static_cast<size_t>(std::max(width, 0)), 32);
  const size_t h = AlignUpSize(static_cast<size_t>(std::max(height, 0)), 32);
  size_t sz = h * w * 3 / 2 / 2;
  if (width < 1280 || height < 720) {
    sz *= 8;
  }
  return AlignUpSize(sz, kVenusBitstreamAlign);
}

size_t ChromeOutputBufferBytes(int width, int height) {
  if (width <= 0 || height <= 0) {
    width = 3840;
    height = 2160;
  }
  const size_t venus = VenusCompressedBitstreamBytes(width, height);
  const int area = width * height;
  if (venus > 4 * kMiB) {
    return std::max(venus, static_cast<size_t>(8) * kMiB);
  }
  if (area > 1920 * 1080) {
    return std::max(venus, static_cast<size_t>(4) * kMiB);
  }
  return std::max(venus, static_cast<size_t>(2) * kMiB);
}

"""

_SETFMT_OLD = """\
  // Allocate larger |OUTPUT_queue_| buffers for resolutions above 1080p.
  // TODO(hnt): Investigate ways to reduce this size.
  constexpr size_t kMiB = 1024 * 1024;
  constexpr int kFullHDNumPixels = 1920 * 1080;
  const size_t kInputBufferInMBs =
      (config.coded_size().GetArea() <= kFullHDNumPixels) ? 2 : 4;
  const auto v4l2_format = OUTPUT_queue_->SetFormat(
      profile_as_v4l2_fourcc, gfx::Size(), kInputBufferInMBs * kMiB);
"""

_SETFMT_NEW = """\
  // dagu: pass the real coded size. An empty S_FMT is clamped to the
  // firmware minimum, so a 4 MiB guess wins and 4K HEVC (6266880 bytes)
  // comes back as HFI insufficient-buffer. 8 MiB is the driver request
  // clamp and covers a large IDR.
  const gfx::Size output_coded_size = config.coded_size().IsEmpty()
                                           ? gfx::Size(3840, 2160)
                                           : config.coded_size();
  size_t output_buffer_bytes = ChromeOutputBufferBytes(
      output_coded_size.width(), output_coded_size.height());
  // Driver S_FMT clamps the bitstream plane at 8 MiB. GStreamer asks for
  // that and Venus returns pictures. A 2 MiB 1080p plane still reports the
  // resolution, then never dequeues a capture buffer.
  if (VideoCodecProfileToVideoCodec(config.profile()) == VideoCodec::kHEVC) {
    output_buffer_bytes =
        std::max(output_buffer_bytes, static_cast<size_t>(8) * kMiB);
  }
  const auto v4l2_format = OUTPUT_queue_->SetFormat(
      profile_as_v4l2_fourcc, output_coded_size, output_buffer_bytes);
"""

_COUNT_OLD = """\
  const bool is_h264 =
      VideoCodecProfileToVideoCodec(config.profile()) == VideoCodec::kH264;
  constexpr size_t kNumInputBuffersH264 = 16;
  constexpr size_t kNumInputBuffersVPx = 2;
  const auto num_input_buffers =
      is_h264 ? kNumInputBuffersH264 : kNumInputBuffersVPx;
"""

_COUNT_NEW = """\
  const bool is_h264 =
      VideoCodecProfileToVideoCodec(config.profile()) == VideoCodec::kH264;
  const bool above_hd = output_coded_size.GetArea() > (1920 * 1080);
  constexpr size_t kNumInputBuffersH264 = 16;
  constexpr size_t kNumInputBuffersAboveHd = 8;
  constexpr size_t kNumInputBuffersVPx = 2;
  const auto num_input_buffers =
      is_h264 ? kNumInputBuffersH264
              : (above_hd ? kNumInputBuffersAboveHd : kNumInputBuffersVPx);
"""

_NOTIFY_OLD = """\
  client_->NotifyEstimatedMaxDecodeRequests(base::checked_cast<int>(
      std::min(static_cast<size_t>(4), num_input_buffers)));
"""

_NOTIFY_NEW = """\
  const size_t request_cap = above_hd ? 8 : 4;
  client_->NotifyEstimatedMaxDecodeRequests(base::checked_cast<int>(
      std::min(request_cap, num_input_buffers)));
"""

_CHECK_OLD = """\
      CHECK_GE(v4l2_buffer->GetPlaneSize(/*plane=*/0),
               media_buffer_span.size());
"""

_CHECK_NEW = """\
      const size_t plane_size = v4l2_buffer->GetPlaneSize(/*plane=*/0);
      if (plane_size < media_buffer_span.size()) {
        LOG(ERROR) << "bitstream access unit " << media_buffer_span.size()
                   << " exceeds OUTPUT plane " << plane_size;
        std::move(media_decode_cb)
            .Run(DecoderStatus::Codes::kPlatformDecodeFailure);
        return false;
      }
"""


def apply_supported_types(text: str) -> str:
    if "dagu SM8250: Venus has no AV1" in text:
        return text
    if _AV1_OLD not in text:
        raise SystemExit("supported_types.cc: AV1 function not found")
    return text.replace(_AV1_OLD, _AV1_NEW, 1)


_IRAP_HELPER = """\
// HEVC IRAP (intra random access point) NALs: BLA 16-18, IDR 19-20, CRA 21.
// ITU-T H.265 7.4.2.2. Bilibili MSE queues a few TRAIL pictures before the
// first IDR; Venus then never returns those OUTPUT buffers.
bool AnnexBHasHevcIrap(base::span<const uint8_t> data) {
  for (size_t i = 0; i + 3 < data.size();) {
    size_t sc = 0;
    if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
      sc = 3;
    } else if (i + 4 < data.size() && data[i] == 0 && data[i + 1] == 0 &&
               data[i + 2] == 0 && data[i + 3] == 1) {
      sc = 4;
    }
    if (sc == 0) {
      ++i;
      continue;
    }
    if (i + sc >= data.size()) {
      break;
    }
    const uint8_t nal = (data[i + sc] >> 1) & 0x3f;
    if (nal >= 16 && nal <= 21) {
      return true;
    }
    i += sc + 1;
  }
  return false;
}

"""

_HEVC_OLD = """\
  } else if (VideoCodecProfileToVideoCodec(config_.profile()) ==
             VideoCodec::kHEVC) {
    // Venus stateful (SM8250 /dev/video14) takes whole MP4/MSE access
    // units, same as VP8/VP9. Upstream left HEVC as NOTIMPLEMENTED after
    // removing the old splitter; that returns kUnsupportedCodec (201) and
    // HTML5 HEVC never reaches the hardware.
    decoder_buffer_and_callbacks_.emplace(std::move(buffer),
                                          std::move(decode_cb));
"""

_HEVC_NEW = """\
  } else if (VideoCodecProfileToVideoCodec(config_.profile()) ==
             VideoCodec::kHEVC) {
    // Venus stateful (SM8250 /dev/video14) takes whole MP4/MSE access
    // units, same as VP8/VP9. Upstream left HEVC as NOTIMPLEMENTED after
    // removing the old splitter; that returns kUnsupportedCodec (201) and
    // HTML5 HEVC never reaches the hardware.
    //
    // Do not queue a non-IRAP until the first IDR/CRA/BLA. Bilibili's
    // fMP4 starts with TRAIL pictures; Venus holds those OUTPUT buffers
    // and never emits the keyframe that is already queued behind them.
    if (!hevc_seen_irap_) {
      if (!AnnexBHasHevcIrap(base::span(*buffer))) {
        VLOGF(2) << "Dropping HEVC access unit before the first IRAP, size="
                 << buffer->size();
        std::move(decode_cb).Run(DecoderStatus::Codes::kOk);
        return;
      }
      hevc_seen_irap_ = true;
    }
    decoder_buffer_and_callbacks_.emplace(std::move(buffer),
                                          std::move(decode_cb));
"""

_REASM_OLD = """\
  std::unique_ptr<H264FrameReassembler> h264_frame_reassembler_
      GUARDED_BY_CONTEXT(sequence_checker_);
"""

_REASM_NEW = """\
  std::unique_ptr<H264FrameReassembler> h264_frame_reassembler_
      GUARDED_BY_CONTEXT(sequence_checker_);

  // Venus keeps an OUTPUT buffer until it can decode it. A non-IRAP HEVC
  // access unit queued before the first IDR/CRA/BLA is never returned, so
  // the keyframe behind it never becomes a picture.
  bool hevc_seen_irap_ GUARDED_BY_CONTEXT(sequence_checker_) = false;
"""


def annexb_has_hevc_irap(data: bytes) -> bool:
    """Same rule as AnnexBHasHevcIrap. BLA/IDR/CRA are NAL types 16..21."""
    i = 0
    n = len(data)
    while i + 3 < n:
        sc = 0
        if data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1:
            sc = 3
        elif (
            i + 4 < n
            and data[i] == 0
            and data[i + 1] == 0
            and data[i + 2] == 0
            and data[i + 3] == 1
        ):
            sc = 4
        if sc == 0:
            i += 1
            continue
        if i + sc >= n:
            break
        nal = (data[i + sc] >> 1) & 0x3F
        if 16 <= nal <= 21:
            return True
        i += sc + 1
    return False


def apply_hevc_irap(text: str) -> str:
    """Drop HEVC access units that arrive before the first IRAP."""
    if "AnnexBHasHevcIrap" not in text:
        anchor = "constexpr int kIoctlOk = 0;\n"
        if anchor in text:
            text = text.replace(anchor, anchor + "\n" + _IRAP_HELPER, 1)
    if "Dropping HEVC access unit before the first IRAP" not in text and _HEVC_OLD in text:
        text = text.replace(_HEVC_OLD, _HEVC_NEW, 1)
    if "A 2 MiB 1080p plane still reports the resolution" not in text:
        old_bytes = (
            "  const size_t output_buffer_bytes = ChromeOutputBufferBytes(\n"
            "      output_coded_size.width(), output_coded_size.height());\n"
        )
        new_bytes = (
            "  size_t output_buffer_bytes = ChromeOutputBufferBytes(\n"
            "      output_coded_size.width(), output_coded_size.height());\n"
            "  // Driver S_FMT clamps the bitstream plane at 8 MiB. GStreamer asks for\n"
            "  // that and Venus returns pictures. A 2 MiB 1080p plane still reports the\n"
            "  // resolution, then never dequeues a capture buffer.\n"
            "  if (VideoCodecProfileToVideoCodec(config.profile()) == VideoCodec::kHEVC) {\n"
            "    output_buffer_bytes =\n"
            "        std::max(output_buffer_bytes, static_cast<size_t>(8) * kMiB);\n"
            "  }\n"
        )
        if old_bytes in text:
            text = text.replace(old_bytes, new_bytes, 1)
    if "Failed to set Venus decode order" not in text:
        streamon = "  if (!OUTPUT_queue_->Streamon()) {\n"
        display_order = (
            "  // Venus defaults to display order. Bilibili HEVC reference B frames are\n"
            "  // then held until EOS, and every OUTPUT buffer stays queued, so no further\n"
            "  // access unit can be submitted and no picture is ever returned. Decode\n"
            "  // order releases each picture as it is decoded; presentation order is the\n"
            "  // renderer's timestamp.\n"
            "  struct v4l2_control display_delay = {\n"
            "      .id = V4L2_CID_MPEG_VIDEO_DEC_DISPLAY_DELAY, .value = 0};\n"
            "  struct v4l2_control display_delay_enable = {\n"
            "      .id = V4L2_CID_MPEG_VIDEO_DEC_DISPLAY_DELAY_ENABLE, .value = 1};\n"
            "  if (HandledIoctl(device_fd_.get(), VIDIOC_S_CTRL, &display_delay) !=\n"
            "          kIoctlOk ||\n"
            "      HandledIoctl(device_fd_.get(), VIDIOC_S_CTRL, &display_delay_enable) !=\n"
            "          kIoctlOk) {\n"
            "    PLOG(ERROR) << \"Failed to set Venus decode order\";\n"
            "    std::move(init_cb).Run(DecoderStatus::Codes::kFailedToCreateDecoder);\n"
            "    return;\n"
            "  }\n"
        )
        if streamon in text:
            text = text.replace(streamon, display_order + streamon, 1)
    if "hevc_seen_irap_ = false" not in text:
        text = text.replace(
            "  config_ = config;\n",
            "  config_ = config;\n  hevc_seen_irap_ = false;\n",
            1,
        )
        text = text.replace(
            "  if (h264_frame_reassembler_) {\n"
            "    h264_frame_reassembler_ = std::make_unique<H264FrameReassembler>();\n"
            "  }\n",
            "  if (h264_frame_reassembler_) {\n"
            "    h264_frame_reassembler_ = std::make_unique<H264FrameReassembler>();\n"
            "  }\n"
            "  hevc_seen_irap_ = false;\n",
            1,
        )
    return text


def apply_decoder_header(text: str) -> str:
    if "hevc_seen_irap_" in text:
        return text
    if _REASM_OLD not in text:
        raise SystemExit("v4l2_stateful_video_decoder.h: reassembler member missing")
    return text.replace(_REASM_OLD, _REASM_NEW, 1)


def apply_decoder(text: str) -> str:
    if "VenusCompressedBitstreamBytes" in text and "exceeds OUTPUT plane" in text:
        return apply_hevc_irap(text)
    if "#include <algorithm>" not in text:
        needle = '#include "ui/gfx/geometry/size.h"\n'
        if needle not in text:
            raise SystemExit("v4l2_stateful_video_decoder.cc: include anchor missing")
        text = text.replace(needle, '#include <algorithm>\n\n' + needle, 1)
    anchor = "constexpr int kIoctlOk = 0;\n"
    if "VenusCompressedBitstreamBytes" not in text:
        if anchor not in text:
            raise SystemExit("v4l2_stateful_video_decoder.cc: kIoctlOk missing")
        text = text.replace(anchor, anchor + "\n" + _HELPER, 1)
    for old, new, label in (
        (_SETFMT_OLD, _SETFMT_NEW, "SetFormat"),
        (_COUNT_OLD, _COUNT_NEW, "buffer count"),
        (_NOTIFY_OLD, _NOTIFY_NEW, "decode requests"),
        (_CHECK_OLD, _CHECK_NEW, "plane size check"),
    ):
        if old not in text:
            raise SystemExit(f"v4l2_stateful_video_decoder.cc: {label} block missing")
        text = text.replace(old, new, 1)
    return apply_hevc_irap(text)


def patch_chromium_tree(root: Path) -> list[str]:
    """Patch an official-152 checkout. Returns files written."""
    supported = root / "media/base/supported_types.cc"
    decoder = root / "media/gpu/v4l2/v4l2_stateful_video_decoder.cc"
    header = root / "media/gpu/v4l2/v4l2_stateful_video_decoder.h"
    written: list[str] = []
    for path, fn in (
        (supported, apply_supported_types),
        (decoder, apply_decoder),
        (header, apply_decoder_header),
    ):
        if not path.is_file():
            raise SystemExit(f"missing {path}")
        old = path.read_text()
        new = fn(old)
        if new != old:
            path.write_text(new)
            written.append(str(path))
    return written


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--patch-chromium", type=Path, default=None)
    args = ap.parse_args(argv)
    if args.patch_chromium:
        wrote = patch_chromium_tree(args.patch_chromium)
        if wrote:
            print("patched:")
            for path in wrote:
                print(" ", path)
        else:
            print("already patched")
        return 0
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
