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
