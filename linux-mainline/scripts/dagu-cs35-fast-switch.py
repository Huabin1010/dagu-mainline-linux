#!/usr/bin/env python3
"""Apply Xiaomi CS35L41 Fast Use Case (music.txt) the Android way.

CAF cs35l41_do_fast_switch(): parse comma-separated s32, write
CSPL_UPDATE_PARAMS_CONFIG, then CSPL_COMMAND=UPDATE_PARAM (8), wait
CSPL_ST_RUNNING (0). Same Halo BYTE mixers mainline already exposes.

Needs DSP running (PCM open). Does not touch Digital PCM.
"""
from __future__ import annotations

import argparse
import struct
import subprocess
import sys
import time
from pathlib import Path

CSPL_CMD_UPDATE_PARAM = 8
CSPL_ST_RUNNING = 0
AMPS = ("TL", "TR", "BL", "BR")
FWDIR = Path("/lib/firmware/cirrus")
PCM_STATUS = Path("/proc/asound/card0/pcm0p/sub0/status")


def pcm_running() -> bool:
    try:
        text = PCM_STATUS.read_text()
    except OSError:
        return False
    return "state: RUNNING" in text or "state: DRAINING" in text


def parse_android_txt(path: Path) -> bytes:
    raw = path.read_bytes()
    parts: list[int] = []
    cur: list[bytes] = []
    for i, b in enumerate(raw):
        if b in b" \t\r\n":
            continue
        if b == ord(","):
            if not cur:
                raise ValueError(f"{path}: empty field")
            parts.append(int(b"".join(cur)))
            cur = []
            continue
        cur.append(bytes([b]))
        if i == len(raw) - 1:
            break
    if cur:
        parts.append(int(b"".join(cur)))
    if not parts:
        raise ValueError(f"{path}: empty")
    data_ctl_len = parts[0]
    if data_ctl_len < 1 or data_ctl_len != len(parts):
        raise ValueError(
            f"{path}: first field {data_ctl_len} != {len(parts)} numbers"
        )
    # Android: buf[0] = length, buf[1:] = remaining fields (already in parts).
    return b"".join(struct.pack(">i", v) for v in parts)


def ctl_bytes_name(prefix: str, suffix: str) -> str:
    return f"{prefix} DSP1 Protection cd {suffix}"


def amixer_cget(card: str, name: str) -> bytes:
    out = subprocess.check_output(
        ["amixer", "-c", card, "cget", f"name={name}"],
        text=True,
        stderr=subprocess.STDOUT,
    )
    for line in out.splitlines():
        if ": values=" not in line:
            continue
        hexes = line.split("=", 1)[1].strip()
        return bytes(int(x, 0) for x in hexes.split(",") if x)
    raise RuntimeError(f"no values in cget {name}: {out}")


def amixer_cset_bytes(card: str, name: str, payload: bytes, width: int) -> None:
    if len(payload) > width:
        raise ValueError(f"{name}: payload {len(payload)} > {width}")
    buf = payload + bytes(width - len(payload))
    hexes = ",".join(f"0x{b:02x}" for b in buf)
    subprocess.check_call(
        ["amixer", "-c", card, "cset", f"name={name}", hexes],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )


def apply_amp(card: str, prefix: str, txt: Path) -> None:
    payload = parse_android_txt(txt)
    cfg_name = ctl_bytes_name(prefix, "_UPDATE_PARAMS_CONFIG")
    cmd_name = ctl_bytes_name(prefix, "CSPL_COMMAND")
    st_name = ctl_bytes_name(prefix, "CSPL_STATE")
    cfg_info = subprocess.check_output(
        ["amixer", "-c", card, "cget", f"name={cfg_name}"], text=True
    )
    width = 400
    for line in cfg_info.splitlines():
        if "type=BYTES" in line and "values=" in line:
            width = int(line.split("values=")[1].split(",")[0])
            break
    amixer_cset_bytes(card, cfg_name, payload, width)
    amixer_cset_bytes(
        card, cmd_name, struct.pack(">I", CSPL_CMD_UPDATE_PARAM), 4
    )
    running = False
    st = b""
    for _ in range(8):
        st = amixer_cget(card, st_name)
        if len(st) >= 4 and struct.unpack(">I", st[:4])[0] == CSPL_ST_RUNNING:
            running = True
            break
        time.sleep(0.001)
    if not running:
        raise RuntimeError(
            f"{prefix}: CSPL_STATE={st[:4].hex() if st else 'empty'} after UPDATE_PARAM"
        )
    print(f"{prefix}: wrote {txt.name} ({len(payload)} bytes) CSPL_STATE=RUNNING")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-c", "--card", default="0")
    ap.add_argument("--force", action="store_true", help="write even if PCM is idle")
    args = ap.parse_args()
    if not args.force and not pcm_running():
        print("dagu-cs35-fast-switch: PCM not RUNNING, skip (DSP cache would reorder COMMAND)")
        return 0
    n = 0
    for prefix in AMPS:
        txt = FWDIR / f"{prefix}-music.txt"
        if not txt.is_file():
            print(f"{prefix}: missing {txt}", file=sys.stderr)
            return 1
        apply_amp(args.card, prefix, txt)
        n += 1
    print(f"fast-switch ok ({n} amps), Digital PCM untouched")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as e:
        err = e.stderr.decode() if isinstance(e.stderr, bytes) else (e.stderr or "")
        print(f"amixer failed: {err or e}", file=sys.stderr)
        raise SystemExit(1)
