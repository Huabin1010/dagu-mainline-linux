#!/usr/bin/env python3
"""Tell ABL that this A/B slot booted, as Android's boot_control HAL does.

ABL keeps the A/B state in the GPT attribute bits of the boot_a / boot_b
entries (Qualcomm PartitionTableUpdate.h):

  bits 48-49  priority        bit 50  active
  bits 51-53  retry count     bit 54  boot successful
  bit  55     unbootable

`fastboot set_active` (every flash-b) sets retry=7 and clears successful.
Each boot of a slot whose successful bit is clear costs one retry. At 0
ABL marks the slot unbootable and stops in fastboot. Android clears the
countdown by setting the successful bit once boot completes
(update_verifier -> markBootSuccessful). Ubuntu has no such HAL, so
without this every boot, charger wakes included, burned a retry and the
8th boot after a flash landed in fastboot.

  dagu-boot-success status   print both slots
  dagu-boot-success mark     set successful on the slot ABL booted

Only the attribute bits of one entry change. The entry array CRC and the
header CRC are rewritten in the primary and the backup GPT, and both are
read back and checked.
"""
from __future__ import annotations

import argparse
import os
import struct
import sys
import zlib
from pathlib import Path

PRIO_SHIFT, PRIO_MASK = 48, 0x3
ACTIVE_BIT = 50
RETRY_SHIFT, RETRY_MASK = 51, 0x7
SUCCESS_BIT = 54
UNBOOTABLE_BIT = 55

GPT_SIG = b"EFI PART"


def slot_suffix() -> str:
	for tok in Path("/proc/cmdline").read_text().split():
		if tok.startswith("androidboot.slot_suffix="):
			s = tok.split("=", 1)[1]
			if s in ("_a", "_b"):
				return s
	raise SystemExit("androidboot.slot_suffix=_a|_b missing from /proc/cmdline")


def locate(label: str) -> tuple[str, int, int]:
	"""(disk node, 0-based entry index, logical sector size) for a partlabel."""
	link = Path("/dev/disk/by-partlabel") / label
	if not link.exists():
		raise SystemExit(f"{link} missing")
	part = Path(os.path.realpath(link)).name
	sysp = Path("/sys/class/block") / part
	num = int((sysp / "partition").read_text())
	disk = Path(os.path.realpath(sysp / "..")).name
	lbs = int((Path("/sys/block") / disk / "queue/logical_block_size").read_text())
	return f"/dev/{disk}", num - 1, lbs


class Gpt:
	def __init__(self, fd: int, lba: int, lbs: int, where: str) -> None:
		self.fd, self.lba, self.lbs, self.where = fd, lba, lbs, where
		self.hdr = bytearray(os.pread(fd, lbs, lba * lbs))
		if self.hdr[:8] != GPT_SIG:
			raise SystemExit(f"{where} GPT at LBA {lba}: bad signature")
		(self.hsize,) = struct.unpack_from("<I", self.hdr, 12)
		if not 92 <= self.hsize <= lbs:
			raise SystemExit(f"{where} GPT: header size {self.hsize}")
		if self._hcrc() != struct.unpack_from("<I", self.hdr, 16)[0]:
			raise SystemExit(f"{where} GPT: header CRC mismatch, not touching it")
		(self.my_lba, self.alt_lba) = struct.unpack_from("<QQ", self.hdr, 24)
		(self.ent_lba, self.n_ent, self.ent_sz, ecrc) = struct.unpack_from(
			"<QIII", self.hdr, 72
		)
		if self.my_lba != lba or self.ent_sz < 128:
			raise SystemExit(f"{where} GPT: inconsistent header")
		self.ents = bytearray(os.pread(fd, self.n_ent * self.ent_sz, self.ent_lba * lbs))
		if len(self.ents) != self.n_ent * self.ent_sz:
			raise SystemExit(f"{where} GPT: short entry read")
		if zlib.crc32(self.ents) != ecrc:
			raise SystemExit(f"{where} GPT: entry CRC mismatch, not touching it")

	def _hcrc(self) -> int:
		h = bytearray(self.hdr[: self.hsize])
		h[16:20] = b"\0\0\0\0"
		return zlib.crc32(h)

	def name(self, idx: int) -> str:
		off = idx * self.ent_sz
		return self.ents[off + 56 : off + 128].decode("utf-16-le").split("\0", 1)[0]

	def attrs(self, idx: int) -> int:
		return struct.unpack_from("<Q", self.ents, idx * self.ent_sz + 48)[0]

	def set_attrs(self, idx: int, val: int) -> None:
		struct.pack_into("<Q", self.ents, idx * self.ent_sz + 48, val)
		struct.pack_into("<I", self.hdr, 88, zlib.crc32(self.ents))
		struct.pack_into("<I", self.hdr, 16, self._hcrc())

	def write(self) -> None:
		os.pwrite(self.fd, bytes(self.ents), self.ent_lba * self.lbs)
		os.pwrite(self.fd, bytes(self.hdr), self.lba * self.lbs)


