#!/usr/bin/env python3
"""Folio hold-repeat verdict from evdev and nanosic kmsg.

Kernel #501 keeps KEY down across 0x22 keepalives. mutter 50.1 must not
clear compositor repeat on another key's release. A single HID usage
held >=0.5s with no empty report is single_ok. Symptom 3 (handoff) is
press A, press B, release A, B still in the report.
"""
from __future__ import annotations

import array
import fcntl
import json
import os
import re
import select
import struct
import subprocess
import time
from pathlib import Path

FMT = "llHHI"
EV_KEY = 1
OUT = Path("/tmp/folio-repeat-verify.json")
HOLD_S = 0.5
KBD_RE = re.compile(
    r"(?:\[\s*([0-9.]+)\]\s+)?nanosic-803-dagu.*kbd seq=([0-9a-fA-F]+) "
    r"empty=(\d) keys=([0-9a-fA-F-]+)"
)
DROP_RE = re.compile(r"nanosic-803-dagu.*kbd drop leftover empty")
MUTTER_START_RE = re.compile(
    r"dagu folio: start compositor repeat key=(0x[0-9a-fA-F]+) count=(\d+)"
)
MUTTER_CLEAR_RE = re.compile(
    r"dagu folio: KEY_UP clears repeat key=(0x[0-9a-fA-F]+)"
)
MUTTER_DROP_RE = re.compile(
    r"dagu folio: drop key-(\w+) 0x([0-9a-fA-F]+) seat_key_count=(\d+)"
)


def kmsg_count(pat: re.Pattern) -> int:
    try:
        raw = subprocess.check_output(["dmesg"], text=True, errors="replace")
    except (OSError, subprocess.CalledProcessError):
        return 0
    return sum(1 for line in raw.splitlines() if pat.search(line))


def mutter_journal() -> dict:
    starts = clears = drops = 0
    try:
        raw = subprocess.check_output(
            ["journalctl", "-b", "--no-pager", "-t", "gnome-shell"],
            text=True,
            errors="replace",
        )
    except (OSError, subprocess.CalledProcessError):
        raw = ""
    if "dagu folio:" not in raw:
        try:
            raw = subprocess.check_output(
                ["journalctl", "-b", "--no-pager"],
                text=True,
                errors="replace",
            )
        except (OSError, subprocess.CalledProcessError):
            raw = ""
    wakeup_steals = 0
    count2 = 0
    cancelled = 0
    for line in raw.splitlines():
        m = MUTTER_START_RE.search(line)
        if m:
            starts += 1
            if int(m.group(2)) >= 2:
                count2 += 1
        if MUTTER_CLEAR_RE.search(line):
            clears += 1
        if MUTTER_DROP_RE.search(line):
            drops += 1
        if "key=0x8f" in line and "start compositor repeat" in line:
            wakeup_steals += 1
        if "cancelled by libinput queue" in line:
            cancelled += 1
    return {
        "starts": starts,
        "clears": clears,
        "drops": drops,
        "wakeup_steals": wakeup_steals,
        "repeat_count2": count2,
        "libinput_cancel": cancelled,
    }


def find_kb() -> str:
    for p in Path("/sys/class/input").glob("event*/device/name"):
        if p.read_text().strip() == "Xiaomi Keyboard":
            return "/dev/input/" + p.parts[-3]
    raise SystemExit("no Xiaomi Keyboard")


def irq_count() -> int:
    try:
        for line in Path("/proc/interrupts").read_text().splitlines():
            if "nanosic-803" in line:
                return int(line.split()[1])
    except OSError:
        pass
    return -1


def sw_bits() -> str:
    for p in Path("/sys/class/input").glob("event*/device/name"):
        if p.read_text().strip() != "gpio-keys":
            continue
        ev = "/dev/input/" + p.parts[-3]
        try:
            fd = os.open(ev, os.O_RDONLY)
            b = array.array("Q", [0])
            fcntl.ioctl(fd, 0x8008451B, b, True)
            os.close(fd)
            return hex(b[0])
        except OSError:
            return "err"
    return "none"


def keys_of(hex_slots: str) -> set[int]:
    out: set[int] = set()
    for part in hex_slots.split("-"):
        if not part:
            continue
        v = int(part, 16)
        if v:
            out.add(v)
    return out


