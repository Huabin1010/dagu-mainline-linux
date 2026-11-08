/* SPDX-License-Identifier: MIT
 * dagu-smmushim: stand in for qcsmmu8250 on the Adreno / display SMMU
 * device interfaces that qcdxkm8250 waits for (stage 20).
 *
 * qcdx does not call qcsmmu directly. For each engine MMUINFO it:
 *   1. IoRegisterPlugPlayNotification on the SMMUID device-interface GUID
 *      and waits up to 30 s (qcdx RVA 0x284e38).
 *   2. IoGetDeviceInterfaces + IoGetDeviceObjectPointer on that link.
 *   3. WdfIoTargetCreate / WdfIoTargetOpen(ByName) on the symbolic link.
 *   4. WdfIoTargetQueryForInterface, version 2, buffer 0x1A0 bytes.
 *      Interface GUID is ACPI SMMUINTERFACEID, or {c178bd17-...} when that
 *      buffer is all zeros. The returned INTERFACE.Size must be <= 0x1A0.
 *      Offset 0x180 is a probe. qcdx caches its low byte at engine+0x47f8,
 *      and a non-zero value skips the map call at offset 0x198. The probe
 *      therefore returns 0. Hardware is written only when Parameters\map is 1.
 *
 * This driver publishes the three SMMUIDs (display 36079AE4, GPU 9833C712,
 * video 665E0F8E) from a root-enumerated PDO and answers those queries.
 * It never maps the APPS SMMU at 0x15000000 (that drops the UFS boot disk).
 * The Adreno SMMU at 0x03DA0000 is programmed only when Parameters\map is 1
 * and the call is the 0x198 slot: S2CR[0]=translate to CB0, SMR[0]=SID 0.
 * sCR0, sCR2, CBAR and the context-fault interrupt are not touched. TTBR0 is
 * written only when Parameters\ttbrlo/ttbrhi is non-zero, because the slot's
 * argument layout does not carry a page-table address we can trust, and a
 * live walk of a bad table is what resets the SoC (stage 19).
 *
 * Progress is flushed to Services\dagusmmu\Parameters so a reset can be read
 * back from the B-slot Linux hive. Slot calls stay in a memory ring and
 * that key is flushed once every 16 calls, not on every callback.
 */
#include <ntddk.h>
#include "dagu-dsdt-ov.h"

NTKERNELAPI NTSTATUS ZwFlushBuffersFile(HANDLE FileHandle,
                                        PIO_STATUS_BLOCK IoStatusBlock);

#define IFACE_BYTES 0x1A0u
#define IFACE_FN0   0x20u
#define SLOT_COUNT  ((IFACE_BYTES - IFACE_FN0) / sizeof(PVOID))
#define SLOT_ALLOC  ((0x050u - IFACE_FN0) / sizeof(PVOID)) /* 6 */
#define SLOT_FREE   ((0x058u - IFACE_FN0) / sizeof(PVOID)) /* 7 */
#define SLOT_COMMIT ((0x090u - IFACE_FN0) / sizeof(PVOID)) /* 14 */
#define SLOT_DROP   ((0x0A8u - IFACE_FN0) / sizeof(PVOID)) /* 17 */
#define SLOT_BIND   ((0x0D0u - IFACE_FN0) / sizeof(PVOID)) /* 22 */
#define SLOT_SUB    ((0x0E8u - IFACE_FN0) / sizeof(PVOID)) /* 25 */
#define SLOT_UNBIND ((0x0F0u - IFACE_FN0) / sizeof(PVOID)) /* 26 */
#define SLOT_BASE   ((0x0F8u - IFACE_FN0) / sizeof(PVOID)) /* 27 */
#define SLOT_PHYS   ((0x100u - IFACE_FN0) / sizeof(PVOID)) /* 28 */
#define SLOT_LOCK   ((0x108u - IFACE_FN0) / sizeof(PVOID)) /* 29 */
#define SLOT_PROBE  ((0x180u - IFACE_FN0) / sizeof(PVOID)) /* 44 */
#define SLOT_MAP    ((0x198u - IFACE_FN0) / sizeof(PVOID)) /* 47 */
/* qcdx checks a subrange against [base, base+length). The address it asks
 * for comes from the display descriptor and is below 4GB, while the size
 * passed to slot 22 is only the named region. Report at least a 4GB window
 * so that check can succeed. This length is never allocated. */
#define VA_WINDOW   0x100000000ULL
#define ALLOC_MAX   128u

#define SMMU_PHYS   0x03DA0000ULL
#define SMMU_SIZE   0x00010000u
#define SMR0        0x0800u
#define S2CR0       0x0C00u
#define CB0_TTBR0   (0x8000u + 0x20u)

static const GUID kGuidDisp = {
    0x36079AE4, 0x78E8, 0x452D, { 0xAF, 0x50, 0x0C, 0xFF, 0x78, 0xB2, 0xF1, 0xCA }
};
static const GUID kGuidGpu = {
    0x9833C712, 0x3292, 0x4FFB, { 0xB0, 0xF4, 0x2B, 0xD2, 0x0E, 0x1F, 0x7F, 0x66 }
};
static const GUID kGuidVideo = {
    0x665E0F8E, 0xADD3, 0x49D1, { 0x91, 0xBC, 0x55, 0x40, 0xC5, 0xF5, 0x7F, 0xBA }
};
/* qcdx fallback when SMMUINTERFACEID is zeros, and the video-only one. */
static const GUID kIfaceDefault = {
    0xC178BD17, 0x15DC, 0x4145, { 0xA9, 0x07, 0x61, 0x32, 0x7E, 0xC6, 0x28, 0x4D }
};
static const GUID kIfaceVideo = {
    0x1C3FC0E8, 0x0B11, 0x4EE0, { 0xBE, 0x89, 0x3E, 0x21, 0x42, 0x0A, 0x86, 0x5F }
};
/* Used only if the 0x1A0 size check fails and qcdx retries. */
static const GUID kIfaceRetry = {
    0xFBF4F730, 0x5D06, 0x4B12, { 0xA3, 0xE3, 0x83, 0xBD, 0x94, 0xED, 0x1A, 0x45 }
};

typedef struct _SHIM_EXT {
    PDEVICE_OBJECT Lower;
    PDEVICE_OBJECT Pdo;
    UNICODE_STRING Link[3];
    LONG Refs;
    BOOLEAN Started;
} SHIM_EXT, *PSHIM_EXT;

static HANDLE gKey;
static ULONG gBootGen;
static ULONG gLastStep;
static LONG gIfaceKind; /* 0 none, 1 default/gpu, 2 video */
static PVOID gAlloc[ALLOC_MAX];
/* Load-notify diagnostics. ntfy counts every callback. The ring keeps the
 * last four images that were large enough to be qcdx, or whose name
 * contains "qcdx". ihit is 1 when the name matched and 2 when only the
 * image size matched. nirq is the IRQL of that attempt. */
static ULONG gNtfy;
static ULONG gIhit;
static ULONG gIseq;
static ULONG gNirq;
/* DSDT override writer result, flushed by RecordStatus. */
static ULONG gOvIns;
static ULONG gOvLen;
static ULONG gOvFlt;
/* Latest failure state, written by RecordStatus and flushed by DiagThread.
 * The thread is the reliable writer: the compiler dropped the direct
 * WriteDiag call from the failure tail, and a bugcheck can lose cached
 * file data, so a PASSIVE thread writes whenever the log ring changes. */
static ULONG gLastFail;
static ULONG gLastSite;
static ULONG_PTR gLastAd;
/* Active ACPI DSDT identity from HKLM\HARDWARE\ACPI\DSDT\QCOMM_\SM8250_.
 * acpk* are the decoded subkey names (the table revision, e.g. 4), acpl* the
 * first value length in that subkey, acpn the subkey count, acpf the first
 * failing status. A 53457-byte first value means our _ROM overlay is live. */
static ULONG gAcpN;
static ULONG gAcpK[4];
static ULONG gAcpL[4];
static ULONG gAcpF;
static LONG gAcpDone;
static ULONG gPendMask;
static ULONG gPendStep;
static LONG gPendValid;
/* ImageBase used for this attempt, plus one 20-byte window per site.
 * Byte 0 of a window is RVA-8 and bytes 8..11 are the compared dword,
 * so RVA-4, RVA+4 and RVA+8 are in the same record. qflt bit i means
 * the dword itself faulted. qflt bit i+8 means the window faulted;
 * the other bytes are then zeros, not a read. A dword that was read
 * is still stored at offset 8.
 *
 * qflt does not say why. Both a missing page and a present page that
 * stage-2 will not allow a data read raise 0xC0000005. The descriptor
 * is sampled before the data read. qexc is that read's exception code
 * (0 if it succeeded, 0xC0000006 if the pager tried and failed). qprs
 * bit i is the stage-1 valid bit. qrd bit i is set for a valid leaf:
 * every architectural AP value still allows an EL1 data read, so a
 * present readable page that nevertheless raises 0xC0000005 is not a
 * stage-1 permission. qwlk is per site and is 0 only when qpte holds
 * the descriptor; any other value means the walk failed and qprs must
 * not be read as "not present". */
static ULONG_PTR gPendBase;
static ULONG gPendFlt;
static UCHAR gPendWin[7][20];
static ULONG gPendPrs;
static ULONG gPendRd;
static ULONG gPendExc[7];
static ULONG gPendXi0[7];
static ULONG gPendWlk[7];
static ULONG64 gPendPte[7];
static ULONG64 gPendTcr;
static ULONG64 gPendTtbr;
static ULONG gPendMrs;
/* Per site, written only when WriteQcdx ran. 0 means it was not called
 * or the store finished. The numbers follow the call order:
 * 1 IoAllocateMdl returned NULL.
 * 2 MmProbeAndLockPages raised; wprot is that exception code.
 * 3 MmGetSystemAddressForMdlSafe returned NULL.
 * 4 MmProtectMdlSystemAddress failed; wprot is the NTSTATUS.
 * qwin is still the pre-write window, so a later Want there means the
 * site was already patched and this function was not called. */
static ULONG gPendWstat[7];
static ULONG gPendWprot[7];
static ULONG *gExcOut;
static ULONG *gXi0Out;
static ULONG gIsz[4];
static WCHAR gInm[4][48];
static WORK_QUEUE_ITEM gNoteItem;
static LONG gNoteQueued;
static VOID NoteCaller(ULONG_PTR ret);
static VOID NoteFlush(VOID);
static UINT64 SlotDispatch(ULONG slot, ULONG_PTR a, ULONG_PTR b, ULONG_PTR c, ULONG_PTR d, ULONG_PTR caller);

static VOID
Put(PCWSTR name, ULONG v)
{
    UNICODE_STRING n;
    if (!gKey || KeGetCurrentIrql() != PASSIVE_LEVEL)
        return;
    RtlInitUnicodeString(&n, name);
    ZwSetValueKey(gKey, &n, 0, REG_DWORD, &v, sizeof(v));
}

static VOID
PutStr(PCWSTR name, PCWSTR val)
{
    UNICODE_STRING n;
    SIZE_T chars;

    if (!gKey || KeGetCurrentIrql() != PASSIVE_LEVEL || !val)
        return;
    chars = 0;
    while (val[chars] && chars < 80)
        chars++;
    RtlInitUnicodeString(&n, name);
    ZwSetValueKey(gKey, &n, 0, REG_SZ, (PVOID)val, (ULONG)((chars + 1) * sizeof(WCHAR)));
}

static VOID
PutBin(PCWSTR name, const VOID *buf, ULONG len)
{
    UNICODE_STRING n;

    if (!gKey || KeGetCurrentIrql() != PASSIVE_LEVEL || !buf)
        return;
    RtlInitUnicodeString(&n, name);
    ZwSetValueKey(gKey, &n, 0, REG_BINARY, (PVOID)buf, len);
}

static VOID
StampGen(VOID)
{
    Put(L"bootgen", gBootGen);
}

static VOID
Step(ULONG s)
{
    gLastStep = s;
    Put(L"step", s);
    StampGen();
    if (gKey && KeGetCurrentIrql() == PASSIVE_LEVEL)
        ZwFlushKey(gKey);
}

/* Parameters survive the previous load. Wipe the session fields before
 * step 0x10 so a later Linux read of this bootgen cannot see the old
 * fail/ncall/qpatch/ring. map and the page-table base stay. */
