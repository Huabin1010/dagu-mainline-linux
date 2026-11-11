#!/usr/bin/env python3
"""Tests for dagu-dump-triage.py: qcdx log rings and dump address mapping.

  python3 tools/winarm/test_dagu_dump_triage.py
"""
import importlib.util
import io
import os
import re
import struct
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.abspath(os.path.join(_HERE, "..", ".."))
_spec = importlib.util.spec_from_file_location("triage", os.path.join(_HERE, "dagu-dump-triage.py"))
triage = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(triage)

REC = triage.QCDX_REC
PAGE = 0x1000
KBASE = 0xFFFF800000000000          # kernel VA base used by the fake dumps
QCDX_BASE = 0xFFFFF80297A00000      # qcdx base from the 2026-11-11 dump
PSLML = KBASE + 0x1000              # PsLoadedModuleList head
ENTRY = KBASE + 0x2000              # one KLDR_DATA_TABLE_ENTRY
NAME = KBASE + 0x3000


def rec(ts, seq, lr, code, p=(0, 0, 0, 0, 0)):
    return struct.pack("<QIIIIIIII", ts, seq, lr, *p, code)


def build_dump(pages, dirbase, bugcheck=0xA, params=(0, 2, 0, 0)):
    """Full (run-based) PAGEDU64 dump holding the given {pfn: bytes} pages."""
    pfns = sorted(pages)
    runs = []
    for pfn in pfns:
        if runs and runs[-1][0] + runs[-1][1] == pfn:
            runs[-1][1] += 1
        else:
            runs.append([pfn, 1])
    hdr = bytearray(0x2000)
    hdr[:8] = b"PAGEDU64"
    struct.pack_into("<Q", hdr, 0x10, dirbase)
    struct.pack_into("<Q", hdr, 0x20, PSLML)
    struct.pack_into("<I", hdr, 0x38, bugcheck)
    struct.pack_into("<4Q", hdr, 0x40, *params)
    struct.pack_into("<QQ", hdr, 0x88, len(runs), len(pfns))
    for i, (base, cnt) in enumerate(runs):
        struct.pack_into("<QQ", hdr, 0x98 + 16 * i, base, cnt)
    body = b"".join(bytes(pages[p]).ljust(PAGE, b"\0") for p in pfns)
    return io.BytesIO(bytes(hdr) + body)


class Mem:
    """Kernel VA -> pages, with a 4-level AArch64 table like the real dump."""

    def __init__(self):
        self.pages = {}
        self.next_pfn = 0x100
        self.root = self._alloc()

    def _alloc(self):
        pfn = self.next_pfn
        self.next_pfn += 1
        self.pages[pfn] = bytearray(PAGE)
        return pfn

    def _leaf(self, va):
        table = self.root
        for shift in (39, 30, 21, 12):
            idx = (va >> shift) & 0x1FF
            ent = struct.unpack_from("<Q", self.pages[table], idx * 8)[0]
            if not ent & 1:
                ent = (self._alloc() << 12) | 3
                struct.pack_into("<Q", self.pages[table], idx * 8, ent)
            table = (ent & triage.TBL) >> 12
        return table

    def write(self, va, data):
        while data:
            pfn = self._leaf(va)
            o = va & 0xFFF
            n = min(PAGE - o, len(data))
            self.pages[pfn][o:o + n] = data[:n]
            va += n
            data = data[n:]

    def dump(self):
        return build_dump(self.pages, self.root << 12)


def qcdx_memory(rings, image_size=0x35B000, with_module=True):
    """rings: {"ERR"|"WRN"|"INF": (capacity, write index, [records])}."""
    m = Mem()
    if with_module:
        name = "qcdxkm8250.sys".encode("utf-16le")
        m.write(PSLML, struct.pack("<QQ", ENTRY, ENTRY))
        e = bytearray(0x70)
        struct.pack_into("<QQ", e, 0, PSLML, PSLML)
        struct.pack_into("<Q", e, 0x30, QCDX_BASE)
        struct.pack_into("<I", e, 0x40, image_size)
        struct.pack_into("<HH", e, 0x58, len(name), len(name))
        struct.pack_into("<Q", e, 0x60, NAME)
        m.write(ENTRY, bytes(e))
        m.write(NAME, name)
    else:
        m.write(PSLML, struct.pack("<QQ", PSLML, PSLML))
    bufva = KBASE + 0x100000
    for ring, p_buf, p_cap, p_idx in triage.QCDX_RINGS:
        if ring not in rings:
            continue
        cap, index, recs = rings[ring]
        m.write(QCDX_BASE + p_buf, struct.pack("<Q", bufva))
        m.write(QCDX_BASE + p_cap, struct.pack("<I", cap))
        m.write(QCDX_BASE + p_idx, struct.pack("<I", index))
        m.write(bufva, b"".join(recs).ljust(cap * REC, b"\0"))
        bufva += 0x10000
    return m


