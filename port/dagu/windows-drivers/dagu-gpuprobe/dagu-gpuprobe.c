/* SPDX-License-Identifier: MIT
 * dagu-gpuprobe: read-only look at the GPU clocks and the Adreno SMMU from a
 * running Windows (stage 16).
 *
 * Question: when qcsmmu8250 resets the SoC (stage 14), is the Adreno SMMU
 * even clocked at that point? UEFI (DaguPlatDxe) powers GPU CX and enables
 * the clocks mainline lists for adreno_smmu (gpu_cc_ahb, gcc_gpu_memnoc_gfx,
 * gcc_gpu_snoc_dvm_gfx), but nothing proves they survive ExitBootServices.
 * An access to an unclocked block stalls the bus and the SoC resets, which
 * looks exactly like stage 14.
 *
 * Order matters. GCC is always reachable, so its CBCRs are read first. GPU_CC
 * is only read if gcc_gpu_cfg_ahb is running; the SMMU only if CX is on and
 * its three clocks are running. Nothing is ever written to hardware.
 *
 * Results go to HKLM\SYSTEM\CurrentControlSet\Services\<svc>\Parameters as
 * REG_DWORDs. "step" is written and flushed before each stage, so if a read
 * hangs the box, the last step says which one (readable from B-slot Linux).
 *
 *   sc create daguprobe type= kernel start= demand binPath= C:\dagu\dagu-gpuprobe.sys
 *   sc start daguprobe     (DriverEntry returns an error, so it unloads again)
 */
#include <ntddk.h>

#define GCC_PHYS        0x00100000ULL
#define GCC_SIZE        0x00080000u
#define GCC_GPU_CFG_AHB 0x71004u
#define GCC_GPU_MEMNOC  0x7100Cu
#define GCC_GPU_SNOCDVM 0x71018u
#define GCC_DDRSS_GPU   0x71154u

#define GPUCC_PHYS      0x03D90000ULL
#define GPUCC_SIZE      0x00009000u
#define GPUCC_GX_GDSCR  0x100Cu
#define GPUCC_CX_GDSCR  0x106Cu
#define GPUCC_AHB       0x1078u
#define GPUCC_SNOCDVM   0x108Cu
#define GPUCC_CX_GMU    0x1098u
#define GPUCC_CXO       0x109Cu
#define GPUCC_HLOS1     0x5000u

#define SMMU_PHYS       0x03DA0000ULL
#define SMMU_SIZE       0x00010000u

#define CBCR_OFF        0x80000000u
#define GDSC_ON         0x80000000u

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

/* Value name "<prefix><two hex digits>", e.g. smr05. */
static VOID
PutIdx(PCWSTR prefix, ULONG i, ULONG v)
{
    static const WCHAR hex[] = L"0123456789abcdef";
    WCHAR buf[16];
    ULONG n = 0;

    while (prefix[n] && n < 10) {
        buf[n] = prefix[n];
        n++;
    }
    buf[n++] = hex[(i >> 4) & 0xF];
    buf[n++] = hex[i & 0xF];
    buf[n] = 0;
    Put(buf, v);
}

static ULONG
Rd(volatile UCHAR *base, ULONG off)
{
    return READ_REGISTER_ULONG((volatile ULONG *)(base + off));
}

static NTSTATUS
OpenParams(PUNICODE_STRING reg)
{
    OBJECT_ATTRIBUTES oa;
    UNICODE_STRING sub;
    HANDLE svc;
    NTSTATUS st;
    ULONG disp;

    InitializeObjectAttributes(&oa, reg, OBJ_KERNEL_HANDLE | OBJ_CASE_INSENSITIVE, NULL, NULL);
    st = ZwOpenKey(&svc, KEY_ALL_ACCESS, &oa);
    if (!NT_SUCCESS(st))
        return st;
    RtlInitUnicodeString(&sub, L"Parameters");
    InitializeObjectAttributes(&oa, &sub, OBJ_KERNEL_HANDLE | OBJ_CASE_INSENSITIVE, svc, NULL);
    st = ZwCreateKey(&gKey, KEY_ALL_ACCESS, &oa, 0, NULL, REG_OPTION_NON_VOLATILE, &disp);
    ZwClose(svc);
    return st;
}