static VOID
ClearStale(VOID)
{
    static const PCWSTR kNames[] = {
        L"fail", L"ncall", L"seen0", L"seen1", L"qpatch", L"slot",
        L"arg0", L"arg1", L"arg2", L"arg3", L"retlo",
        L"subok", L"suboff", L"subsz", L"iface", L"qsize", L"qver",
        L"ntfy", L"ihit", L"iseq", L"nirq",
        L"i0sz", L"i1sz", L"i2sz", L"i3sz",
        L"iblo", L"ibhi", L"qflt",
        L"qprs", L"qrd",
        L"tcrlo", L"tcrhi", L"tb1lo", L"tb1hi", L"qmrs",
        L"rethi", L"site", L"pout", L"qblo", L"qbhi",
        L"fail1", L"fcall1", L"fsite1", L"fcall", L"fsite", L"nfail",
        L"adlo", L"adhi", L"a630", L"a638lo", L"a638hi", L"a780", L"aflt",
        L"a784", L"a788", L"a3b78", L"a3b7c", L"a3b90", L"a46c4", L"mflt",
        L"d1108lo", L"d1108hi", L"d1110lo", L"d1110hi",
        L"d1118lo", L"d1118hi", L"dflt", L"rst",
        L"fminst", L"fmidet", L"fmcall", L"fmhit",
        L"fmaflt", L"fmbflt", L"fmdsclo", L"fmdschi",
        L"fmseen", L"fmlast",
        L"hist0", L"hist1", L"hist2", L"hist3", L"logseen", L"loginst",
        L"ls0", L"ls1", L"ls2", L"ls3",
        L"ovins", L"ovlen", L"ovflt",
        L"acpn", L"acpf", L"acpk0", L"acpk1", L"acpk2", L"acpk3",
        L"acpl0", L"acpl1", L"acpl2", L"acpl3",
    };
    static const UCHAR kNoRing[8 * 8 * sizeof(ULONG) + sizeof(ULONG)] = { 0 };
    ULONG i, k;
    WCHAR ring[3];

    gNtfy = 0;
    gIhit = 0;
    gIseq = 0;
    gNirq = 0;
    gOvIns = 0;
    gOvLen = 0;
    gOvFlt = 0;
    gAcpN = 0;
    gAcpF = 0;
    gAcpDone = 0;
    for (i = 0; i < 4; i++) {
        gAcpK[i] = 0;
        gAcpL[i] = 0;
    }
    gPendBase = 0;
    gPendFlt = 0;
    gPendPrs = 0;
    gPendRd = 0;
    gPendTcr = 0;
    gPendTtbr = 0;
    gPendMrs = 0;
    RtlZeroMemory(gPendWin, sizeof(gPendWin));
    RtlZeroMemory(gPendExc, sizeof(gPendExc));
    RtlZeroMemory(gPendXi0, sizeof(gPendXi0));
    RtlZeroMemory(gPendWlk, sizeof(gPendWlk));
    RtlZeroMemory(gPendPte, sizeof(gPendPte));
    RtlZeroMemory(gPendWstat, sizeof(gPendWstat));
    RtlZeroMemory(gPendWprot, sizeof(gPendWprot));
    for (i = 0; i < 4; i++) {
        gIsz[i] = 0;
        gInm[i][0] = 0;
    }
    for (i = 0; i < sizeof(kNames) / sizeof(kNames[0]); i++)
        Put(kNames[i], 0);
    PutStr(L"i0nm", L"");
    PutStr(L"i1nm", L"");
    PutStr(L"i2nm", L"");
    PutStr(L"i3nm", L"");
    PutBin(L"qwin", gPendWin, sizeof(gPendWin));
    PutBin(L"qexc", gPendExc, sizeof(gPendExc));
    PutBin(L"qxi0", gPendXi0, sizeof(gPendXi0));
    PutBin(L"qpte", gPendPte, sizeof(gPendPte));
    PutBin(L"qwlk", gPendWlk, sizeof(gPendWlk));
    PutBin(L"wstat", gPendWstat, sizeof(gPendWstat));
    PutBin(L"wprot", gPendWprot, sizeof(gPendWprot));
    ring[2] = 0;
    for (k = 0; k < 8; k++) {
        ring[1] = (WCHAR)(L'0' + k);
        ring[0] = L's'; Put(ring, 0);
        ring[0] = L'a'; Put(ring, 0);
        ring[0] = L'b'; Put(ring, 0);
        ring[0] = L'c'; Put(ring, 0);
        ring[0] = L'd'; Put(ring, 0);
        ring[0] = L'r'; Put(ring, 0);
        ring[0] = L'h'; Put(ring, 0);
        ring[0] = L'p'; Put(ring, 0);
    }
    PutBin(L"ring1", kNoRing, sizeof(kNoRing));
}

static ULONG
GetDword(PCWSTR name, ULONG def)
{
    UNICODE_STRING n;
    UCHAR buf[sizeof(KEY_VALUE_PARTIAL_INFORMATION) + 8];
    PKEY_VALUE_PARTIAL_INFORMATION pi = (PVOID)buf;
    ULONG got = 0;

    if (!gKey || KeGetCurrentIrql() != PASSIVE_LEVEL)
        return def;
    RtlInitUnicodeString(&n, name);
    if (NT_SUCCESS(ZwQueryValueKey(gKey, &n, KeyValuePartialInformation, pi, sizeof(buf), &got)) &&
        pi->Type == REG_DWORD && pi->DataLength == 4)
        return *(ULONG *)pi->Data;
    return def;
}

static BOOLEAN
GuidEq(const GUID *a, const GUID *b)
{
    return a && b && RtlCompareMemory(a, b, sizeof(GUID)) == sizeof(GUID);
}

/* Program the one stream stage 18 showed HLOS may write: SID 0 -> CB0.
 * Never touches sCR0/sCR2/CBAR or the APPS SMMU. */
static VOID
ProgramGpuStream(VOID)
{
    PHYSICAL_ADDRESS pa;
    PVOID base;
    ULONG smr, s2, ttlo, tthi;

    pa.QuadPart = SMMU_PHYS;
    Step(0x80);
    base = MmMapIoSpaceEx(pa, SMMU_SIZE, PAGE_READWRITE | PAGE_NOCACHE);
    if (!base) {
        Step(0x81);
        return;
    }
    Step(0x82);
    WRITE_REGISTER_ULONG((volatile ULONG *)((PUCHAR)base + S2CR0), 0u);
    WRITE_REGISTER_ULONG((volatile ULONG *)((PUCHAR)base + SMR0), 0x80000000u);
    smr = READ_REGISTER_ULONG((volatile ULONG *)((PUCHAR)base + SMR0));
    s2 = READ_REGISTER_ULONG((volatile ULONG *)((PUCHAR)base + S2CR0));
    Put(L"smr_rb", smr);
    Put(L"s2cr_rb", s2);
    ttlo = GetDword(L"ttbrlo", 0);
    tthi = GetDword(L"ttbrhi", 0);
    if (ttlo | tthi) {
        Step(0x88);
        WRITE_REGISTER_ULONG((volatile ULONG *)((PUCHAR)base + CB0_TTBR0), ttlo);
        WRITE_REGISTER_ULONG((volatile ULONG *)((PUCHAR)base + CB0_TTBR0 + 4u), tthi);
        Put(L"ttbr_rb", READ_REGISTER_ULONG((volatile ULONG *)((PUCHAR)base + CB0_TTBR0)));
    }
    MmUnmapIoSpace(base, SMMU_SIZE);
    Step(0x90);
}

/* qcdx at 0x266628 calls offset 0x50 and treats x0 == 0 as failure.
 * The pointer is only stored and later handed back to offset 0x58. */
static UINT64
AllocHandle(VOID)
{
    PVOID p;
    ULONG i;

    if (KeGetCurrentIrql() > APC_LEVEL)
        return 1;
    p = ExAllocatePoolWithTag(NonPagedPoolNx, PAGE_SIZE, 'mmSD');
    if (!p)
        return 1;
    RtlZeroMemory(p, PAGE_SIZE);
    for (i = 0; i < ALLOC_MAX; i++) {
        if (gAlloc[i] == NULL) {
            gAlloc[i] = p;
            return (UINT64)(ULONG_PTR)p;
        }
    }
    return (UINT64)(ULONG_PTR)p;
}

static VOID
FreeHandle(ULONG_PTR p)
{
    ULONG i;

    if (p <= 1 || KeGetCurrentIrql() > APC_LEVEL)
        return;
    for (i = 0; i < ALLOC_MAX; i++) {
        if (gAlloc[i] == (PVOID)p) {
            gAlloc[i] = NULL;
            ExFreePoolWithTag((PVOID)p, 'mmSD');
            return;
        }
    }
}

/* Slot 22 builds one of these. Slot 28 must return its byte length and
 * slot 27 its base (1 is qcdx's failure sentinel, so the base stays 0).
 * Slot 25 then carves a subrange and has to return that pointer: NULL is
 * the STATUS_NO_MEMORY behind problem code 43. */
#define VA_MAGIC  0x52474E53u
#define VA_PARENT 1u
#define VA_SUB    2u

typedef struct _VA_RANGE {
    ULONG Magic;
    ULONG Kind;
    ULONG_PTR Base;
    ULONG_PTR Size;
    ULONG_PTR Offset;
    ULONG Flags;
    struct _VA_RANGE *Parent;
} VA_RANGE;

static VA_RANGE *
NewRange(ULONG kind, ULONG_PTR base, ULONG_PTR size, ULONG_PTR offset, ULONG flags, VA_RANGE *parent)
{
    VA_RANGE *r;
    ULONG i;

    /* NonPagedPoolNx allocation is legal up to DISPATCH_LEVEL. The earlier
     * APC-only guard made slot 25 return NULL when the display path calls
     * the range allocator from a DPC, which qcdx reports as 0xC0001817. */
    if (KeGetCurrentIrql() > DISPATCH_LEVEL)
        return NULL;
    r = ExAllocatePoolWithTag(NonPagedPoolNx, sizeof(VA_RANGE), 'mmSD');
    if (!r)
        return NULL;
    RtlZeroMemory(r, sizeof(*r));
    r->Magic = VA_MAGIC;
    r->Kind = kind;
    r->Base = base;
    r->Size = size;
    r->Offset = offset;
    r->Flags = flags;
    r->Parent = parent;
    for (i = 0; i < ALLOC_MAX; i++) {
        if (gAlloc[i] == NULL) {
            gAlloc[i] = r;
            return r;
        }
    }
    return r;
}

static VA_RANGE *
AsRange(ULONG_PTR p)
{
    VA_RANGE *r;
    ULONG i;

    if (p < 0x10000)
        return NULL;
    for (i = 0; i < ALLOC_MAX; i++) {
        if (gAlloc[i] != (PVOID)p)
            continue;
        r = (VA_RANGE *)p;
        if (r->Magic == VA_MAGIC && (r->Kind == VA_PARENT || r->Kind == VA_SUB))
            return r;
        return NULL;
    }
    return NULL;
}

/* Last eight calls stay in the driver image. A bugcheck while ZwFlushKey
 * is running tears the SYSTEM hive (0xc000014c), so the ring is published
 * only every 16 calls, in one flush, and once more from the failure hook.
 * Entry i holds the call whose zero-based number n has (n & 7) == i.
 * Site is the qcdx return address as an RVA. When the return address is
 * outside the known qcdx image, Site is its low 32 bits and bit i of pout
 * is set. Rhi is the high half of the slot's 64-bit return value. */
typedef struct _CALL_REC {
    ULONG Slot;
    ULONG A, B, C, D, R;
    ULONG Rhi;
    ULONG Site;
} CALL_REC;

static CALL_REC gRing[8];
static ULONG gNcall;
/* Last slot call, used by the encoded stop code: the display path's failure
 * is slot 25 returning NULL, and this shows whether it was the IRQL guard,
 * a zero length, or the allocator. */
static ULONG gLastSlot;
static ULONG gLastIrql;
static ULONG gLastB;
static ULONG gLastSubOk;
/* Slot 24 is not implemented; record who calls it so the next stop code
 * points at the qcdx function that needs it. */
static ULONG gSite24;
static ULONG gA24, gB24, gC24, gD24;
static ULONG gSeen0;
static ULONG gSeen1;
static ULONG gPout;
static LONG gMap = -1;
/* qcdx image of the current load. OnLoad sets it when the name matches;
 * NoteCaller fills it from the PE header if OnLoad did not. */
static ULONG_PTR gQcdxBase;
static ULONG gQcdxSize;

static ULONG
SiteOf(ULONG_PTR caller, ULONG idx)
{
    ULONG_PTR base = gQcdxBase;

    if (base && caller >= base && caller - base < gQcdxSize) {
        gPout &= ~(1u << idx);
        return (ULONG)(caller - base);
    }
    gPout |= 1u << idx;
    return (ULONG)caller;
}

/* Values only, no flush. The caller decides when to ZwFlushKey. */
static VOID
WriteRing(VOID)
{
    ULONG i, last;
    WCHAR name[3];

    if (!gKey || KeGetCurrentIrql() != PASSIVE_LEVEL)
        return;
    for (i = 0; i < 8; i++) {
        name[1] = (WCHAR)(L'0' + i);
        name[2] = 0;
        name[0] = L's'; Put(name, gRing[i].Slot);
        name[0] = L'a'; Put(name, gRing[i].A);
        name[0] = L'b'; Put(name, gRing[i].B);
        name[0] = L'c'; Put(name, gRing[i].C);
        name[0] = L'd'; Put(name, gRing[i].D);
        name[0] = L'r'; Put(name, gRing[i].R);
        name[0] = L'h'; Put(name, gRing[i].Rhi);
        name[0] = L'p'; Put(name, gRing[i].Site);
    }
    last = (gNcall - 1) & 7;
    Put(L"ncall", gNcall);
    Put(L"slot", gRing[last].Slot);
    Put(L"arg0", gRing[last].A);
    Put(L"arg1", gRing[last].B);
    Put(L"arg2", gRing[last].C);
    Put(L"arg3", gRing[last].D);
    Put(L"retlo", gRing[last].R);
    Put(L"rethi", gRing[last].Rhi);
    Put(L"site", gRing[last].Site);
    Put(L"pout", gPout);
    Put(L"qblo", (ULONG)gQcdxBase);
    Put(L"qbhi", (ULONG)(gQcdxBase >> 32));
    Put(L"seen0", gSeen0);
    Put(L"seen1", gSeen1);
}

