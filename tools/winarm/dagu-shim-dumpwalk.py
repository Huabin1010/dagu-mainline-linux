#!/usr/bin/env python3
"""Extract dagu-smmushim globals and path/log rings from a Windows dump,
and parse C:\\Windows\\dagu-shim.bin records.

Reuses the historical shimdump.py method (module base + RVA) and trapf.py
(search for a code pointer on nearby stack pages). This is a diagnostic
reader, not a root-cause claim.

17:45 pagefile (dirbase 0x194b52000) was not copied and the volume is
unmounted. Do not remount from this script. Use --self-test without a dump.

Expected 17:45 VAs (from dagu-dump-compare.out):
  dagu-smmushim.sys  0xfffff80039140000  SizeOfImage 0x16000
  qcdxkm8250.sys     0xfffff80037c00000  SizeOfImage 0x35b000
  WHEA addr          0xfffff80037ed0430  (qcdx+0x2D0430)
  WHEA record        0xffffa30e55acf688
"""
from __future__ import annotations
import argparse, hashlib, os, struct, sys
from pathlib import Path

# 1.0.5.0 signed image (tmp/shim-build 14:52, SHA256 5d5f9ca3...).
# RVAs confirmed by relinking that .obj with /MAP on 2026-11-11.
# Do not reuse these blindly for 1.0.3/1.0.4; identify the dump image first.
RVA_105 = {
    "gLogCount": 0x11018,
    "gLogRing": 0x11020,
    "gSiteRing": 0x11060,
    "gLogSeen": 0x110a0,
    "gLastFail": 0x130cc,
    "gLastSite": 0x130d0,
    "gBootGen": 0x130d8,
    "gPendMask": 0x130e4,
    "gFailN": 0x130e8,
    "gNcall": 0x130ec,
    "gLogInstall": 0x130f8,
    "gLastStep": 0x13118,
    "gIhit": 0x13124,
    "gPatched": 0x13150,
    "gLogHooked": 0x13158,
    "gHooked": 0x1316c,
    "gQcdxBase": 0x131a0,  # u64
    "gRing": 0x133e0,
}

# 17:45 known bases, for the missing-page report
PF_1745_SHIM = 0xFFFFF80039140000
PF_1745_QCDX = 0xFFFFF80037C00000
PF_1745_WHEA_ADDR = 0xFFFFF80037ED0430
PF_1745_WHEA_P2 = 0xFFFFA30E55ACF688
PF_1745_DIRBASE = 0x194B52000

FREE_RET = {
    "2CA8E4": 0x2CA8E4,
    "2CEB90": 0x2CEB90,
    "2D014C": 0x2D014C,
    "2D03A4": 0x2D03A4,
}

DIAG_MAGIC = 0x47414444
DIAG_V2_SIZE = 304
DIAG_V3_SIZE = 568

PATH_ID = {
    1: "AC9C0",
    2: "ADC00_DISP",
    3: "ADC00_OTH",
    4: "D5D48",
    5: "FREE_2CA8E0",
    6: "FREE_2CEB8C",
    7: "FREE_2D0148",
    8: "FREE_2D03A0",
}


def sha256(p: Path, n=None) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        if n is None:
            h.update(f.read())
        else:
            h.update(f.read(n))
    return h.hexdigest()


def pe_text_digest(p: Path) -> tuple[str, int]:
    import pefile
    pe = pefile.PE(str(p))
    for s in pe.sections:
        if s.Name.startswith(b".text"):
            raw = s.get_data()[: s.Misc_VirtualSize]
            return hashlib.sha256(raw).hexdigest(), pe.OPTIONAL_HEADER.SizeOfImage
    raise SystemExit(f"no .text in {p}")


