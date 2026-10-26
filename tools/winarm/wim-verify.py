#!/usr/bin/env python3
"""Verify an applied WIM image file-by-file (SHA-1 of every unnamed stream).

  wim-verify.py IMAGE.wim INDEX MOUNTPOINT [--max N]
  wim-verify.py MANIFEST.txt - MOUNTPOINT     # "<sha1> <path>" lines

Reads `wimlib-imagex dir --detailed` for the reference hashes, then hashes the
files under MOUNTPOINT (e.g. an ntfs-3g mount of the target volume).
"""
import hashlib
import os
import subprocess
import sys

wim, index, root = sys.argv[1], sys.argv[2], sys.argv[3]
limit = int(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[4] == "--max" else 0
entries, path, attrs, in_unnamed = [], None, 0, False
if index == "-":
    # Precomputed manifest ("<sha1> <path>" per line), e.g. when the WIM itself
    # is not on the target machine.
    for line in open(wim, encoding="utf-8", errors="replace"):
        h, _, p = line.rstrip("\n").partition(" ")
        entries.append((p, h))
    out = ""
else:
    out = subprocess.run(["wimlib-imagex", "dir", wim, index, "--detailed"],
                         capture_output=True, text=True, errors="replace").stdout
for line in out.splitlines():
    s = line.strip()
    if s.startswith("Full Path"):
        path = s.split("=", 1)[1].strip().strip('"')
        in_unnamed = False
    elif s.startswith("Attributes"):
        attrs = int(s.split("=", 1)[1], 16)
    elif s == "Unnamed data stream:":
        in_unnamed = True
    elif s.startswith("Hash") and in_unnamed and path:
        h = s.split("=", 1)[1].strip()[2:]
        if attrs & 0x10 == 0 and attrs & 0x400 == 0 and int(h, 16) != 0:
            entries.append((path, h))
        in_unnamed = False
bad = err = ok = 0
for i, (p, h) in enumerate(entries):
    if limit and i >= limit:
        break
    f = os.path.join(root, p.lstrip("/"))
    try:
        d = hashlib.sha1()
        with open(f, "rb") as fh:
            for blk in iter(lambda: fh.read(1 << 20), b""):
                d.update(blk)
        if d.hexdigest() == h:
            ok += 1
        else:
            bad += 1
            if bad <= 15:
                print("MISMATCH", p)
    except OSError as e:
        err += 1
        if err <= 15:
            print("ERROR", p, e.strerror)
print(f"files={len(entries)} ok={ok} mismatch={bad} error={err}")
sys.exit(1 if bad or err else 0)
