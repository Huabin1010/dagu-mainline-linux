#!/usr/bin/env python3
"""Rewrite the PCFG panel XML buffer inside an ASL Method (_ROM) in place.

  pcfg-edit.py FILE.asl --drop-tag PMIPowerPmicNum --drop-tag PMIPowerConfig ...
  pcfg-edit.py FILE.asl --show

The XML lives as `Name (PCFG, Buffer (0xLEN) { 0x.., ... })`. Editing the hex
by hand is error prone, so this tool decodes it, edits whole <Tag>..</Tag>
lines, and re-emits the buffer with the same layout (16 bytes per line) and an
updated length. A trailing NUL pair is kept.
"""
from __future__ import annotations

import argparse
import re
import sys

PAT = re.compile(r"(Name \(PCFG, Buffer \()(0x[0-9A-Fa-f]+)(\)\s*\{)(.*?)(\})", re.S)


def decode(asl: str) -> tuple[re.Match, bytes]:
    m = PAT.search(asl)
    if not m:
        raise ValueError("no PCFG buffer found")
    data = bytes(int(x, 16) for x in re.findall(r"0x([0-9A-Fa-f]{2})\b", m.group(4)))
    if len(data) != int(m.group(2), 16):
        raise ValueError("PCFG length %d does not match declared %s" % (len(data), m.group(2)))
    return m, data


def drop_tags(xml: bytes, tags: list[str]) -> tuple[bytes, list[str]]:
    """Remove each `<Tag>value</Tag>` line. Returns the new XML and the tags
    that were actually present. A tag that is missing is not an error."""
    out = xml
    gone = []
    for tag in tags:
        pat = re.compile(rb"[ \t]*<" + re.escape(tag.encode()) + rb">[^<\n]*</" + re.escape(tag.encode()) + rb">\r?\n")
        out, n = pat.subn(b"", out)
        if n:
            gone.append(tag)
    return out, gone


def encode(data: bytes, indent: str) -> str:
    lines = []
    for i in range(0, len(data), 16):
        lines.append(indent + ", ".join("0x%02X" % b for b in data[i:i + 16]) + ",")
    return "\n" + "\n".join(lines) + "\n" + indent[:-4]


def rewrite(asl: str, tags: list[str]) -> tuple[str, list[str], int, int]:
    m, data = decode(asl)
    new, gone = drop_tags(data, tags)
    first = m.group(4).lstrip("\n")
    indent = first[:len(first) - len(first.lstrip())]
    body = encode(new, indent)
    out = asl[:m.start()] + m.group(1) + "0x%X" % len(new) + m.group(3) + body + m.group(5) + asl[m.end():]
    return out, gone, len(data), len(new)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("asl")
    ap.add_argument("--drop-tag", action="append", default=[])
    ap.add_argument("--show", action="store_true")
    a = ap.parse_args(argv)
    asl = open(a.asl, encoding="utf-8").read()
    if a.show:
        sys.stdout.write(decode(asl)[1].decode("latin1"))
        return 0
    out, gone, old, new = rewrite(asl, a.drop_tag)
    missing = sorted(set(a.drop_tag) - set(gone))
    if missing:
        print("not present:", ", ".join(missing), file=sys.stderr)
    open(a.asl, "w", encoding="utf-8").write(out)
    print("PCFG %d -> %d bytes, dropped %s" % (old, new, ", ".join(gone) or "nothing"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