static VOID
FlushRing(VOID)
{
    if (!gKey || KeGetCurrentIrql() != PASSIVE_LEVEL)
        return;
    WriteRing();
    Put(L"step", 0x60);
    StampGen();
    ZwFlushKey(gKey);
}

static UINT64
SlotDispatch(ULONG slot, ULONG_PTR a, ULONG_PTR b, ULONG_PTR c, ULONG_PTR d, ULONG_PTR caller)
{
    CALL_REC *rec;
    UINT64 ret = 0;

    NoteCaller(caller);
    gLastSlot = slot;
    gLastIrql = KeGetCurrentIrql();
    gLastB = (ULONG)b;
    if (slot == 24) {
        if (gQcdxBase && caller >= gQcdxBase && caller - gQcdxBase < gQcdxSize)
            gSite24 = (ULONG)(caller - gQcdxBase);
        else
            gSite24 = (ULONG)caller | 0x80000000u;
        gA24 = (ULONG)a;
        gB24 = (ULONG)b;
        gC24 = (ULONG)c;
        gD24 = (ULONG)d;
    }
    if (slot == SLOT_ALLOC)
        ret = AllocHandle();
    else if (slot == SLOT_BIND) {
        VA_RANGE *parent;
        ULONG_PTR window = b;

        if (window < VA_WINDOW)
            window = VA_WINDOW;
        parent = NewRange(VA_PARENT, 0, window, 0, (ULONG)c, NULL);
        ret = parent ? (UINT64)(ULONG_PTR)parent : 0;
    } else if (slot == SLOT_SUB) {
        VA_RANGE *sub = NULL;

        if (b != 0)
            sub = NewRange(VA_SUB, c, b, c, (ULONG)d, AsRange(a));
        ret = sub ? (UINT64)(ULONG_PTR)sub : 0;
        gLastSubOk = ret ? 1u : 0u;
        Put(L"suboff", (ULONG)c);
        Put(L"subsz", (ULONG)b);
        Put(L"subok", ret ? 1u : 0u);
    } else if (slot == SLOT_BASE) {
        VA_RANGE *r = AsRange(a);
        ret = r ? r->Base : 0;
    } else if (slot == SLOT_PHYS) {
        VA_RANGE *r = AsRange(a);
        ret = r ? r->Size : (a ? (UINT64)a : 1);
    } else if (slot == SLOT_FREE || slot == SLOT_UNBIND || slot == SLOT_DROP)
        FreeHandle(a);
    rec = &gRing[gNcall & 7];
    rec->Slot = slot;
    rec->A = (ULONG)a;
    rec->B = (ULONG)b;
    rec->C = (ULONG)c;
    rec->D = (ULONG)d;
    rec->R = (ULONG)ret;
    rec->Rhi = (ULONG)(ret >> 32);
    rec->Site = SiteOf(caller, gNcall & 7);
    if (slot < 32)
        gSeen0 |= (1u << slot);
    else if (slot < 64)
        gSeen1 |= (1u << (slot - 32));
    gNcall++;
    if ((gNcall & 15) == 0)
        FlushRing();
    if (slot == SLOT_MAP && gIfaceKind == 1) {
        if (gMap < 0)
            gMap = (LONG)GetDword(L"map", 0);
        if (gMap != 0)
            ProgramGpuStream();
    }
    /* Probe (slot 44) is 0, so qcdx does call the map slot.
     * Slot 6 must not be 0: qcdx treats that as a failed allocation. */
    return ret;
}

#define SLOT(n) \
    static UINT64 Slot##n(ULONG_PTR a, ULONG_PTR b, ULONG_PTR c, ULONG_PTR d) \
    { return SlotDispatch(n, a, b, c, d, (ULONG_PTR)__builtin_return_address(0)); }
SLOT(0)  SLOT(1)  SLOT(2)  SLOT(3)  SLOT(4)  SLOT(5)  SLOT(6)  SLOT(7)
SLOT(8)  SLOT(9)  SLOT(10) SLOT(11) SLOT(12) SLOT(13) SLOT(14) SLOT(15)
SLOT(16) SLOT(17) SLOT(18) SLOT(19) SLOT(20) SLOT(21) SLOT(22) SLOT(23)
SLOT(24) SLOT(25) SLOT(26) SLOT(27) SLOT(28) SLOT(29) SLOT(30) SLOT(31)
SLOT(32) SLOT(33) SLOT(34) SLOT(35) SLOT(36) SLOT(37) SLOT(38) SLOT(39)
SLOT(40) SLOT(41) SLOT(42) SLOT(43) SLOT(44) SLOT(45) SLOT(46) SLOT(47)

typedef UINT64 (*SLOT_FN)(ULONG_PTR, ULONG_PTR, ULONG_PTR, ULONG_PTR);
static const SLOT_FN kSlots[SLOT_COUNT] = {
    Slot0,  Slot1,  Slot2,  Slot3,  Slot4,  Slot5,  Slot6,  Slot7,
    Slot8,  Slot9,  Slot10, Slot11, Slot12, Slot13, Slot14, Slot15,
    Slot16, Slot17, Slot18, Slot19, Slot20, Slot21, Slot22, Slot23,
    Slot24, Slot25, Slot26, Slot27, Slot28, Slot29, Slot30, Slot31,
    Slot32, Slot33, Slot34, Slot35, Slot36, Slot37, Slot38, Slot39,
    Slot40, Slot41, Slot42, Slot43, Slot44, Slot45, Slot46, Slot47
};

static VOID
IfaceRef(PVOID ctx)
{
    InterlockedIncrement(&((PSHIM_EXT)ctx)->Refs);
}

static VOID
IfaceDeref(PVOID ctx)
{
    InterlockedDecrement(&((PSHIM_EXT)ctx)->Refs);
}

static NTSTATUS
SyncComplete(PDEVICE_OBJECT dev, PIRP irp, PVOID ctx)
{
    UNREFERENCED_PARAMETER(dev);
    UNREFERENCED_PARAMETER(irp);
    KeSetEvent((PKEVENT)ctx, IO_NO_INCREMENT, FALSE);
    return STATUS_MORE_PROCESSING_REQUIRED;
}

static NTSTATUS
ForwardAndWait(PDEVICE_OBJECT dev, PIRP irp)
{
    KEVENT ev;
    NTSTATUS st;
    PSHIM_EXT ext = dev->DeviceExtension;

    KeInitializeEvent(&ev, NotificationEvent, FALSE);
    IoCopyCurrentIrpStackLocationToNext(irp);
    IoSetCompletionRoutine(irp, SyncComplete, &ev, TRUE, TRUE, TRUE);
    st = IoCallDriver(ext->Lower, irp);
    if (st == STATUS_PENDING) {
        KeWaitForSingleObject(&ev, Executive, KernelMode, FALSE, NULL);
        st = irp->IoStatus.Status;
    }
    return st;
}

static NTSTATUS
PublishLinks(PSHIM_EXT ext)
{
    const GUID *guids[3];
    ULONG i;
    NTSTATUS st;

    guids[0] = &kGuidDisp;
    guids[1] = &kGuidGpu;
    guids[2] = &kGuidVideo;
    for (i = 0; i < 3; i++) {
        st = IoRegisterDeviceInterface(ext->Pdo, guids[i], NULL, &ext->Link[i]);
        if (!NT_SUCCESS(st)) {
            Put(L"regif", st);
            Step(0x31);
            return st;
        }
        st = IoSetDeviceInterfaceState(&ext->Link[i], TRUE);
        if (!NT_SUCCESS(st)) {
            Put(L"enif", st);
            Step(0x32);
            return st;
        }
    }
    ext->Started = TRUE;
    Step(0x30);
    return STATUS_SUCCESS;
}

static VOID
DropLinks(PSHIM_EXT ext)
{
    ULONG i;
    for (i = 0; i < 3; i++) {
        if (ext->Link[i].Buffer) {
            IoSetDeviceInterfaceState(&ext->Link[i], FALSE);
            RtlFreeUnicodeString(&ext->Link[i]);
        }
    }
    ext->Started = FALSE;
}

static NTSTATUS
FillInterface(PSHIM_EXT ext, const GUID *type, USHORT size, USHORT version, PINTERFACE iface)
{
    PUCHAR raw;
    ULONG i, n;

    if (!iface || size < sizeof(INTERFACE) || version < 1)
        return STATUS_INVALID_PARAMETER;
    if (!GuidEq(type, &kIfaceDefault) && !GuidEq(type, &kIfaceVideo) && !GuidEq(type, &kIfaceRetry))
        return STATUS_NOT_SUPPORTED;
    gIfaceKind = GuidEq(type, &kIfaceVideo) ? 2 : 1;
    Put(L"iface", (ULONG)gIfaceKind);
    Put(L"qsize", size);
    Put(L"qver", version);
    raw = (PUCHAR)iface;
    RtlZeroMemory(raw, size);
    iface->Size = size;
    iface->Version = version;
    iface->Context = ext;
    iface->InterfaceReference = IfaceRef;
    iface->InterfaceDereference = IfaceDeref;
    IfaceRef(ext);
    n = (size - IFACE_FN0) / sizeof(PVOID);
    if (n > SLOT_COUNT)
        n = SLOT_COUNT;
    for (i = 0; i < n; i++)
        *(PVOID *)(raw + IFACE_FN0 + i * sizeof(PVOID)) = (PVOID)kSlots[i];
    Step(0x40);
    return STATUS_SUCCESS;
}

static NTSTATUS
DispatchOk(PDEVICE_OBJECT dev, PIRP irp)
{
    UNREFERENCED_PARAMETER(dev);
    irp->IoStatus.Status = STATUS_SUCCESS;
    irp->IoStatus.Information = 0;
    IoCompleteRequest(irp, IO_NO_INCREMENT);
    return STATUS_SUCCESS;
}

static NTSTATUS
DispatchPass(PDEVICE_OBJECT dev, PIRP irp)
{
    PSHIM_EXT ext = dev->DeviceExtension;
    IoSkipCurrentIrpStackLocation(irp);
    return IoCallDriver(ext->Lower, irp);
}

static NTSTATUS
DispatchPower(PDEVICE_OBJECT dev, PIRP irp)
{
    PSHIM_EXT ext = dev->DeviceExtension;
    PoStartNextPowerIrp(irp);
    IoSkipCurrentIrpStackLocation(irp);
    return PoCallDriver(ext->Lower, irp);
}

static NTSTATUS
DispatchPnp(PDEVICE_OBJECT dev, PIRP irp)
{
    PSHIM_EXT ext = dev->DeviceExtension;
    PIO_STACK_LOCATION sp = IoGetCurrentIrpStackLocation(irp);
    NTSTATUS st;

    switch (sp->MinorFunction) {
    case IRP_MN_START_DEVICE:
        st = ForwardAndWait(dev, irp);
        if (NT_SUCCESS(st))
            st = PublishLinks(ext);
        irp->IoStatus.Status = st;
        IoCompleteRequest(irp, IO_NO_INCREMENT);
        return st;
    case IRP_MN_QUERY_INTERFACE:
        st = FillInterface(ext, sp->Parameters.QueryInterface.InterfaceType,
                           sp->Parameters.QueryInterface.Size,
                           sp->Parameters.QueryInterface.Version,
                           sp->Parameters.QueryInterface.Interface);
        if (st == STATUS_NOT_SUPPORTED)
            return DispatchPass(dev, irp);
        irp->IoStatus.Status = st;
        IoCompleteRequest(irp, IO_NO_INCREMENT);
        return st;
    case IRP_MN_REMOVE_DEVICE:
        DropLinks(ext);
        IoSkipCurrentIrpStackLocation(irp);
        st = IoCallDriver(ext->Lower, irp);
        IoDetachDevice(ext->Lower);
        IoDeleteDevice(dev);
        Step(0x70);
        return st;
    default:
        return DispatchPass(dev, irp);
    }
}

static NTSTATUS
AddDevice(PDRIVER_OBJECT drv, PDEVICE_OBJECT pdo)
{
    PDEVICE_OBJECT fdo = NULL;
    PSHIM_EXT ext;
    NTSTATUS st;

    st = IoCreateDevice(drv, sizeof(SHIM_EXT), NULL, FILE_DEVICE_UNKNOWN,
                        FILE_DEVICE_SECURE_OPEN, FALSE, &fdo);
    if (!NT_SUCCESS(st))
        return st;
    ext = fdo->DeviceExtension;
    RtlZeroMemory(ext, sizeof(*ext));
    ext->Pdo = pdo;
    ext->Lower = IoAttachDeviceToDeviceStack(fdo, pdo);
    if (!ext->Lower) {
        IoDeleteDevice(fdo);
        Step(0x21);
        return STATUS_NO_SUCH_DEVICE;
    }
    fdo->Flags |= DO_POWER_PAGABLE;
    fdo->Flags &= ~DO_DEVICE_INITIALIZING;
    Step(0x20);
    return STATUS_SUCCESS;
}

static VOID OnLoad(PUNICODE_STRING name, HANDLE pid, PIMAGE_INFO info);

static VOID
Unload(PDRIVER_OBJECT drv)
{
    UNREFERENCED_PARAMETER(drv);
    PsRemoveLoadImageNotifyRoutine(OnLoad);
    if (gKey) {
        ZwClose(gKey);
        gKey = NULL;
    }
}