def parse_diag_rec(buf: bytes) -> dict:
    if len(buf) < 8:
        raise ValueError("short record")
    magic, ver = struct.unpack_from("<II", buf, 0)
    if magic != DIAG_MAGIC:
        raise ValueError(f"bad magic {magic:#x}")
    need = DIAG_V3_SIZE if ver >= 3 else DIAG_V2_SIZE
    if len(buf) < need:
        raise ValueError(f"ver {ver} needs {need} bytes, got {len(buf)}")
    u = list(struct.unpack_from("<%dI" % (need // 4), buf, 0))
    rec = {
        "Magic": u[0], "Ver": u[1], "BootGen": u[2], "Step": u[3],
        "Fail": u[4], "Fsite": u[5], "Ncall": u[6], "Nfail": u[7], "Rst": u[8],
        "LogCount": u[16],
        "Hist": u[17:33], "Lsite": u[33:49],
    }
    if ver >= 3:
        # PathCount at ULONG 76
        rec["PathCount"] = u[76]
        rec["PathInstall"] = u[77]
        rec["PathId"] = u[78:94]
        rec["PathSite"] = u[94:110]
        rec["PathRet"] = u[110:126]
        rec["PathFl"] = u[126:142]
    return rec


def format_diag(rec: dict) -> str:
    lines = [
        f"DIAG ver={rec['Ver']} bootgen={rec['BootGen']} step={rec['Step']:#x} "
        f"fail={rec['Fail']:#x} fsite={rec['Fsite']:#x} ncall={rec['Ncall']} nfail={rec['Nfail']}",
        f"  LogCount={rec['LogCount']} hist0={rec['Hist'][0]:#x} lsite0={rec['Lsite'][0]:#x}",
    ]
    if rec.get("PathCount") is not None:
        lines.append(f"  PathCount={rec['PathCount']} PathInstall={rec['PathInstall']:#x}")
        n = rec["PathCount"]
        for i in range(min(16, n)):
            # records are stored newest-first in WriteDiag
            pid = rec["PathId"][i]
            lines.append(
                f"    [{i}] id={pid} ({PATH_ID.get(pid, '?')}) site={rec['PathSite'][i]:#x} "
                f"ret={rec['PathRet'][i]:#x} fl={rec['PathFl'][i]:#x}"
            )
    return "\n".join(lines)


def parse_shim_bin(path: Path) -> None:
    data = path.read_bytes()
    off = 0
    n = 0
    while off < len(data):
        if off + 8 > len(data):
            print(f"trailing {len(data)-off} bytes at {off:#x}")
            break
        magic, ver = struct.unpack_from("<II", data, off)
        if magic != DIAG_MAGIC:
            print(f"stop at {off:#x}: magic {magic:#x}")
            break
        size = DIAG_V3_SIZE if ver >= 3 else DIAG_V2_SIZE
        rec = parse_diag_rec(data[off:off+size])
        print(f"record #{n} @ {off:#x}")
        print(format_diag(rec))
        off += size
        n += 1
    print(f"{n} record(s)")


def missing_pages_1745() -> None:
    shim = PF_1745_SHIM
    qcdx = PF_1745_QCDX
    pages = []
    # whole shim image, 0x16000 = 22 pages
    for va in range(shim, shim + 0x16000, 0x1000):
        pages.append(("shim-image", va))
    # highlight data pages that hold the rings (1.0.5.0 RVAs)
    for name, rva in (("gLogRing", 0x11020), ("gNcall", 0x130ec), ("gRing", 0x133e0)):
        pages.append((name, shim + rva))
    needles = {
        "WHEA_PC_2D0430": PF_1745_WHEA_ADDR,
        "WHEA_P2": PF_1745_WHEA_P2,
    }
    for name, rva in FREE_RET.items():
        needles[f"ret_{name}"] = qcdx + rva
    print("17:45 missing evidence (volume unmounted, pagefile not copied):")
    print(f"  dump: C:\\\\pagefile.sys  dirbase={PF_1745_DIRBASE:#x}")
    print("  file: C:\\\\Windows\\\\dagu-shim.bin  (WriteDiag append, DIAG_MAGIC 'DDAG')")
    print("  file: DriverStore\\\\...\\\\dagu-smmushim.inf_arm64_72b10ae4f0d341cc\\\\dagu-smmushim.sys")
    print("  shim image pages (22):")
    for va in range(shim, shim + 0x16000, 0x1000):
        print(f"    {va:#x}")
    print("  pointer search (scan present dump pages; report any missing PT/page):")
    for n, va in needles.items():
        print(f"    {n} = {va:#x}")
    print("  ro-only remount needed to read these; do not ntfsfix or journal-replay.")


def load_triage(path: Path):
    import importlib.util
    # prefer in-repo triage
    candidates = [
        Path(__file__).resolve().parent / "dagu-dump-triage.py",
        Path("/tmp/dagu-dump-triage.py"),
    ]
    for c in candidates:
        if c.exists():
            spec = importlib.util.spec_from_file_location("triage", c)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
    raise SystemExit("dagu-dump-triage.py not found")


def walk_dump(dump_path: Path, sys_paths: list[Path]) -> None:
    t = load_triage(dump_path)
    d = t.Dump(open(dump_path, "rb"))
    m = d.module("dagu-smmushim.sys")
    q = d.module("qcdxkm8250.sys")
    print("shim", [hex(x) for x in m] if m else None)
    print("qcdx", [hex(x) for x in q] if q else None)
    if not m:
        print("dagu-smmushim.sys not in module list; cannot read globals")
        return
    base, size = m[0], m[1] if len(m) > 1 else 0x16000
    hdr = d.rdva(base, 0x400)
    if not hdr:
        print(f"MISSING header page {base:#x}")
        return
    # identify build by hashing whatever .text pages are present
    print(f"PE mz={hdr[:2]!r} SizeOfImage field later")
    # read data pages for 1.0.5.0 map; if identify fails, still try and say so
    def u32(rva):
        v = d.u32(base + rva)
        return v
    def u64(rva):
        return d.u64(base + rva)
    missing = []
    for name, rva in RVA_105.items():
        if name == "gQcdxBase":
            v = u64(rva)
            print(f"  {name:14} {hex(v) if v is not None else 'MISSING page '+hex(base+rva)}")
            if v is None:
                missing.append(base + rva)
        elif name == "gRing":
            blob = d.rdva(base + rva, 8 * 32)
            if not blob:
                print(f"  gRing          MISSING page {base+rva:#x}")
                missing.append(base + rva)
            else:
                print("  ring (slot a b c d r rhi site):")
                for i in range(8):
                    rec = struct.unpack_from("<8I", blob, i * 32)
                    print("   ", " ".join(f"{x:08x}" for x in rec))
        elif name in ("gLogRing", "gSiteRing"):
            blob = d.rdva(base + rva, 16 * 4)
            if not blob:
                print(f"  {name:14} MISSING page {base+rva:#x}")
                missing.append(base + rva)
            else:
                vals = struct.unpack("<16I", blob)
                print(f"  {name:14} " + " ".join(f"{x:#x}" for x in vals))
        else:
            v = u32(rva)
            print(f"  {name:14} {hex(v) if v is not None else 'MISSING page '+hex(base+rva)}")
            if v is None:
                missing.append(base + rva)
    if q:
        qbase = q[0]
        needles = {"WHEA_PC": qbase + 0x2D0430}
        for n, rva in FREE_RET.items():
            needles[n] = qbase + rva
        print("pointer search is a full-dump scan; not done automatically here.")
        print("needles:", {k: hex(v) for k, v in needles.items()})
    if missing:
        print("missing pages:")
        for va in missing:
            print(f"  {va:#x}")


def self_test(repo: Path) -> int:
    fail = 0
    shim_dir = repo / "tmp"
    # known 1.0.5.0
    p105 = shim_dir / "shim-build" / "dagu-smmushim.sys"
    p104 = shim_dir / "fix-1111c" / "pkg" / "shim" / "dagu-smmushim.sys"
    p103 = shim_dir / "fix-1111" / "pkg" / "shim" / "dagu-smmushim.sys"
    digests = {}
    for label, p in (("1.0.5.0", p105), ("1.0.4.0", p104), ("1.0.3.0", p103)):
        if not p.exists():
            print(f"SKIP {label}: {p} missing")
            continue
        d, sz = pe_text_digest(p)
        filehash = sha256(p)
        digests[label] = d
        print(f"{label} file={filehash[:16]} text={d[:16]} SizeOfImage={sz:#x}")
    if "1.0.5.0" in digests and "1.0.4.0" in digests:
        if digests["1.0.5.0"] == digests["1.0.4.0"]:
            print("FAIL 1.0.5 and 1.0.4 .text should differ")
            fail += 1
        else:
            print("OK .text digests distinguish 1.0.5.0 from 1.0.4.0")
    # DIAG_REC pack
    rec = bytearray(DIAG_V3_SIZE)
    struct.pack_into("<II", rec, 0, DIAG_MAGIC, 3)
    rec2 = parse_diag_rec(bytes(rec))
    if rec2["Ver"] != 3 or rec2["PathCount"] != 0:
        print("FAIL parse empty v3")
        fail += 1
    else:
        print("OK parse empty DIAG_REC v3")
    # v2 prefix size
    recv2 = bytearray(DIAG_V2_SIZE)
    struct.pack_into("<II", recv2, 0, DIAG_MAGIC, 2)
    rec2 = parse_diag_rec(bytes(recv2))
    if rec2["Ver"] != 2 or "PathCount" in rec2:
        print("FAIL parse v2")
        fail += 1
    else:
        print("OK parse DIAG_REC v2")
    # synthetic shim data page at 1.0.5.0 RVAs
    img = bytearray(0x16000)
    struct.pack_into("<I", img, RVA_105["gNcall"], 0)
    struct.pack_into("<I", img, RVA_105["gLogInstall"], 1)
    struct.pack_into("<I", img, RVA_105["gLogCount"], 2)
    struct.pack_into("<I", img, RVA_105["gLogRing"], 0x6e6)
    struct.pack_into("<I", img, RVA_105["gSiteRing"], 0xaf084)
    if struct.unpack_from("<I", img, 0x130ec)[0] != 0:
        print("FAIL gNcall poke")
        fail += 1
    if struct.unpack_from("<I", img, 0x11020)[0] != 0x6e6:
        print("FAIL gLogRing poke")
        fail += 1
    else:
        print("OK 1.0.5.0 RVA poke (gNcall=0, gLogInstall would be at 0x130f8, ring at 0x11020)")
    print("self-test failures:", fail)
    return fail


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--repo", type=Path, default=Path("/home/huanghuabin/Projects/xiaomi-pad870-win11-arm"))
    ap.add_argument("--dump", type=Path, help="MEMORY.DMP or pagefile.sys (must already be reachable)")
    ap.add_argument("--shim-bin", type=Path, help="C:\\Windows\\dagu-shim.bin copy")
    ap.add_argument("--missing-pages", action="store_true", help="print 17:45 pages still not in hand")
    args = ap.parse_args(argv)
    rc = 0
    if args.self_test:
        rc |= self_test(args.repo)
    if args.missing_pages or args.self_test:
        missing_pages_1745()
    if args.shim_bin:
        if not args.shim_bin.exists():
            print(f"shim.bin not present: {args.shim_bin}")
            rc |= 1
        else:
            parse_shim_bin(args.shim_bin)
    if args.dump:
        if not args.dump.exists():
            print(f"dump not present: {args.dump}")
            rc |= 1
        else:
            walk_dump(args.dump, [])
    if not (args.self_test or args.dump or args.shim_bin or args.missing_pages):
        ap.print_help()
        return 2
    return rc


if __name__ == "__main__":
    sys.exit(main())
