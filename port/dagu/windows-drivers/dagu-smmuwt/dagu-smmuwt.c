/* SPDX-License-Identifier: MIT
 * dagu-smmuwt: one gated Adreno-SMMU write per run, to find out exactly which
 * register write QHEE traps (stage 18).
 *
 * Stage 17 showed qcsmmu resets the SoC by writing the SMMU global control
 * (sCR0 @ GR0+0x0, sCR2 @ +0x8) plus per-stream SMR/S2CR, all by bare MMIO.
 * Mainline Linux drives the same SMMU by *not* rewriting the globals and only
 * routing streams. The open question: does QHEE reject every HLOS write, or
 * only the global ones? If stream-only writes (SMR/S2CR) stick, a conservative
 * SMMU shim can work; if even those reset, the path is closed.
 *
 * This driver reads a DWORD "test" from its own ...\Services\<svc>\Parameters
 * and performs exactly ONE pre-declared write, so each `sc start` is a single
 * isolated experiment selected from the host:
 *   test=1  SMR[0]  = 0x80000F00   (valid stream-match, test SID)
 *   test=2  S2CR[0] = 0x00010000   (type=1 bypass)
 *   test=3  S2CR[0] = 0x00000000   (type=0 translate -> CB0)
 *   test=4  sCR0    = <readback>   (rewrite same value: is the GR0 global
 *                                   write transaction itself trapped?)
 * Any other value: read-only, writes nothing.
 *
 * test=100 (stage 24) runs the CB0 sequence below once per `sc start`. The
 * service is demand-start, so a reset cannot make a later boot run it again.
 * Each sub-test stores tNN_pre / tNN_wr / tNN_rb (after the write) /
 * tNN_rs (after restoring) and step = (NN << 8) | phase.
 *   30  read-only snapshot of CB0..CB4, CBAR/CBA2R, SMR/S2CR, ID regs
 *   31  CB0.TTBR1 = empty zeroed page        36  CB0.ACTLR = 0x303
 *   32  CB0.TCR   = 0xB5100080               37  CBA2R[0]  = 0x1 (VA64)
 *   33  CB0.TCR2  = 0x00038011               38  CBAR[0]   = 0x1F300
 *   34  CB0.MAIR0 = 0xF404FF44
 *   35  CB0.SCTLR = 0x1166 (Linux value without M)
 *   40  all of the above in Linux order, SCTLR.M=1, no stream routed
 *   99  snapshot again
 * 40 is skipped when a valid SMR already translates through CB0 or a
 * sub-test could not restore its register. Nothing here routes SID 0, so
 * no transaction ever walks the table (stage 19: the reset came from a live
 * walk, not from a register write).
 *
 * "step" is written and FLUSHED before the risky write, so if the box resets
 * the on-disk hive shows how far it got (read it from B-slot Linux):
 *   step=0x10 mapped, pre-values read   0x20 ABOUT TO WRITE   0x30 survived
 *   0x40 readback done   0x50 restored
 * DriverEntry always returns an error so the driver unloads after one shot.
 */
#include <ntddk.h>

#define SMMU_PHYS   0x03DA0000ULL
#define SMMU_SIZE   0x00010000u
#define SMR0        0x0800u
#define S2CR0       0x0C00u
#define SCR0        0x0000u

#define GR0_SGFSR    0x0048u
#define GR0_ID0      0x0020u
#define GR0_ID1      0x0024u
#define GR0_ID2      0x0028u
#define GR1_CBAR0    0x1000u
#define GR1_CBA2R0   0x1800u
#define CB_BASE(n)   (0x8000u + ((n) << 12))
#define CB_SCTLR     0x000u
#define CB_ACTLR     0x004u
#define CB_TCR2      0x010u
#define CB_TTBR0     0x020u
#define CB_TTBR1     0x028u
#define CB_TCR       0x030u
#define CB_MAIR0     0x038u
#define CB_MAIR1     0x03Cu
#define CB_FSR       0x058u
#define CB_FAR       0x060u
#define CB_FSYNR0    0x068u
#define CB_TLBIASID  0x610u
#define CB_TLBSYNC   0x7F0u
#define CB_TLBSTATUS 0x7F4u

/* What Linux 7.0 arm-smmu-qcom writes into the Adreno CB0 on this board.
 * TCR and MAIR0 are the stage 23 capture. TCR2 follows arm_smmu_lpae_tcr2()
 * for a 36-bit IPA (PASIZE=1, SEP=7, AS). SCTLR is CFIE|CFRE|AFE|TRE|M|
 * ASIDPNE plus HUPCF from qcom_adreno_smmu_write_sctlr(). ACTLR is the
 * qcom,adreno entry PREFETCH_DEEP|CPRE|CMTLB. CBAR is S1 translate with
 * BPSHCFG=NSH and MEMATTR=WB. CBA2R is VA64 with VMID 0. */