static VOID
OpenParams(PUNICODE_STRING reg)
{
    OBJECT_ATTRIBUTES oa;
    UNICODE_STRING sub;
    HANDLE svc;
    ULONG disp;

    InitializeObjectAttributes(&oa, reg, OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE, NULL, NULL);
    if (!NT_SUCCESS(ZwOpenKey(&svc, KEY_CREATE_SUB_KEY, &oa)))
        return;
    RtlInitUnicodeString(&sub, L"Parameters");
    InitializeObjectAttributes(&oa, &sub, OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE, svc, NULL);
    ZwCreateKey(&gKey, KEY_SET_VALUE | KEY_QUERY_VALUE, &oa, 0, NULL, REG_OPTION_NON_VOLATILE, &disp);
    ZwClose(svc);
}

/* qcdx's failure path loads this pointer and calls it with w19 before it
 * returns. The write happens on the first slot callback, while qcdx is still
 * mapped. Nothing reads qcdx after it unloads. */
#define QCDX_HOOK_RVA 0x1c66c0u

static LONG gHooked;
static ULONG gFailN;
/* When set (Parameters\rstonfail=1), the GPU StartDevice failure tail
 * resets the box after flushing, so an A-slot hang becomes a counted reset
 * and ABL falls back to B on its own. Read once in DriverEntry. */
static ULONG gRstOnFail;

/* RVA of the loadpatch trampoline's return site. When RecordStatus runs
 * with this return address, the call came through the failure-tail
 * trampoline at 0x2c7768, and the adapter pointer is still live in x20.
 * At the three generic hook sites (0x133854/0x133a2c/0x133b0c) x20 is not
 * the adapter, so the adapter fields are read only for this exact site. */
#define QCDX_TRAMP_SITE 0x2c777cu

/* FillMode injection. FUN_1402934b0 (StartDevice adapter init) fails at
 * 0xC0000001 because the upstream mode-enumeration stage produced no mode
 * data: adapter+0x780 (mode type) is 0 but FUN_140276fd0 needs 5, and the
 * framebuffer descriptor at adapter+0x638 has a zero scan buffer where
 * FUN_140319718 needs +0x1110 >= 0x5000 with +0x1108/+0x1118 non-null.
 *
 * At 0x294438 the function calls KeInitializeGuardedMutex(&global) through
 * the import slot at .rdata 0x14a360, returning to 0x29443c. That call sits
 * before 0x294460 (first read of adapter+0x638) and before 0x2944e8 (the
 * FUN_140276fd0 call that reads +0x780). The whole 0x2934b0 body (1244
 * instructions, fully decoded) has no store to +0x638, so the descriptor
 * pointer is stable upstream input. x20 holds the adapter across the call
 * (callee-saved). Redirecting that one import slot to a thunk that calls the
 * real KeInitializeGuardedMutex and then fills the mode fields lands both
 * groups before any gate reads them, without editing a single instruction.
 *
 * The slot is shared by every KeInitializeGuardedMutex caller, so the thunk
 * forwards unconditionally and only fills when the return address is the
 * 0x29443c site. */
#define QCDX_KEINITGM_IAT_RVA 0x14a360u
#define QCDX_FILLMODE_SITE    0x29443cu

/* Measured on the device (B-slot Linux, panel l81a_42_04_0a, 1600x2560x32).
 * +0x780 == 5 is hard gate 1. The GOP framebuffer UEFI already lit is at
 * phys 0x9C000000, 0xFA0000 bytes (== 1600*2560*4), stride 0x1900 (1600*4);
 * its size satisfies the >= 0x5000 scan-size gate. The sub-mode id only
 * selects a pixel-format branch and avoids an error log; a mismatch still
 * continues, so it is not a gate. */
#define FM_MODE_TYPE  5u
#define FM_SUBMODE_ID 0x026a0064u
#define FM_FB_BASE    0x9C000000ull
#define FM_SCAN_SIZE  0x00FA0000ull
#define FM_STRIDE     0x00001900ull

/* Set once when the import slot is redirected. gRealKeInitGM is the original
 * KeInitializeGuardedMutex pointer read out of the slot; the thunk forwards
 * to it. gFillSite is base+0x29443c, the one return address that triggers a
 * fill. The fm* counters are diagnostics flushed by RecordStatus. */
static LONG gFillHooked;
/* Not static: FillModeThunk's naked asm loads these. A static symbol is
 * not a reliable operand for adrp/:lo12: in clang-cl inline asm. */
PVOID gRealKeInitGM;
ULONG_PTR gFillSite;
/* Naked thunk updates these. gFmSeen counts every import call, gFmLastRet
 * is the low 32 bits of the last return address, so a missed site compare
 * is visible after the failure bugcheck. */
ULONG gFmSeen;
ULONG gFmLastRet;
static ULONG gFmInstall;   /* 0 none, 1 installed, 9 slot read faulted, 0x1x WriteQcdxPtr stat */
static ULONG gFmInstDetail;
static ULONG gFmCall;      /* thunk reached our site */
static ULONG gFmHit;       /* FillMode completed */
static ULONG gFmAflt;      /* A group / descriptor read faulted */
static ULONG gFmBflt;      /* B group write faulted */
static ULONG64 gFmDesc;    /* descriptor pointer seen at fill time */

/* Last qcdx log-wrapper event codes, newest first. The wrapper at RVA
 * 0x10920 forwards its event code to FUN_140107d8 through the bl at RVA
 * 0x10950; the shim redirects that one instruction to LogThunk, which
 * records w2 and then calls the original target. The failure tail always
 * logs 0x998, so the gate that failed sits a few entries deeper. A 16-entry
 * ring is kept because the display-config parser logs several stages before
 * the StartDevice tail. Non-static for the inline asm. */
PVOID gLogReal;
ULONG gLogRing[16];
ULONG gSiteRing[16];
ULONG gLogCount;
ULONG gLogSeen;
static LONG gLogHooked;
static ULONG gLogInstall;  /* 0 none, 1 installed, 3 unexpected insn, 8 out of bl range, 9 read fault, 0x1x write stat */

VOID FillMode(ULONG_PTR adapter);

/* Read the active DSDT identity from the HARDWARE hive. ACPI publishes one
 * subkey per loaded table under ...\ACPI\DSDT\<OEMID>\<TABLEID>; the subkey
 * name is the table revision and its values carry the AML bytes. Run once at
 * the failure point (PASSIVE), so it describes the table this boot used. */
static ULONG
HexName(PCWSTR s, ULONG n)
{
    ULONG v = 0;
    ULONG i;

    for (i = 0; i < n; i++) {
        WCHAR c = s[i];
        ULONG d;

        if (c >= L'0' && c <= L'9')
            d = c - L'0';
        else if (c >= L'a' && c <= L'f')
            d = c - L'a' + 10;
        else if (c >= L'A' && c <= L'F')
            d = c - L'A' + 10;
        else
            break;
        v = (v << 4) | d;
    }
    return v;
}

static VOID
ReadActiveDsdt(VOID)
{
    UNICODE_STRING name;
    OBJECT_ATTRIBUTES oa;
    HANDLE h = NULL;
    NTSTATUS st;
    UCHAR buf[512];
    ULONG i;
    ULONG len;

    if (InterlockedCompareExchange(&gAcpDone, 1, 0) != 0)
        return;
    RtlInitUnicodeString(&name,
        L"\\Registry\\Machine\\HARDWARE\\ACPI\\DSDT\\QCOMM_\\SM8250_");
    InitializeObjectAttributes(&oa, &name,
                               OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE,
                               NULL, NULL);
    st = ZwOpenKey(&h, KEY_QUERY_VALUE, &oa);
    if (!NT_SUCCESS(st)) {
        gAcpF = (ULONG)st;
        return;
    }
    for (i = 0; i < 4; i++) {
        KEY_BASIC_INFORMATION *bi = (KEY_BASIC_INFORMATION *)buf;
        UNICODE_STRING sub;
        HANDLE hs = NULL;

        len = 0;
        st = ZwEnumerateKey(h, i, KeyBasicInformation, buf, sizeof(buf), &len);
        if (!NT_SUCCESS(st))
            break;
        gAcpN++;
        gAcpK[i] = HexName(bi->Name, bi->NameLength / sizeof(WCHAR));
        sub.Buffer = bi->Name;
        sub.Length = (USHORT)bi->NameLength;
        sub.MaximumLength = (USHORT)bi->NameLength;
        InitializeObjectAttributes(&oa, &sub,
                                   OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE, h, NULL);
        if (NT_SUCCESS(ZwOpenKey(&hs, KEY_QUERY_VALUE, &oa))) {
            UCHAR vbuf[512];
            ULONG vlen = 0;

            if (NT_SUCCESS(ZwEnumerateValueKey(hs, 0, KeyValueFullInformation,
                                               vbuf, sizeof(vbuf), &vlen)))
                gAcpL[i] = ((KEY_VALUE_FULL_INFORMATION *)vbuf)->DataLength;
            else if (!gAcpF)
                gAcpF = 1;
            ZwClose(hs);
        } else if (!gAcpF) {
            gAcpF = 2;
        }
    }
    ZwClose(h);
}

/* Binary diagnostic record appended to \??\C:\dagu\shim.bin. The registry
 * channel stopped persisting after the manual hive edit (fail stayed 0 even
 * though the bugcheck ran), so file output is the reliable measurement path.
 * One fixed-size record per call; parse it on the B-slot Linux side. */
#define DIAG_MAGIC 0x47414444u /* 'DDAG' */
#define DIAG_VER   2u

typedef struct _DIAG_REC {
    ULONG Magic, Ver, BootGen, Step, Fail, Fsite, Ncall, Nfail, Rst;
    ULONG Fminst, Fmseen, Fmlast, Fmcall, Fmhit, Fmaflt, Fmbflt;
    ULONG LogCount;
    ULONG Hist[16], Lsite[16];
    ULONG OvIns, OvLen, OvFlt;
    ULONG AcpN, AcpF, AcpK[4], AcpL[4];
    ULONG Adlo, Adhi, A630, A638lo, A638hi, A780, A46c4, Aflt;
    ULONG QPatch, QPendStep, Ihit, Fmdsclo, Fmdschi, Pad;
} DIAG_REC;

static VOID
WriteDiag(ULONG fail, ULONG fsite, ULONG_PTR adapter)
{
    UNICODE_STRING path;
    OBJECT_ATTRIBUTES oa;
    IO_STATUS_BLOCK iosb;
    HANDLE h = NULL;
    NTSTATUS st;
    DIAG_REC r;
    ULONG i;

    RtlZeroMemory(&r, sizeof(r));
    r.Magic = DIAG_MAGIC;
    r.Ver = DIAG_VER;
    r.BootGen = gBootGen;
    r.Step = gLastStep;
    r.Fail = fail;
    r.Fsite = fsite;
    r.Ncall = gNcall;
    r.Nfail = gFailN;
    r.Rst = gRstOnFail;
    r.Fminst = gFmInstall;
    r.Fmseen = gFmSeen;
    r.Fmlast = gFmLastRet;
    r.Fmcall = gFmCall;
    r.Fmhit = gFmHit;
    r.Fmaflt = gFmAflt;
    r.Fmbflt = gFmBflt;
    r.LogCount = gLogCount;
    for (i = 0; i < 16; i++) {
        ULONG k = (gLogCount ? (gLogCount - 1 - i) : 0) & 15;

        r.Hist[i] = gLogRing[k];
        r.Lsite[i] = gSiteRing[k];
    }
    r.OvIns = gOvIns;
    r.OvLen = gOvLen;
    r.OvFlt = gOvFlt;
    r.QPatch = gPendMask;
    r.QPendStep = gPendStep;
    r.Ihit = gIhit;
    r.AcpN = gAcpN;
    r.AcpF = gAcpF;
    for (i = 0; i < 4; i++) {
        r.AcpK[i] = gAcpK[i];
        r.AcpL[i] = gAcpL[i];
    }
    r.Fmdsclo = (ULONG)gFmDesc;
    r.Fmdschi = (ULONG)(gFmDesc >> 32);
    if (adapter) {
        __try {
            ULONG64 d638 = *(volatile ULONG64 *)(adapter + 0x638);

            r.Adlo = (ULONG)adapter;
            r.Adhi = (ULONG)(adapter >> 32);
            r.A630 = *(volatile ULONG *)(adapter + 0x630);
            r.A638lo = (ULONG)d638;
            r.A638hi = (ULONG)(d638 >> 32);
            r.A780 = *(volatile ULONG *)(adapter + 0x780);
            r.A46c4 = *(volatile ULONG *)(adapter + 0x46c4);
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            r.Aflt = 1;
        }
    }
    RtlInitUnicodeString(&path, L"\\SystemRoot\\dagu-shim.bin");
    InitializeObjectAttributes(&oa, &path,
                               OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE,
                               NULL, NULL);
    st = ZwCreateFile(&h, FILE_APPEND_DATA | SYNCHRONIZE, &oa, &iosb, NULL,
                      FILE_ATTRIBUTE_NORMAL, FILE_SHARE_READ | FILE_SHARE_WRITE,
                      FILE_OPEN_IF,
                      FILE_SYNCHRONOUS_IO_NONALERT | FILE_NON_DIRECTORY_FILE |
                          FILE_WRITE_THROUGH,
                      NULL, 0);
    if (!NT_SUCCESS(st))
        return;
    st = ZwWriteFile(h, NULL, NULL, NULL, &iosb, &r, sizeof(r), NULL, NULL);
    if (NT_SUCCESS(st))
        ZwFlushBuffersFile(h, &iosb);
    ZwClose(h);
}

