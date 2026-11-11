#!/usr/bin/env python3
"""Triage an ARM64 Windows kernel crash dump without WinDbg.

Handles the SDMPDUMP bitmap kernel dump that dagu's Windows writes (PAGEDU64
outer header + "SDMPDUMP" bitmap at 0x2000). Resolves the bugcheck, walks
PsLoadedModuleList, reads the crash CONTEXT, and (optionally) disassembles the
faulting instruction in a given driver image.

  dagu-dump-triage.py MEMORY.DMP [qcdxkm8250.sys]

Why this exists: this build has no kd/cdb, aka.ms/windbg 403s, and the dumps are
full bitmap kernel dumps (not triage minidumps), so the stage-2 triage.py does
not apply. See docs/woa-dagu-gpu-stage11-*.md.
"""
import struct, sys

def main():
    dmp = sys.argv[1]
    drv = sys.argv[2] if len(sys.argv) > 2 else None
    f = open(dmp, "rb")
    hdr = f.read(0x2000)
    if hdr[:8] != b"PAGEDU64":
        sys.exit("not a PAGEDU64 dump: %r" % hdr[:8])
    dirbase = struct.unpack_from("<Q", hdr, 0x10)[0]
    pslml   = struct.unpack_from("<Q", hdr, 0x20)[0]
    bc      = struct.unpack_from("<I", hdr, 0x38)[0]
    params  = [struct.unpack_from("<Q", hdr, 0x40 + 8*i)[0] for i in range(4)]
    f.seek(0x2000); bh = f.read(0x40)
    print("bugcheck=0x%x" % bc, "params=", [hex(x) for x in params])
    if bh[:8] == b"SDMPDUMP":
        data_start  = struct.unpack_from("<Q", bh, 0x20)[0]
        total_pages = struct.unpack_from("<Q", bh, 0x30)[0]
        f.seek(0x2038); bitmap = f.read((total_pages + 7)//8)
        words = list(struct.unpack_from("<%dQ" % (len(bitmap)//8), bitmap, 0))
        pre = [0]*(len(words)+1)
        for i, w in enumerate(words):
            pre[i+1] = pre[i] + bin(w).count("1")

        def pa2off(pa):
            pg = pa >> 12; w = pg >> 6; b = pg & 63
            if w >= len(words) or not (words[w] >> b) & 1:
                return None
            return data_start + (pre[w] + bin(words[w] & ((1 << b)-1)).count("1"))*0x1000 + (pa & 0xFFF)
    else:
        # Full (run-based) dump, DumpType 1: PHYSICAL_MEMORY_DESCRIPTOR at
        # 0x88 = NumberOfRuns, NumberOfPages, then {BasePage, PageCount}
        # pairs; page data starts at 0x2000 in run order.
        nruns = struct.unpack_from("<Q", hdr, 0x88)[0]
        if not 0 < nruns < 256:
            sys.exit("unknown dump layout: %r runs=%d" % (bh[:8], nruns))
        runs = []
        off = 0x2000
        for i in range(nruns):
            base_pg, cnt = struct.unpack_from("<QQ", hdr, 0x98 + 16*i)
            runs.append((base_pg, cnt, off))
            off += cnt * 0x1000
        f.seek(0, 2); fsize = f.tell()
        print("full dump: %d runs, %d pages, file holds %d" % (nruns, sum(r[1] for r in runs), (fsize - 0x2000) // 0x1000))

        def pa2off(pa):
            pg = pa >> 12
            for base_pg, cnt, o in runs:
                if base_pg <= pg < base_pg + cnt:
                    o = o + (pg - base_pg)*0x1000 + (pa & 0xFFF)
                    return o if o < fsize else None
            return None

    def rdpa(pa, n):
        o = pa2off(pa)
        if o is None:
            return None
        f.seek(o); return f.read(n)

    TBL = 0x0000FFFFFFFFF000
    def tr(va):
        tb = dirbase & TBL
        idx = [(va>>39)&0x1FF,(va>>30)&0x1FF,(va>>21)&0x1FF,(va>>12)&0x1FF]
        for lvl in range(4):
            e = rdpa(tb + idx[lvl]*8, 8)
            if not e: return None
            d = struct.unpack("<Q", e)[0]
            if not d & 1: return None
            if d & 3 == 1:
                if lvl == 1: return (d & TBL) | (va & 0x3FFFFFFF)
                if lvl == 2: return (d & TBL) | (va & 0x1FFFFF)
                return None
            tb = d & TBL
        return tb | (va & 0xFFF)

    def rdva(va, n):
        out = b""
        while n > 0:
            pa = tr(va)
            if pa is None: return out or None
            c = min(0x1000-(va & 0xFFF), n); b = rdpa(pa, c)
            if b is None: return out or None
            out += b; va += c; n -= c
        return out

    mods = []
    b = rdva(pslml, 16)
    if b:
        cur = struct.unpack("<Q", b[:8])[0]
        for _ in range(500):
            if cur == pslml: break
            base = rdva(cur+0x30, 8); size = rdva(cur+0x40, 4)
            ln = rdva(cur+0x58, 2); buf = rdva(cur+0x60, 8); nxt = rdva(cur, 8)
            if not all((base, size, ln, buf, nxt)): break
            base = struct.unpack("<Q", base)[0]; size = struct.unpack("<I", size)[0]
            ln = struct.unpack("<H", ln)[0]; buf = struct.unpack("<Q", buf)[0]
            s = rdva(buf, ln) if ln and buf else None
            mods.append((base, size, s.decode("utf-16le","replace") if s else "?"))
            cur = struct.unpack("<Q", nxt)[0]

    def who(va):
        for base, size, name in mods:
            if base <= va < base+size:
                return "%s+0x%x" % (name, va-base)
        return "0x%x" % va

    print("modules=%d" % len(mods))
    fault_rva = fault_mod = None
    def set_fault(pc):
        nonlocal fault_rva, fault_mod
        for base, size, name in mods:
            if base <= pc < base+size and drv and name.lower() in drv.lower():
                fault_rva, fault_mod = pc-base, name
    if bc == 0x3b:
        # P3 points at the CONTEXT of the faulting instruction.
        ctx = rdva(params[2], 0x120)
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
        stk = rdva(sp, span)
        if stk:
            print("stack return-address candidates (sp..sp+0x%x):" % span)
            seen = set()
            for o in range(0, len(stk), 8):
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

if __name__ == "__main__":
    main()