#define LX_TCR       0xB5100080u
#define LX_TCR2      0x00038011u
#define LX_MAIR0     0xF404FF44u
#define LX_MAIR1     0x00000000u
#define LX_SCTLR     0x00001167u
#define LX_SCTLR_NOM 0x00001166u
#define LX_ACTLR     0x00000303u
#define LX_CBAR      0x0001F300u
#define LX_CBA2R     0x00000001u
#define GPU_SMR      0x80000000u   /* valid, SID 0, mask 0 (stage 18) */
#define GPU_S2CR     0x00000000u   /* translate -> CB0 */

static HANDLE gKey;

static VOID
Put(PCWSTR name, ULONG v)
{
    UNICODE_STRING n;
    if (!gKey)
        return;
    RtlInitUnicodeString(&n, name);
    ZwSetValueKey(gKey, &n, 0, REG_DWORD, &v, sizeof(v));
}

static VOID
Step(ULONG s)
{
    Put(L"step", s);
    if (gKey)
        ZwFlushKey(gKey);
}

static ULONG
GetDword(PCWSTR name, ULONG def)
{
    UNICODE_STRING n;
    UCHAR buf[sizeof(KEY_VALUE_PARTIAL_INFORMATION) + 8];
    PKEY_VALUE_PARTIAL_INFORMATION pi = (PVOID)buf;
    ULONG got = 0;

    if (!gKey)
        return def;
    RtlInitUnicodeString(&n, name);
    if (NT_SUCCESS(ZwQueryValueKey(gKey, &n, KeyValuePartialInformation, pi, sizeof(buf), &got)) &&
        pi->Type == REG_DWORD && pi->DataLength == 4)
        return *(ULONG *)pi->Data;
    return def;
}

static NTSTATUS
OpenParams(PUNICODE_STRING reg, ULONG *test)
{
    OBJECT_ATTRIBUTES oa;
    UNICODE_STRING sub, tn;
    HANDLE svc;
    NTSTATUS st;
    ULONG disp, got = 0;
    UCHAR buf[sizeof(KEY_VALUE_PARTIAL_INFORMATION) + 8];
    PKEY_VALUE_PARTIAL_INFORMATION pi = (PVOID)buf;

    InitializeObjectAttributes(&oa, reg, OBJ_KERNEL_HANDLE | OBJ_CASE_INSENSITIVE, NULL, NULL);
    st = ZwOpenKey(&svc, KEY_ALL_ACCESS, &oa);
    if (!NT_SUCCESS(st))
        return st;
    RtlInitUnicodeString(&sub, L"Parameters");
    InitializeObjectAttributes(&oa, &sub, OBJ_KERNEL_HANDLE | OBJ_CASE_INSENSITIVE, svc, NULL);
    st = ZwCreateKey(&gKey, KEY_ALL_ACCESS, &oa, 0, NULL, REG_OPTION_NON_VOLATILE, &disp);
    ZwClose(svc);
    if (!NT_SUCCESS(st))
        return st;
    RtlInitUnicodeString(&tn, L"test");
    if (NT_SUCCESS(ZwQueryValueKey(gKey, &tn, KeyValuePartialInformation, pi, sizeof(buf), &got)) &&
        pi->Type == REG_DWORD && pi->DataLength == 4)
        *test = *(ULONG *)pi->Data;
    return STATUS_SUCCESS;
}

/* ---- test=100: Linux CB0 programme (stage 24) ---------------------------- */

#define GCC_PHYS        0x00100000ULL
#define GCC_SIZE        0x00080000u
#define GCC_GPU_CFG_AHB 0x71004u
#define GCC_GPU_MEMNOC  0x7100Cu
#define GCC_GPU_SNOCDVM 0x71018u
#define GPUCC_PHYS      0x03D90000ULL
#define GPUCC_SIZE      0x00009000u
#define GPUCC_CX_GDSCR  0x106Cu
#define GPUCC_AHB       0x1078u
#define CBCR_OFF        0x80000000u
#define GDSC_ON         0x80000000u

#define NUM_CB      5u
#define NUM_SMR     6u

static volatile UCHAR *gS;

static ULONG   R32(ULONG o) { return READ_REGISTER_ULONG((volatile ULONG *)(gS + o)); }
static VOID    W32(ULONG o, ULONG v) { WRITE_REGISTER_ULONG((volatile ULONG *)(gS + o), v); }
static ULONG64 R64(ULONG o) { return READ_REGISTER_ULONG64((volatile ULONG64 *)(gS + o)); }
static VOID    W64(ULONG o, ULONG64 v) { WRITE_REGISTER_ULONG64((volatile ULONG64 *)(gS + o), v); }

