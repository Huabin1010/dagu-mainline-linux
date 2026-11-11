#!/usr/bin/env python3
"""Triage an ARM64 Windows kernel crash dump without WinDbg.

Handles the SDMPDUMP bitmap kernel dump that dagu's Windows writes (PAGEDU64
outer header + "SDMPDUMP" bitmap at 0x2000) and full run-based dumps. Resolves
the bugcheck, walks PsLoadedModuleList, reads the crash CONTEXT, and
(optionally) disassembles the faulting instruction in a given driver image.

  dagu-dump-triage.py MEMORY.DMP [qcdxkm8250.sys]
  dagu-dump-triage.py --qcdx-log MEMORY.DMP     # qcdx ERR/WRN/INF rings

The dump may also be pagefile.sys: Windows writes the dump there first and
only copies it to MEMORY.DMP on the next successful boot.

Why this exists: this build has no kd/cdb, aka.ms/windbg 403s, and the dumps are
full bitmap kernel dumps (not triage minidumps), so the stage-2 triage.py does
not apply. See docs/woa-dagu-gpu-stage11-*.md.
"""
import struct, sys

TBL = 0x0000FFFFFFFFF000


class DumpError(Exception):
    pass


class Dump:
    """Physical and kernel-virtual reads over a PAGEDU64 dump file."""

    def __init__(self, f):
        self.f = f
        hdr = f.read(0x2000)
        if hdr[:8] != b"PAGEDU64":
            raise DumpError("not a PAGEDU64 dump: %r" % hdr[:8])
        self.hdr = hdr
        self.dirbase = struct.unpack_from("<Q", hdr, 0x10)[0]
        self.pslml = struct.unpack_from("<Q", hdr, 0x20)[0]
        self.bugcheck = struct.unpack_from("<I", hdr, 0x38)[0]
        self.params = [struct.unpack_from("<Q", hdr, 0x40 + 8*i)[0] for i in range(4)]
        f.seek(0, 2)
        self.fsize = f.tell()
        f.seek(0x2000)
        bh = f.read(0x40)
        if bh[:8] == b"SDMPDUMP":
            self._init_bitmap(bh)
        else:
            self._init_runs(bh)
        self._mods = None

    def _init_bitmap(self, bh):
        self.layout = "bitmap"
        self.data_start = struct.unpack_from("<Q", bh, 0x20)[0]
        total_pages = struct.unpack_from("<Q", bh, 0x30)[0]
        self.f.seek(0x2038)
        bitmap = self.f.read((total_pages + 7)//8)
        n = len(bitmap)//8
        self.words = list(struct.unpack_from("<%dQ" % n, bitmap, 0))
        self.pre = [0]*(n+1)
        for i, w in enumerate(self.words):
            self.pre[i+1] = self.pre[i] + bin(w).count("1")

    def _init_runs(self, bh):
        # Full (run-based) dump, DumpType 1: PHYSICAL_MEMORY_DESCRIPTOR at
        # 0x88 = NumberOfRuns, NumberOfPages, then {BasePage, PageCount}
        # pairs; page data starts at 0x2000 in run order.
        nruns = struct.unpack_from("<Q", self.hdr, 0x88)[0]
        if not 0 < nruns < 256:
            raise DumpError("unknown dump layout: %r runs=%d" % (bh[:8], nruns))
        self.layout = "runs"
        self.runs = []
        off = 0x2000
        for i in range(nruns):
            base_pg, cnt = struct.unpack_from("<QQ", self.hdr, 0x98 + 16*i)
            self.runs.append((base_pg, cnt, off))
            off += cnt * 0x1000

    def pa2off(self, pa):
        pg = pa >> 12
        if self.layout == "bitmap":
            w = pg >> 6; b = pg & 63
            if w >= len(self.words) or not (self.words[w] >> b) & 1:
                return None
            o = self.data_start + (self.pre[w] + bin(self.words[w] & ((1 << b)-1)).count("1"))*0x1000
            return o + (pa & 0xFFF)
        for base_pg, cnt, o in self.runs:
            if base_pg <= pg < base_pg + cnt:
                o = o + (pg - base_pg)*0x1000 + (pa & 0xFFF)
                return o if o < self.fsize else None
        return None

    def rdpa(self, pa, n):
        o = self.pa2off(pa)
        if o is None:
            return None
        self.f.seek(o)
        return self.f.read(n)

    def tr(self, va):
        tb = self.dirbase & TBL
        idx = [(va>>39)&0x1FF, (va>>30)&0x1FF, (va>>21)&0x1FF, (va>>12)&0x1FF]
        for lvl in range(4):
            e = self.rdpa(tb + idx[lvl]*8, 8)
            if not e:
                return None
            d = struct.unpack("<Q", e)[0]
            if not d & 1:
                return None
            if d & 3 == 1:
                if lvl == 1: return (d & TBL) | (va & 0x3FFFFFFF)
                if lvl == 2: return (d & TBL) | (va & 0x1FFFFF)
                return None
            tb = d & TBL
        return tb | (va & 0xFFF)

    def rdva(self, va, n):
        """Bytes at a kernel VA, or None if the first page is missing.
        A read that runs into a missing page returns the readable prefix."""
        out = b""
        while n > 0:
            pa = self.tr(va)
            if pa is None:
                return out or None
            c = min(0x1000-(va & 0xFFF), n)
            b = self.rdpa(pa, c)
            if b is None:
                return out or None
            out += b; va += c; n -= c
        return out

    def u32(self, va):
        b = self.rdva(va, 4)
        return struct.unpack("<I", b)[0] if b and len(b) == 4 else None

    def u64(self, va):
        b = self.rdva(va, 8)
        return struct.unpack("<Q", b)[0] if b and len(b) == 8 else None

    def modules(self):
        if self._mods is not None:
            return self._mods
        mods = []
        cur = self.u64(self.pslml)
        for _ in range(500):
            if cur is None or cur == self.pslml:
                break
            base = self.u64(cur+0x30); size = self.u32(cur+0x40)
            ln = self.rdva(cur+0x58, 2); buf = self.u64(cur+0x60); nxt = self.u64(cur)
            if None in (base, size, ln, buf, nxt):
                break
            ln = struct.unpack("<H", ln)[0]
            s = self.rdva(buf, ln) if ln and buf else None
            mods.append((base, size, s.decode("utf-16le", "replace") if s else "?"))
            cur = nxt
        self._mods = mods
        return mods

    def module(self, name):
        name = name.lower()
        for base, size, n in self.modules():
            if n.lower() == name:
                return base, size
        return None

    def who(self, va):
        for base, size, name in self.modules():
            if base <= va < base+size:
                return "%s+0x%x" % (name, va-base)
        return "0x%x" % va


# qcdxkm8250.sys keeps three in-memory log rings, written by 0x107d8 through
# the wrappers 0x10920 (ERR), 0x10960 (WRN), 0x109a0 (INF). Each record is
# 0x28 bytes: u64 timestamp, u32 sequence, u32 caller LR (low 32 bits of
# the return address into qcdx), u32 p1..p5, u32 event code. The slot is
# (index++ mod capacity); sequence is shared by all three rings. RVAs are for
# the qcdx8250 package in tmp/gpu-1110/pkg/qcdx (image base 0x140000000).
QCDX_RINGS = (
    # name, buffer pointer, capacity, write index
    ("ERR", 0x1C6B80, 0x1C6BAC, 0x1C6C04),
    ("WRN", 0x1C6C18, 0x1C6C48, 0x1C6B7C),
    ("INF", 0x1C6C58, 0x1C6BF0, 0x1C6C2C),
)
QCDX_REC = 0x28


def parse_ring(blob, cap, index):
    """Records of one ring, oldest first. index is the next slot to write
    (monotonic); only min(index, cap) slots have ever been written."""
    used = min(index, cap)
    out = []
    for k in range(used):
        slot = (index - used + k) % cap
        o = slot * QCDX_REC
        if o + QCDX_REC > len(blob):
            break
        ts, seq, lr, p1, p2, p3, p4, p5, code = struct.unpack_from("<QIIIIIIII", blob, o)
        out.append({"ts": ts, "seq": seq, "lr": lr, "p": (p1, p2, p3, p4, p5), "code": code})
    return out


def qcdx_log(dump, image="qcdxkm8250.sys"):
    """Merged ERR/WRN/INF records in sequence order, each tagged with its ring
    and the caller as a qcdx RVA. Raises DumpError if qcdx is not loaded."""
    m = dump.module(image)
    if not m:
        raise DumpError("%s not in the loaded module list" % image)
    base, size = m
    recs = []
    for name, p_buf, p_cap, p_idx in QCDX_RINGS:
        buf = dump.u64(base + p_buf); cap = dump.u32(base + p_cap); idx = dump.u32(base + p_idx)
        if not buf or not cap or idx is None:
            continue
        blob = dump.rdva(buf, cap * QCDX_REC) or b""
        for r in parse_ring(blob, cap, idx):
            r["ring"] = name
            # The LR is stored truncated to 32 bits; rebuild it against the
            # module base so it reads as a qcdx RVA.
            full = (base & ~0xFFFFFFFF) | r["lr"]
            if full < base:
                full += 1 << 32
            r["rva"] = full - base if base <= full < base + size else None
            recs.append(r)
    recs.sort(key=lambda r: r["seq"])
    return recs


def print_qcdx_log(dump, last=120):
    recs = qcdx_log(dump)
    print("qcdx log: %d records (showing last %d)" % (len(recs), min(last, len(recs))))
    for r in recs[-last:]:
        where = "qcdx+0x%x" % r["rva"] if r["rva"] is not None else "lr=0x%x" % r["lr"]
        print("  #%-6d %s code=0x%-5x %-18s %s" % (
            r["seq"], r["ring"], r["code"], where, " ".join("%x" % p for p in r["p"])))


def triage(dump, drv=None):
    bc, params, hdr = dump.bugcheck, dump.params, dump.hdr
    print("bugcheck=0x%x" % bc, "params=", [hex(x) for x in params])
    if dump.layout == "runs":
        print("full dump: %d runs, %d pages, file holds %d" % (
            len(dump.runs), sum(r[1] for r in dump.runs), (dump.fsize - 0x2000) // 0x1000))
    mods = dump.modules()
    who = dump.who
    print("modules=%d" % len(mods))
    fault_rva = fault_mod = None
    def set_fault(pc):
        nonlocal fault_rva, fault_mod
        for base, size, name in mods:
            if base <= pc < base+size and drv and name.lower() in drv.lower():
                fault_rva, fault_mod = pc-base, name
    if bc == 0x3b:
        # P3 points at the CONTEXT of the faulting instruction.
        ctx = dump.rdva(params[2], 0x120)
    else:
        # Other bugchecks: use the CONTEXT saved in the dump header (the CPU
        # that called KeBugCheckEx); its stack still holds the trap frame.
        ctx = hdr[0x348:0x348+0x120]
    if bc in (0xa, 0xd1):
        # IRQL_NOT_LESS_OR_EQUAL / DRIVER_IRQL_NOT_LESS_OR_EQUAL: P1=address,
        # P2=IRQL, P3=0 read / 1 write / 8 execute, P4=faulting PC.
        print("fault: %s %s @ IRQL %d, Pc=%s" % (
            {0: "read", 1: "write", 8: "execute"}.get(params[2], "op%d" % params[2]),
            hex(params[0]), params[1], who(params[3])))
        set_fault(params[3])
    if ctx:
        regs = struct.unpack_from("<29Q", ctx, 8)
        fp, lr, sp, pc = struct.unpack_from("<QQQQ", ctx, 0xf0)
        print("Pc=%s  Lr=%s  Sp=0x%x" % (who(pc), who(lr), sp))
        print("  " + " ".join("x%d=%x" % (i, r) for i, r in enumerate(regs)))
        if bc == 0x3b:
            set_fault(pc)
        span = 0x800 if bc == 0x3b else 0x3000
        stk = dump.rdva(sp, span)
        if stk:
            print("stack return-address candidates (sp..sp+0x%x):" % span)
            seen = set()
            for o in range(0, len(stk) - 7, 8):
                v = struct.unpack_from("<Q", stk, o)[0] & 0x0000FFFFFFFFFFFF | 0xFFFF000000000000
                w = who(v)
                if not w.startswith("0x") and v not in seen:
                    seen.add(v); print("  sp+0x%x: %s" % (o, w))

    if drv and fault_rva is not None:
        try:
            from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN
        except ImportError:
            return
        d = open(drv, "rb").read()
        pe = struct.unpack_from("<I", d, 0x3c)[0]
        nsec = struct.unpack_from("<H", d, pe+6)[0]; optsz = struct.unpack_from("<H", d, pe+20)[0]
        def r2o(rva):
            for i in range(nsec):
                o = pe+24+optsz+i*40
                vs, va, rs, ra = struct.unpack_from("<IIII", d, o+8)
                if va <= rva < va+max(vs, rs): return ra+(rva-va)
        md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
        print("\nfault @ %s+0x%x disasm:" % (fault_mod, fault_rva))
        o = r2o(fault_rva-0x20)
        for insn in md.disasm(d[o:o+0x40], fault_rva-0x20):
            print("  0x%06x: %-8s %s%s" % (insn.address, insn.mnemonic, insn.op_str,
                                           " <<< FAULT" if insn.address == fault_rva else ""))


def main(argv):
    qlog = "--qcdx-log" in argv
    args = [a for a in argv if a != "--qcdx-log"]
    if not args:
        sys.exit(__doc__)
    try:
        dump = Dump(open(args[0], "rb"))
        if qlog:
            print("bugcheck=0x%x" % dump.bugcheck, "params=", [hex(x) for x in dump.params])
            print_qcdx_log(dump)
        else:
            triage(dump, args[1] if len(args) > 1 else None)
    except DumpError as e:
        sys.exit(str(e))


if __name__ == "__main__":
    main(sys.argv[1:])
