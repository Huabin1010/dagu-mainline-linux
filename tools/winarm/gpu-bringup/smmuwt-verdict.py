#!/usr/bin/env python3
"""Read the stage 24 dagu-smmuwt result (test=100) out of an offline SYSTEM
hive, the way B-slot Linux sees it after the tablet comes back.

  python3 smmuwt-verdict.py /mnt/w/Windows/System32/config/SYSTEM

The verdict says, per CB0 register, whether a write from Windows EL1 stuck,
was reverted by the hypervisor, or never ran because the SoC reset. A reset
is located by Parameters\\step, which the driver flushes before every write.
"""
import sys

SINGLE = {
    31: "CB0.TTBR1",
    32: "CB0.TCR",
    33: "CB0.TCR2",
    34: "CB0.MAIR0",
    35: "CB0.SCTLR",
    36: "CB0.ACTLR",
    37: "CBA2R0",
    38: "CBAR0",
}
PHASE = {
    0x10: "pre-read",
    0x20: "about to write",
    0x30: "write survived",
    0x40: "readback done",
    0x50: "restored",
}
COMBINED_PHASE = {
    0x01: "ACTLR", 0x02: "CBA2R", 0x03: "CBAR", 0x04: "TCR2/TCR",
    0x05: "TTBR0/TTBR1", 0x06: "MAIR", 0x07: "SCTLR.M=1",
    0x08: "TLB sync", 0x09: "readback", 0x0A: "fault read",
    0x0B: "disable + restore", 0x0C: "done",
}
FIELDS = ("actlr", "cba2r", "cbar", "tcr2", "tcr", "ttbr0", "ttbr1",
          "mair0", "mair1", "sctlr")
DONE = 0x6399


def classify(pre, wr, rb):
    if rb is None:
        return "not run"
    if rb == wr:
        return "stuck"
    if rb == pre:
        return "reverted"
    return "changed"


def where(step):
    """Human text for the last flushed step."""
    if step is None:
        return "driver never ran (no step value)"
    if step == DONE:
        return "programme finished"
    if step == 0x01A2:
        return "stopped: SMMU clocks or GPU CX off, nothing written"
    if step == 0x01E4:
        return "stopped: no contiguous page for the table"
    if step == 0x2700:
        return "combined skipped: a single write did not restore"
    if step == 0x2701:
        return "combined skipped: a stream already translates via CB0"
    nn, ph = step >> 8, step & 0xFF
    if nn in SINGLE:
        return "%s: %s" % (SINGLE[nn], PHASE.get(ph, "phase %#x" % ph))
    if nn == 40:
        return "combined: after %s" % COMBINED_PHASE.get(ph, "phase %#x" % ph)
    return "step %#x" % step


def verdict(p):
    """p: dict of value name -> int. Returns list of report lines."""
    out = []
    step = p.get("step")
    out.append("step %s -> %s" % ("-" if step is None else "%#x" % step, where(step)))
    finished = step == DONE
    reset_at = None if finished or step is None else step
    for nn, name in SINGLE.items():
        pre, wr = p.get("t%d_pre" % nn), p.get("t%d_wr" % nn)
        rb, rb2, rs = (p.get("t%d_%s" % (nn, k)) for k in ("rb", "rb2", "rs"))
        v = classify(pre, wr, rb)
        if rb is not None and rb2 is not None and rb2 != rb:
            v += ", then drifted to %#x" % rb2
        if rs is not None and pre is not None and rs != pre:
            v += ", RESTORE FAILED"
        if v == "not run" and reset_at is not None and (reset_at >> 8) == nn:
            v = "RESET during this write"
        out.append("%-10s pre=%s wr=%s rb=%s  %s" % (
            name, _h(pre), _h(wr), _h(rb), v))
    if "t40_g_sctlr" in p:
        diffs = []
        for f in FIELDS:
            g, pre = p.get("t40_g_" + f), p.get("t40_p_" + f)
            diffs.append("%s %s->%s" % (f, _h(pre), _h(g)))
        out.append("combined: " + ", ".join(diffs))
        out.append("combined: sync=%s fsr=%s fsr100ms=%s sgfsr=%s restored=%s" % (
            _h(p.get("t40_sync")), _h(p.get("t40_fsr")), _h(p.get("t40_fsr2")),
            _h(p.get("t40_sgfsr")), _h(p.get("t40_restored"))))
        m_on = (p.get("t40_g_sctlr") or 0) & 1
        out.append("combined: CB0 %s with the Linux values" % (
            "ENABLED (SCTLR.M stuck)" if m_on else "not enabled (SCTLR.M reverted)"))
    elif reset_at is not None and (reset_at >> 8) == 40:
        out.append("combined: RESET at %s" % where(reset_at))
    elif p.get("combined_skip") == 1 or (finished and p.get("single_fails")):
        out.append("combined: skipped, %s single write(s) did not restore" % p.get("single_fails"))
    elif p.get("combined_skip") == 2:
        out.append("combined: skipped, a stream already translates via CB0")
    return out


def _h(v):
    return "-" if v is None else "%#x" % v


def read_hive(path):
    import hivex  # python3-hivex on the tablet Linux
    h = hivex.Hivex(path)
    node = h.root()
    for part in ("ControlSet001", "Services", "daguwt", "Parameters"):
        node = h.node_get_child(node, part)
        if not node:
            raise SystemExit("no daguwt\\Parameters in this hive")
    vals = {}
    for v in h.node_values(node):
        t, raw = h.value_value(v)
        if t == 4 and len(raw) == 4:
            vals[h.value_key(v)] = int.from_bytes(raw, "little")
        elif t == 11 and len(raw) == 8:
            vals[h.value_key(v)] = int.from_bytes(raw, "little")
    return vals


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    for line in verdict(read_hive(sys.argv[1])):
        print(line)
