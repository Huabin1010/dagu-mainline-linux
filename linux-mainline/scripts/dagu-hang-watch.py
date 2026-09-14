#!/usr/bin/env python3
"""Log mem / Venus / DPU and abort Chrome if the board is about to hard-hang.

On tablet: python3 /usr/local/sbin/dagu-hang-watch.py
Abort threshold: MemAvailable < 350 MiB (Venus REQBUFS OOM was ~80–130 MiB).
Does not enable software decode. Does not touch gnome-shell.
"""
from __future__ import annotations

import os
import signal
import time
from pathlib import Path

LOG = Path("/var/log/dagu-dpu/hang-watch.log")
ABORT_MB = 350
WARN_MB = 700


def mem_avail_mb() -> int:
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemAvailable:"):
                return int(line.split()[1]) // 1024
    except (OSError, ValueError, IndexError):
        pass
    return -1


def venus_irq() -> int:
    try:
        for line in Path("/proc/interrupts").read_text().splitlines():
            if "venus" not in line.lower():
                continue
            return sum(int(t) for t in line.split()[1:] if t.isdigit())
    except OSError:
        pass
    return -1


def chrome_pids() -> list[int]:
    pids = []
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            cmd = (proc / "cmdline").read_bytes()
        except OSError:
            continue
        if b"/usr/lib/chromium/chromium" in cmd:
            pids.append(int(proc.name))
    return pids


def main() -> int:
    LOG.parent.mkdir(parents=True, exist_ok=True)
    aborted = False
    while True:
        avail = mem_avail_mb()
        irq = venus_irq()
        line = f"{time.strftime('%H:%M:%S')} mem={avail}M venus={irq} chrome={len(chrome_pids())}\n"
        try:
            with LOG.open("a") as f:
                f.write(line)
        except OSError:
            pass
        if avail >= 0 and avail < ABORT_MB and not aborted:
            for pid in chrome_pids():
                try:
                    os.kill(pid, signal.SIGTERM)
                except OSError:
                    pass
            aborted = True
            try:
                with LOG.open("a") as f:
                    f.write(f"{time.strftime('%H:%M:%S')} ABORT mem={avail}M SIGTERM chromium\n")
            except OSError:
                pass
        if avail > WARN_MB:
            aborted = False
        time.sleep(1.0)


if __name__ == "__main__":
    raise SystemExit(main())
