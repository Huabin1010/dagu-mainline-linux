#!/usr/bin/env python3
"""Exclusive libusb fastboot for dagu.

Google platform-tools 37 hangs on USBDEVFS_REAPURB (fwupd claims 18d1:d00d,
leftover INFO packets desync the pipe). Protocol itself works.
"""
from __future__ import annotations

import argparse
import ctypes
import os
import sys

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

	def flash(self, part: str, path: str) -> None:
		data = open(path, "rb").read()
		n = len(data)
		if n < 1:
			raise SystemExit(f"empty {path}")
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
			fb.flash(ns.part, ns.file)
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
