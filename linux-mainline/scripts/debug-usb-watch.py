#!/usr/bin/env python3
"""Log USB device snapshots for dagu bring-up (debug session 5c27b9)."""
from __future__ import annotations

import json
import os
import time
from pathlib import Path

LOG = Path(os.environ.get("DAGU_USB_WATCH_LOG", "/tmp/dagu-usb-watch.log"))
SYS = Path("/sys/bus/usb/devices")
SESSION = "5c27b9"


def read(p: Path) -> str:
    try:
        return p.read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return ""


def snapshot() -> list[dict]:
    out = []
    if not SYS.is_dir():
        return out
    for d in sorted(SYS.iterdir()):
        if ":" in d.name:
            continue
        vid, pid = read(d / "idVendor"), read(d / "idProduct")
        if not vid:
            continue
        out.append(
            {
                "path": d.name,
                "vid": vid,
                "pid": pid,
                "serial": read(d / "serial"),
                "product": read(d / "product"),
                "manufacturer": read(d / "manufacturer"),
            }
        )
    return out


def emit(hypothesis_id: str, message: str, data: dict) -> None:
    rec = {
        "sessionId": SESSION,
        "hypothesisId": hypothesis_id,
        "location": "debug-usb-watch.py",
        "message": message,
        "data": data,
        "timestamp": int(time.time() * 1000),
        "runId": "pre-fix",
    }
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def classify(dev: dict) -> str:
    vp = f"{dev['vid']}:{dev['pid']}".lower()
    if vp == "18d1:d00d":
        return "D"
    if vp in ("1d6b:0104", "0525:a4a7"):
        return "A"
    return "D"


def main() -> None:
    emit("D", "usb-watch-start", {"pid": os.getpid()})
    prev: list | None = None
    t0 = time.time()
    while True:
        cur = snapshot()
        key = [(x["vid"], x["pid"], x["serial"], x["product"]) for x in cur]
        if key != prev:
            interesting = [
                x
                for x in cur
                if x["vid"] in ("18d1", "1d6b", "2717", "05c6", "0525")
                or "dagu" in (x["serial"] + x["product"] + x["manufacturer"]).lower()
                or x["serial"].startswith("dt")
            ]
            hyp = "D"
            for x in interesting:
                hyp = classify(x)
                if x["serial"].startswith("dt"):
                    hyp = "A"
                    break
            payload = {
                "elapsed_s": round(time.time() - t0, 3),
                "interesting": interesting,
                "count": len(cur),
            }
            emit(hyp, "usb-snapshot", payload)
            tablet = [
                x
                for x in interesting
                if x["vid"] in ("18d1", "1d6b", "2717", "05c6", "0525")
                or x["serial"].startswith("dt")
            ]
            if tablet:
                line = (
                    f"[{payload['elapsed_s']:7.1f}s] "
                    + " | ".join(
                        f"{x['vid']}:{x['pid']} serial={x['serial']!r}"
                        for x in tablet
                    )
                )
                print(line, flush=True)
                if any(
                    (x["vid"] == "0525" and x["pid"] == "a4a7")
                    or (x["vid"] == "1d6b" and x["pid"] == "0104")
                    for x in tablet
                ):
                    print("      -> USB serial up; try: ./scripts/usb-tty.sh", flush=True)
            elif any(x["vid"] == "18d1" for x in cur) is False and prev and any(
                p[0] == "18d1" for p in prev
            ):
                print(f"[{payload['elapsed_s']:7.1f}s] 18d1:d00d gone (kernel jump?)", flush=True)
            prev = key
        time.sleep(0.25)


if __name__ == "__main__":
    main()
