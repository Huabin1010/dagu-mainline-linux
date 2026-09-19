# Shared mic contract for dagu-mic-test and unit tests.
# No GTK / GStreamer: host CI can import this without the board desktop.
from __future__ import annotations

import array
import math
import wave
from pathlib import Path

# WCD9385 ADC4 analog. TLV 0..30 dB, 1.5 dB/step. 16 = 24 dB.
# Analog 12 (18 dB) + TX_DEC0 84 (0 dB) is the Fluence path: native S16
# speech peak ~170, inaudible after S24_32LE false gain is removed.
ADC4_ANALOG = 16
# TX_DEC0 digital. TLV -84..+40 dB, 84 = 0 dB. 108 = +24 dB makeup.
TX_DEC0_DIGITAL = 108
TX_DEC0_ZERO_DB = 84

# spa format name (not ALSA S16_LE). S16_LE left Q6 on S24_LE.
# Q6 S24_LE is 8 bits left of spa S24_32LE (~48 dB + 5.3 kHz carrier).
SPA_FORMAT = "S16LE"
ALSA_FORMAT = "S16_LE"
CHANNELS = 1
RATE = 48000
RESOLUTION_BITS = 16
# Preferred MultiMedia3. MultiMedia2 leaked Q6 ASM (ADSP_EALREADY).
# After MM3 leak, OPEN_READ_V3 0x10db4 returns 9; probe MM4 then MM2.
CAPTURE_PCM = 2
CAPTURE_FE_TRY_ORDER = ((2, 3), (3, 4), (1, 2))  # (alsa device, MultiMedia N)
CAPTURE_PROBE_MIN_BYTES = 2000
RUNDIR = "/run/user/1001"


def pick_capture_fe(sizes: dict[int, int], min_bytes: int = CAPTURE_PROBE_MIN_BYTES) -> int | None:
    """First FE in product order whose arecord wav is larger than silence."""
    for dev, _mm in CAPTURE_FE_TRY_ORDER:
        if int(sizes.get(dev, 0)) > min_bytes:
            return dev
    return None

# S16 peak below this is "too quiet" in the tester (analog12+0dB speech).
AUDIBLE_PEAK_MIN = 800
EMPTY_PEAK_MAX = 8
# Measured Fluence-off analog12+0dB speech on this board.
FLUENCE_OFF_S16_SPEECH_PEAK = 170
# Hardware wrote left-justified 24-bit; spa read S24_32LE right-justified.
S24_FALSE_SHIFT = 8


def write_wav_s16(path: Path, pcm: bytes, rate: int = RATE) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(CHANNELS)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)


def wav_peak_s16(path: Path) -> int:
    if not path.exists() or path.stat().st_size < 64:
        return 0
    with wave.open(str(path), "rb") as w:
        raw = w.readframes(w.getnframes())
    n = len(raw) // 2
    if n == 0:
        return 0
    a = array.array("h")
    a.frombytes(raw[: n * 2])
    return max(abs(x) for x in a)


def peak_from_db(peaks) -> float:
    if not peaks:
        return 0.0
    db = max(float(x) for x in peaks)
    lin = 10.0 ** (db / 20.0)
    return max(0.0, min(1.0, lin))


def s24_32le_misread_peak(native_s16: int) -> int:
    """Peak if spa treats Q6 S24_LE as S24_32LE (8-bit left shift)."""
    return int(native_s16) << S24_FALSE_SHIFT


def s24_false_gain_db() -> float:
    return 20.0 * math.log10(1 << S24_FALSE_SHIFT)