static VOID
PutQ(PCWSTR name, ULONG64 v)
{
    UNICODE_STRING n;
    if (!gKey)
        return;
    RtlInitUnicodeString(&n, name);
    ZwSetValueKey(gKey, &n, 0, REG_QWORD, &v, sizeof(v));
}

/* name = a + b, both short ASCII-only wide strings */
static VOID
Cat(PWCHAR out, ULONG cap, PCWSTR a, PCWSTR b)
{
    ULONG n = 0;
    while (*a && n + 1 < cap)
        out[n++] = *a++;
    while (b && *b && n + 1 < cap)
        out[n++] = *b++;
    out[n] = 0;
}

/* "tNN_<suffix>" */
static VOID
PutT(ULONG nn, PCWSTR suffix, ULONG64 v)
{
    WCHAR pre[5] = { L't', (WCHAR)(L'0' + (nn / 10) % 10), (WCHAR)(L'0' + nn % 10), L'_', 0 };
    WCHAR name[32];
    Cat(name, 32, pre, suffix);
    PutQ(name, v);
}

static VOID
Delay(ULONG ms)
{
    LARGE_INTEGER t;
    t.QuadPart = -(LONGLONG)ms * 10000;
    KeDelayExecutionThread(KernelMode, FALSE, &t);
}

/* The SMMU only answers while GPU CX and its three clocks run (stage 12,
 * 16). An access to it otherwise stalls the bus, so check first. */
static BOOLEAN
SmmuPowered(VOID)
{
    PHYSICAL_ADDRESS pa;
    volatile UCHAR *gcc, *gpucc;
    ULONG cfg, memnoc, snoc, cx = 0, ahb = CBCR_OFF;

    pa.QuadPart = GCC_PHYS;
    gcc = MmMapIoSpaceEx(pa, GCC_SIZE, PAGE_READWRITE | PAGE_NOCACHE);
    if (!gcc)
        return FALSE;
    cfg = READ_REGISTER_ULONG((volatile ULONG *)(gcc + GCC_GPU_CFG_AHB));
    memnoc = READ_REGISTER_ULONG((volatile ULONG *)(gcc + GCC_GPU_MEMNOC));
    snoc = READ_REGISTER_ULONG((volatile ULONG *)(gcc + GCC_GPU_SNOCDVM));
    MmUnmapIoSpace((PVOID)gcc, GCC_SIZE);
    Put(L"pw_cfg_ahb", cfg);
    Put(L"pw_memnoc", memnoc);
    Put(L"pw_snocdvm", snoc);
    if (cfg & CBCR_OFF)
        return FALSE;
    pa.QuadPart = GPUCC_PHYS;
    gpucc = MmMapIoSpaceEx(pa, GPUCC_SIZE, PAGE_READWRITE | PAGE_NOCACHE);
    if (!gpucc)
        return FALSE;
    cx = READ_REGISTER_ULONG((volatile ULONG *)(gpucc + GPUCC_CX_GDSCR));
    ahb = READ_REGISTER_ULONG((volatile ULONG *)(gpucc + GPUCC_AHB));
    MmUnmapIoSpace((PVOID)gpucc, GPUCC_SIZE);
    Put(L"pw_cx_gdscr", cx);
    Put(L"pw_gpucc_ahb", ahb);
    return (cx & GDSC_ON) && !(ahb & CBCR_OFF) && !(memnoc & CBCR_OFF) && !(snoc & CBCR_OFF);
}

/* "<p><base><i>" */
static VOID
PutIdxQ(PCWSTR p, PCWSTR base, ULONG i, ULONG64 v)
{
    WCHAR q[24], n[32], d[2] = { (WCHAR)(L'0' + (i & 0xF)), 0 };
    Cat(q, 24, p, base);
    Cat(n, 32, q, d);
    PutQ(n, v);
}

/* Read-only. CB0 in full; CB1..4 only the registers stage 16 already read,
 * because CB1 belongs to the CP_PIXEL VMID. */
