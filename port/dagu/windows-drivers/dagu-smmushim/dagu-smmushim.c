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
static UCHAR gPendWin[6][20];
static ULONG gPendPrs;
static ULONG gPendRd;
static ULONG gPendExc[6];
static ULONG gPendXi0[6];
static ULONG gPendWlk[6];
static ULONG64 gPendPte[6];
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
static ULONG gPendWstat[6];
static ULONG gPendWprot[6];
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
    };
    ULONG i, k;
    WCHAR ring[3];

    gNtfy = 0;
    gIhit = 0;
    gIseq = 0;
    gNirq = 0;
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
    }
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

    if (KeGetCurrentIrql() > APC_LEVEL)
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
 * only every 16 calls, in one flush. */
typedef struct _CALL_REC {
    ULONG Slot;
    ULONG A, B, C, D, R;
} CALL_REC;

static CALL_REC gRing[8];
static ULONG gNcall;
static ULONG gSeen0;
static ULONG gSeen1;
static LONG gMap = -1;

static VOID
FlushRing(VOID)
{
    ULONG i;
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
    }
    Put(L"ncall", gNcall);
    Put(L"slot", gRing[(gNcall - 1) & 7].Slot);
    Put(L"arg0", gRing[(gNcall - 1) & 7].A);
    Put(L"arg1", gRing[(gNcall - 1) & 7].B);
    Put(L"arg2", gRing[(gNcall - 1) & 7].C);
    Put(L"arg3", gRing[(gNcall - 1) & 7].D);
    Put(L"retlo", gRing[(gNcall - 1) & 7].R);
    Put(L"seen0", gSeen0);
    Put(L"seen1", gSeen1);
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

static VOID
RecordStatus(ULONG status)
{
    /* gNcall is this load's slot-callback count. Zero means adapter init
     * failed before any SMMU callback. */
    Put(L"fail", status);
    Put(L"ncall", gNcall);
    Put(L"seen0", gSeen0);
    Put(L"seen1", gSeen1);
    Step(0x61);
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
};
_Static_assert(sizeof(kQcdxPatch) / sizeof(kQcdxPatch[0]) == 6,
               "qwin is six 20-byte windows");

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
    UCHAR win[6][20];
    ULONG exc[6];
    ULONG xi0[6];
    ULONG wstat[6];
    ULONG wprot[6];
    ULONG wlk[6];
    ULONG64 pte[6];
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
        gPendStep = mask == 0x3fu ? 0x65u : 0x64u;
        gPendValid = 1;
        if (mask != 0x3fu)
            InterlockedExchange(&gPatched, 0);
        return;
    }
    PutBin(L"wstat", wstat, sizeof(wstat));
    PutBin(L"wprot", wprot, sizeof(wprot));
    Put(L"qpatch", mask);
    if (mask != 0x3fu) {
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
        Step(gPendStep);
    } else if (gKey) {
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
    gNirq = KeGetCurrentIrql();
    if (gNirq == PASSIVE_LEVEL)
        PatchQcdx((PUCHAR)info->ImageBase, TRUE);
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
    if (base)
        PatchQcdx(base, FALSE);
    if (InterlockedCompareExchange(&gHooked, 1, 0) != 0)
        return;
    if (!base)
        return;
    __try {
        *(PVOID *)(base + QCDX_HOOK_RVA) = (PVOID)RecordStatus;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        Step(0x63);
    }
}

NTSTATUS
DriverEntry(PDRIVER_OBJECT drv, PUNICODE_STRING reg)
{
    ULONG i;

    OpenParams(reg);
    gBootGen = GetDword(L"bootgen", 0) + 1;
    ExInitializeWorkItem(&gNoteItem, FlushNote, NULL);
    ClearStale();
    Step(0x10);
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
