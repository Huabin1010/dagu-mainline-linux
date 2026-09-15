#!/usr/bin/env python3
"""Generate 1 MiB TestLab FAT32 disk image without root (pyfatfs + fs)."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path


def build_image(out_bin: Path) -> None:
    try:
        from fs import open_fs
        from pyfatfs.PyFat import PyFat
    except ImportError as exc:
        raise RuntimeError("pip install pyfatfs fs setuptools") from exc

    out_bin.parent.mkdir(parents=True, exist_ok=True)
    pf = PyFat()
    pf.mkfs(str(out_bin), fat_type=PyFat.FAT_TYPE_FAT32, size=8 * 1024 * 1024, label="TESTLAB")
    pf.open(str(out_bin))
    fs = open_fs(f"fat://{out_bin}?writeable=1")
    fs.makedirs("TESTLAB")
    files = {
        "TESTLAB/BOOT.LOG": "",
        "TESTLAB/BOOT.SEQ": "0\n",
        "TESTLAB/COMMAND.IN": "",
        "TESTLAB/COMMAND.ACK": "OK\n",
        "TESTLAB/STATUS.JSON": '{"seq":0,"usb":"pending","bridge":"v2"}\n',
    }
    for name, content in files.items():
        with fs.open(name, "w") as fh:
            fh.write(content)
    fs.close()
    pf.close()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--out-bin",
        type=Path,
        default=Path(__file__).resolve().parents[1]
        / "port/dagu/Silicon/Qualcomm/QcomPkg/Drivers/TestLabBridgeDxe/TestLabFatDisk.bin",
    )
    args = ap.parse_args()
    try:
        build_image(args.out_bin)
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except Exception as exc:
        print(f"gen-testlab-fat failed: {exc}", file=sys.stderr)
        return 1
    size = args.out_bin.stat().st_size
    if size != 8 * 1024 * 1024:
        print(f"unexpected size {size} (expected 8 MiB)", file=sys.stderr)
        return 1
    print(f"[gen-testlab-fat] OK -> {args.out_bin} ({size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
