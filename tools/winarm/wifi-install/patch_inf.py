"""Add the large firmware memory block switch to the QCA6390 INF.

The firmware asks the host for two large memory segments right after
it boots. qcwlan6800sc81.sys rejects that request unless the device
key has EnableFirmwareLargeMemoryBlock=1, and the firmware then faults
(device manager code 10). The shipped INF never writes that value, so
a real PnP install drops it. This adds it to the install section the
device actually uses.
"""
from __future__ import annotations

import re

INSTALL_SECTION = "QcWlan_LITHIUM.ndi.NTARM64"
REG_SECTION = "LargeMemoryBlock.reg"
REG_LINE = "HKR, , EnableFirmwareLargeMemoryBlock, 0x00010001, 1"
ANCHOR = "[SourceDisksNames]"


class InfError(ValueError):
    pass


def _newline(text: str) -> str:
    return "\r\n" if "\r\n" in text else "\n"


def _section_span(text: str, name: str) -> tuple[int, int]:
    head = re.compile(r"^[ \t]*\[" + re.escape(name) + r"\][ \t]*\r?$", re.I | re.M)
    m = head.search(text)
    if not m:
        raise InfError("missing section [%s]" % name)
    nxt = re.compile(r"^[ \t]*\[", re.M).search(text, m.end())
    return m.end(), nxt.start() if nxt else len(text)


def patch(text: str) -> str:
    nl = _newline(text)
    start, end = _section_span(text, INSTALL_SECTION)
    body = text[start:end]
    addreg = re.compile(r"^([ \t]*AddReg[ \t]*=[ \t]*)([^\r\n;]*?)([ \t]*(?:;[^\r\n]*)?)(?=\r?$)", re.I | re.M)
    m = addreg.search(body)
    if not m:
        raise InfError("no AddReg in [%s]" % INSTALL_SECTION)
    names = [n.strip() for n in m.group(2).split(",") if n.strip()]
    if REG_SECTION.lower() not in (n.lower() for n in names):
        names.append(REG_SECTION)
        line = m.group(1) + ", ".join(names) + m.group(3)
        body = body[:m.start()] + line + body[m.end():]
        text = text[:start] + body + text[end:]

    try:
        rs, re_ = _section_span(text, REG_SECTION)
    except InfError:
        rs = None
    if rs is not None:
        if REG_LINE.replace(" ", "").lower() not in text[rs:re_].replace(" ", "").lower():
            raise InfError("[%s] exists with different content" % REG_SECTION)
        return text

    at = text.find(ANCHOR)
    if at < 0:
        raise InfError("missing %s" % ANCHOR)
    block = "[" + REG_SECTION + "]" + nl + REG_LINE + nl + nl
    return text[:at] + block + text[at:]


def patch_bytes(raw: bytes) -> bytes:
    if raw[:2] == b"\xff\xfe":
        return b"\xff\xfe" + patch(raw[2:].decode("utf-16-le")).encode("utf-16-le")
    if raw[:3] == b"\xef\xbb\xbf":
        return b"\xef\xbb\xbf" + patch(raw[3:].decode("utf-8")).encode("utf-8")
    return patch(raw.decode("latin-1")).encode("latin-1")


if __name__ == "__main__":
    import sys

    src, dst = sys.argv[1], sys.argv[2]
    data = open(src, "rb").read()
    open(dst, "wb").write(patch_bytes(data))
    print("patched", dst)
