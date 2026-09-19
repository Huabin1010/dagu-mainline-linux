#!/usr/bin/env python3
"""Unit tests for the dagu built-in mic path.

Locks the regressions that already shipped once:

- Fluence Off + analog 12 + TX_DEC0 84 → S16 peak ~170 (silent record)
- spa S24_32LE on Q6 S24_LE → ~48 dB false gain + 5.3 kHz crush
- spa format string S16_LE left hardware on S24_LE
- MultiMedia2 capture leaked Q6 ASM (ADSP_EALREADY)
- HiFi Mic/Bluetooth in the same verb → ACP Dummy
"""
from __future__ import annotations

import math
import sys
import tempfile
import unittest
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))

from dagu_mic_lib import (  # noqa: E402
    ADC4_ANALOG,
    ALSA_FORMAT,
    AUDIBLE_PEAK_MIN,
    CAPTURE_FE_TRY_ORDER,
    CAPTURE_PCM,
    CAPTURE_PROBE_MIN_BYTES,
    CHANNELS,
    EMPTY_PEAK_MAX,
    FLUENCE_OFF_S16_SPEECH_PEAK,
    RATE,
    RESOLUTION_BITS,
    S24_FALSE_SHIFT,
    SPA_FORMAT,
    TX_DEC0_DIGITAL,
    TX_DEC0_ZERO_DB,
    peak_from_db,
    pick_capture_fe,
    s24_32le_misread_peak,
    s24_false_gain_db,
    wav_peak_s16,
    write_wav_s16,
)

MIC_ROUTE = SCRIPTS / "dagu-mic-route.sh"
AUDIO_UP = SCRIPTS / "dagu-audio-up.sh"
MIC_TEST = SCRIPTS / "dagu-mic-test.py"
MIC_LIB = SCRIPTS / "dagu_mic_lib.py"
DEPLOY = SCRIPTS / "dagu-mic-deploy.sh"
ROOTFS = SCRIPTS / "rootfs-desktop-setup.sh"
WP_CONF = ROOT / "alsa" / "50-dagu-speaker.conf"
HIFI = ROOT / "alsa" / "ucm2" / "Xiaomi-dagu" / "HiFi.conf"


def _text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _live_lines(text: str) -> list[str]:
    out = []
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            out.append(line)
    return out


def _wp_mic_props(text: str) -> str:
    key = 'node.name = "dagu-builtin-mic"'
    i = text.find(key)
    if i < 0:
        raise AssertionError("WirePlumber mic match missing dagu-builtin-mic")
    j = text.find("update-props", i)
    if j < 0:
        raise AssertionError("WirePlumber mic update-props missing")
    k = text.find("}", j)
    return "\n".join(_live_lines(text[j:k]))


def _heredoc(text: str, dest: str) -> str:
    needle = f"cat >{dest}"
    start = text.find(needle)
    if start < 0:
        raise AssertionError(f"heredoc {dest} missing")
    nl = text.find("\n", start)
    end = text.find("\nEOF\n", nl)
    if end < 0:
        raise AssertionError(f"heredoc {dest} has no closing EOF")
    return text[nl + 1 : end]


def _create_node_line(text: str) -> str:
    for line in text.splitlines():
        if "pw-cli create-node" in line and "dagu-builtin-mic" in line:
            return line
    raise AssertionError("pw-cli create-node dagu-builtin-mic missing")


def _write_s16_wav(path: Path, samples: list[int], rate: int = RATE) -> None:
    write_wav_s16(
        path,
        b"".join(int(s).to_bytes(2, "little", signed=True) for s in samples),
        rate,
    )


