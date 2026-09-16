#!/usr/bin/env python3
"""Exclusive libusb fastboot for dagu.

Google platform-tools 37 hangs on USBDEVFS_REAPURB (fwupd claims 18d1:d00d,
leftover INFO packets desync the pipe). Protocol itself works.
"""
from __future__ import annotations

import argparse
import ctypes
import os
import struct
import sys

SPARSE_MAGIC = 0xED26FF3A
CHUNK_RAW = 0xCAC1
CHUNK_FILL = 0xCAC2
CHUNK_DONT_CARE = 0xCAC3
SPARSE_BLK = 4096

VID, PID = 0x18D1, 0xD00D
EP_OUT, EP_IN = 0x01, 0x81
CMD_N = 64


class Libusb:
	def __init__(self) -> None:
		self.lib = ctypes.CDLL("libusb-1.0.so.0")
		self.lib.libusb_init.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
		self.lib.libusb_init.restype = ctypes.c_int
		self.lib.libusb_exit.argtypes = [ctypes.c_void_p]
		self.lib.libusb_open_device_with_vid_pid.argtypes = [
			ctypes.c_void_p,
			ctypes.c_uint16,
			ctypes.c_uint16,
		]
		self.lib.libusb_open_device_with_vid_pid.restype = ctypes.c_void_p
		self.lib.libusb_set_auto_detach_kernel_driver.argtypes = [ctypes.c_void_p, ctypes.c_int]
		self.lib.libusb_claim_interface.argtypes = [ctypes.c_void_p, ctypes.c_int]
		self.lib.libusb_claim_interface.restype = ctypes.c_int
		self.lib.libusb_release_interface.argtypes = [ctypes.c_void_p, ctypes.c_int]
		self.lib.libusb_close.argtypes = [ctypes.c_void_p]
		self.lib.libusb_bulk_transfer.argtypes = [
			ctypes.c_void_p,
			ctypes.c_ubyte,
			ctypes.c_void_p,
			ctypes.c_int,
			ctypes.POINTER(ctypes.c_int),
			ctypes.c_uint,
		]
		self.lib.libusb_bulk_transfer.restype = ctypes.c_int
		self.lib.libusb_strerror.argtypes = [ctypes.c_int]
		self.lib.libusb_strerror.restype = ctypes.c_char_p
		self.ctx = ctypes.c_void_p()
		self.h = ctypes.c_void_p()

	def err(self, rc: int) -> str:
		s = self.lib.libusb_strerror(rc)
		return s.decode() if s else str(rc)

	def open(self) -> None:
		rc = self.lib.libusb_init(ctypes.byref(self.ctx))
		if rc:
			raise SystemExit(f"libusb_init: {self.err(rc)}")
		self.h = self.lib.libusb_open_device_with_vid_pid(self.ctx, VID, PID)
		if not self.h:
			raise SystemExit("no 18d1:d00d fastboot device")
		self.lib.libusb_set_auto_detach_kernel_driver(self.h, 1)
		rc = self.lib.libusb_claim_interface(self.h, 0)
		if rc:
			raise SystemExit(f"claim interface: {self.err(rc)}")

	def close(self) -> None:
		if self.h:
			self.lib.libusb_release_interface(self.h, 0)
			self.lib.libusb_close(self.h)
			self.h = ctypes.c_void_p()
		if self.ctx:
			self.lib.libusb_exit(self.ctx)
			self.ctx = ctypes.c_void_p()

	def bulk(self, ep: int, data: bytes, timeout: int) -> bytes:
		n = ctypes.c_int()
		if ep & 0x80:
			buf = ctypes.create_string_buffer(max(len(data), 4096))
			rc = self.lib.libusb_bulk_transfer(
				self.h, ep, buf, len(buf), ctypes.byref(n), timeout
			)
			if rc:
				raise OSError(rc, self.err(rc))
			return buf.raw[: n.value]
		buf = ctypes.create_string_buffer(data, len(data))
		last_rc = 0
		for attempt in range(3):
			rc = self.lib.libusb_bulk_transfer(
				self.h, ep, buf, len(data), ctypes.byref(n), timeout
			)
			last_rc = rc
			if rc == 0:
				if n.value != len(data):
					raise OSError(f"short out {n.value}/{len(data)}")
				return b""
			if rc != -7:  # LIBUSB_ERROR_TIMEOUT
				break
		raise OSError(last_rc, self.err(last_rc))

	def drain(self) -> None:
		while True:
			try:
				self.bulk(EP_IN, bytes(4096), 50)
			except OSError:
				return