class KmsgHold:
    def __init__(self) -> None:
        self.prev: set[int] = set()
        self.down_at: dict[int, float] = {}
        self.single_ok = False
        self.handoff_ok = False
        self.handoff_arm: dict[int, float] = {}
        self.reports: list[dict] = []

    def feed(self, t: float, slots: str) -> None:
        cur = keys_of(slots)
        released = self.prev - cur
        pressed = cur - self.prev
        for k in released:
            held = t - self.down_at.get(k, t)
            if held >= HOLD_S:
                self.single_ok = True
            # Symptom 3: newer key stays in the HID report ≥500ms after this UP.
            for r in cur:
                if self.down_at.get(r, t) > self.down_at.get(k, t):
                    self.handoff_arm[r] = t
        for k in pressed:
            self.down_at[k] = t
        for k in list(self.down_at):
            if k not in cur:
                del self.down_at[k]
        for r, t0 in list(self.handoff_arm.items()):
            if r not in cur:
                del self.handoff_arm[r]
            elif t - t0 >= HOLD_S:
                self.handoff_ok = True
        self.prev = cur
        self.reports.append({"t": t, "keys": sorted(cur)})

    def ingest_dmesg(self) -> None:
        import subprocess

        try:
            raw = subprocess.check_output(["dmesg"], text=True, errors="replace")
        except (OSError, subprocess.CalledProcessError):
            return
        for line in raw.splitlines():
            m = KBD_RE.search(line)
            if not m:
                continue
            self.feed(float(m.group(1)) if m.group(1) else 0.0, m.group(4))


def main() -> None:
    path = find_kb()
    ev_fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    kmsg_fd = os.open("/dev/kmsg", os.O_RDONLY | os.O_NONBLOCK)
    n = struct.calcsize(FMT)
    down: dict[int, float] = {}
    handoff_arm: dict[int, float] = {}
    events: list[dict] = []
    ev_single = False
    ev_handoff = False
    kmsg = KmsgHold()
    kmsg.ingest_dmesg()
    mutter_cache = {"starts": 0, "clears": 0, "drops": 0}
    leftover_drops = 0
    mutter_at = 0.0

    def dump() -> None:
        nonlocal mutter_cache, mutter_at, leftover_drops
        single_ok = ev_single or kmsg.single_ok
        handoff_ok = ev_handoff or kmsg.handoff_ok
        now_m = time.monotonic()
        if now_m - mutter_at >= 2.0:
            mutter_cache = mutter_journal()
            leftover_drops = kmsg_count(DROP_RE)
            mutter_at = now_m
        mutter = mutter_cache
        verdict = {
            "kb": path,
            "single_hold_ge_500ms": single_ok,
            "handoff_remaining_key_stays_down": handoff_ok,
            "evdev_single": ev_single,
            "evdev_handoff": ev_handoff,
            "kmsg_single": kmsg.single_ok,
            "kmsg_handoff": kmsg.handoff_ok,
            "mutter_repeat_start": mutter["starts"],
            "mutter_repeat_clear": mutter["clears"],
            "mutter_seat_key_count_drop": mutter["drops"],
            "mutter_repeat_count2": mutter.get("repeat_count2", 0),
            "mutter_wakeup_steals": mutter.get("wakeup_steals", 0),
            "mutter_libinput_cancel": mutter.get("libinput_cancel", 0),
            "leftover_empty_drops": leftover_drops,
            "n_events": len(events),
            "held": sorted(down),
            "nanosic_irq": irq_count(),
            "gpio_keys_sw": sw_bits(),
            "kmsg_reports": kmsg.reports[-40:],
            "events": events[-80:],
            "pass": bool(
                single_ok
                and handoff_ok
                and mutter.get("repeat_count2", 0) >= 1
            ),
        }
        tmp = OUT.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(verdict, indent=2) + "\n")
        tmp.replace(OUT)

    dump()
    while True:
        r, _, _ = select.select([ev_fd, kmsg_fd], [], [], 0.25)
        now = time.monotonic()
        for t0 in down.values():
            if now - t0 >= HOLD_S:
                ev_single = True
        for c, t_up in list(handoff_arm.items()):
            if c not in down:
                del handoff_arm[c]
            elif now - t_up >= HOLD_S:
                ev_handoff = True
        if kmsg_fd in r:
            try:
                chunk = os.read(kmsg_fd, 8192)
            except BlockingIOError:
                chunk = b""
            for line in chunk.decode("utf-8", "replace").splitlines():
                m = KBD_RE.search(line)
                if m:
                    tstamp = float(m.group(1)) if m.group(1) else time.monotonic()
                    kmsg.feed(tstamp, m.group(4))
        if ev_fd in r:
            data = os.read(ev_fd, n * 64)
            off = 0
            while off + n <= len(data):
                sec, usec, typ, code, val = struct.unpack_from(FMT, data, off)
                off += n
                if typ != EV_KEY:
                    continue
                t = sec + usec / 1e6
                events.append({"t": t, "code": code, "val": val})
                if val == 1:
                    down[code] = now
                elif val == 0 and code in down:
                    started = down.pop(code)
                    held = now - started
                    if held >= HOLD_S:
                        ev_single = True
                    for c, t0 in down.items():
                        if t0 > started:
                            handoff_arm[c] = now
        dump()


if __name__ == "__main__":
    main()