class ParseRingTest(unittest.TestCase):
    def test_partial_ring_returns_written_slots_in_order(self):
        blob = rec(10, 0, 0x100, 0x12F) + rec(20, 1, 0x200, 0x141) + b"\0" * REC * 2

        out = triage.parse_ring(blob, cap=4, index=2)

        self.assertEqual([r["code"] for r in out], [0x12F, 0x141])
        self.assertEqual([r["seq"] for r in out], [0, 1])

    def test_wrapped_ring_starts_at_oldest_slot(self):
        # cap 3 and index 7: slot 0 holds seq 6, so the oldest is slot 1.
        blob = rec(6, 6, 0, 0xD) + rec(4, 4, 0, 0xB) + rec(5, 5, 0, 0xC)

        out = triage.parse_ring(blob, cap=3, index=7)

        self.assertEqual([r["seq"] for r in out], [4, 5, 6])

    def test_exactly_full_ring_reads_from_slot_zero(self):
        blob = rec(3, 3, 0, 0xA) + rec(4, 4, 0, 0xB) + rec(5, 5, 0, 0xC)

        out = triage.parse_ring(blob, cap=3, index=3)

        self.assertEqual([r["seq"] for r in out], [3, 4, 5])

    def test_empty_ring_returns_nothing(self):
        self.assertEqual(triage.parse_ring(b"\0" * REC * 4, cap=4, index=0), [])

    def test_truncated_blob_stops_at_last_full_record(self):
        blob = rec(1, 0, 0, 0x1) + rec(2, 1, 0, 0x2)[:REC - 1]

        out = triage.parse_ring(blob, cap=4, index=2)

        self.assertEqual([r["code"] for r in out], [0x1])

    def test_decodes_all_fields(self):
        blob = rec(7, 9, 0x2947F8, 0x998, (0xC00000C0, 0xF8, 0xF9, 0xFA, 0xFB))

        (r,) = triage.parse_ring(blob, cap=1, index=1)

        self.assertEqual(r, {"ts": 7, "seq": 9, "lr": 0x2947F8, "code": 0x998,
                             "p": (0xC00000C0, 0xF8, 0xF9, 0xFA, 0xFB)})


class QcdxLogTest(unittest.TestCase):
    def test_merges_rings_by_sequence_and_resolves_rva(self):
        lo = QCDX_BASE & 0xFFFFFFFF
        m = qcdx_memory({
            "ERR": (256, 2, [rec(5, 1, lo + 0x284CA4, 0x12F), rec(9, 3, lo + 0x2947F8, 0x998)]),
            "WRN": (48, 1, [rec(4, 2, lo + 0x284F7C, 0x1E7)]),
            "INF": (16, 1, [rec(1, 0, lo + 0x10, 0x7)]),
        })

        out = triage.qcdx_log(triage.Dump(m.dump()))

        self.assertEqual([(r["seq"], r["ring"], r["code"]) for r in out],
                         [(0, "INF", 0x7), (1, "ERR", 0x12F), (2, "WRN", 0x1E7), (3, "ERR", 0x998)])
        self.assertEqual([r["rva"] for r in out], [0x10, 0x284CA4, 0x284F7C, 0x2947F8])

    def test_lr_outside_module_has_no_rva(self):
        m = qcdx_memory({"ERR": (4, 1, [rec(1, 0, 0x12345678, 0x1)])})

        (r,) = triage.qcdx_log(triage.Dump(m.dump()))

        self.assertIsNone(r["rva"])

    def test_ring_with_null_buffer_is_skipped(self):
        m = qcdx_memory({"ERR": (4, 1, [rec(1, 0, 0, 0x1)]), "WRN": (4, 1, [rec(2, 1, 0, 0x2)])})
        m.write(QCDX_BASE + triage.QCDX_RINGS[1][1], struct.pack("<Q", 0))

        out = triage.qcdx_log(triage.Dump(m.dump()))

        self.assertEqual([r["ring"] for r in out], ["ERR"])

    def test_missing_qcdx_module_raises(self):
        m = qcdx_memory({}, with_module=False)

        with self.assertRaisesRegex(triage.DumpError, "not in the loaded module list"):
            triage.qcdx_log(triage.Dump(m.dump()))