/* PASSIVE_LEVEL writer. RecordStatus sets gLastFail/gLastSite/gLastAd and
 * queues a work item; the worker appends the record. This survives the
 * compiler dropping a direct call in the failure tail and does not depend
 * on PsCreateSystemThread, which never produced a record on the device. */
static WORK_QUEUE_ITEM gDiagItem;
static LONG gDiagQueued;

static VOID
DiagWorker(PVOID ctx)
{
    UNREFERENCED_PARAMETER(ctx);
    InterlockedExchange(&gDiagQueued, 0);
    WriteDiag(gLastFail, gLastSite, gLastAd);
}

static VOID
QueueDiag(VOID)
{
    if (InterlockedCompareExchange(&gDiagQueued, 1, 0) == 0)
        ExQueueWorkItem(&gDiagItem, DelayedWorkQueue);
}

/* The hook can run more than once per load: a stop or rollback after the
 * first failure reaches the same exit with the same status. fail1, fcall1,
 * fsite1 and ring1 belong to the first call and are never overwritten.
 * fail, fcall, fsite and the s/a/b/c/d/r/h/p ring keys follow the last one.
 * fsite is the RVA in qcdx that called the hook (pout bit 8 when it is
 * outside the image). ring1 is the eight CALL_REC entries, indexed as in
 * the live ring, followed by ncall at that moment.
 *
 * adapter is x20 captured by RecordStatusThunk before this prologue runs.
 * When fsite is the trampoline site, FUN_1402934b0 reads these adapter
 * fields at the failure point and we sample them here to settle the
 * static ambiguity:
 *   a630      *(ULONG  *)(adapter+0x630)  display-path enable flag
 *   a638lo/hi *(ULONG64*)(adapter+0x638)  framebuffer descriptor pointer
 *   a780      *(ULONG  *)(adapter+0x780)  mode type (FUN_140276fd0 needs 5)
 *   adlo/adhi  adapter pointer itself (sanity)
 * aflt is 1 if any of those reads faulted.
 *
 * External linkage, not static: RecordStatusThunk references this symbol
 * from inline asm (b RecordStatus), which emits an external relocation that
 * an internal-linkage symbol would not satisfy. */
VOID
RecordStatus(ULONG status, ULONG_PTR adapter)
{
    ULONG_PTR ret = (ULONG_PTR)__builtin_return_address(0);
    ULONG site;
    struct {
        CALL_REC Ring[8];
        ULONG Ncall;
    } snap;

    if (KeGetCurrentIrql() == PASSIVE_LEVEL)
        ReadActiveDsdt();
    if (gQcdxBase && ret >= gQcdxBase && ret - gQcdxBase < gQcdxSize) {
        site = (ULONG)(ret - gQcdxBase);
        gPout &= ~(1u << 8);
    } else {
        site = (ULONG)ret;
        gPout |= 1u << 8;
    }
    gLastFail = status;
    gLastSite = site;
    gLastAd = adapter;
    /* Bugcheck before any registry Put/Flush. A flush followed by a reset
     * tears the SYSTEM hive (0xC0000218 / 0xC000014C), so the rstonfail path
     * writes nothing and relies on the encoded stop code instead. */
    if (site == QCDX_TRAMP_SITE && gRstOnFail &&
        KeGetCurrentIrql() == PASSIVE_LEVEL) {
        /* 0xDA0?XX: low byte is the qpatch mask (0x7F = all seven sites,
         * 0x3F = the version patch missed); bit 10 = FillMode ran, bit 11 =
         * the import site matched. */
        KeBugCheckEx(0xDA0000u | ((gFmCall ? 1u : 0u) << 11) |
                         ((gFmHit ? 1u : 0u) << 10) | (gPendMask & 0xFFu),
                     0x780, status, adapter, gBootGen);
    }
    gFailN++;
    if (gFailN == 1) {
        RtlCopyMemory(snap.Ring, gRing, sizeof(snap.Ring));
        snap.Ncall = gNcall;
        Put(L"fail1", status);
        Put(L"fcall1", gNcall);
        Put(L"fsite1", site);
        PutBin(L"ring1", &snap, sizeof(snap));
    }
    /* gNcall is this load's slot-callback count. Zero means adapter init
     * failed before any SMMU callback. */
    Put(L"fail", status);
    Put(L"fcall", gNcall);
    Put(L"fsite", site);
    Put(L"nfail", gFailN);
    /* Only the trampoline site carries the adapter in x20. */
    if (site == QCDX_TRAMP_SITE && adapter) {
        ULONG a630 = 0, a780 = 0, aflt = 0;
        ULONG64 a638 = 0;
        Put(L"adlo", (ULONG)adapter);
        Put(L"adhi", (ULONG)(adapter >> 32));
        __try {
            a630 = *(volatile ULONG *)(adapter + 0x630);
            a638 = *(volatile ULONG64 *)(adapter + 0x638);
            a780 = *(volatile ULONG *)(adapter + 0x780);
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            aflt = 1;
        }
        Put(L"a630", a630);
        Put(L"a638lo", (ULONG)a638);
        Put(L"a638hi", (ULONG)(a638 >> 32));
        Put(L"a780", a780);
        Put(L"aflt", aflt);

        /* a780 == 0 at the failure point but FUN_140276fd0 needs 5. The
         * mode type and its geometry siblings are never stored by any
         * instruction in the image; they are block-filled by the upstream
         * mode-enumeration stage. Sample the whole mode-geometry group so a
         * single boot tells us which input the enumeration failed to
         * produce. FUN_140276fd0 reads these adapter offsets alongside
         * +0x780:
         *   +0x784   mode flags      (a784)
         *   +0x788   sub-mode id     (a788; legal 0x26a0064/0x2760014/
         *                             0x2a80014/0x2b2000a)
         *   +0x3b78  geometry a      (a3b78)
         *   +0x3b7c  geometry b      (a3b7c)
         *   +0x3b90  stride shift    (a3b90)
         *   +0x46c4  packed geometry (a46c4)
         * Separate __try so a fault here cannot lose the group above. */
        {
            ULONG a784 = 0, a788 = 0, a3b78 = 0, a3b7c = 0, a3b90 = 0,
                  a46c4 = 0, mflt = 0;
            __try {
                a784  = *(volatile ULONG *)(adapter + 0x784);
                a788  = *(volatile ULONG *)(adapter + 0x788);
                a3b78 = *(volatile ULONG *)(adapter + 0x3b78);
                a3b7c = *(volatile ULONG *)(adapter + 0x3b7c);
                a3b90 = *(volatile ULONG *)(adapter + 0x3b90);
                a46c4 = *(volatile ULONG *)(adapter + 0x46c4);
            } __except (EXCEPTION_EXECUTE_HANDLER) {
                mflt = 1;
            }
            Put(L"a784", a784);
            Put(L"a788", a788);
            Put(L"a3b78", a3b78);
            Put(L"a3b7c", a3b7c);
            Put(L"a3b90", a3b90);
            Put(L"a46c4", a46c4);
            Put(L"mflt", mflt);
        }

        /* When a638 (the framebuffer descriptor) is non-null, FUN_140294460
         * reads three fields out of it and FUN_140319718 later rejects the
         * mode unless the scan buffer at descriptor +0x1110 is >= 0x5000 and
         * the two pointers at +0x1108/+0x1118 are non-null. Sample them so
         * we know whether a638 carries a usable framebuffer or an empty one.
         *   desc+0x1108  fb base ptr   (d1108lo/hi)
         *   desc+0x1110  scan size     (d1110lo/hi)
         *   desc+0x1118  fb stride ptr (d1118lo/hi)
         * Separate __try; descriptor may be a bad pointer. */
        if (a638 && !aflt) {
            ULONG64 d1108 = 0, d1110 = 0, d1118 = 0;
            ULONG dflt = 0;
            __try {
                d1108 = *(volatile ULONG64 *)(a638 + 0x1108);
                d1110 = *(volatile ULONG64 *)(a638 + 0x1110);
                d1118 = *(volatile ULONG64 *)(a638 + 0x1118);
            } __except (EXCEPTION_EXECUTE_HANDLER) {
                dflt = 1;
            }
            Put(L"d1108lo", (ULONG)d1108);
            Put(L"d1108hi", (ULONG)(d1108 >> 32));
            Put(L"d1110lo", (ULONG)d1110);
            Put(L"d1110hi", (ULONG)(d1110 >> 32));
            Put(L"d1118lo", (ULONG)d1118);
            Put(L"d1118hi", (ULONG)(d1118 >> 32));
            Put(L"dflt", dflt);
        }
        /* FillMode runtime result, flushed on the same failure tail so one
         * boot shows whether the import hook fired before the gates. fmcall
         * is how many times the thunk saw the 0x29443c site, fmhit how many
         * times FillMode ran, fmaflt/fmbflt the per-group fault counts, and
         * fmdesc the descriptor pointer seen at fill time. */
        Put(L"fmcall", gFmCall);
        Put(L"fmhit", gFmHit);
        Put(L"fmaflt", gFmAflt);
        Put(L"fmbflt", gFmBflt);
        Put(L"fmdsclo", (ULONG)gFmDesc);
        Put(L"fmdschi", (ULONG)(gFmDesc >> 32));
    }
    /* Thunk entry count and the last return address it saw. fmcall stays 0
     * when the site compare misses; fmseen tells those two cases apart. */
    Put(L"fmseen", gFmSeen);
    Put(L"fmlast", gFmLastRet);
    /* Last qcdx log events, newest first. The failure tail always logs
     * 0x998; the gate that failed is hist1 (or hist2 when it logs twice). */
    {
        static const PCWSTR hn[4] = { L"hist0", L"hist1", L"hist2", L"hist3" };
        static const PCWSTR sn[4] = { L"ls0", L"ls1", L"ls2", L"ls3" };
        ULONG h;

        for (h = 0; h < 4; h++) {
            ULONG k = (gLogCount ? (gLogCount - 1 - h) : 0) & 15;

            Put(hn[h], gLogRing[k]);
            Put(sn[h], gSiteRing[k]);
        }
    }
    Put(L"logseen", gLogSeen);
    Put(L"loginst", gLogInstall);
    Put(L"ovins", gOvIns);
    Put(L"ovlen", gOvLen);
    Put(L"ovflt", gOvFlt);
    Put(L"acpn", gAcpN);
    Put(L"acpf", gAcpF);
    Put(L"acpk0", gAcpK[0]);
    Put(L"acpk1", gAcpK[1]);
    Put(L"acpk2", gAcpK[2]);
    Put(L"acpk3", gAcpK[3]);
    Put(L"acpl0", gAcpL[0]);
    Put(L"acpl1", gAcpL[1]);
    Put(L"acpl2", gAcpL[2]);
    Put(L"acpl3", gAcpL[3]);
    WriteRing();
    QueueDiag();
    Step(0x61);

    /* The rstonfail bugcheck now runs before any registry write (above),
     * so the failure boot never touches the SYSTEM hive. */
}

/* Installed into qcdx base+0x1c66c0. The loadpatch trampoline calls this
 * with the failure status in w0, and the adapter is still live in x20.
 * Forward x20 as the second argument (x1) and tail-call RecordStatus. The
 * trampoline's return address in lr is preserved through the tail branch,
 * so RecordStatus returns straight back into the trampoline. Naked: no
 * prologue runs before x20 is captured. */
__attribute__((naked)) static VOID
RecordStatusThunk(VOID)
{
    __asm__ volatile(
        "mov x1, x20\n\t"
        "b RecordStatus\n\t");
}

/* Fills the two mode-field groups the enumeration stage never produced.
 * Group A lives in the adapter head (mode type + sub-mode id). Group B lives
 * in the framebuffer descriptor at adapter+0x638 (fb base, scan size,
 * stride). Each group has its own SEH frame so a fault in one does not lose
 * the other. Called from FillModeThunk with the adapter in x0 only when the
 * return address is the 0x29443c site, i.e. after the descriptor pointer is
 * live and before any gate reads these fields.
 *
 * External linkage: FillModeThunk references it from inline asm.
 *
 * noinline is required. clang-cl inlined this into FillModeEntry and
 * deleted both __try frames, so a faulting store became a bugcheck
 * (bootgen 16, step stayed 0x65, the failure tail never ran). */
__declspec(noinline) VOID
FillMode(ULONG_PTR adapter)
{
    ULONG64 desc = 0;

    gFmHit++;
    if (!adapter)
        return;
    /* Group A: adapter head. +0x780 is hard gate 1; +0x788 selects the
     * pixel-format branch. Read the descriptor pointer in the same frame so
     * a bad adapter cannot reach group B. */
    __try {
        *(volatile ULONG *)(adapter + 0x780) = FM_MODE_TYPE;
        *(volatile ULONG *)(adapter + 0x788) = FM_SUBMODE_ID;
        desc = *(volatile ULONG64 *)(adapter + 0x638);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        gFmAflt++;
        return;
    }
    gFmDesc = desc;
    if (!desc)
        return;
    /* Group B: framebuffer descriptor. +0x1110 scan size clears the
     * >= 0x5000 gate; +0x1108/+0x1118 must be non-null. Point the scan
     * output at the GOP framebuffer UEFI already lit. */
    __try {
        *(volatile ULONG64 *)(desc + 0x1108) = FM_FB_BASE;
        *(volatile ULONG64 *)(desc + 0x1110) = FM_SCAN_SIZE;
        *(volatile ULONG64 *)(desc + 0x1118) = FM_STRIDE;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        gFmBflt++;
    }
}

