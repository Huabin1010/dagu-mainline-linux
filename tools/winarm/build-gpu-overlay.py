#!/usr/bin/env python3
"""Build a dagu Windows DSDT override table (live overlay) for GPU bring-up.

The override is applied on the tablet with `asl.exe /loadtable <out>.aml`, which
writes HKLM\\...\\ACPI\\Parameters\\DSDT\\QCOMM_\\SM8250_\\0000000<rev> (splitting
it into 00000000/00000001/... registry blocks itself). So this tool only has to
emit a correct .aml.

Why we splice at the AML level instead of decompiling the firmware DSDT:

  The live firmware DSDT does NOT survive an iasl decompile->recompile round
  trip. Its fixed-width placeholders (the 15-char SIDS serial, backfilled by
  UEFI AcpiPlatformUpdateLib) decompile to `Name (SIDS, "")` followed by orphan
  `Zero` opcodes, which is not legal ASL, and the parse abort cascades into
  bogus "\\_SB.SIDV does not exist" errors. It is a decompiler artifact, not bad
  AML -- the firmware runs the table fine.

  Also, the live DSDT already holds the REAL chip values UEFI backfilled
  (SOID=0x164, SIDV=0x20000, SIDT, and SOSI as a proper 8-byte QWord at
  0x80907228). A live overlay is injected after UEFI, so it must keep those real
  values; rebuilding from source would leave the 0xFFFFFFFF / 0xDEADBEEF
  placeholders and break PMCL/_HRV's `SOID==0x164` logic and re-introduce the
  SOSI landmine (roadmap §3.3).

So: compile just the new nodes as `Scope(\\_SB){ GPU0 [MMU0 MMU1] }` with
`External` refs to the chip symbols (External emits no AML), binary-append that
ScopeOp onto the live firmware AML (multiple \\_SB scopes legally merge), and fix
only the DSDT length, OEM revision, and checksum. SOSI is never touched.
"""
from __future__ import annotations

import argparse
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

# Chip symbols the GPU/SMMU nodes reference; declared External so iasl resolves
# them without emitting (they already live in the firmware DSDT).
EXTERNALS = [
    ("\\_SB.SIDV", "IntObj"), ("\\_SB.SIDT", "IntObj"), ("\\_SB.SOID", "IntObj"),
    ("\\_SB.SDFE", "IntObj"), ("\\_SB.SVMJ", "IntObj"), ("\\_SB.GIO0", "DeviceObj"),
]


def run(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True)


def iasl() -> str:
    exe = shutil.which("iasl")
    if not exe:
        sys.exit("iasl not found (install acpica-tools)")
    return exe


def compile_fragment(gpu: str, smmu: str | None, work: Path) -> bytes:
    """Compile Scope(\\_SB){nodes} and return just the ScopeOp AML blob."""
    lines = ['DefinitionBlock ("", "SSDT", 2, "DAGU  ", "GPUFRAG ", 0x00000001)', "{"]
    for name, typ in EXTERNALS:
        lines.append(f"    External ({name}, {typ})")
    lines.append("    Scope (\\_SB)")
    lines.append("    {")
    lines.append(gpu.rstrip())
    if smmu:
        lines.append(smmu.rstrip())
    lines.append("    }")
    lines.append("}")
    src = work / "frag.dsl"
    src.write_text("\n".join(lines) + "\n")
    p = run([iasl(), "-p", str(work / "frag"), str(src)])
    aml = work / "frag.aml"
    if p.returncode != 0 or not aml.exists():
        sys.exit("fragment compile failed:\n" + p.stdout + p.stderr)
    data = aml.read_bytes()
    # iasl emits the External decls (0x15 ops, wrapped in an If(0)) before the
    # Scope. Anchor on the Scope(\_SB) name: RootChar + the single NameSeg
    # "_SB_" = 5C 5F 53 42 5F. This is unique -- the externals encode \_SB.XXXX
    # as 5C 2E ... (DualNamePrefix) and the GpioIo "\_SB.GIO0" string has a '.'
    # (2E) byte, so neither contains 5C 5F 53 42 5F.
    anchor = data.find(b"\x5c\x5f\x53\x42\x5f")
    if anchor < 0 or data.count(b"\x5c\x5f\x53\x42\x5f") != 1:
        sys.exit("could not uniquely locate the Scope(\\_SB) name in the fragment")
    # the ScopeOp (0x10) sits 1-4 PkgLength bytes before the name
    scope = next((i for i in range(anchor - 1, anchor - 6, -1) if data[i] == 0x10), -1)
    if scope < 0:
        sys.exit("ScopeOp (0x10) not found before the Scope(\\_SB) name")
    blob = data[scope:]
    return blob