def describe(a: int) -> str:
	return (
		f"attrs=0x{a:016x} priority={(a >> PRIO_SHIFT) & PRIO_MASK} "
		f"active={(a >> ACTIVE_BIT) & 1} retry={(a >> RETRY_SHIFT) & RETRY_MASK} "
		f"successful={(a >> SUCCESS_BIT) & 1} unbootable={(a >> UNBOOTABLE_BIT) & 1}"
	)


def open_both(disk: str, lbs: int, flags: int) -> tuple[int, Gpt, Gpt]:
	fd = os.open(disk, flags)
	p = Gpt(fd, 1, lbs, "primary")
	b = Gpt(fd, p.alt_lba, lbs, "backup")
	return fd, p, b


def drop_cache(fd: int) -> None:
	os.fsync(fd)
	os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)


def cmd_status() -> int:
	print(f"booted slot: {slot_suffix()}")
	for label in ("boot_a", "boot_b"):
		disk, idx, lbs = locate(label)
		fd, p, b = open_both(disk, lbs, os.O_RDONLY)
		os.close(fd)
		same = "" if p.attrs(idx) == b.attrs(idx) else f"  (backup 0x{b.attrs(idx):016x})"
		print(f"{label}: {describe(p.attrs(idx))}{same}")
	return 0


def cmd_mark() -> int:
	label = "boot" + slot_suffix()
	disk, idx, lbs = locate(label)
	fd, p, b = open_both(disk, lbs, os.O_RDWR)
	try:
		for g in (p, b):
			if g.name(idx) != label:
				raise SystemExit(f"{g.where} GPT entry {idx} is {g.name(idx)!r}, not {label}")
		cur = p.attrs(idx)
		if (cur >> UNBOOTABLE_BIT) & 1:
			raise SystemExit(f"{label} is marked unbootable yet booted: {describe(cur)}")
		want = cur | (1 << SUCCESS_BIT)
		if p.attrs(idx) == want and b.attrs(idx) == want:
			print(f"{label}: already successful, {describe(want)}")
			return 0
		# Backup first: if power drops between the two, the primary that ABL
		# reads is still the old, self-consistent table.
		b.set_attrs(idx, want)
		b.write()
		os.fsync(fd)
		p.set_attrs(idx, want)
		p.write()
		drop_cache(fd)
	finally:
		os.close(fd)
	fd, p, b = open_both(disk, lbs, os.O_RDONLY)
	os.close(fd)
	if p.attrs(idx) != want or b.attrs(idx) != want:
		raise SystemExit(f"{label}: read-back mismatch")
	print(f"{label}: marked successful, {describe(want)}")
	return 0


def main() -> int:
	ap = argparse.ArgumentParser(prog="dagu-boot-success")
	ap.add_argument("op", choices=("status", "mark"))
	ns = ap.parse_args()
	return cmd_status() if ns.op == "status" else cmd_mark()


if __name__ == "__main__":
	sys.exit(main())