static VOID
Snapshot(PCWSTR tag)
{
    WCHAR n[32], p[24];
    ULONG i;

    Cat(p, 24, tag, L"_");
    Cat(n, 32, p, L"idr0");  Put(n, R32(GR0_ID0));
    Cat(n, 32, p, L"idr1");  Put(n, R32(GR0_ID1));
    Cat(n, 32, p, L"idr2");  Put(n, R32(GR0_ID2));
    Cat(n, 32, p, L"scr0");  Put(n, R32(SCR0));
    Cat(n, 32, p, L"sgfsr"); Put(n, R32(GR0_SGFSR));
    for (i = 0; i < NUM_SMR; i++) {
        PutIdxQ(p, L"smr", i, R32(SMR0 + 4 * i));
        PutIdxQ(p, L"s2cr", i, R32(S2CR0 + 4 * i));
    }
    for (i = 0; i < NUM_CB; i++) {
        PutIdxQ(p, L"cbar", i, R32(GR1_CBAR0 + 4 * i));
        PutIdxQ(p, L"cba2r", i, R32(GR1_CBA2R0 + 4 * i));
        PutIdxQ(p, L"sctlr", i, R32(CB_BASE(i) + CB_SCTLR));
        PutIdxQ(p, L"fsr", i, R32(CB_BASE(i) + CB_FSR));
    }
    Cat(n, 32, p, L"cb0_actlr"); Put(n, R32(CB_BASE(0) + CB_ACTLR));
    Cat(n, 32, p, L"cb0_tcr2");  Put(n, R32(CB_BASE(0) + CB_TCR2));
    Cat(n, 32, p, L"cb0_tcr");   Put(n, R32(CB_BASE(0) + CB_TCR));
    Cat(n, 32, p, L"cb0_ttbr0"); PutQ(n, R64(CB_BASE(0) + CB_TTBR0));
    Cat(n, 32, p, L"cb0_ttbr1"); PutQ(n, R64(CB_BASE(0) + CB_TTBR1));
    Cat(n, 32, p, L"cb0_mair0"); Put(n, R32(CB_BASE(0) + CB_MAIR0));
    Cat(n, 32, p, L"cb0_mair1"); Put(n, R32(CB_BASE(0) + CB_MAIR1));
    Cat(n, 32, p, L"cb0_far");   PutQ(n, R64(CB_BASE(0) + CB_FAR));
    Cat(n, 32, p, L"cb0_fsynr0"); Put(n, R32(CB_BASE(0) + CB_FSYNR0));
}

/* One isolated write. Returns TRUE when the register went back to its
 * original value, or to `alt` when hasAlt: QHEE lets HLOS turn CBAR into a
 * stage-1 type but not back into stage-2 (stage 24 run 1), so CBAR may end
 * at the Linux value instead. That gates the combined test. */
static BOOLEAN
OneWrite(ULONG nn, ULONG off, BOOLEAN wide, ULONG64 val, BOOLEAN hasAlt, ULONG64 alt)
{
    ULONG64 pre, rb, rb2, rs;

    Step((nn << 8) | 0x10);
    pre = wide ? R64(off) : R32(off);
    PutT(nn, L"off", off);
    PutT(nn, L"pre", pre);
    PutT(nn, L"wr", val);
    Step((nn << 8) | 0x20);                 /* flushed: ABOUT TO WRITE */
    if (wide) W64(off, val); else W32(off, (ULONG)val);
    rb = wide ? R64(off) : R32(off);
    Step((nn << 8) | 0x30);                 /* survived the write */
    Delay(50);
    rb2 = wide ? R64(off) : R32(off);
    PutT(nn, L"rb", rb);
    PutT(nn, L"rb2", rb2);
    Step((nn << 8) | 0x40);
    if (wide) W64(off, pre); else W32(off, (ULONG)pre);
    rs = wide ? R64(off) : R32(off);
    PutT(nn, L"rs", rs);
    Step((nn << 8) | 0x50);
    return rs == pre || (hasAlt && rs == alt);
}

/* A valid SMR already translating through CB0 means somebody else owns it;
 * an enabled CB0 would then start walking our table. */
static BOOLEAN
Cb0Routed(VOID)
{
    ULONG i;
    for (i = 0; i < NUM_SMR; i++) {
        ULONG smr = R32(SMR0 + 4 * i), s2 = R32(S2CR0 + 4 * i);
        if ((smr & 0x80000000u) && ((s2 >> 16) & 3u) == 0 && (s2 & 0xFFu) == 0)
            return TRUE;
    }
    return FALSE;
}

typedef struct {
    ULONG actlr, cba2r, cbar, tcr2, tcr, mair0, mair1, sctlr;
    ULONG64 ttbr0, ttbr1;
} CB0_REGS;

static VOID
ReadCb0(CB0_REGS *r)
{
    r->actlr = R32(CB_BASE(0) + CB_ACTLR);
    r->cba2r = R32(GR1_CBA2R0);
    r->cbar = R32(GR1_CBAR0);
    r->tcr2 = R32(CB_BASE(0) + CB_TCR2);
    r->tcr = R32(CB_BASE(0) + CB_TCR);
    r->ttbr0 = R64(CB_BASE(0) + CB_TTBR0);
    r->ttbr1 = R64(CB_BASE(0) + CB_TTBR1);
    r->mair0 = R32(CB_BASE(0) + CB_MAIR0);
    r->mair1 = R32(CB_BASE(0) + CB_MAIR1);
    r->sctlr = R32(CB_BASE(0) + CB_SCTLR);
}