class DumpTest(unittest.TestCase):
    def test_rejects_non_pagedu64_file(self):
        with self.assertRaisesRegex(triage.DumpError, "not a PAGEDU64"):
            triage.Dump(io.BytesIO(b"MDMP" + b"\0" * 0x3000))

    def test_unmapped_va_reads_as_none(self):
        dump = triage.Dump(qcdx_memory({}).dump())

        self.assertIsNone(dump.rdva(KBASE + 0x7000000, 8))
        self.assertIsNone(dump.u64(KBASE + 0x7000000))

    def test_run_dump_page_past_file_end_reads_as_none(self):
        m = Mem()
        f = m.dump().getvalue()
        hdr = bytearray(f[:0x2000])
        nruns = struct.unpack_from("<Q", hdr, 0x88)[0]
        base, cnt = struct.unpack_from("<QQ", hdr, 0x98 + 16 * (nruns - 1))
        struct.pack_into("<QQ", hdr, 0x98 + 16 * (nruns - 1), base, cnt + 1)  # claims one extra page

        dump = triage.Dump(io.BytesIO(bytes(hdr) + f[0x2000:]))

        self.assertIsNone(dump.rdpa((base + cnt) << 12, 8))

    def test_bitmap_dump_maps_only_present_pages(self):
        hdr = bytearray(0x2000)
        hdr[:8] = b"PAGEDU64"
        sd = bytearray(0x38)
        sd[:8] = b"SDMPDUMP"
        data_start = 0x3000
        struct.pack_into("<Q", sd, 0x20, data_start)
        struct.pack_into("<Q", sd, 0x30, 128)
        bitmap = bytearray(16)
        bitmap[0] = 0b00000101                       # pfn 0 and 2 present
        f = (bytes(hdr) + bytes(sd) + bytes(bitmap)).ljust(data_start, b"\0")
        f += b"A" * PAGE + b"C" * PAGE

        dump = triage.Dump(io.BytesIO(f))

        self.assertEqual(dump.rdpa(0x0000, 1), b"A")
        self.assertIsNone(dump.rdpa(0x1000, 1))
        self.assertEqual(dump.rdpa(0x2005, 1), b"C")


def _guids_in_c(path):
    with open(path) as fh:
        src = fh.read()
    out = set()
    pat = r"0x([0-9A-Fa-f]{8}),\s*0x([0-9A-Fa-f]{4}),\s*0x([0-9A-Fa-f]{4}),\s*\{([^}]*)\}"
    for m in re.finditer(pat, src):
        b = [int(x, 16) for x in re.findall(r"0x([0-9A-Fa-f]{2})", m.group(4))]
        out.add("{%s-%s-%s-%02x%02x-%s}" % (m.group(1).lower(), m.group(2).lower(), m.group(3).lower(),
                                           b[0], b[1], "".join("%02x" % x for x in b[2:])))
    return out


class QcifGateTest(unittest.TestCase):
    """2-run.cmd must refuse to start qcdx unless every interface it waits on
    is live, and dagu-qcif is what publishes them."""

    def test_gpu_ps1_gate_matches_qcif_published_interfaces(self):
        qcif = _guids_in_c(os.path.join(_REPO, "port/dagu/windows-drivers/dagu-qcif/dagu-qcif.c"))
        with open(os.path.join(_HERE, "gpu-bringup", "gpu.ps1")) as fh:
            ps1 = fh.read()
        block = ps1.split("$QcifIfaces = @(", 1)[1].split(")", 1)[0]
        gate = {g.lower() for g in re.findall(r"\{[0-9a-fA-F-]{36}\}", block)}

        self.assertEqual(len(qcif), 4)
        self.assertEqual(gate, qcif)
        # MemSharing: its absence is what failed StartDevice on 2026-11-11.
        self.assertIn("{eb3c7242-1b1a-4d51-ab55-f268f018f860}", gate)


if __name__ == "__main__":
    unittest.main()
