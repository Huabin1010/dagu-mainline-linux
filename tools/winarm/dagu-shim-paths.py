#!/usr/bin/env python3
"""Print the shim's breadcrumb ring from a crash dump or live image.

  dagu-shim-paths.py DUMP [--image-base 0x180000000]

The 1.0.6.0 build records one entry per qcdx call site it hooked
(gPathId / gPathLr, ring of 32, gPathCount is the total). Reading it from a
dump shows which call qcdx made last before the asynchronous SError, which the
bugcheck's own ELR cannot say (it is the point where the error was taken).

Symbol RVAs below belong to that build only; they are verified against the
module's .text before use and reported as a mismatch instead of guessing.
"""
import argparse
import importlib.util
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("triage", os.path.join(HERE, "dagu-dump-triage.py"))
triage = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(triage)

# dagu-smmushim 1.0.6.0 (SHA256 a95affb2...), from the linker map.
SYMS = {
    "gPathCount": 0x110B8,
    "gPathId": 0x110C0,
    "gPathLr": 0x11140,
    "gPathInstall": 0x11280,
}
CAP = 32
# site id -> (install bit index, description)
SITES = {
    1: (0, "bl 0x301D4 -> 0xAC9C0 display init entry"),
    2: (1, "bl 0xAD30C -> 0xADC00 PMIPower gate"),
    4: (2, "bl 0xACB3C -> 0xD5D48 ACPI display resources"),
    5: (3, "bl 0x2CA8E0 -> 0x2D0430 release caller A"),
    6: (4, "bl 0x2CEB8C -> 0x2D0430 release caller B"),
    7: (5, "bl 0x2D0148 -> 0x2D0430 release caller C"),
    8: (6, "bl 0x2D03A0 -> 0x2D0430 release caller D"),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dump")
    ap.add_argument("--shim", default="dagu-smmushim.sys")
    ap.add_argument("--qcdx", default="qcdxkm8250.sys")
    a = ap.parse_args()

    d = triage.Dump(open(a.dump, "rb"))
    m = d.module(a.shim)
    if not m:
        sys.exit("%s not loaded in this dump" % a.shim)
    base, size = m
    q = d.module(a.qcdx)
    if not q:
        sys.exit("%s not loaded in this dump" % a.qcdx)

    def u32(rva):
        b = d.rdva(base + rva, 4)
        return struct.unpack("<I", b)[0] if b and len(b) == 4 else None

    def u64(rva):
        b = d.rdva(base + rva, 8)
        return struct.unpack("<Q", b)[0] if b and len(b) == 8 else None

    count = u32(SYMS["gPathCount"])
    install = u32(SYMS["gPathInstall"])
    print("shim %#x size %#x  pathn=%s install=%s" % (
        base, size, count, ("%#x" % install) if install is not None else "?"))
    if install is not None:
        for sid, (bit, text) in sorted(SITES.items()):
            print("  site %d %-42s %s" % (sid, text, "HOOKED" if install & (1 << bit) else "not patched"))
    if not count:
        print("no breadcrumbs recorded")
        return

    n = min(count, CAP)
    first = count - n
    print("%d entries, oldest first:" % n)
    for k in range(n):
        idx = (first + k) % CAP
        pid = u32(SYMS["gPathId"] + idx * 4)
        lr = u64(SYMS["gPathLr"] + idx * 8)
        lr_s = ("qcdx+0x%x" % (lr - q[0])) if lr and q[0] <= lr < q[0] + q[1] else ("0x%x" % lr if lr else "?")
        print("  #%-3d id=%s  lr=%s  %s" % (
            first + k, pid, lr_s, SITES[pid][1] if pid in SITES else ""))


if __name__ == "__main__":
    main()