static VOID
PutCb0(ULONG nn, PCWSTR tag, const CB0_REGS *r)
{
    WCHAR n[16];
    Cat(n, 16, tag, L"actlr"); PutT(nn, n, r->actlr);
    Cat(n, 16, tag, L"cba2r"); PutT(nn, n, r->cba2r);
    Cat(n, 16, tag, L"cbar");  PutT(nn, n, r->cbar);
    Cat(n, 16, tag, L"tcr2");  PutT(nn, n, r->tcr2);
    Cat(n, 16, tag, L"tcr");   PutT(nn, n, r->tcr);
    Cat(n, 16, tag, L"ttbr0"); PutT(nn, n, r->ttbr0);
    Cat(n, 16, tag, L"ttbr1"); PutT(nn, n, r->ttbr1);
    Cat(n, 16, tag, L"mair0"); PutT(nn, n, r->mair0);
    Cat(n, 16, tag, L"mair1"); PutT(nn, n, r->mair1);
    Cat(n, 16, tag, L"sctlr"); PutT(nn, n, r->sctlr);
}

static ULONG
TlbSyncCb0(VOID)
{
    ULONG i;
    W32(CB_BASE(0) + CB_TLBIASID, 0);       /* ASID 0 = cbndx, as Linux */
    W32(CB_BASE(0) + CB_TLBSYNC, 0);
    for (i = 0; i < 1000000u; i++)
        if ((R32(CB_BASE(0) + CB_TLBSTATUS) & 1u) == 0)
            return i;
    return 0xFFFFFFFFu;
}

/* Linux arm_smmu_write_context_bank() order for the Adreno CB0, with an
 * empty level-0 table behind TTBR1. No stream is routed, so nothing walks. */
static VOID
Combined(ULONG64 table)
{
    CB0_REGS pre, got, back;
    ULONG nn = 40, ok;

    ReadCb0(&pre);
    PutCb0(nn, L"p_", &pre);
    Step((nn << 8) | 0x01);
    W32(CB_BASE(0) + CB_ACTLR, LX_ACTLR);
    Step((nn << 8) | 0x02);
    W32(GR1_CBA2R0, LX_CBA2R);
    Step((nn << 8) | 0x03);
    W32(GR1_CBAR0, LX_CBAR);
    Step((nn << 8) | 0x04);
    W32(CB_BASE(0) + CB_TCR2, LX_TCR2);
    W32(CB_BASE(0) + CB_TCR, LX_TCR);
    Step((nn << 8) | 0x05);
    W64(CB_BASE(0) + CB_TTBR0, 0);
    W64(CB_BASE(0) + CB_TTBR1, table);
    Step((nn << 8) | 0x06);
    W32(CB_BASE(0) + CB_MAIR0, LX_MAIR0);
    W32(CB_BASE(0) + CB_MAIR1, LX_MAIR1);
    Step((nn << 8) | 0x07);                 /* flushed: ABOUT TO SET SCTLR.M */
    W32(CB_BASE(0) + CB_SCTLR, LX_SCTLR);
    Step((nn << 8) | 0x08);
    PutT(nn, L"sync", TlbSyncCb0());
    Step((nn << 8) | 0x09);
    ReadCb0(&got);
    PutCb0(nn, L"g_", &got);
    PutT(nn, L"fsr", R32(CB_BASE(0) + CB_FSR));
    Step((nn << 8) | 0x0A);
    Delay(100);
    PutT(nn, L"sctlr2", R32(CB_BASE(0) + CB_SCTLR));
    PutT(nn, L"fsr2", R32(CB_BASE(0) + CB_FSR));
    PutT(nn, L"sgfsr", R32(GR0_SGFSR));
    Step((nn << 8) | 0x0B);

    /* Disable first, flush, then put every field back. */
    W32(CB_BASE(0) + CB_SCTLR, pre.sctlr);
    PutT(nn, L"sync2", TlbSyncCb0());
    W32(CB_BASE(0) + CB_MAIR1, pre.mair1);
    W32(CB_BASE(0) + CB_MAIR0, pre.mair0);
    W64(CB_BASE(0) + CB_TTBR1, pre.ttbr1);
    W64(CB_BASE(0) + CB_TTBR0, pre.ttbr0);
    W32(CB_BASE(0) + CB_TCR, pre.tcr);
    W32(CB_BASE(0) + CB_TCR2, pre.tcr2);
    W32(GR1_CBAR0, pre.cbar);
    W32(GR1_CBA2R0, pre.cba2r);
    W32(CB_BASE(0) + CB_ACTLR, pre.actlr);
    ReadCb0(&back);
    PutCb0(nn, L"r_", &back);
    ok = RtlCompareMemory(&pre, &back, sizeof(pre)) == sizeof(pre);
    PutT(nn, L"restored", ok);
    Step((nn << 8) | 0x0C);
}