/* C body behind the FillModeThunk naked shim. mutex (x0) is the caller's
 * original argument, adapter (x1) is x20 captured before any prologue, and
 * ret (x2) is the caller's return address captured from lr. Call the real
 * KeInitializeGuardedMutex first so every caller of the import behaves
 * normally, then fill the mode fields only when the return address is the
 * 0x29443c site. Returning from here returns straight to the caller because
 * FillModeThunk tail-branched with lr preserved.
 *
 * External linkage: FillModeThunk references it from inline asm. */
VOID
FillModeEntry(PVOID mutex, ULONG_PTR adapter, ULONG_PTR ret)
{
    VOID (*real)(PVOID) = (VOID (*)(PVOID))gRealKeInitGM;

    if (real)
        real(mutex);
    /* Low 32 bits only. The thunk already filtered on this, and the high
     * bits of ret may be a pointer-auth tag. */
    if ((ULONG)ret == (ULONG)gFillSite) {
        gFmCall++;
        /* Flush before the stores. A fault inside FillMode then leaves
         * step 0x66 / fmcall>=1 instead of looking like the hook never ran.
         * Only this one call site reaches here; the thunk tail-calls the
         * real import for every other caller. */
        if (gKey && KeGetCurrentIrql() == PASSIVE_LEVEL) {
            Put(L"fmcall", gFmCall);
            Put(L"step", 0x66);
            ZwFlushKey(gKey);
        }
        FillMode(adapter);
        if (gKey && KeGetCurrentIrql() == PASSIVE_LEVEL) {
            Put(L"fmhit", gFmHit);
            Put(L"fmaflt", gFmAflt);
            Put(L"fmbflt", gFmBflt);
            Put(L"fmdsclo", (ULONG)gFmDesc);
            Put(L"fmdschi", (ULONG)(gFmDesc >> 32));
            Put(L"step", 0x67);
            ZwFlushKey(gKey);
        }
    }
}

/* Installed into the KeInitializeGuardedMutex import slot (.rdata 0x14a360).
 * Every caller of that import reaches here. Other callers tail-branch to the
 * real function with x0/x30/x19-x28 untouched (x16/x17 are the intra-call
 * volatiles a blr target may clobber). Only the 0x29443c site enters
 * FillModeEntry, which needs a frame to call the real import and then fill.
 * Naked so that site still sees the caller's x20 and lr. */
__attribute__((naked)) static VOID
FillModeThunk(VOID)
{
    __asm__ volatile(
        /* bti c: qcdx enters this with blr. Harmless hint if BTI is off. */
        "bti c\n\t"
        "adrp x16, gFmSeen\n\t"
        "ldr w17, [x16, :lo12:gFmSeen]\n\t"
        "add w17, w17, #1\n\t"
        "str w17, [x16, :lo12:gFmSeen]\n\t"
        "adrp x16, gFmLastRet\n\t"
        "str w30, [x16, :lo12:gFmLastRet]\n\t"
        /* Compare the low 32 bits. A kernel return address can carry a
         * pointer-auth tag in the high bits, so a full 64-bit compare
         * against base+0x29443c never matches (bootgen 20, fmcall=0). */
        "adrp x16, gFillSite\n\t"
        "ldr x16, [x16, :lo12:gFillSite]\n\t"
        "cmp w30, w16\n\t"
        "b.ne 1f\n\t"
        "mov x1, x20\n\t"
        "mov x2, x30\n\t"
        "b FillModeEntry\n\t"
        /* ntoskrnl exports are call targets. br (a jump) is not a call and
         * faults their landing pad; blr is. x30 is restored so qcdx's blr
         * still returns to the instruction after the import call. */
        "1:\n\t"
        "str x30, [sp, #-16]!\n\t"
        "adrp x16, gRealKeInitGM\n\t"
        "ldr x16, [x16, :lo12:gRealKeInitGM]\n\t"
        "blr x16\n\t"
        "ldr x30, [sp], #16\n\t"
        "ret\n\t");
}

static PUCHAR
ImageBaseFrom(ULONG_PTR pc)
{
    ULONG_PTR p = pc & ~(ULONG_PTR)0xFFF;
    ULONG n;

    for (n = 0; n < 0x600 && p > 0x10000; n++, p -= 0x1000) {
        __try {
            if (*(USHORT *)p == 0x5A4D) {
                LONG lfanew = *(LONG *)(p + 0x3C);
                if (lfanew > 0 && lfanew < 0x400 && *(ULONG *)(p + (ULONG)lfanew) == 0x00004550)
                    return (PUCHAR)p;
            }
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            return NULL;
        }
    }
    return NULL;
}

/* The running qcdx is the diagnostic image. OnLoad writes these before
 * DriverEntry returns. The slot callback is too late: FUN_14029ba78 returns
 * before CreatePageTable, and that helper is the only caller of the
 * interface methods.
 *
 * 0x29baf0: SupportsSecureInAperture is 1 in the flashed _DSD. If either
 * SMMU context already has +0x40 == 1 (the GOP aperture on a cold start),
 * 0x29ba78 returns 0xC0000001 without opening SCM. The CBZ becomes an
 * unconditional branch to the same target, so page-table setup runs.
 * FUN_1402aa7e0 then calls the shim vtable. map stays 0, so there is no
 * live walk and no touch of the APPS SMMU.
 *
 * The four mov w2,#timeout sites are the SCM and TrEE waits inside
 * FUN_14029ac00 and FUN_14029ae70 (30000, 30000, 30000, 1000 ms).
 * FUN_140284e38 waits only when the timeout argument is nonzero. Zero
 * skips KeWait and returns success. Arrival only queues a work item, so
 * the device object is still null when the version query runs.
 *
 * 0x27a420 is loaded once into w25 and compared after both version
 * ioctls in FUN_14027a130. FUN_140009358 returns 0xC0000001 when
 * param+0x28 is null. Matching that status takes the driver's own
 * "version not implemented, continue" path and StartDevice proceeds
 * without an SCM function table. */
static const struct {
    ULONG Rva;
    ULONG Expect;
    ULONG Want;
} kQcdxPatch[] = {
    { 0x29baf0u, 0x34000248u, 0x14000012u },
    { 0x29aca0u, 0x528ea602u, 0x52800002u },
    { 0x29af10u, 0x528ea602u, 0x52800002u },
    { 0x29afc4u, 0x528ea602u, 0x52800002u },
    { 0x29b070u, 0x52807d02u, 0x52800002u },
    { 0x27a420u, 0xC0000010u, 0xC0000001u },
    /* Force the display version parser's major to 5 so it indexes the
     * table[5] row instead of table[0] (null when the GPU version is not
     * available). RVA 0xacb80 is `lsr w21,w8,#0x1c`; mov w21,#5 keeps the
     * rest of the parse unchanged. Diagnostic experiment only. */
    { 0xacb80u, 0x531C7D15u, 0x528000B5u },
};
_Static_assert(sizeof(kQcdxPatch) / sizeof(kQcdxPatch[0]) == 7,
               "qwin is seven 20-byte windows");

NTKERNELAPI NTSTATUS MmProtectMdlSystemAddress(PMDL mdl, ULONG protect);

static LONG gPatched;
static int NoteExc(PEXCEPTION_POINTERS ep);

static ULONG
WriteQcdx(PVOID addr, ULONG value, ULONG *stat, ULONG *detail)
{
    PMDL mdl;
    ULONG *slot;
    ULONG *savedExc;
    ULONG *savedXi0;
    ULONG exc = 0;
    ULONG xi0 = 0;
    NTSTATUS st;

    *stat = 0;
    *detail = 0;
    mdl = IoAllocateMdl(addr, sizeof(ULONG), FALSE, FALSE, NULL);
    if (!mdl) {
        *stat = 1;
        return 0;
    }
    /* This handler is the one that sees the probe exception. The call
     * does not pass it outward, so the code has to be stored here. */
    savedExc = gExcOut;
    savedXi0 = gXi0Out;
    gExcOut = &exc;
    gXi0Out = &xi0;
    __try {
        MmProbeAndLockPages(mdl, KernelMode, IoReadAccess);
    } __except (NoteExc(GetExceptionInformation())) {
        gExcOut = savedExc;
        gXi0Out = savedXi0;
        *stat = 2;
        *detail = exc;
        IoFreeMdl(mdl);
        return 0;
    }
    gExcOut = savedExc;
    gXi0Out = savedXi0;
    /* Protect changes an existing system mapping. On a locked but
     * unmapped MDL it returns STATUS_NOT_MAPPED_VIEW. */
    slot = MmGetSystemAddressForMdlSafe(mdl, NormalPagePriority);
    if (!slot) {
        *stat = 3;
        MmUnlockPages(mdl);
        IoFreeMdl(mdl);
        return 0;
    }
    st = MmProtectMdlSystemAddress(mdl, PAGE_EXECUTE_READWRITE);
    if (!NT_SUCCESS(st)) {
        *stat = 4;
        *detail = (ULONG)st;
        MmUnlockPages(mdl);
        IoFreeMdl(mdl);
        return 0;
    }
    *slot = value;
    MmProtectMdlSystemAddress(mdl, PAGE_EXECUTE_READ);
    MmUnlockPages(mdl);
    IoFreeMdl(mdl);
    return 1;
}

/* Eight-byte sibling of WriteQcdx for the import-slot redirect. The slot at
 * .rdata 0x14a360 holds a 64-bit pointer; WriteQcdx only stores a dword.
 * Same MDL/probe/protect dance, same stat codes (1 alloc, 2 probe raised,
 * 3 no system address, 4 protect failed). Returns the original pointer in
 * *old so the caller can forward to it. */
static ULONG
WriteQcdxPtr(PVOID addr, PVOID value, PVOID *old, ULONG *stat, ULONG *detail)
{
    PMDL mdl;
    PVOID *slot;
    ULONG *savedExc;
    ULONG *savedXi0;
    ULONG exc = 0;
    ULONG xi0 = 0;
    NTSTATUS st;

    *stat = 0;
    *detail = 0;
    if (old)
        *old = NULL;
    mdl = IoAllocateMdl(addr, sizeof(PVOID), FALSE, FALSE, NULL);
    if (!mdl) {
        *stat = 1;
        return 0;
    }
    savedExc = gExcOut;
    savedXi0 = gXi0Out;
    gExcOut = &exc;
    gXi0Out = &xi0;
    __try {
        MmProbeAndLockPages(mdl, KernelMode, IoReadAccess);
    } __except (NoteExc(GetExceptionInformation())) {
        gExcOut = savedExc;
        gXi0Out = savedXi0;
        *stat = 2;
        *detail = exc;
        IoFreeMdl(mdl);
        return 0;
    }
    gExcOut = savedExc;
    gXi0Out = savedXi0;
    slot = MmGetSystemAddressForMdlSafe(mdl, NormalPagePriority);
    if (!slot) {
        *stat = 3;
        MmUnlockPages(mdl);
        IoFreeMdl(mdl);
        return 0;
    }
    st = MmProtectMdlSystemAddress(mdl, PAGE_EXECUTE_READWRITE);
    if (!NT_SUCCESS(st)) {
        *stat = 4;
        *detail = (ULONG)st;
        MmUnlockPages(mdl);
        IoFreeMdl(mdl);
        return 0;
    }
    if (old)
        *old = *slot;
    *slot = value;
    /* Import slot lives in .rdata. Restoring RX would mark a data page
     * executable; the original protection is read-only. */
    MmProtectMdlSystemAddress(mdl, PAGE_READONLY);
    MmUnlockPages(mdl);
    IoFreeMdl(mdl);
    return 1;
}

/* Redirect qcdx's KeInitializeGuardedMutex import slot to FillModeThunk.
 * Runs once per load, after PatchQcdx, from the same PASSIVE_LEVEL contexts.
 * Reads the original pointer first (so the thunk can forward to it) and only
 * writes the slot if the read succeeded and the slot still holds a kernel
 * pointer, i.e. it has not already been redirected. gFillSite is the one
 * return address (base+0x29443c) that triggers a mode fill; every other
 * caller of the import is forwarded untouched. */
static VOID
InstallFillHook(PUCHAR base)
{
    PVOID *iat = (PVOID *)(base + QCDX_KEINITGM_IAT_RVA);
    PVOID cur = NULL;
    PVOID old = NULL;
    ULONG stat = 0;
    ULONG detail = 0;

    if (InterlockedCompareExchange(&gFillHooked, 1, 0) != 0)
        return;
    __try {
        cur = *iat;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        gFmInstall = 9;
        return;
    }
    /* Already pointing at our thunk from an earlier load of this image:
     * keep the saved real pointer and do nothing. */
    if (cur == (PVOID)FillModeThunk) {
        gFmInstall = 1;
        return;
    }
    gFillSite = (ULONG_PTR)base + QCDX_FILLMODE_SITE;
    gRealKeInitGM = cur;
    if (WriteQcdxPtr(iat, (PVOID)FillModeThunk, &old, &stat, &detail)) {
        gFmInstall = 1;
    } else {
        gFmInstall = 0x10u | (stat & 0xFu);
        gFmInstDetail = detail;
        gRealKeInitGM = NULL;
        gFillSite = 0;
    }
}