def splice(base: bytes, blob: bytes, rev: int) -> bytearray:
    out = bytearray(base) + blob
    struct.pack_into("<I", out, 4, len(out))       # DSDT length
    struct.pack_into("<I", out, 24, rev)           # OEM revision
    out[9] = 0
    out[9] = (-sum(out)) & 0xFF                     # checksum: whole table sums to 0
    return out


def verify(aml: bytes, work: Path, want_smmu: bool) -> tuple[list[str], bool]:
    report, ok = [], True

    def check(label: str, cond: bool) -> None:
        nonlocal ok
        report.append(f"{'OK ' if cond else 'BAD'} {label}")
        ok = ok and cond

    check("sig==DSDT", aml[:4] == b"DSDT")
    check(f"length field 0x{struct.unpack_from('<I', aml, 4)[0]:x} == file 0x{len(aml):x}",
          struct.unpack_from("<I", aml, 4)[0] == len(aml))
    check("checksum sums to 0", sum(aml) & 0xFF == 0)
    rev = struct.unpack_from("<I", aml, 24)[0]
    check(f"OEM revision {rev} >= 4", rev >= 4)
    i = aml.find(b"SOSI")
    sosi_qword = i >= 0 and aml[i + 4] == 0x0E and aml[i + 5:i + 13] == struct.pack("<Q", 0x80907228)
    check("SOSI is 8-byte QWord 0x80907228 (untouched)", sosi_qword)
    for nm, want in ((b"QCOM253A", True), (b"QCOM2509", want_smmu),
                     (b"QCOM2519", False), (b"ENGINES", True),
                     (b"GraphicsGmuPT", True), (b"GraphicsGlobalPT", True)):
        check(f"{nm.decode()} present == {want}", (nm in aml) == want)
    # structural validity: iasl must be able to disassemble the result
    rt = work / "verify.aml"
    rt.write_bytes(aml)
    p = run([iasl(), "-d", str(rt)])
    check("iasl -d disassembles cleanly", p.returncode == 0)
    return report, ok


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", required=True, type=Path, help="live firmware DSDT .aml (dumped from the tablet)")
    ap.add_argument("--gpu", required=True, type=Path, help="GPU0 node .asl (bare Device)")
    ap.add_argument("--smmu", type=Path, help="SMMU nodes .asl (bare Device MMU0/MMU1)")
    ap.add_argument("--rev", type=int, default=4, help="OEM revision (default 4, must be > firmware's 3)")
    ap.add_argument("--out", required=True, type=Path, help="output overlay .aml")
    ns = ap.parse_args()
    if ns.rev < 4:
        sys.exit("--rev must be >= 4 to override the firmware (rev 3)")

    base = ns.base.read_bytes()
    if base[:4] != b"DSDT":
        sys.exit("--base is not a DSDT")
    if b"SOSI" not in base:
        sys.exit("--base has no SOSI; is it the real firmware DSDT?")

    gpu = ns.gpu.read_text()
    smmu = ns.smmu.read_text() if ns.smmu else None
    with tempfile.TemporaryDirectory() as td:
        work = Path(td)
        blob = compile_fragment(gpu, smmu, work)
        aml = splice(base, blob, ns.rev)
        ns.out.write_bytes(aml)
        report, ok = verify(bytes(aml), work, want_smmu=bool(smmu))

    print(f"== {ns.out} ({len(aml)} bytes, +{len(blob)} spliced) ==")
    for line in report:
        print("  " + line)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
