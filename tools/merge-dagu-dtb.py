#!/usr/bin/env python3
"""Build merged dagu.dtb from stock vendor_boot.img + dtbo.img."""
from __future__ import annotations

import struct
import subprocess
import sys
from pathlib import Path

DT_TABLE_MAGIC = 0xD7B7AB1E
FDT_MAGIC = b"\xd0\x0d\xfe\xed"
DAGU_BOARD_ID = 0x33  # qcom,board-id = <51 0>


def split_dtbs(blob: bytes) -> list[bytes]:
    out: list[bytes] = []
    idx = 0
    while True:
        pos = blob.find(FDT_MAGIC, idx)
        if pos < 0:
            break
        if pos + 8 > len(blob):
            break
        size = struct.unpack(">I", blob[pos + 4 : pos + 8])[0]
        if size < 0x28 or pos + size > len(blob):
            idx = pos + 4
            continue
        out.append(blob[pos : pos + size])
        idx = pos + size
    return out


def unpack_vendor_boot(path: Path) -> bytes:
    data = path.read_bytes()
    if len(data) < 0x30 or data[:8] != b"VNDRBOOT":
        raise SystemExit(f"not a vendor_boot image: {path}")
    page_size = struct.unpack_from("<I", data, 12)[0]
    vendor_ramdisk_size = struct.unpack_from("<I", data, 24)[0]
    header_size = struct.unpack_from("<I", data, 2096)[0]
    dtb_size = struct.unpack_from("<I", data, 2100)[0]
    if page_size <= 0 or dtb_size <= 0:
        raise SystemExit("invalid vendor_boot header")

    def pages(n: int) -> int:
        return (n + page_size - 1) // page_size

    dtb_off = page_size * (pages(header_size) + pages(vendor_ramdisk_size))
    if dtb_off + dtb_size > len(data):
        raise SystemExit("vendor_boot dtb out of range")
    return data[dtb_off : dtb_off + dtb_size]


def parse_dtbo_entries(path: Path) -> list[tuple[int, bytes]]:
    data = path.read_bytes()
    if len(data) < 32:
        raise SystemExit(f"dtbo too small: {path}")
    magic, total_size, header_size, entry_size, entry_count, entries_off, page_size, version = (
        struct.unpack_from(">8I", data, 0)
    )
    if magic != DT_TABLE_MAGIC:
        raise SystemExit(f"bad dtbo magic: {hex(magic)}")
    entries: list[tuple[int, bytes]] = []
    for i in range(entry_count):
        off = entries_off + i * entry_size
        if off + 32 > len(data):
            break
        dt_size, dt_offset, dt_id, dt_rev, c0, c1, c2, c3 = struct.unpack_from(">8I", data, off)
        blob = data[dt_offset : dt_offset + dt_size]
        if blob[:4] != FDT_MAGIC:
            continue
        entries.append((dt_id, blob))
    return entries


def fdtdump_text(blob: bytes) -> str:
    tmp = Path("/tmp/dtb-inspect.dtb")
    tmp.write_bytes(blob)
    try:
        return subprocess.check_output(["fdtdump", str(tmp)], stderr=subprocess.STDOUT, text=True)
    except Exception:
        return ""


def pick_base_dtbs(vendor_dtb_blob: bytes) -> list[bytes]:
    dtbs = split_dtbs(vendor_dtb_blob)
    if not dtbs:
        raise SystemExit("no base dtbs in vendor_boot")
    preferred = []
    for blob in dtbs:
        txt = fdtdump_text(blob)
        if "kona v2.1" in txt or "kona v2" in txt or "kona v1" in txt:
            preferred.append(blob)
    return preferred or dtbs


def pick_dtbo(entries: list[tuple[int, bytes]]) -> bytes:
    for dt_id, blob in entries:
        if dt_id == DAGU_BOARD_ID:
            return blob
    for dt_id, blob in entries:
        txt = fdtdump_text(blob)
        if "xiaomi dagu" in txt.lower() or "l81a" in txt.lower():
            return blob
    if not entries:
        raise SystemExit("no dtbo entries")
    # Fall back to first overlay.
    return entries[0][1]


def fdtoverlay(base: Path, overlay: Path, out: Path) -> None:
    subprocess.check_call(["fdtoverlay", "-i", str(base), "-o", str(out), str(overlay)])


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(f"Usage: {argv[0]} <vendor_boot.img> <dtbo.img> <out.dtb>", file=sys.stderr)
        return 2
    vendor_boot = Path(argv[1])
    dtbo = Path(argv[2])
    out = Path(argv[3])
    work = out.parent / ".merge-work"
    work.mkdir(parents=True, exist_ok=True)

    vendor_blob = unpack_vendor_boot(vendor_boot)
    base_candidates = pick_base_dtbs(vendor_blob)
    overlay = pick_dtbo(parse_dtbo_entries(dtbo))

    merged = None
    last_err = ""
    for idx, base_blob in enumerate(base_candidates):
        base_path = work / f"base-{idx}.dtb"
        overlay_path = work / "overlay.dtbo"
        merged_path = work / "merged.dtb"
        base_path.write_bytes(base_blob)
        overlay_path.write_bytes(overlay)
        try:
            fdtoverlay(base_path, overlay_path, merged_path)
            txt = fdtdump_text(merged_path.read_bytes())
            if "xiaomi dagu" in txt.lower() or "l81a" in txt.lower():
                merged = merged_path
                break
            if merged is None:
                merged = merged_path
        except subprocess.CalledProcessError as exc:
            last_err = str(exc)
            continue

    if merged is None:
        raise SystemExit(f"fdtoverlay failed: {last_err}")

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(merged.read_bytes())
    txt = fdtdump_text(out.read_bytes())
    model = next((line.strip() for line in txt.splitlines() if "model =" in line), "?")
    panel = next((line.strip() for line in txt.splitlines() if "mdss-dsi-panel-name" in line), "?")
    print(f"[merge-dagu-dtb] {model}")
    print(f"[merge-dagu-dtb] {panel}")
    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