/* qcdx's log wrapper at RVA 0x10920 moves its event code into w2 and calls
 * FUN_140107d8 through the bl at RVA 0x10950. Redirecting that one bl
 * records the code and then calls the original target. A direct bl is not
 * a BTI-checked indirect branch, so bti c is only a safety landing pad. */
__attribute__((naked)) static VOID
LogThunk(VOID)
{
    __asm__ volatile(
        "bti c\n\t"
        /* site = wrapper's caller, still at [sp+8]. */
        "ldr x15, [sp, #8]\n\t"
        /* idx = gLogCount++ & 15 */
        "adrp x16, gLogCount\n\t"
        "ldr w17, [x16, :lo12:gLogCount]\n\t"
        "add w14, w17, #1\n\t"
        "str w14, [x16, :lo12:gLogCount]\n\t"
        "and w14, w17, #15\n\t"
        "lsl w14, w14, #2\n\t"
        "adrp x16, gLogRing\n\t"
        "add x16, x16, :lo12:gLogRing\n\t"
        "add x16, x16, x14\n\t"
        "str w2, [x16]\n\t"
        "adrp x16, gSiteRing\n\t"
        "add x16, x16, :lo12:gSiteRing\n\t"
        "add x16, x16, x14\n\t"
        "str w15, [x16]\n\t"
        "adrp x16, gLogSeen\n\t"
        "ldr w17, [x16, :lo12:gLogSeen]\n\t"
        "add w17, w17, #1\n\t"
        "str w17, [x16, :lo12:gLogSeen]\n\t"
        /* x30 at entry is the wrapper's return site; blr below clobbers it. */
        "str x30, [sp, #-16]!\n\t"
        "adrp x16, gLogReal\n\t"
        "ldr x16, [x16, :lo12:gLogReal]\n\t"
        "blr x16\n\t"
        "ldr x30, [sp], #16\n\t"
        "ret\n\t");
}

#define QCDX_LOG_BL_RVA     0x10950u
#define QCDX_LOG_CALLEE_RVA 0x107d8u

/* Runs once per load from the same PASSIVE contexts as InstallFillHook.
 * The original bl is checked before writing; a mismatch leaves qcdx
 * untouched. The thunk must be within the +-128 MB bl range. */
static VOID
InstallLogHook(PUCHAR base)
{
    ULONG *slot = (ULONG *)(base + QCDX_LOG_BL_RVA);
    ULONG cur = 0;
    ULONG stat = 0;
    ULONG detail = 0;
    LONG_PTR delta;
    ULONG want;

    if (InterlockedCompareExchange(&gLogHooked, 1, 0) != 0)
        return;
    __try {
        cur = *slot;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        gLogInstall = 9;
        return;
    }
    if (cur != 0x97FFFFA2u) {
        gLogInstall = 3;
        return;
    }
    delta = (LONG_PTR)LogThunk - (LONG_PTR)slot;
    if (delta < -(1LL << 27) || delta >= (1LL << 27)) {
        gLogInstall = 8;
        return;
    }
    want = 0x94000000u | ((ULONG)(delta >> 2) & 0x03FFFFFFu);
    gLogReal = base + QCDX_LOG_CALLEE_RVA;
    if (WriteQcdx(slot, want, &stat, &detail))
        gLogInstall = 1;
    else
        gLogInstall = 0x10u | (stat & 0xFu);
}

#define WALK_OK 0u
#define WALK_NOT_KERNEL 1u
#define WALK_GRANULE 2u
#define WALK_DEPTH 4u
#define WALK_NOREG 5u

static ULONG64
MrsTcr(VOID)
{
    ULONG64 v;
    __asm__ __volatile__("mrs %0, tcr_el1" : "=r"(v));
    return v;
}

static ULONG64
MrsTtbr1(VOID)
{
    ULONG64 v;
    __asm__ __volatile__("mrs %0, ttbr1_el1" : "=r"(v));
    return v;
}

static int
NoteExc(PEXCEPTION_POINTERS ep)
{
    PEXCEPTION_RECORD rec;

    if (ep && (rec = ep->ExceptionRecord) != NULL) {
        if (gExcOut)
            *gExcOut = rec->ExceptionCode;
        if (gXi0Out)
            *gXi0Out = rec->NumberParameters > 0 ? (ULONG)rec->ExceptionInformation[0] : 0;
    }
    return EXCEPTION_EXECUTE_HANDLER;
}

static BOOLEAN
TryMrs(ULONG64 (*fn)(VOID), ULONG64 *out, ULONG *excOut)
{
    ULONG exc = 0;
    ULONG xi0 = 0;

    gExcOut = &exc;
    gXi0Out = &xi0;
    __try {
        *out = fn();
        *excOut = 0;
        return TRUE;
    } __except (NoteExc(GetExceptionInformation())) {
        *excOut = exc;
        return FALSE;
    }
}

/* Read one stage-1 descriptor without touching va. A valid bit of 0 is
 * still a successful walk: qpte then holds the software PTE. */
static ULONG
ReadStage1(ULONG_PTR va, ULONG64 tcr, ULONG64 ttbr, ULONG64 *descOut)
{
    ULONG t1sz, tg1, vaBits, level, start, shift;
    ULONG64 pa, desc;
    MM_COPY_ADDRESS src;
    SIZE_T got;
    NTSTATUS st;

    *descOut = 0;
    t1sz = (ULONG)((tcr >> 16) & 0x3F);
    tg1 = (ULONG)((tcr >> 30) & 0x3);
    if (tg1 != 2)
        return WALK_GRANULE;
    if (t1sz == 0 || t1sz >= 48)
        return WALK_NOT_KERNEL;
    vaBits = 64 - t1sz;
    if (((ULONG64)va >> vaBits) != ((1ULL << t1sz) - 1))
        return WALK_NOT_KERNEL;
    if (vaBits > 39)
        start = 0;
    else if (vaBits > 30)
        start = 1;
    else if (vaBits > 21)
        start = 2;
    else
        start = 3;
    pa = ttbr & 0x0000FFFFFFFFF000ULL;
    for (level = start; level <= 3; level++) {
        shift = 12 + 9 * (3 - level);
        pa = (pa & 0x0000FFFFFFFFF000ULL) + ((((ULONG64)va >> shift) & 0x1FF) * 8);
        got = 0;
        src.PhysicalAddress.QuadPart = (LONGLONG)pa;
        st = MmCopyMemory(&desc, src, sizeof(desc), MM_COPY_MEMORY_PHYSICAL, &got);
        if (!NT_SUCCESS(st) || got != sizeof(desc))
            return NT_SUCCESS(st) ? (ULONG)STATUS_PARTIAL_COPY : (ULONG)st;
        *descOut = desc;
        if ((desc & 1) == 0)
            return WALK_OK;
        if (level == 3 || (desc & 2) == 0)
            return WALK_OK;
        pa = desc;
    }
    return WALK_DEPTH;
}

static VOID
PatchQcdx(PUCHAR base, BOOLEAN defer)
{
    ULONG mask = 0;
    ULONG fault = 0;
    ULONG prs = 0;
    ULONG rd = 0;
    UCHAR win[7][20];
    ULONG exc[7];
    ULONG xi0[7];
    ULONG wstat[7];
    ULONG wprot[7];
    ULONG wlk[7];
    ULONG64 pte[7];
    ULONG64 tcr = 0;
    ULONG64 ttbr = 0;
    ULONG tcrExc = 0;
    ULONG ttbrExc = 0;
    ULONG mrs = 0;
    BOOLEAN regs;
    ULONG i;

    if (KeGetCurrentIrql() != PASSIVE_LEVEL)
        return;
    if (InterlockedCompareExchange(&gPatched, 1, 0) != 0)
        return;
    RtlZeroMemory(win, sizeof(win));
    RtlZeroMemory(exc, sizeof(exc));
    RtlZeroMemory(xi0, sizeof(xi0));
    RtlZeroMemory(wstat, sizeof(wstat));
    RtlZeroMemory(wprot, sizeof(wprot));
    RtlZeroMemory(wlk, sizeof(wlk));
    RtlZeroMemory(pte, sizeof(pte));
    regs = TryMrs(MrsTcr, &tcr, &tcrExc) && TryMrs(MrsTtbr1, &ttbr, &ttbrExc);
    mrs = tcrExc != 0 ? tcrExc : ttbrExc;
    for (i = 0; i < sizeof(kQcdxPatch) / sizeof(kQcdxPatch[0]); i++) {
        ULONG *slot = (ULONG *)(base + kQcdxPatch[i].Rva);
        UCHAR tmp[20];
        ULONG cur = 0;
        ULONG k;
        ULONG64 desc = 0;
        BOOLEAN dwordOk = FALSE;
        BOOLEAN winOk = FALSE;

        if (!regs)
            wlk[i] = WALK_NOREG;
        else
            wlk[i] = ReadStage1((ULONG_PTR)slot, tcr, ttbr, &desc);
        pte[i] = desc;
        if (wlk[i] == WALK_OK && (desc & 1) != 0) {
            prs |= 1u << i;
            /* Valid leaf. AP[7:6] never denies an EL1 data read. */
            rd |= 1u << i;
        }
        /* The compare stays a single dword read. A fault in the
         * surrounding window must not turn a readable site into a miss.
         * The descriptor above was taken first, so a fault-in caused by
         * this read does not hide the previous state. */
        gExcOut = &exc[i];
        gXi0Out = &xi0[i];
        __try {
            cur = *slot;
            dwordOk = TRUE;
        } __except (NoteExc(GetExceptionInformation())) {
            fault |= 1u << i;
        }
        __try {
            PUCHAR p = (PUCHAR)slot - 8;
            for (k = 0; k < 20; k++)
                tmp[k] = p[k];
            winOk = TRUE;
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            fault |= 1u << (i + 8);
        }
        if (winOk) {
            for (k = 0; k < 20; k++)
                win[i][k] = tmp[k];
        } else if (dwordOk) {
            win[i][8] = (UCHAR)cur;
            win[i][9] = (UCHAR)(cur >> 8);
            win[i][10] = (UCHAR)(cur >> 16);
            win[i][11] = (UCHAR)(cur >> 24);
        }
        if (!dwordOk)
            continue;
        if (cur == kQcdxPatch[i].Want) {
            mask |= 1u << i;
            continue;
        }
        if (cur != kQcdxPatch[i].Expect)
            continue;
        if (WriteQcdx(slot, kQcdxPatch[i].Want, &wstat[i], &wprot[i]))
            mask |= 1u << i;
    }
    gExcOut = NULL;
    gXi0Out = NULL;
    /* A site that already holds Want counts as done. The offline-patched
     * qcdx image therefore still reports qpatch 0x3F / step 0x65. */
    if (defer) {
        gPendBase = (ULONG_PTR)base;
        gPendFlt = fault;
        gPendPrs = prs;
        gPendRd = rd;
        gPendTcr = tcr;
        gPendTtbr = ttbr;
        gPendMrs = mrs;
        RtlCopyMemory(gPendWin, win, sizeof(gPendWin));
        RtlCopyMemory(gPendExc, exc, sizeof(gPendExc));
        RtlCopyMemory(gPendXi0, xi0, sizeof(gPendXi0));
        RtlCopyMemory(gPendWlk, wlk, sizeof(gPendWlk));
        RtlCopyMemory(gPendPte, pte, sizeof(gPendPte));
        RtlCopyMemory(gPendWstat, wstat, sizeof(gPendWstat));
        RtlCopyMemory(gPendWprot, wprot, sizeof(gPendWprot));
        gPendMask = mask;
        gPendStep = mask == 0x7fu ? 0x65u : 0x64u;
        gPendValid = 1;
        if (mask != 0x7fu)
            InterlockedExchange(&gPatched, 0);
        return;
    }
    PutBin(L"wstat", wstat, sizeof(wstat));
    PutBin(L"wprot", wprot, sizeof(wprot));
    Put(L"qpatch", mask);
    if (mask != 0x7fu) {
        InterlockedExchange(&gPatched, 0);
        Step(0x64);
    } else {
        Step(0x65);
    }
}

/* StartDevice reaches the secure-aperture return before any slot callback.
 * Patch as soon as the image is mapped; PnP starts the device later.
 * Do not trust IMAGE_INFO bitfields: clang does not pack them the way
 * the notification reads, and that made the previous boot skip qcdx. */
static BOOLEAN
NameIsQcdx(PUNICODE_STRING name)
{
    UNICODE_STRING tail, last;

    RtlInitUnicodeString(&tail, L"qcdxkm8250.sys");
    if (!name || !name->Buffer || name->Length < tail.Length)
        return FALSE;
    last.Buffer = name->Buffer + (name->Length - tail.Length) / sizeof(WCHAR);
    last.Length = tail.Length;
    last.MaximumLength = tail.Length;
    return RtlEqualUnicodeString(&last, &tail, TRUE);
}