static VOID
RunCb0Programme(VOID)
{
    PHYSICAL_ADDRESS lo, hi, bound, tpa;
    PVOID table;
    ULONG fails = 0;

    Put(L"runs", GetDword(L"runs", 0) + 1);
    Step(0x0100);
    if (!SmmuPowered()) {
        Step(0x01A2);                       /* SMMU unclocked: touch nothing */
        return;
    }
    Snapshot(L"s30");
    Step(0x1E00);

    /* 4 KB level-0 table for T1SZ=16, 4 KB granule: 512 invalid entries.
     * Below 64 GB because the CB output size is 36 bits. Cached, because
     * the Adreno SMMU walks coherently (dma-coherent, TCR SH=IS WBWA). */
    lo.QuadPart = 0;
    hi.QuadPart = 0xFFFFFFFFFULL;
    bound.QuadPart = 0;
    table = MmAllocateContiguousMemorySpecifyCache(PAGE_SIZE, lo, hi, bound, MmCached);
    if (!table) {
        Step(0x01E4);
        return;
    }
    RtlZeroMemory(table, PAGE_SIZE);
    KeMemoryBarrier();
    tpa = MmGetPhysicalAddress(table);
    PutQ(L"table_pa", (ULONG64)tpa.QuadPart);

    fails += !OneWrite(31, CB_BASE(0) + CB_TTBR1, TRUE, (ULONG64)tpa.QuadPart, FALSE, 0);
    fails += !OneWrite(32, CB_BASE(0) + CB_TCR, FALSE, LX_TCR, FALSE, 0);
    fails += !OneWrite(33, CB_BASE(0) + CB_TCR2, FALSE, LX_TCR2, FALSE, 0);
    fails += !OneWrite(34, CB_BASE(0) + CB_MAIR0, FALSE, LX_MAIR0, FALSE, 0);
    fails += !OneWrite(35, CB_BASE(0) + CB_SCTLR, FALSE, LX_SCTLR_NOM, FALSE, 0);
    fails += !OneWrite(36, CB_BASE(0) + CB_ACTLR, FALSE, LX_ACTLR, FALSE, 0);
    fails += !OneWrite(37, GR1_CBA2R0, FALSE, LX_CBA2R, FALSE, 0);
    fails += !OneWrite(38, GR1_CBAR0, FALSE, LX_CBAR, TRUE, LX_CBAR);
    Put(L"single_fails", fails);

    if (fails) {
        Put(L"combined_skip", 1);
        Step(0x2700);                       /* combined skipped: a restore failed */
    } else if (Cb0Routed()) {
        Put(L"combined_skip", 2);
        Step(0x2701);                       /* combined skipped: CB0 in use */
    } else {
        Put(L"combined_skip", 0);
        Combined((ULONG64)tpa.QuadPart);
    }

    Snapshot(L"s99");
    Step(0x6300);
    MmFreeContiguousMemory(table);
    Step(0x6399);                           /* programme finished */
}

