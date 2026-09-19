#!/usr/bin/env python3
"""Capstone 4.5: pin Display Full Crop/MNDS 9-word fill from camera.qcom.so.

One pass over PT_LOAD+X. Xrefs the C-string *start*, not a substring.
Does not flash. Does not invent dest.
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

from capstone import CS_ARCH_ARM64, CS_MODE_ARM, Cs
from capstone.arm64 import ARM64_INS_ADD, ARM64_INS_ADRP, ARM64_OP_IMM, ARM64_OP_REG

SO = Path(
    "/home/huanghuabin/Projects/xiaomi-pad870-win11-arm/dumps/"
    "dagu-android-live/camera-ife-20260916/so/camera.qcom.so"
)
OUT = Path(
    "/home/huanghuabin/Projects/xiaomi-pad870-win11-arm/linux-mainline/"
    "out/camera/ife-android-analyze/so-disp-full"
)

# Display Full VERB is "MNDS Disp …". "MNDS Full Luma imageSize" is identity.
NEEDLES = [
    b"DisplayFullpath %d %d %dx%d",
    b"MNDS Disp Luma horizontalStripe0",
    b"MNDS Disp Luma verticalPhase",
    b"MNDS Disp Luma horizontalPhase",
    b"MNDS Display Chroma horizontalSize",
    b"MNDS Display Chroma horizontalStripe1",
    b"MNDS Display Chroma verticalPadding",
    b"MNDS Full Luma imageSize",
    b"Path %d[0-FD,1-Full], MNDS output dimension",
]

AHB = {
    0x4460: "Crop Y",
    0x4660: "Crop C",
    0x4C60: "MNDS Y DISP",
    0x4E60: "MNDS C DISP",
    0x6460: "FD Y",
    0x6660: "FD C",
}


def load_elf(data: bytes):
    if data[:4] != b"\x7fELF":
        raise SystemExit("not ELF")
    e_phoff = struct.unpack_from("<Q", data, 32)[0]
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 54)
    loads, execs = [], []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, p_flags = struct.unpack_from("<II", data, off)
        p_offset, p_vaddr, _p, p_filesz, _m, _a = struct.unpack_from(
            "<QQQQQQ", data, off + 8
        )
        if p_type != 1:
            continue
        loads.append((p_vaddr, p_offset, p_filesz))
        if p_flags & 1:
            execs.append((p_vaddr, p_offset, p_filesz))
    return loads, execs


def va_to_off(loads, va: int) -> int | None:
    for vaddr, offset, filesz in loads:
        if vaddr <= va < vaddr + filesz:
            return offset + (va - vaddr)
    return None


def cstart(data: bytes, needle: bytes) -> int | None:
    j = data.find(needle)
    if j < 0:
        return None
    return data.rfind(b"\0", 0, j) + 1


def scan_xrefs(md: Cs, data: bytes, execs, want: set[int]) -> dict[int, list[int]]:
    xrefs: dict[int, list[int]] = {s: [] for s in want}
    page_reg: dict[int, int] = {}
    for vaddr, offset, filesz in execs:
        blob = data[offset : offset + filesz]
        for insn in md.disasm(blob, vaddr):
            if insn.id == ARM64_INS_ADRP and insn.operands:
                page_reg[insn.operands[0].reg] = insn.operands[1].imm
                continue
            if insn.id != ARM64_INS_ADD or len(insn.operands) < 3:
                continue
            src, imm_op = insn.operands[1], insn.operands[2]
            if src.type != ARM64_OP_REG or imm_op.type != ARM64_OP_IMM:
                continue
            page = page_reg.get(src.reg)
            if page is None:
                continue
            va = page + imm_op.imm
            if va in xrefs:
                xrefs[va].append(insn.address)
    return xrefs


def dump_window(md: Cs, data: bytes, loads, va: int, before=48, after=64) -> str:
    start = max(va - before * 4, 0)
    off = va_to_off(loads, start)
    if off is None:
        return ""
    blob = data[off : off + (before + after) * 4]
    lines = []
    for insn in md.disasm(blob, start):
        mark = " <<<" if insn.address == va else ""
        lines.append(f"  {insn.address:08x}  {insn.mnemonic} {insn.op_str}{mark}")
        if insn.address > va + after * 4:
            break
    return "\n".join(lines)


def scan_create_cmd(md: Cs, data: bytes, loads) -> str:
    va = 0x538F80
    off = va_to_off(loads, va)
    if off is None:
        return "CreateCmdList VA 0x538f80 not in PT_LOAD\n"
    blob = data[off : off + 0x800]
    lines = ["CreateCmdList window 0x538f80..+0x800 (path==6 / n=9 / AHB):"]
    for insn in md.disasm(blob, va):
        text = f"{insn.mnemonic} {insn.op_str}"
        interesting = any(hex(a)[2:] in insn.op_str.lower() for a in AHB)
        interesting = interesting or "#9" in insn.op_str or "#0x9" in insn.op_str.lower()
        interesting = interesting or "#6" in insn.op_str or "#0x6" in insn.op_str.lower()
        if not interesting:
            continue
        tag = ""
        for a, name in AHB.items():
            if hex(a) in insn.op_str.lower():
                tag = f"  ; {name}"
        lines.append(f"  {insn.address:08x}  {text}{tag}")
    return "\n".join(lines) + "\n"


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    data = SO.read_bytes()
    loads, execs = load_elf(data)
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    md.detail = True

    strings: list[tuple[str, int]] = []
    for n in NEEDLES:
        s = cstart(data, n)
        if s is None:
            strings.append((n.decode("ascii", "replace") + " MISSING", -1))
            continue
        strings.append((data[s : data.find(b"\0", s)].decode("ascii", "replace"), s))

    want = {s for _, s in strings if s >= 0}
    xrefs = scan_xrefs(md, data, execs, want)

    report = [
        "# camera.qcom.so Display Full pack (Capstone, one pass)\n",
        f"so={SO} size={len(data)}\n",
        "## C-string starts (not substring offsets)\n",
    ]
    for name, off in strings:
        if off < 0:
            report.append(f"- `{name}`")
            continue
        x = xrefs.get(off, [])
        report.append(f"- start=0x{off:x} xrefs={[hex(v) for v in x]} `{name[:90]}`")
    report.append("\n## xref windows\n")
    for name, off in strings:
        if off < 0:
            continue
        for va in xrefs.get(off, [])[:2]:
            report.append(f"### {name[:60]} @ {va:#x}\n")
            report.append("```")
            report.append(dump_window(md, data, loads, va))
            report.append("```\n")
    report.append("## CreateCmdList\n```\n")
    report.append(scan_create_cmd(md, data, loads))
    report.append("```\n")
    report.append(
        "Display Full VERB is Stripe0/Phase/Chroma size, not "
        "`MNDS Disp Luma imageSize` (that string does not exist). "
        "`MNDS Full Luma imageSize` is identity. "
        "`mov w4, #0x900` at 0x57aef4 is RNF FIR maxVal, not dest. "
        "Heap Display Full 9-word word4 H_STRIPE is 0; do not write "
        "Crop Y H_STRIPE 0x090f0000.\n"
    )
    text = "\n".join(report)
    (OUT / "NOTES.md").write_text(text)
    print(f"wrote {OUT / 'NOTES.md'} ({len(text)} bytes)")
    for name, off in strings:
        if off < 0:
            print(f"MISSING {name}")
            continue
        print(f"0x{off:x} xrefs={list(map(hex, xrefs.get(off, [])))} {name[:70]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