class Fastboot:
	def __init__(self, usb: Libusb) -> None:
		self.usb = usb
		usb.drain()

	def cmd(self, s: str, timeout: int = 5000) -> str:
		raw = s.encode("ascii")
		if len(raw) > CMD_N:
			raise ValueError(s)
		self.usb.bulk(EP_OUT, raw + b"\x00" * (CMD_N - len(raw)), timeout)
		infos: list[str] = []
		while True:
			pkt = self.usb.bulk(EP_IN, bytes(64), timeout)
			if len(pkt) < 4:
				raise SystemExit(f"short response {pkt!r}")
			tag, rest = pkt[:4].decode("ascii", "replace"), pkt[4:].split(b"\x00", 1)[0].decode(
				"ascii", "replace"
			)
			if tag == "INFO":
				infos.append(rest)
				continue
			if tag in ("OKAY", "FAIL", "DATA"):
				if tag == "FAIL":
					raise SystemExit(f"FAIL {rest}")
				return tag + rest
			raise SystemExit(f"bad response {pkt!r}")

	def getvar(self, name: str) -> str:
		r = self.cmd("getvar:" + name)
		if not r.startswith("OKAY"):
			raise SystemExit(r)
		return r[4:]

	def _max_download(self) -> int:
		raw = (self.getvar("max-download-size") or "").strip()
		if not raw:
			return 768 * 1024 * 1024
		try:
			return int(raw, 0)
		except ValueError:
			return 768 * 1024 * 1024

	def download_and_flash(self, part: str, data: bytes) -> None:
		n = len(data)
		if n < 1:
			raise SystemExit(f"empty payload for {part}")
		print(f"Sending '{part}' ({n / 1024:.1f} KB)")
		r = self.cmd(f"download:{n:08x}", timeout=10000)
		if not r.startswith("DATA"):
			raise SystemExit(f"expected DATA, got {r}")
		# Last URB is 1 byte so the total is never a 512-multiple transfer
		# (libusb ZLP hangs this AMD xHCI).
		chunk = 256 * 1024
		body, last = data[:-1], data[-1:]
		off = 0
		while off < len(body):
			piece = body[off : off + chunk]
			self.usb.bulk(EP_OUT, piece, 120000)
			off += len(piece)
			print(f"\r  {off + 1}/{n}", end="", flush=True)
		self.usb.bulk(EP_OUT, last, 120000)
		print(f"\r  {n}/{n}")
		ok = self.usb.bulk(EP_IN, bytes(64), 60000)
		tag = ok[:4].decode("ascii", "replace")
		if tag != "OKAY":
			raise SystemExit(f"download {ok!r}")
		print(f"Writing '{part}'")
		r = self.cmd("flash:" + part, timeout=300000)
		if not r.startswith("OKAY"):
			raise SystemExit(r)
		print("OKAY")

	def flash(self, part: str, path: str, chunk: int | None = None) -> None:
		n = os.path.getsize(path)
		if n < 1:
			raise SystemExit(f"empty {path}")
		max_dl = self._max_download()
		with open(path, "rb") as fh:
			magic = fh.read(4)
		if magic == struct.pack("<I", SPARSE_MAGIC):
			if n > max_dl:
				raise SystemExit(
					f"{path} is already sparse and larger than max-download-size "
					f"({n} > {max_dl})"
				)
			self.download_and_flash(part, open(path, "rb").read())
			return
		need_sparse = chunk is not None or n > max_dl
		if not need_sparse:
			self.download_and_flash(part, open(path, "rb").read())
			return
		slice_len = chunk or min(256 * 1024 * 1024, max_dl - 1024 * 1024)
		if slice_len < SPARSE_BLK:
			raise SystemExit("sparse chunk too small")
		total_blks = (n + SPARSE_BLK - 1) // SPARSE_BLK
		nslice = (n + slice_len - 1) // slice_len
		print(
			f"sparse flash {path} -> {part}: {n} bytes, {nslice} slice(s), "
			f"chunk={slice_len}"
		)
		with open(path, "rb") as fh:
			for i, off in enumerate(range(0, n, slice_len)):
				this = min(slice_len, n - off)
				blob = build_sparse_slice(fh, off, this, total_blks)
				if len(blob) > max_dl:
					raise SystemExit(
						f"slice {i + 1} is {len(blob)} bytes > max-download-size {max_dl}"
					)
				print(f"==> slice {i + 1}/{nslice} file_off={off} raw={this}")
				self.download_and_flash(part, blob)


def parse_size(s: str) -> int:
	t = s.strip().upper()
	if t.endswith("G"):
		return int(t[:-1]) * 1024 * 1024 * 1024
	if t.endswith("M"):
		return int(t[:-1]) * 1024 * 1024
	if t.endswith("K"):
		return int(t[:-1]) * 1024
	return int(t, 0)


