#!/usr/bin/env python3
"""Generate an 8 MiB FAT32 disk image for TestLabBridgeDxe."""
from __future__ import annotations

import argparse
import struct
import subprocess
import sys
from pathlib import Path


def write_c_header(image: bytes, out_h: Path, var_name: str = "gTestLabFatDiskImage") -> None:
    lines = [
        "/** @file Auto-generated TestLab FAT32 disk image. Do not edit. */",
        "#ifndef TESTLAB_FAT_DISK_IMAGE_H_",
        "#define TESTLAB_FAT_DISK_IMAGE_H_",
        "",
        f"#define TESTLAB_FAT_DISK_SIZE {len(image)}",
        "",
        f"STATIC CONST UINT8 {var_name}[TESTLAB_FAT_DISK_SIZE] = {{",
    ]
    row: list[str] = []
    for i, b in enumerate(image):
        row.append(f"0x{b:02x}")
        if len(row) == 12:
            lines.append("  " + ", ".join(row) + ",")
            row = []
    if row:
        lines.append("  " + ", ".join(row))
    lines.extend(["};", "", "#endif"])
    out_h.write_text("\n".join(lines) + "\n", encoding="ascii")


def win_to_wsl(path: Path) -> str:
    resolved = path.resolve()
    drive = resolved.drive.rstrip(":").lower()
    rest = resolved.as_posix().split(":", 1)[1]
    return f"/mnt/{drive}{rest}"


def build_with_wsl(img_path: Path) -> None:
    wsl_img = win_to_wsl(img_path)
    wsl_script = win_to_wsl(Path(__file__).resolve().parent / "gen-testlab-fat.sh")
    subprocess.run(["wsl", "-d", "Ubuntu-22.04", "bash", "-lc", f"bash '{wsl_script}'"], check=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-mkfs", action="store_true")
    ap.add_argument(
        "--out-bin",
        type=Path,
        default=Path(__file__).resolve().parents[1]
        / "port/dagu/Silicon/Qualcomm/QcomPkg/Drivers/TestLabBridgeDxe/TestLabFatDisk.bin",
    )
    ap.add_argument(
        "--out-h",
        type=Path,
        default=Path(__file__).resolve().parents[1]
        / "port/dagu/Silicon/Qualcomm/QcomPkg/Drivers/TestLabBridgeDxe/TestLabFatDiskImage.h",
    )
    args = ap.parse_args()
    args.out_bin.parent.mkdir(parents=True, exist_ok=True)
    if args.skip_mkfs:
        if not args.out_bin.exists():
            print(f"missing {args.out_bin}", file=sys.stderr)
            return 1
        image = args.out_bin.read_bytes()
        write_c_header(image, args.out_h)
        return 0
    build_with_wsl(args.out_bin)
    image = args.out_bin.read_bytes()
    if len(image) != 8 * 1024 * 1024:
        print(f"unexpected image size: {len(image)} (expected 8 MiB)", file=sys.stderr)
        return 1
    write_c_header(image, args.out_h)
    print(f"[gen-testlab-fat] OK -> {args.out_bin} + {args.out_h}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