class WavPeakTests(unittest.TestCase):
    def test_write_wav_roundtrip_peak(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "t.wav"
            write_wav_s16(p, (1234).to_bytes(2, "little", signed=True) * 64, RATE)
            self.assertEqual(wav_peak_s16(p), 1234)

    def test_empty_and_missing(self) -> None:
        self.assertEqual(wav_peak_s16(Path("/no/such/mic-test.wav")), 0)
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "tiny.wav"
            p.write_bytes(b"RIFF")
            self.assertEqual(wav_peak_s16(p), 0)

    def test_silence_is_empty(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "z.wav"
            _write_s16_wav(p, [0] * 480)
            self.assertEqual(wav_peak_s16(p), 0)
            self.assertLess(wav_peak_s16(p), EMPTY_PEAK_MAX)

    def test_fluence_off_speech_is_below_audible_gate(self) -> None:
        """analog 12 + DEC0 84: recorded, but playback/Meeting hear nothing."""
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "quiet.wav"
            _write_s16_wav(p, [FLUENCE_OFF_S16_SPEECH_PEAK, -FLUENCE_OFF_S16_SPEECH_PEAK] * 240)
            pk = wav_peak_s16(p)
            self.assertEqual(pk, FLUENCE_OFF_S16_SPEECH_PEAK)
            self.assertLess(pk, AUDIBLE_PEAK_MIN)

    def test_makeup_speech_clears_audible_gate(self) -> None:
        # +30 dB vs analog12+0dB ≈ ×31.6; 170 * 31.6 ≈ 5370.
        makeup = int(FLUENCE_OFF_S16_SPEECH_PEAK * 10 ** ((6 + 24) / 20.0))
        self.assertGreaterEqual(makeup, AUDIBLE_PEAK_MIN)
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "ok.wav"
            _write_s16_wav(p, [makeup, -makeup] * 240)
            self.assertGreaterEqual(wav_peak_s16(p), AUDIBLE_PEAK_MIN)

    def test_peak_from_db(self) -> None:
        self.assertEqual(peak_from_db([]), 0.0)
        self.assertAlmostEqual(peak_from_db([-6.0]), 10 ** (-6.0 / 20.0), places=6)
        self.assertEqual(peak_from_db([0.0]), 1.0)


class S24MisreadTests(unittest.TestCase):
    def test_false_gain_is_48db(self) -> None:
        self.assertEqual(S24_FALSE_SHIFT, 8)
        self.assertAlmostEqual(s24_false_gain_db(), 20.0 * math.log10(256), places=6)
        self.assertGreater(s24_false_gain_db(), 47.0)
        self.assertLess(s24_false_gain_db(), 49.0)

    def test_quiet_s16_becomes_crush_when_read_as_s24_32le(self) -> None:
        native = 93
        hot = s24_32le_misread_peak(native)
        self.assertEqual(hot, native << 8)
        self.assertGreater(hot, 20000)
        self.assertGreater(hot, AUDIBLE_PEAK_MIN * 20)


class MixerContractTests(unittest.TestCase):
    def test_mic_route_pins_makeup_and_fluence_off(self) -> None:
        live = "\n".join(_live_lines(_text(MIC_ROUTE)))
        self.assertIn(f'cset_any {ADC4_ANALOG} "ADC4 Volume"', live)
        self.assertIn(f'cset_any {TX_DEC0_DIGITAL} "TX_DEC0 Volume"', live)
        self.assertNotIn(f'cset_any 12 "ADC4 Volume"', live)
        self.assertNotIn(f'cset_any {TX_DEC0_ZERO_DB} "TX_DEC0 Volume"', live)
        self.assertIn('cset "Fluence AEC NS" Off', live)
        self.assertNotIn("AEC_NS", live)
        self.assertIn("probe_fe 2 3 || probe_fe 3 4 || probe_fe 1 2", live)
        self.assertIn("timeout -s INT", live)
        self.assertIn('DAGU_MIC_PROBE:-0', _text(MIC_ROUTE))
        self.assertIn('cset "ADC4 MUX" INP5', live)
        self.assertIn('cset "TX SMIC MUX0" ADC3', live)
        self.assertIn('cset "TX DEC0 MUX" SWR_MIC', live)

    def test_rootfs_mic_route_matches(self) -> None:
        body = _heredoc(_text(ROOTFS), "/usr/local/sbin/dagu-mic-route.sh")
        live = "\n".join(_live_lines(body))
        self.assertIn(f'cset_any {ADC4_ANALOG} "ADC4 Volume"', live)
        self.assertIn(f'cset_any {TX_DEC0_DIGITAL} "TX_DEC0 Volume"', live)
        self.assertNotIn(f'cset_any 12 "ADC4 Volume"', live)
        self.assertNotIn(f'cset_any {TX_DEC0_ZERO_DB} "TX_DEC0 Volume"', live)
        self.assertIn('cset "Fluence AEC NS" Off', live)
        self.assertIn("probe_fe 2 3 || probe_fe 3 4 || probe_fe 1 2", live)
        self.assertIn("DAGU_MIC_PROBE", body)


class CaptureFormatContractTests(unittest.TestCase):
    def test_wp_mic_is_s16le_mono(self) -> None:
        props = _wp_mic_props(_text(WP_CONF))
        self.assertIn(f'audio.channels = {CHANNELS}', props)
        self.assertIn(f'audio.format = "{SPA_FORMAT}"', props)
        self.assertIn(f"alsa.resolution_bits = {RESOLUTION_BITS}", props)
        self.assertIn("audio.position = [ MONO ]", props)
        self.assertIn("node.always-process = true", props)
        self.assertNotIn("S24_32LE", props)
        self.assertNotIn(f'audio.format = "{ALSA_FORMAT}"', props)
        self.assertNotIn("audio.channels = 2", props)

    def test_rootfs_wp_mic_matches(self) -> None:
        props = _wp_mic_props(_text(ROOTFS))
        self.assertIn(f'audio.format = "{SPA_FORMAT}"', props)
        self.assertIn(f"audio.channels = {CHANNELS}", props)
        self.assertNotIn("S24_32LE", props)
        self.assertNotIn(f'audio.format = "{ALSA_FORMAT}"', props)

    def test_linger_node_follows_live_fe(self) -> None:
        for src in (_text(AUDIO_UP), _text(ROOTFS)):
            line = _create_node_line(src)
            self.assertIn(f"audio.format={SPA_FORMAT}", line)
            self.assertIn("audio.channels=1", line)
            self.assertIn("alsa.resolution_bits=16", line)
            self.assertIn('api.alsa.path=\\"hw:${CARD},${MICDEV}\\"', line)
            self.assertIn("node.always-process=true", line)
            self.assertNotIn("S24_32LE", line)
            self.assertNotIn(f"audio.format={ALSA_FORMAT}", line)
            self.assertNotIn('api.alsa.path=\\"hw:${CARD},1\\"', line)
            self.assertNotIn("hw:0,1", line)

    def test_audio_up_waits_on_any_capture_pcm(self) -> None:
        up = _text(AUDIO_UP)
        self.assertIn('pcmC${CARD}D2c', up)
        self.assertIn('pcmC${CARD}D3c', up)
        self.assertIn('pcmC${CARD}D0p', up)
        self.assertIn("${RUNDIR}/mic-pcm", up)
        self.assertIn("destroy_mic", up)
        self.assertIn("sleep 0.4", up)
        self.assertIn("DAGU_MIC_PROBE=1", up)
        self.assertIn("--repair", up)
        self.assertIn("虚拟输出", up)
        self.assertIn("is_dummy", up)

    def test_audio_up_waits_for_adc4_mixer(self) -> None:
        up = _text(AUDIO_UP)
        self.assertIn('cget name="ADC4 Volume"', up)
        self.assertIn("mixer_ready", up)
        self.assertIn("Microphone source missing", up)
        rootfs = _text(ROOTFS)
        self.assertIn('cget name="ADC4 Volume"', rootfs)
        self.assertIn("mixer_ready", rootfs)
        self.assertIn("Microphone source missing", rootfs)

    def test_speaker_stays_s24_le_stereo(self) -> None:
        text = _text(WP_CONF)
        i = text.find("alsa_output.platform-sound")
        block = text[i : text.find("}", text.find("update-props", i))]
        self.assertIn('audio.format = "S24_LE"', block)
        self.assertIn("audio.channels = 2", block)


class HifiDummyContractTests(unittest.TestCase):
    def test_hifi_has_speaker_only(self) -> None:
        text = "\n".join(_live_lines(_text(HIFI)))
        self.assertIn('SectionDevice."Speaker"', text)
        self.assertNotIn("CapturePCM", text)
        self.assertNotIn('SectionDevice."Mic"', text)
        self.assertNotIn('SectionDevice."Headset"', text)
        self.assertNotIn('SectionDevice."Bluetooth"', text)
        self.assertNotIn("hw:${CardId},1", text)
        self.assertNotIn("hw:${CardId},3", text)
        self.assertIn('PlaybackPCM "hw:${CardId},0"', text)

    def test_acp_does_not_auto_port_slim(self) -> None:
        for src in (_text(WP_CONF), _text(ROOTFS)):
            self.assertIn("api.acp.auto-port = false", src)
            self.assertNotIn("api.acp.auto-port = true", src)
            self.assertIn('alsa.device = "3"', src)
            self.assertIn(
                '{ media.class = "Audio/Sink", alsa.device = "3" }', src
            )
            self.assertNotIn('{ media.class = "Audio/Sink" }', src)
            self.assertIn("node.disabled = true", src)

    def test_audio_up_service_retries_after_mixer(self) -> None:
        unit = _text(ROOT / "systemd" / "dagu-audio-up.service")
        self.assertIn("TimeoutStartSec=180", unit)
        self.assertIn("Restart=on-failure", unit)
        rootfs = _text(ROOTFS)
        self.assertIn("TimeoutStartSec=180", rootfs)
        self.assertIn("Restart=on-failure", rootfs)


class TesterAppContractTests(unittest.TestCase):
    def test_app_uses_pulse_s16_mono_and_peak_gate(self) -> None:
        text = _text(MIC_TEST)
        self.assertIn("from dagu_mic_lib import", text)
        self.assertIn("pulsesrc", text)
        self.assertIn("pulsesink", text)
        self.assertIn("channels=1,format=S16LE", text)
        self.assertIn("AUDIBLE_PEAK_MIN", text)
        self.assertIn("appsink", text)
        self.assertIn("sync=false", text)
        self.assertIn("async=false", text)
        self.assertIn("--repair", text)
        self.assertIn("_kick_repair", text)
        self.assertIn("_prep_mixer", text)
        self.assertNotIn("CLOCK_TIME_NONE", text)
        self.assertIn("300 * Gst.MSECOND", text)
        self.assertIn("write_wav_s16", text)
        self.assertNotIn("wavenc", text)
        self.assertNotIn("alsasrc", text)
        self.assertNotIn("drop=true", text)

    def test_deploy_installs_lib(self) -> None:
        text = _text(DEPLOY)
        self.assertIn("dagu_mic_lib.py", text)
        self.assertIn("dagu-mic-test.py", text)


class ImportSanityTests(unittest.TestCase):
    def test_lib_imports_without_gi(self) -> None:
        self.assertTrue(MIC_LIB.is_file())
        self.assertEqual(SPA_FORMAT, "S16LE")
        self.assertEqual(ADC4_ANALOG, 16)
        self.assertEqual(TX_DEC0_DIGITAL, 108)
        self.assertEqual(CAPTURE_PCM, 2)
        self.assertEqual(CAPTURE_FE_TRY_ORDER, ((2, 3), (3, 4), (1, 2)))
        self.assertGreater(AUDIBLE_PEAK_MIN, FLUENCE_OFF_S16_SPEECH_PEAK)


class CaptureFeFailoverTests(unittest.TestCase):
    def test_pick_prefers_mm3(self) -> None:
        self.assertEqual(pick_capture_fe({2: 96044, 3: 96044, 1: 96044}), 2)

    def test_pick_skips_leaked_mm3(self) -> None:
        # Live board: MM3 hw_params EINVAL (0 bytes), MM4 96044 peak 1175.
        self.assertEqual(pick_capture_fe({2: 0, 3: 96044, 1: 19244}), 3)

    def test_pick_falls_to_mm2_last(self) -> None:
        self.assertEqual(pick_capture_fe({2: 44, 3: 44, 1: 96044}), 1)

    def test_pick_none_when_all_silent(self) -> None:
        self.assertIsNone(pick_capture_fe({2: 44, 3: 44, 1: 44}))
        self.assertGreater(CAPTURE_PROBE_MIN_BYTES, 44)

    def test_udev_does_not_arecord_on_control_add(self) -> None:
        rules = _text(ROOT / "alsa" / "99-dagu-speaker.rules")
        self.assertIn("DAGU_MIC_PROBE=0", rules)
        rootfs = _heredoc(_text(ROOTFS), "/etc/udev/rules.d/99-dagu-speaker.rules")
        self.assertIn("DAGU_MIC_PROBE=0", rootfs)


def main() -> int:
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
