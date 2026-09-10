#!/usr/bin/env python3
"""vbmeta verify-off + DTBO that ABL can actually apply.

Empty dt_entry_count=0 makes this ABL bounce to fastboot in ~6s (even
stock kernel + stock vendor_boot). Stock overlay #15 is the dagu CAF
tree and must not be stacked on a mainline DTB.

Build 29 no-op overlays with the stock board-ids so ABL still selects
idx=15. Only stamp qcom,board-id — do not replace root compatible (UBWC
and other of_machine_get_match_data() lookups need qcom,sm8250).
"""
from __future__ import annotations

import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "out"
DUMP = ROOT.parent / "dumps/dagu-20260826-210700-root/images"

DT_TABLE_MAGIC = 0xD7B7AB1E


def write_empty_dtbo(path: Path) -> None:
	# Kept for experiments. Do not flash on dagu: ABL rejects count=0.
	hdr = struct.pack(
		">8I",
		DT_TABLE_MAGIC,
		32,
		32,
		32,
		0,
		32,
		4096,
		0,
	)
	path.write_bytes(hdr + bytes(4096 - len(hdr)))
	print(f"wrote {path} ({path.stat().st_size} bytes, 0 overlays, USB-padded)")


def _fdtget_u32s(blob: Path, prop: str) -> list[int]:
	r = subprocess.run(
		["fdtget", "-tx", str(blob), "/", prop],
		capture_output=True,
		text=True,
	)
	if r.returncode != 0:
		return []
	return [int(x, 16) for x in r.stdout.split()]


def _compile_stub(board: list[int], dst: Path) -> None:
	b0 = board[0] if len(board) > 0 else 0
	b1 = board[1] if len(board) > 1 else 0
	# Do not overwrite root compatible/model. ABL only needs board-id to
	# pick idx=15; replacing compatible with kona-mtp made
	# qcom_ubwc_config_get_data() miss "qcom,sm8250" and msm-mdss probe
	# failed with -EINVAL ("Couldn't find UBWC config data").
	dts = f"""/dts-v1/;
/plugin/;

/ {{
	qcom,board-id = <{b0:#x} {b1:#x}>;
}};

&soc {{
	dagu,dtbo-stub;
}};
"""
	src = dst.with_suffix(".dts")
	src.write_text(dts)
	subprocess.check_call(["dtc", "-@", "-I", "dts", "-O", "dtb", "-o", str(dst), str(src)])


def write_stub_dtbo(stock: Path, dst: Path) -> None:
	if not stock.is_file():
		raise SystemExit(f"missing {stock}")
	b = stock.read_bytes()
	magic, total, hdr_sz, entry_sz, count, entries_off, page, ver = struct.unpack_from(
		">8I", b
	)
	if magic != DT_TABLE_MAGIC or count < 1:
		raise SystemExit(f"bad stock dtbo {stock}: magic={magic:#x} count={count}")

	stubs: list[bytes] = []
	with tempfile.TemporaryDirectory() as td:
		tdp = Path(td)
		for i in range(count):
			o = entries_off + i * entry_sz
			size, offset, _id, _rev = struct.unpack_from(">4I", b, o)
			blob = tdp / f"stock-{i}.dtbo"
			blob.write_bytes(b[offset : offset + size])
			board = _fdtget_u32s(blob, "qcom,board-id")
			out = tdp / f"stub-{i}.dtb"
			_compile_stub(board, out)
			stubs.append(out.read_bytes())

	entries_off_out = 32
	blob_off = entries_off_out + 32 * len(stubs)
	entries = bytearray()
	payload = bytearray()
	for blob in stubs:
		pad = (4 - (blob_off % 4)) % 4
		blob_off += pad
		payload.extend(bytes(pad))
		entries.extend(
			struct.pack(">8I", len(blob), blob_off, 0, 0, 0, 0, 0, 0)
		)
		payload.extend(blob)
		blob_off += len(blob)

	total_size = 32 + len(entries) + len(payload)
	hdr = struct.pack(
		">8I",
		DT_TABLE_MAGIC,
		total_size,
		32,
		32,
		len(stubs),
		entries_off_out,
		4096,
		0,
	)
	img = hdr + bytes(entries) + bytes(payload)
	if len(img) < 4096:
		img += bytes(4096 - len(img))
	dst.write_bytes(img)
	print(f"wrote {dst} ({dst.stat().st_size} bytes, {len(stubs)} stub overlays)")


def write_vbmeta_disabled(src: Path, dst: Path) -> None:
	b = bytearray(src.read_bytes())
	if b[:4] != b"AVB0":
		raise SystemExit(f"not vbmeta: {src}")
	# AvbVBMetaImageHeader.flags @ 120, BE; 1=hashtree off, 2=verify off
	struct.pack_into(">I", b, 120, 3)
	dst.write_bytes(b)
	print(f"wrote {dst} flags=3 from {src.name}")


def main() -> int:
	OUT.mkdir(parents=True, exist_ok=True)
	write_empty_dtbo(OUT / "dtbo-empty.img")
	write_stub_dtbo(DUMP / "dtbo_a.img", OUT / "dtbo-stub.img")
	src = DUMP / "vbmeta_a.img"
	if not src.is_file():
		raise SystemExit(f"missing {src}")
	write_vbmeta_disabled(src, OUT / "vbmeta-disabled.img")
	return 0


if __name__ == "__main__":
	sys.exit(main())
