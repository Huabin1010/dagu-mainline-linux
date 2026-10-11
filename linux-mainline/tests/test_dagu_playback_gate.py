#!/usr/bin/env python3
"""Netflix-bar unit tests for 4K playback on this tablet.

Run:

  python3 linux-mainline/tests/test_dagu_playback_gate.py
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from dagu_playback_gate import (  # noqa: E402
    MAX_ABS_AV_SKEW_MS,
    MAX_DROP_RATIO,
    MAX_STALL_MS,
    MIB,
    _AV1_OLD,
    _CHECK_OLD,
    _COUNT_OLD,
    _NOTIFY_OLD,
    _SETFMT_OLD,
    annexb_has_hevc_irap,
    apply_decoder,
    apply_supported_types,
    bilibili_codec,
    chrome_output_buffer_bytes,
    dagu_can_play,
    max_decode_requests,
    netflix_gate,
    output_buffer_count,
    stock_chrome_can_play,
    venus_compressed_bitstream_bytes,
)

CHROMIUM = ROOT / "out/chromium-v4l2-src/official-152"
DECODER_CC = CHROMIUM / "media/gpu/v4l2/v4l2_stateful_video_decoder.cc"
SUPPORTED_CC = CHROMIUM / "media/base/supported_types.cc"

_UPSTREAM_AV1 = _AV1_OLD
_UPSTREAM_DECODER = (
    '#include "ui/gfx/geometry/size.h"\n\n'
    "namespace {\n"
    "constexpr int kIoctlOk = 0;\n\n"
    "void Initialize() {\n"
    + _SETFMT_OLD
    + _COUNT_OLD
    + _NOTIFY_OLD
    + "      auto media_buffer_span = base::span(*media_buffer);\n"
    + _CHECK_OLD
    + "}\n}\n"
)


def _smooth_4k() -> dict:
    return {
        "profile": "4k",
        "codec": "hevc",
        "w": 3840,
        "h": 2160,
        "dropped": 0,
        "total": 360,
        "max_av_skew_ms": 12.0,
        "max_frame_gap_ms": 33.4,
        "decoder": "V4L2StatefulVideoDecoder",
        "decoder_log": "Using a stateful API",
        "video14": True,
        "venus_irq_delta": 400,
        "can_play": dagu_can_play(),
    }


class VenusContractTests(unittest.TestCase):
    def test_4k_bitstream_is_above_the_old_4mib_guess(self) -> None:
        # ALIGN(2160,32)*ALIGN(3840,32)*3/4 = 2176*3840*3/4 = 6266880
        self.assertEqual(venus_compressed_bitstream_bytes(3840, 2160), 6_266_880)
        self.assertGreater(6_266_880, 4 * MIB)
        self.assertEqual(chrome_output_buffer_bytes(3840, 2160), 8 * MIB)

    def test_1080p_stays_in_the_2mib_slot(self) -> None:
        venus = venus_compressed_bitstream_bytes(1920, 1080)
        self.assertEqual(venus, 1_568_768)
        self.assertLess(venus, 2 * MIB)
        self.assertEqual(chrome_output_buffer_bytes(1920, 1080), 2 * MIB)

    def test_unknown_coded_size_allocates_for_4k(self) -> None:
        self.assertEqual(chrome_output_buffer_bytes(0, 0), 8 * MIB)

    def test_4k_hevc_queue_is_deeper_than_two(self) -> None:
        self.assertEqual(output_buffer_count("hevc", 3840, 2160), 8)
        self.assertEqual(output_buffer_count("vp9", 3840, 2160), 8)
        self.assertEqual(output_buffer_count("h264", 3840, 2160), 16)
        self.assertEqual(output_buffer_count("vp9", 1920, 1080), 2)
        self.assertEqual(max_decode_requests("hevc", 3840, 2160), 8)
        self.assertEqual(max_decode_requests("h264", 1920, 1080), 4)

    def test_c_formula_matches_python(self) -> None:
        src = r"""
        #include <stdint.h>
        #include <stdio.h>
        static size_t align_up(size_t value, size_t align) {
          return (value + align - 1) & ~(align - 1);
        }
        static size_t venus(int width, int height) {
          size_t w = align_up((size_t)(width > 0 ? width : 0), 32);
          size_t h = align_up((size_t)(height > 0 ? height : 0), 32);
          size_t sz = h * w * 3 / 2 / 2;
          if (width < 1280 || height < 720) sz *= 8;
          return align_up(sz, 4096);
        }
        int main(void) {
          printf("%zu %zu\n", venus(3840, 2160), venus(1920, 1080));
          return 0;
        }
        """
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "venus.c"
            path.write_text(textwrap.dedent(src))
            bin_path = Path(tmp) / "venus"
            subprocess.run(
                ["gcc", "-O2", "-o", str(bin_path), str(path)],
                check=True,
                capture_output=True,
            )
            out = subprocess.run(
                [str(bin_path)], check=True, capture_output=True, text=True
            ).stdout.split()
        self.assertEqual(int(out[0]), venus_compressed_bitstream_bytes(3840, 2160))
        self.assertEqual(int(out[1]), venus_compressed_bitstream_bytes(1920, 1080))


class CodecChoiceTests(unittest.TestCase):
    def test_bilibili_picks_hevc_when_av1_is_hidden(self) -> None:
        self.assertEqual(bilibili_codec(dagu_can_play()), "hevc")

    def test_bilibili_picks_av1_on_stock_chrome(self) -> None:
        self.assertEqual(bilibili_codec(stock_chrome_can_play()), "av1")


class NetflixGateTests(unittest.TestCase):
    def test_thresholds_are_inside_the_itu_window(self) -> None:
        self.assertLessEqual(MAX_ABS_AV_SKEW_MS, 45.0)
        self.assertLessEqual(MAX_DROP_RATIO, 0.001)
        self.assertLessEqual(MAX_STALL_MS, 50.0)

    def test_smooth_4k_hevc_passes(self) -> None:
        ok, reasons = netflix_gate(_smooth_4k())
        self.assertTrue(ok, reasons)

    def test_one_dropped_frame_in_twelve_seconds_fails(self) -> None:
        sample = _smooth_4k()
        sample["dropped"] = 1
        ok, reasons = netflix_gate(sample)
        self.assertFalse(ok)
        self.assertTrue(any("drop ratio" in r for r in reasons))

    def test_audio_ahead_by_a_detectable_margin_fails(self) -> None:
        sample = _smooth_4k()
        sample["max_av_skew_ms"] = 80
        ok, reasons = netflix_gate(sample)
        self.assertFalse(ok)
        self.assertTrue(any("skew" in r for r in reasons))

    def test_visible_stall_fails(self) -> None:
        sample = _smooth_4k()
        sample["max_frame_gap_ms"] = 90
        ok, reasons = netflix_gate(sample)
        self.assertFalse(ok)
        self.assertTrue(any("frame gap" in r for r in reasons))

    def test_dav1d_4k_is_the_old_bilibili_failure(self) -> None:
        sample = _smooth_4k()
        sample["codec"] = "av1"
        sample["decoder"] = "FFmpegVideoDecoder"
        sample["decoder_log"] = "dav1d-worker"
        sample["video14"] = False
        sample["venus_irq_delta"] = 0
        sample["dropped"] = 48
        sample["max_av_skew_ms"] = 220
        sample["max_frame_gap_ms"] = 180
        sample["can_play"] = stock_chrome_can_play()
        ok, reasons = netflix_gate(sample)
        self.assertFalse(ok)
        self.assertGreaterEqual(len(reasons), 4)

    def test_software_hevc_without_venus_fails(self) -> None:
        sample = _smooth_4k()
        sample["decoder"] = "FFmpegVideoDecoder"
        sample["video14"] = False
        sample["venus_irq_delta"] = 0
        ok, reasons = netflix_gate(sample)
        self.assertFalse(ok)
        self.assertTrue(any("video14" in r for r in reasons))


class ChromiumPatchTests(unittest.TestCase):
    def test_patch_hides_av1_and_sizes_4k_buffers(self) -> None:
        supported = apply_supported_types(_UPSTREAM_AV1)
        decoder = apply_decoder(_UPSTREAM_DECODER)
        self.assertIn("return false;", supported)
        self.assertNotIn("ENABLE_AV1_DECODER", supported)
        self.assertIn("VenusCompressedBitstreamBytes", decoder)
        self.assertIn("gfx::Size(3840, 2160)", decoder)
        self.assertNotIn("gfx::Size()", decoder)
        self.assertIn("kNumInputBuffersAboveHd = 8", decoder)
        self.assertIn("exceeds OUTPUT plane", decoder)
        self.assertNotIn("CHECK_GE(v4l2_buffer->GetPlaneSize", decoder)
        self.assertIn("AnnexBHasHevcIrap", decoder)
        self.assertEqual(apply_supported_types(supported), supported)
        self.assertEqual(apply_decoder(decoder), decoder)

    def test_hevc_irap_is_required_before_trail(self) -> None:
        trail = b"\x00\x00\x00\x01\x02\x01\xe1"
        idr = b"\x00\x00\x00\x01\x40\x01" + b"\x00\x00\x00\x01\x28\x01"
        self.assertFalse(annexb_has_hevc_irap(trail))
        self.assertTrue(annexb_has_hevc_irap(idr))
        from dagu_playback_gate import _HEVC_OLD

        patched = apply_decoder(
            "VenusCompressedBitstreamBytes\nexceeds OUTPUT plane\n" + _HEVC_OLD
        )
        self.assertIn("Dropping HEVC access unit before the first IRAP", patched)
        self.assertEqual(apply_decoder(patched), patched)

    def test_live_tree_matches_the_contract(self) -> None:
        if not DECODER_CC.is_file() or not SUPPORTED_CC.is_file():
            self.skipTest("official-152 checkout is not on this machine")
        decoder = DECODER_CC.read_text()
        supported = SUPPORTED_CC.read_text()
        self.assertIn("dagu SM8250: Venus has no AV1", supported)
        self.assertIn("return false;", supported[supported.find("IsDecoderAV1Supported"):supported.find("IsDecoderAV1Supported") + 400])
        self.assertIn("VenusCompressedBitstreamBytes", decoder)
        self.assertIn("output_coded_size", decoder)
        self.assertNotIn("kInputBufferInMBs", decoder)
        self.assertIn("exceeds OUTPUT plane", decoder)
        self.assertIn("Dropping HEVC access unit before the first IRAP", decoder)
        self.assertIn("hevc_seen_irap_", decoder)
        self.assertIn("Failed to set Venus decode order", decoder)
        self.assertIn("V4L2_CID_MPEG_VIDEO_DEC_DISPLAY_DELAY_ENABLE", decoder)


if __name__ == "__main__":
    unittest.main()
