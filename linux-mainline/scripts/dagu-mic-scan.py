#!/usr/bin/env python3
"""Scan WCD938x ADC/INP combinations to find which one the dagu mics sit on.

Plays a 440 Hz tone on the speakers as a known source, then records each
candidate route and reports the 440 Hz energy. Run this on the tablet.
"""
import math
import struct
import subprocess
import sys
import time
import wave

WAV = "/tmp/scan.wav"
RATE = 48000
DUR = 3


def amixer(name, value):
    subprocess.run(["amixer", "-c", "0", "cset", "name=" + name, str(value)],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def reset_routes():
    for n in (1, 2, 3, 4):
        amixer("ADC%d_MIXER Switch" % n, 0)
    amixer("TX SMIC MUX0", "ZERO")
    amixer("TX DEC0 MUX", "ZERO")
    amixer("TX_AIF1_CAP Mixer DEC0", 0)
    amixer("MultiMedia1 Mixer TX_CODEC_DMA_TX_3", 0)
    amixer("VA DMIC MUX0", "ZERO")
    amixer("VA_AIF1_CAP Mixer DEC0", 0)
    amixer("MultiMedia1 Mixer VA_CODEC_DMA_TX_0", 0)


def goertzel(buf, freq):
    n = len(buf)
    k = int(0.5 + n * freq / RATE)
    w = 2 * math.pi * k / n
    cw, sw = math.cos(w), math.sin(w)
    coeff = 2 * cw
    s1 = s2 = 0.0
    for x in buf:
        s0 = x + coeff * s1 - s2
        s2, s1 = s1, s0
    re, im = s1 - s2 * cw, s2 * sw
    return math.sqrt(re * re + im * im) / (n / 2)


def analyze():
    try:
        w = wave.open(WAV, "rb")
    except Exception as e:
        return "  open failed: %s" % e
    data = w.readframes(w.getnframes())
    s = struct.unpack("<%dh" % (len(data) // 2), data)
    # Skip the first 2s: the first DMA buffer can hold stale data.
    buf = s[2 * RATE:3 * RATE] if len(s) >= 3 * RATE else s[len(s) // 2:]
    if not buf:
        return "  recording too short (%d frames)" % len(s)
    rms = math.sqrt(sum(x * x for x in buf) / len(buf))
    peak = max(abs(x) for x in buf)
    e440, e997 = goertzel(buf, 440), goertzel(buf, 997)
    if e440 > 20 and e440 > 3 * e997:
        verdict = "*** 440Hz TONE DETECTED ***"
    elif rms > 5:
        verdict = "audio (no clear tone)"
    else:
        verdict = "silent"
    return "  rms=%8.1f peak=%6d E440=%8.1f E997=%7.1f  %s" % (
        rms, peak, e440, e997, verdict)


def try_route(adc, inp, smic):
    reset_routes()
    amixer("MultiMedia1 Mixer TX_CODEC_DMA_TX_3", 1)
    amixer("TX DEC0 MUX", "SWR_MIC")
    amixer("TX SMIC MUX0", smic)
    amixer("TX_AIF1_CAP Mixer DEC0", 1)
    amixer("ADC%d_MIXER Switch" % adc, 1)
    if inp:
        amixer("ADC%d MUX" % adc, inp)
    amixer("ADC%d Volume" % adc, 20)
    time.sleep(0.3)
    subprocess.run(["rm", "-f", WAV])
    print("ADC%d/%-5s smic=%s" % (adc, inp or "INP1", smic), flush=True)
    r = subprocess.run(["arecord", "-D", "hw:0,0", "-c", "1", "-r", str(RATE),
                        "-f", "S16_LE", "-d", str(DUR), WAV],
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                       text=True)
    if r.returncode != 0:
        print("  arecord rc=%d: %s" % (r.returncode, r.stderr.strip()),
              flush=True)
    print(analyze(), flush=True)
    time.sleep(1)


def try_va_dmic(dmic):
    """VA macro path: DMIC pin -> VA DMIC MUX0 -> VA DEC0 -> VA_CODEC_DMA_TX_0."""
    reset_routes()
    amixer("MultiMedia1 Mixer VA_CODEC_DMA_TX_0", 1)
    amixer("VA DEC0 MUX", "VA_DMIC")
    amixer("VA DMIC MUX0", "DMIC%d" % dmic)
    amixer("VA_AIF1_CAP Mixer DEC0", 1)
    time.sleep(0.3)
    subprocess.run(["rm", "-f", WAV])
    print("VA DMIC%d" % dmic, flush=True)
    r = subprocess.run(["arecord", "-D", "hw:0,0", "-c", "1", "-r", str(RATE),
                        "-f", "S16_LE", "-d", str(DUR), WAV],
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                       text=True)
    if r.returncode != 0:
        print("  arecord rc=%d: %s" % (r.returncode,
                                       r.stderr.strip().splitlines()[0]),
              flush=True)
    print(analyze(), flush=True)
    time.sleep(1)


CANDIDATES = [
    (1, "",     "ADC0"),
    (2, "INP2", "ADC1"),
    (2, "INP3", "ADC1"),
    (3, "INP4", "ADC2"),
    (3, "INP6", "ADC2"),
    (4, "INP5", "ADC3"),
    (4, "INP7", "ADC3"),
]


def main():
    # Prepare the speaker path so the tone is a real acoustic source.
    amixer("TERT_TDM_RX_0 Audio Mixer MultiMedia1", 1)
    for p in ("TL", "TR", "BL", "BR"):
        amixer("%s PCM Source" % p, "ASP")
        amixer("%s Analog PCM Volume" % p, 20)
        amixer("%s Digital PCM Volume" % p, 850)

    spk = None
    if "--no-tone" not in sys.argv:
        spk = subprocess.Popen(
            ["speaker-test", "-D", "hw:0,0", "-c", "2", "-r", str(RATE),
             "-F", "S24_LE", "-t", "sine", "-f", "440", "-l", "40"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1)

    try:
        if "--va" in sys.argv:
            for d in range(8):
                try_va_dmic(d)
        else:
            for adc, inp, smic in CANDIDATES:
                try_route(adc, inp, smic)
    finally:
        if spk:
            spk.kill()
    print("SCAN_DONE")


if __name__ == "__main__":
    main()
