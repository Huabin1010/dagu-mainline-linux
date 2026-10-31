#!/usr/bin/env python3
"""Swap a new Mu UEFI payload into an existing dagu boot_a image.

build-dagu-uefi.sh normally repacks the stock HyperOS v3 boot with magiskboot.
That needs the stock dump and magiskboot, which are local, git-ignored files.
When they are missing, take the boot_a that is on the tablet now (dumped from
B-slot Linux: dd if=/dev/disk/by-partlabel/boot_a), which already passed ABL,
and replace only its kernel with the new payload, prepared the same way
build-bootimg.sh does (text_offset 0x80000 header, FDT magics scrambled).

  repack-uefi-boot.py --boot boot_a-dump.img --payload dagu-uefi-payload.raw \
                      --out boot-dagu-uefi-new.img

Android boot image v3/v4: 4096-byte pages, header | kernel | ramdisk [| sig].
Only kernel_size and the kernel pages change; header, cmdline, os_version and
ramdisk bytes are copied verbatim.
"""
import argparse, struct, sys
from pathlib import Path

PAGE = 4096


def pages(n):
    return (n + PAGE - 1) // PAGE * PAGE


def prepare(payload: bytes) -> bytes:
    """Mirror build-bootimg.sh's default branch."""
    inner = bytearray(payload)
    if inner[56:60] != b"ARM\x64":
        sys.exit("payload has no ARM64 Image header")
    text_off = struct.unpack_from("<Q", inner, 8)[0]
    off = 0
    while (i := inner.find(b"\xd0\x0d\xfe\xed", off)) >= 0:
        inner[i:i + 4] = b"\0\0\0\0"
        off = i + 4
    pad = 0x80000
    if text_off == pad:
        return bytes(inner)
    hdr = bytearray(pad)
    b_imm = lambda d: 0x14000000 | ((d >> 2) & 0x3FFFFFF)
    struct.pack_into("<I", hdr, 0, b_imm(pad))
    struct.pack_into("<Q", hdr, 8, pad)
    struct.pack_into("<Q", hdr, 16, pad + len(inner))
    hdr[24:56] = inner[24:56]
    hdr[56:60] = b"ARM\x64"
    return bytes(hdr) + bytes(inner)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--boot", required=True, type=Path)
    ap.add_argument("--payload", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ns = ap.parse_args()

    b = ns.boot.read_bytes()
    if b[:8] != b"ANDROID!":
        sys.exit("not an Android boot image")
    ver = struct.unpack_from("<I", b, 40)[0]
    if ver not in (3, 4):
        sys.exit(f"header_version {ver}; only v3/v4 supported")
    ksz, rsz = struct.unpack_from("<II", b, 8)
    hdr_sz = struct.unpack_from("<I", b, 20)[0]
    old_k = b[PAGE:PAGE + ksz]
    rd_off = PAGE + pages(ksz)
    ramdisk = b[rd_off:rd_off + rsz]
    sig = b""
    if ver == 4:
        ssz = struct.unpack_from("<I", b, 1580)[0]
        sig = b[rd_off + pages(rsz):rd_off + pages(rsz) + ssz]

    kernel = prepare(ns.payload.read_bytes())
    head = bytearray(b[:PAGE])
    struct.pack_into("<I", head, 8, len(kernel))
    out = bytes(head) + kernel.ljust(pages(len(kernel)), b"\0") + ramdisk.ljust(pages(rsz), b"\0")
    if sig:
        out += sig.ljust(pages(len(sig)), b"\0")
    ns.out.write_bytes(out)
    print(f"v{ver} hdr={hdr_sz} kernel {ksz} -> {len(kernel)} ramdisk {rsz} (kept) -> {ns.out} {len(out)} bytes")
    print(f"old kernel text_offset=0x{struct.unpack_from('<Q', old_k, 8)[0]:x} "
          f"new=0x{struct.unpack_from('<Q', kernel, 8)[0]:x}")


if __name__ == "__main__":
    main()