def _sparse_header(total_blks: int, n_chunks: int) -> bytes:
	return struct.pack(
		"<IHHHHIIII",
		SPARSE_MAGIC,
		1,
		0,
		28,
		12,
		SPARSE_BLK,
		total_blks,
		n_chunks,
		0,
	)


def _chunk_hdr(kind: int, nblks: int, payload: int) -> bytes:
	return struct.pack("<HHII", kind, 0, nblks, 12 + payload)


def build_sparse_slice(fh, offset: int, length: int, total_blks: int) -> bytes:
	"""One Android sparse image covering the whole file.

	Blocks inside this slice are RAW or FILL 0 (never DONT_CARE — leftover
	Android bytes in a zero journal block would brick ext4). Other regions
	are DONT_CARE so later slices do not wipe earlier ones.
	"""
	if offset % SPARSE_BLK:
		raise SystemExit("sparse offset must be 4096-aligned")
	chunks: list[bytes] = []
	prefix_blks = offset // SPARSE_BLK
	slice_blks = (length + SPARSE_BLK - 1) // SPARSE_BLK
	suffix_blks = total_blks - prefix_blks - slice_blks
	if prefix_blks:
		chunks.append(_chunk_hdr(CHUNK_DONT_CARE, prefix_blks, 0))
	fh.seek(offset)
	run_kind: int | None = None
	run_blks = 0
	run_data = bytearray()

	def flush() -> None:
		nonlocal run_kind, run_blks, run_data
		if not run_blks or run_kind is None:
			return
		if run_kind == CHUNK_FILL:
			chunks.append(_chunk_hdr(CHUNK_FILL, run_blks, 4) + struct.pack("<I", 0))
		else:
			chunks.append(_chunk_hdr(CHUNK_RAW, run_blks, len(run_data)) + bytes(run_data))
		run_kind = None
		run_blks = 0
		run_data = bytearray()

	remain = length
	for _ in range(slice_blks):
		take = min(SPARSE_BLK, remain) if remain > 0 else 0
		block = fh.read(take) if take else b""
		if len(block) < SPARSE_BLK:
			block = block + b"\x00" * (SPARSE_BLK - len(block))
		remain -= take
		kind = CHUNK_FILL if block == b"\x00" * SPARSE_BLK else CHUNK_RAW
		if kind != run_kind:
			flush()
			run_kind = kind
		run_blks += 1
		if kind == CHUNK_RAW:
			run_data.extend(block)
	flush()
	if suffix_blks > 0:
		chunks.append(_chunk_hdr(CHUNK_DONT_CARE, suffix_blks, 0))
	body = b"".join(chunks)
	return _sparse_header(total_blks, len(chunks)) + body

	def erase(self, part: str) -> None:
		print(f"Erasing '{part}'")
		r = self.cmd("erase:" + part, timeout=120000)
		if not r.startswith("OKAY"):
			raise SystemExit(r)
		print("OKAY")

	def reboot(self) -> None:
		self.cmd("reboot")
		print("rebooting")


def main() -> int:
	p = argparse.ArgumentParser(prog="fb-usb.py")
	sub = p.add_subparsers(dest="op", required=True)
	sub.add_parser("devices")
	g = sub.add_parser("getvar")
	g.add_argument("name")
	f = sub.add_parser("flash")
	f.add_argument("part")
	f.add_argument("file")
	f.add_argument(
		"-S",
		"--chunk",
		default=None,
		help="sparse-split size (e.g. 256M). Default: auto when file > max-download-size",
	)
	sub.add_parser("reboot")
	e = sub.add_parser("erase")
	e.add_argument("part")
	a = sub.add_parser("set-active")
	a.add_argument("slot", choices=("a", "b"))
	ns = p.parse_args()

	usb = Libusb()
	if ns.op == "devices":
		try:
			usb.open()
		except SystemExit:
			return 0
		try:
			fb = Fastboot(usb)
			sn = fb.getvar("serialno") or "?"
			print(f"{sn}\tfastboot")
		finally:
			usb.close()
		return 0

	usb.open()
	try:
		fb = Fastboot(usb)
		if ns.op == "getvar":
			v = fb.getvar(ns.name)
			print(f"{ns.name}: {v}")
		elif ns.op == "flash":
			if not os.path.isfile(ns.file):
				raise SystemExit(f"missing {ns.file}")
			chunk = parse_size(ns.chunk) if ns.chunk else None
			fb.flash(ns.part, ns.file, chunk=chunk)
		elif ns.op == "reboot":
			fb.reboot()
		elif ns.op == "erase":
			fb.erase(ns.part)
		elif ns.op == "set-active":
			fb.cmd("set_active:" + ns.slot)
			print(f"current-slot: {ns.slot}")
	finally:
		usb.close()
	return 0


if __name__ == "__main__":
	sys.exit(main())