static VOID
ProbeSmmu(volatile UCHAR *s)
{
    ULONG idr0, idr1, numsmr, numcb, pgshift, gpages, i;

    Step(40);
    idr0 = Rd(s, 0x20);
    idr1 = Rd(s, 0x24);
    Put(L"smmu_idr0", idr0);
    Put(L"smmu_idr1", idr1);
    Put(L"smmu_idr2", Rd(s, 0x28));
    Put(L"smmu_idr7", Rd(s, 0x3C));
    Put(L"smmu_scr0", Rd(s, 0x00));
    Put(L"smmu_sacr", Rd(s, 0x10));
    Put(L"smmu_sgfsr", Rd(s, 0x48));
    Put(L"smmu_sgfsynr0", Rd(s, 0x50));
    Put(L"smmu_sgfsynr1", Rd(s, 0x54));
    Put(L"smmu_sgfar", Rd(s, 0x40));

    Step(41);
    numsmr = idr0 & 0xFF;
    numcb = idr1 & 0xFF;
    if (numsmr > 64)
        numsmr = 64;
    for (i = 0; i < numsmr; i++) {
        PutIdx(L"smr", i, Rd(s, 0x800 + i * 4));
        PutIdx(L"s2cr", i, Rd(s, 0xC00 + i * 4));
    }

    /* GR1 is page 1; CB space starts after 2^(NUMPAGENDXB+1) pages. */
    Step(42);
    pgshift = (idr1 & 0x80000000u) ? 16 : 12;
    gpages = 1u << (((idr1 >> 28) & 7) + 1);
    if (numcb > 8)
        numcb = 8;
    for (i = 0; i < numcb; i++) {
        ULONG cb = (gpages + i) << pgshift;

        PutIdx(L"cbar", i, Rd(s, (1u << pgshift) + i * 4));
        if (cb + 0x60 > SMMU_SIZE)
            break;
        PutIdx(L"cb_sctlr", i, Rd(s, cb + 0x00));
        PutIdx(L"cb_fsr", i, Rd(s, cb + 0x58));
    }
    Step(49);
}

NTSTATUS
DriverEntry(_In_ PDRIVER_OBJECT DriverObject, _In_ PUNICODE_STRING RegistryPath)
{
    PHYSICAL_ADDRESS pa;
    volatile UCHAR *gcc = NULL, *gpucc = NULL, *smmu = NULL;
    ULONG cfg, memnoc, snocdvm, cx, ahb;

    UNREFERENCED_PARAMETER(DriverObject);
    if (!NT_SUCCESS(OpenParams(RegistryPath)))
        return STATUS_UNSUCCESSFUL;
    Step(1);

    pa.QuadPart = GCC_PHYS;
    gcc = MmMapIoSpaceEx(pa, GCC_SIZE, PAGE_READWRITE | PAGE_NOCACHE);
    if (!gcc) {
        Step(0xE1);
        goto out;
    }
    Step(10);
    cfg = Rd(gcc, GCC_GPU_CFG_AHB);
    memnoc = Rd(gcc, GCC_GPU_MEMNOC);
    snocdvm = Rd(gcc, GCC_GPU_SNOCDVM);
    Put(L"gcc_gpu_cfg_ahb", cfg);
    Put(L"gcc_gpu_memnoc_gfx", memnoc);
    Put(L"gcc_gpu_snoc_dvm_gfx", snocdvm);
    Put(L"gcc_ddrss_gpu_axi", Rd(gcc, GCC_DDRSS_GPU));
    if (cfg & CBCR_OFF) {
        Step(0xA1);                     /* GPU_CC not reachable: stop here */
        goto out;
    }

    pa.QuadPart = GPUCC_PHYS;
    gpucc = MmMapIoSpaceEx(pa, GPUCC_SIZE, PAGE_READWRITE | PAGE_NOCACHE);
    if (!gpucc) {
        Step(0xE2);
        goto out;
    }
    Step(20);
    cx = Rd(gpucc, GPUCC_CX_GDSCR);
    ahb = Rd(gpucc, GPUCC_AHB);
    Put(L"gpucc_cx_gdscr", cx);
    Put(L"gpucc_gx_gdscr", Rd(gpucc, GPUCC_GX_GDSCR));
    Put(L"gpucc_ahb", ahb);
    Put(L"gpucc_cx_snoc_dvm", Rd(gpucc, GPUCC_SNOCDVM));
    Put(L"gpucc_cx_gmu", Rd(gpucc, GPUCC_CX_GMU));
    Put(L"gpucc_cxo", Rd(gpucc, GPUCC_CXO));
    Put(L"gpucc_hlos1_smmu", Rd(gpucc, GPUCC_HLOS1));
    if (!(cx & GDSC_ON) || (ahb & CBCR_OFF) || (memnoc & CBCR_OFF) || (snocdvm & CBCR_OFF)) {
        Step(0xA2);                     /* SMMU unclocked or unpowered: stop */
        goto out;
    }

    pa.QuadPart = SMMU_PHYS;
    smmu = MmMapIoSpaceEx(pa, SMMU_SIZE, PAGE_READWRITE | PAGE_NOCACHE);
    if (!smmu) {
        Step(0xE3);
        goto out;
    }
    ProbeSmmu(smmu);
    Step(0x99);                         /* everything read */

out:
    if (smmu)
        MmUnmapIoSpace((PVOID)smmu, SMMU_SIZE);
    if (gpucc)
        MmUnmapIoSpace((PVOID)gpucc, GPUCC_SIZE);
    if (gcc)
        MmUnmapIoSpace((PVOID)gcc, GCC_SIZE);
    if (gKey) {
        ZwFlushKey(gKey);
        ZwClose(gKey);
    }
    /* Never stay loaded: there is nothing to serve. */
    return STATUS_UNSUCCESSFUL;
}