NTSTATUS
DriverEntry(_In_ PDRIVER_OBJECT DriverObject, _In_ PUNICODE_STRING RegistryPath)
{
    PHYSICAL_ADDRESS pa;
    volatile UCHAR *s = NULL;
    volatile ULONG *reg;
    ULONG test = 0, pre, rb, wrval = 0, offs = 0;

    UNREFERENCED_PARAMETER(DriverObject);
    if (!NT_SUCCESS(OpenParams(RegistryPath, &test)))
        return STATUS_UNSUCCESSFUL;
    Put(L"test_echo", test);
    Step(1);

    pa.QuadPart = SMMU_PHYS;
    s = MmMapIoSpaceEx(pa, SMMU_SIZE, PAGE_READWRITE | PAGE_NOCACHE);
    if (!s) {
        Step(0xE1);
        goto out;
    }

    if (test == 100) {
        gS = s;
        RunCb0Programme();
        goto out;
    }

    /* Pick the target and value. */
    switch (test) {
    case 1: offs = SMR0;  wrval = 0x80000F00u; break;
    case 2: offs = S2CR0; wrval = 0x00010000u; break;
    case 3: offs = S2CR0; wrval = 0x00000000u; break;
    case 4: offs = SCR0;  wrval = 0xFFFFFFFFu; break;  /* sentinel: rewrite readback */
    case 5: {
        /* Ordered stream program: S2CR[0]=translate->CB0 first, then SMR[0]=valid.
         * Hypothesis: QHEE rejects a valid SMR only while its S2CR is fault. */
        volatile ULONG *rs2 = (volatile ULONG *)(s + S2CR0);
        volatile ULONG *rsmr = (volatile ULONG *)(s + SMR0);
        ULONG ps2 = READ_REGISTER_ULONG(rs2), psmr = READ_REGISTER_ULONG(rsmr);
        Put(L"pre_s2cr", ps2);
        Put(L"pre_smr", psmr);
        Step(0x20);
        WRITE_REGISTER_ULONG(rs2, 0x00000000u);     /* translate -> CB0 */
        Step(0x22);
        WRITE_REGISTER_ULONG(rsmr, 0x80000F00u);    /* valid, SID 0xF00 */
        Step(0x30);
        Put(L"s2cr_rb", READ_REGISTER_ULONG(rs2));
        Put(L"smr_rb", READ_REGISTER_ULONG(rsmr));
        Step(0x40);
        WRITE_REGISTER_ULONG(rsmr, psmr);
        WRITE_REGISTER_ULONG(rs2, ps2);
        Step(0x50);
        goto out;
    }
    case 20:
    case 21: {
        /* Generic probe of one SMMU offset given by DWORD "off".
         * 20 = read only, 21 = read then write the same value back.
         * Targets the Perf page (0x3000) and IMPL-DEF1 page (0x6000) that
         * qcsmmu's OFFI map uses and no earlier test touched. */
        ULONG o = GetDword(L"off", 0) & (SMMU_SIZE - 4);
        volatile ULONG *rc = (volatile ULONG *)(s + o);
        ULONG p;
        Put(L"offs", o);
        Step(0x18);                       /* flushed: ABOUT TO READ */
        p = READ_REGISTER_ULONG(rc);
        Put(L"pre", p);
        Step(0x1C);                       /* read survived */
        if (test == 21) {
            Step(0x20);                   /* flushed: ABOUT TO WRITE */
            WRITE_REGISTER_ULONG(rc, p);
            Step(0x30);
            Put(L"readback", READ_REGISTER_ULONG(rc));
            Step(0x40);
        }
        goto out;
    }
    case 12: {
        /* Change CBAR[0] (GR1 = page 1 = 0x1000, offset 0): sets CB0's type/VMID.
         * QHEE owns the CBs; changing a CB's attribute is a strong reset candidate. */
        volatile ULONG *rc = (volatile ULONG *)(s + 0x1000u);
        ULONG p = READ_REGISTER_ULONG(rc);
        Put(L"pre", p);
        Put(L"wrval", (p & ~0x3u) | 0x1u);     /* set CBAR type field low bit */
        Step(0x20);
        WRITE_REGISTER_ULONG(rc, (p & ~0x3u) | 0x1u);
        Step(0x30);
        Put(L"readback", READ_REGISTER_ULONG(rc));
        Step(0x40);
        WRITE_REGISTER_ULONG(rc, p);
        Step(0x50);
        goto out;
    }
    case 10: {
        /* Change sCR2 (GR0+0x8): BPVMID etc. A global control qcsmmu writes. */
        volatile ULONG *rc = (volatile ULONG *)(s + 0x8u);
        ULONG p = READ_REGISTER_ULONG(rc);
        Put(L"pre", p);
        Put(L"wrval", p ^ 0x1u);
        Step(0x20);
        WRITE_REGISTER_ULONG(rc, p ^ 0x1u);
        Step(0x30);
        Put(L"readback", READ_REGISTER_ULONG(rc));
        Step(0x40);
        WRITE_REGISTER_ULONG(rc, p);
        Step(0x50);
        goto out;
    }
    case 11: {
        /* Global TLB invalidate-all + sync, with a bounded poll. qcsmmu does
         * this during init; a sync that never completes on a half-set SMMU is a
         * prime reset/hang candidate. TLBIALLH=0x6C, sTLBGSYNC=0x70, sGSTATUS=0x74. */
        volatile ULONG *sync = (volatile ULONG *)(s + 0x70u);
        volatile ULONG *stat = (volatile ULONG *)(s + 0x74u);
        ULONG i, done = 0;
        Step(0x20);
        WRITE_REGISTER_ULONG((volatile ULONG *)(s + 0x6Cu), 0u); /* TLBIALLH */
        Step(0x28);
        WRITE_REGISTER_ULONG(sync, 0u);                          /* sTLBGSYNC */
        Step(0x30);
        for (i = 0; i < 1000000u; i++) {
            if ((READ_REGISTER_ULONG(stat) & 1u) == 0) { done = 1; break; }
        }
        Put(L"sync_done", done);
        Put(L"sync_iters", i);
        Step(0x40);
        goto out;
    }
    case 9: {
        /* Route the REAL GPU stream (SID 0, per DT <&adreno_smmu 0 ...>):
         * SMR[0]=valid,ID=0,mask=0 ; S2CR[0]=translate->CB0. Earlier SMR test
         * used a fake ID (0xF00) which QHEE dropped; try the genuine SID. */
        volatile ULONG *rsmr = (volatile ULONG *)(s + SMR0);
        volatile ULONG *rs2 = (volatile ULONG *)(s + S2CR0);
        ULONG psmr = READ_REGISTER_ULONG(rsmr), ps2 = READ_REGISTER_ULONG(rs2);
        Put(L"pre_smr", psmr);
        Put(L"pre_s2cr", ps2);
        Step(0x20);
        WRITE_REGISTER_ULONG(rs2, 0x00000000u);     /* translate -> CB0 first */
        Step(0x22);
        WRITE_REGISTER_ULONG(rsmr, 0x80000000u);    /* valid, ID=0, mask=0 */
        Step(0x30);
        Put(L"smr_rb", READ_REGISTER_ULONG(rsmr));
        Put(L"s2cr_rb", READ_REGISTER_ULONG(rs2));
        Step(0x40);
        WRITE_REGISTER_ULONG(rsmr, psmr);           /* restore */
        WRITE_REGISTER_ULONG(rs2, ps2);
        Step(0x50);
        goto out;
    }
    case 8: {
        /* Change CB0.TTBR0 (CB base 0x8000 + 0x20): reassign a QHEE-owned
         * context bank's translation base. If QHEE traps CB reconfiguration
         * this is the reset; else it sticks (CB reprogrammable from HLOS). */
        volatile ULONG *rc = (volatile ULONG *)(s + 0x8000u + 0x20u);
        ULONG p = READ_REGISTER_ULONG(rc);
        Put(L"pre", p);
        Put(L"wrval", p ^ 0x1000u);
        Step(0x20);
        WRITE_REGISTER_ULONG(rc, p ^ 0x1000u);
        Step(0x30);
        Put(L"readback", READ_REGISTER_ULONG(rc));
        Step(0x40);
        WRITE_REGISTER_ULONG(rc, p);          /* restore */
        Step(0x50);
        goto out;
    }
    case 7: {
        /* Same-value write to CB0.SCTLR (CB space starts at page 8 = 0x8000,
         * 4KB pages, NUMPAGENDXB=2). CBs are QHEE-owned (SCTLR pre-set), so a
         * write here is the most likely reset trigger. Same value = safest probe. */
        volatile ULONG *rc = (volatile ULONG *)(s + 0x8000u);
        ULONG p = READ_REGISTER_ULONG(rc);
        Put(L"pre", p);
        Put(L"wrval", p);
        Step(0x20);
        WRITE_REGISTER_ULONG(rc, p);
        Step(0x30);
        Put(L"readback", READ_REGISTER_ULONG(rc));
        Step(0x40);
        goto out;
    }
    case 6: {
        /* Clear sCR0.USFCFG (bit10): stop faulting unmatched streams. */
        volatile ULONG *rc = (volatile ULONG *)(s + SCR0);
        ULONG p = READ_REGISTER_ULONG(rc);
        Put(L"pre", p);
        Put(L"wrval", p & ~0x400u);
        Step(0x20);
        WRITE_REGISTER_ULONG(rc, p & ~0x400u);
        Step(0x30);
        Put(L"readback", READ_REGISTER_ULONG(rc));
        Step(0x40);
        WRITE_REGISTER_ULONG(rc, p);          /* restore */
        Step(0x50);
        goto out;
    }
    default:
        /* read-only snapshot */
        Put(L"smr0",  READ_REGISTER_ULONG((volatile ULONG *)(s + SMR0)));
        Put(L"s2cr0", READ_REGISTER_ULONG((volatile ULONG *)(s + S2CR0)));
        Put(L"scr0",  READ_REGISTER_ULONG((volatile ULONG *)(s + SCR0)));
        Step(0x99);
        goto out;
    }

    reg = (volatile ULONG *)(s + offs);
    pre = READ_REGISTER_ULONG(reg);
    Put(L"pre", pre);
    Put(L"offs", offs);
    if (test == 4)
        wrval = pre;                 /* rewrite the same value we just read */
    Put(L"wrval", wrval);
    Step(0x20);                      /* flushed: ABOUT TO WRITE */

    WRITE_REGISTER_ULONG(reg, wrval);

    Step(0x30);                      /* survived the write */
    rb = READ_REGISTER_ULONG(reg);
    Put(L"readback", rb);
    Put(L"stuck", (rb == wrval) ? 1u : 0u);
    Step(0x40);

    if (test != 4) {
        WRITE_REGISTER_ULONG(reg, pre);   /* restore */
        Step(0x50);
    }

out:
    if (s)
        MmUnmapIoSpace((PVOID)s, SMMU_SIZE);
    if (gKey) {
        ZwFlushKey(gKey);
        ZwClose(gKey);
    }
    return STATUS_UNSUCCESSFUL;       /* one-shot: unload */
}