static BOOLEAN
NameHasQcdx(PUNICODE_STRING name)
{
    static const WCHAR needle[] = L"qcdx";
    ULONG n, i, j;

    if (!name || !name->Buffer || name->Length < 8)
        return FALSE;
    n = name->Length / sizeof(WCHAR);
    for (i = 0; i + 3 < n; i++) {
        for (j = 0; j < 4; j++) {
            WCHAR c = name->Buffer[i + j];
            if (c >= L'A' && c <= L'Z')
                c = (WCHAR)(c - L'A' + L'a');
            if (c != needle[j])
                break;
        }
        if (j == 4)
            return TRUE;
    }
    return FALSE;
}

static VOID
TailOf(PUNICODE_STRING name, WCHAR *dst, ULONG cap)
{
    ULONG nchars, start, i;

    dst[0] = 0;
    if (!name || !name->Buffer || name->Length < sizeof(WCHAR) || cap < 2) {
        dst[0] = L'-';
        dst[1] = 0;
        return;
    }
    nchars = name->Length / sizeof(WCHAR);
    start = nchars > cap - 1 ? nchars - (cap - 1) : 0;
    for (i = 0; i < nchars - start && i + 1 < cap; i++)
        dst[i] = name->Buffer[start + i];
    dst[i] = 0;
}

static VOID
FlushNote(PVOID ctx)
{
    ULONG i, ntfy, iseq;
    WCHAR szn[5], nmn[5];

    UNREFERENCED_PARAMETER(ctx);
    if (KeGetCurrentIrql() != PASSIVE_LEVEL)
        return;
    ntfy = gNtfy;
    iseq = gIseq;
    Put(L"ntfy", ntfy);
    Put(L"ihit", gIhit);
    Put(L"iseq", iseq);
    Put(L"nirq", gNirq);
    for (i = 0; i < 4; i++) {
        szn[0] = nmn[0] = L'i';
        szn[1] = nmn[1] = (WCHAR)(L'0' + i);
        szn[2] = L's';
        szn[3] = L'z';
        szn[4] = 0;
        nmn[2] = L'n';
        nmn[3] = L'm';
        nmn[4] = 0;
        Put(szn, gIsz[i]);
        PutStr(nmn, gInm[i][0] ? gInm[i] : L"-");
    }
    if (gPendValid) {
        Put(L"iblo", (ULONG)gPendBase);
        Put(L"ibhi", (ULONG)(gPendBase >> 32));
        Put(L"qflt", gPendFlt);
        Put(L"qprs", gPendPrs);
        Put(L"qrd", gPendRd);
        Put(L"tcrlo", (ULONG)gPendTcr);
        Put(L"tcrhi", (ULONG)(gPendTcr >> 32));
        Put(L"tb1lo", (ULONG)gPendTtbr);
        Put(L"tb1hi", (ULONG)(gPendTtbr >> 32));
        Put(L"qmrs", gPendMrs);
        PutBin(L"qwin", gPendWin, sizeof(gPendWin));
        PutBin(L"qexc", gPendExc, sizeof(gPendExc));
        PutBin(L"qxi0", gPendXi0, sizeof(gPendXi0));
        PutBin(L"qpte", gPendPte, sizeof(gPendPte));
        PutBin(L"qwlk", gPendWlk, sizeof(gPendWlk));
        PutBin(L"wstat", gPendWstat, sizeof(gPendWstat));
        PutBin(L"wprot", gPendWprot, sizeof(gPendWprot));
        Put(L"qpatch", gPendMask);
        /* FillMode import-hook install result, known once the image mapped.
         * fminst 1 installed, 9 slot read faulted, 0x1x WriteQcdxPtr stat. */
        Put(L"fminst", gFmInstall);
        Put(L"fmidet", gFmInstDetail);
        /* The pointer the thunk forwards to. A null or non-canonical value
         * here means the import slot was snapshotted wrong. */
        Put(L"fmrllo", (ULONG)(ULONG_PTR)gRealKeInitGM);
        Put(L"fmrlhi", (ULONG)((ULONG_PTR)gRealKeInitGM >> 32));
        Step(gPendStep);
        /* Consume once. The qcdx patch result is fixed after the image is
         * mapped; rewriting and flushing it on every later image load only
         * adds hard-reset tear windows to the SYSTEM hive (0xc000014c). */
        InterlockedExchange(&gPendValid, 0);
    } else if (gKey && (ntfy & 0xFFu) == 0) {
        /* Heartbeat only. Flushing on every notification turned ~9800 image
         * loads into ~9800 synchronous hive writes, each a tear window on a
         * hard reset. Every 256th load keeps coarse early/late visibility. */
        ZwFlushKey(gKey);
    }
    InterlockedExchange(&gNoteQueued, 0);
    if (gNtfy != ntfy || gIseq != iseq)
        NoteFlush();
}

/* Queue only. OnLoad stays off the registry so a loader lock cannot meet
 * ZwFlushKey, and the flush does not wait for a slot callback. The aperture
 * check returns before any slot call, so a callback-time flush would never
 * land when step stays 0x30. */
static VOID
NoteFlush(VOID)
{
    if (InterlockedCompareExchange(&gNoteQueued, 1, 0) == 0)
        ExQueueWorkItem(&gNoteItem, DelayedWorkQueue);
}

static VOID
Remember(PUNICODE_STRING name, ULONG size)
{
    ULONG slot = gIseq & 3;

    gIsz[slot] = size;
    TailOf(name, gInm[slot], 48);
    gIseq++;
}

static VOID
OnLoad(PUNICODE_STRING name, HANDLE pid, PIMAGE_INFO info)
{
    BOOLEAN named, big, loose;
    ULONG how;

    UNREFERENCED_PARAMETER(pid);
    gNtfy++;
    if (!info || !info->ImageBase)
        return;
    named = NameIsQcdx(name);
    loose = named || NameHasQcdx(name);
    big = info->ImageSize >= 0x29c000;
    if (big || loose)
        Remember(name, info->ImageSize > 0xFFFFFFFFu ? 0xFFFFFFFFu : (ULONG)info->ImageSize);
    if (!big)
        goto out;
    if (named)
        how = 1;
    else if (!(name && name->Buffer) && info->ImageSize == 0x35b000)
        how = 2;
    else
        goto out;
    gIhit = how;
    gQcdxBase = (ULONG_PTR)info->ImageBase;
    gQcdxSize = info->ImageSize > 0xFFFFFFFFu ? 0xFFFFFFFFu : (ULONG)info->ImageSize;
    gNirq = KeGetCurrentIrql();
    if (gNirq == PASSIVE_LEVEL) {
        PatchQcdx((PUCHAR)info->ImageBase, TRUE);
        InstallFillHook((PUCHAR)info->ImageBase);
        InstallLogHook((PUCHAR)info->ImageBase);
        QueueDiag();
    }
out:
    if (big || loose)
        NoteFlush();
}

static VOID
NoteCaller(ULONG_PTR ret)
{
    PUCHAR base;

    if (gHooked && gPatched)
        return;
    base = ImageBaseFrom(ret);
    if (base && !gQcdxBase) {
        /* OnLoad missed it. SizeOfImage is at optional header + 56 in
         * both PE32 and PE32+. */
        __try {
            LONG lfanew = *(LONG *)(base + 0x3C);
            gQcdxSize = *(ULONG *)(base + (ULONG)lfanew + 24 + 56);
            gQcdxBase = (ULONG_PTR)base;
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            gQcdxSize = 0;
        }
    }
    if (base) {
        PatchQcdx(base, FALSE);
        InstallFillHook(base);
        InstallLogHook(base);
    }
    if (InterlockedCompareExchange(&gHooked, 1, 0) != 0)
        return;
    if (!base)
        return;
    __try {
        *(PVOID *)(base + QCDX_HOOK_RVA) = (PVOID)RecordStatusThunk;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        Step(0x63);
    }
}

/* Write the DSDT override (GPU0 + _ROM/PCFG) into the ACPI Parameters key.
 * The ACPI driver reads that key during boot, so the table takes effect on
 * the NEXT boot; the current boot keeps the old one. Layout matches what
 * asl.exe /loadtable writes:
 *   00000000: u32 total_len, 0, 0, data_len0; then up to 7152 table bytes
 *   0000000N: u32 table_offset, data_len; then up to 7160 table bytes
 * Action=0 (REG_DWORD) marks the table loadable. Leftover chunks from an
 * older, larger overlay are deleted. Read the result back as
 * ovins/ovlen/ovflt in Services\dagusmmu\Parameters. */
#define OV_CHUNK0 7152u
#define OV_CHUNKN 7160u
#define OV_MAXVAL 16u

static VOID
EnsureDsdtOverride(VOID)
{
    UNICODE_STRING keyName;
    UNICODE_STRING valName;
    OBJECT_ATTRIBUTES oa;
    HANDLE hKey = NULL;
    NTSTATUS st;
    PUCHAR buf;
    WCHAR nameBuf[9];
    ULONG pos = 0;
    ULONG idx = 0;
    ULONG total = DAGU_DSDT_OV_LEN;
    ULONG i;

    buf = ExAllocatePoolWithTag(NonPagedPoolNx, 16 + OV_CHUNKN, 'VODG');
    if (!buf) {
        gOvFlt = 0xC0000017u;
        return;
    }
    RtlInitUnicodeString(&keyName,
        L"\\Registry\\Machine\\SYSTEM\\CurrentControlSet\\Services\\ACPI"
        L"\\Parameters\\DSDT\\QCOMM_\\SM8250_\\00000004");
    InitializeObjectAttributes(&oa, &keyName,
                               OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE,
                               NULL, NULL);
    st = ZwCreateKey(&hKey, KEY_SET_VALUE | KEY_QUERY_VALUE, &oa, 0, NULL,
                     REG_OPTION_NON_VOLATILE, NULL);
    if (!NT_SUCCESS(st)) {
        gOvFlt = (ULONG)st;
        ExFreePoolWithTag(buf, 'VODG');
        return;
    }
    while (pos < total && idx < OV_MAXVAL) {
        ULONG hdr = idx ? 8u : 16u;
        ULONG cap = idx ? OV_CHUNKN : OV_CHUNK0;
        ULONG n = total - pos;

        if (n > cap)
            n = cap;
        if (idx == 0) {
            *(ULONG *)(buf + 0) = total;
            *(ULONG *)(buf + 4) = 0;
            *(ULONG *)(buf + 8) = 0;
            *(ULONG *)(buf + 12) = n;
        } else {
            *(ULONG *)(buf + 0) = pos;
            *(ULONG *)(buf + 4) = n;
        }
        RtlCopyMemory(buf + hdr, gDsdtOv + pos, n);
        for (i = 0; i < 8; i++)
            nameBuf[i] = L"0123456789ABCDEF"[(idx >> (28 - 4 * i)) & 0xF];
        nameBuf[8] = 0;
        RtlInitUnicodeString(&valName, nameBuf);
        st = ZwSetValueKey(hKey, &valName, 0, REG_BINARY, buf, hdr + n);
        if (!NT_SUCCESS(st)) {
            gOvFlt = (ULONG)st;
            break;
        }
        gOvIns++;
        pos += n;
        idx++;
    }
    /* Drop chunks left over from a previous overlay. */
    for (; idx < OV_MAXVAL; idx++) {
        for (i = 0; i < 8; i++)
            nameBuf[i] = L"0123456789ABCDEF"[(idx >> (28 - 4 * i)) & 0xF];
        nameBuf[8] = 0;
        RtlInitUnicodeString(&valName, nameBuf);
        ZwDeleteValueKey(hKey, &valName);
    }
    {
        ULONG zero = 0;
        RtlInitUnicodeString(&valName, L"Action");
        ZwSetValueKey(hKey, &valName, 0, REG_DWORD, &zero, sizeof(zero));
    }
    gOvLen = total;
    ZwClose(hKey);
    ExFreePoolWithTag(buf, 'VODG');
}

NTSTATUS
DriverEntry(PDRIVER_OBJECT drv, PUNICODE_STRING reg)
{
    ULONG i;

    OpenParams(reg);
    gBootGen = GetDword(L"bootgen", 0) + 1;
    gRstOnFail = GetDword(L"rstonfail", 0);
    ExInitializeWorkItem(&gNoteItem, FlushNote, NULL);
    ExInitializeWorkItem(&gDiagItem, DiagWorker, NULL);
    ClearStale();
    Step(0x10);
    /* Do not rewrite the 53 KB ACPI override every boot: with the
     * rstonfail bugcheck/reset it tore the SYSTEM hive (0xc000014c). The
     * restored hive already carries the 8-chunk overlay. */
    WriteDiag(0, 0, 0);
    if (!NT_SUCCESS(PsSetLoadImageNotifyRoutine(OnLoad)))
        Step(0x11);
    drv->DriverExtension->AddDevice = AddDevice;
    drv->DriverUnload = Unload;
    for (i = 0; i <= IRP_MJ_MAXIMUM_FUNCTION; i++)
        drv->MajorFunction[i] = DispatchPass;
    drv->MajorFunction[IRP_MJ_PNP] = DispatchPnp;
    drv->MajorFunction[IRP_MJ_POWER] = DispatchPower;
    drv->MajorFunction[IRP_MJ_CREATE] = DispatchOk;
    drv->MajorFunction[IRP_MJ_CLOSE] = DispatchOk;
    drv->MajorFunction[IRP_MJ_CLEANUP] = DispatchOk;
    return STATUS_SUCCESS;
}
