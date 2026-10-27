/* SPDX-License-Identifier: MIT
 * dagu power key: short press turns the panel backlight off, the next
 * press turns it back on.
 *
 * The key is inside PM8150, not a SoC GPIO. Linux reads it through the
 * SPMI arbiter observer channel (spmi-pmic-arb.c v5, ee 0):
 *   core 0x0c440000, obsrvr 0x0e600000, cnfg 0x0c40a000
 *   pon@800 on SID 0, PON_RT_STS at 0x810, pm8941 status bit 0.
 * This driver only issues observer reads. It never writes a PMIC register
 * and never touches the read/write channel, so it cannot retune a rail.
 *
 * The panel light is two Kinetic KTZ8866 chips. The same bit-bang the
 * UEFI backlight driver uses writes brightness 0 or the boot level 1500.
 */
#include <ntddk.h>

#define CORE_PHYS   0x0C440000ULL
#define CORE_SIZE   0x2000u
#define CORE_LIMIT  0x1100u
#define OBS_PHYS    0x0E600000ULL
#define OBS_SIZE    0x10000u
#define CNFG_PHYS   0x0C40A000ULL
#define CNFG_SIZE   0x2000u

#define ARB_VERSION     0x0000u
#define ARB_FEATURES    0x0004u
#define ARB_CMD         0x00u
#define ARB_STATUS      0x08u
#define ARB_RDATA0      0x18u
#define ARB_V5_MIN      0x50000000u
#define ARB_V7_MIN      0x70000000u
#define ARB_OP_EXT_READ 13u
#define PON_PPID        0x0008u
#define PON_BASE        0x0800u
#define PON_SUBTYPE     0x05u
#define PON_RT_STS      0x10u
#define PON_BIT_GEN1    0x01u
#define PON_BIT_GEN3    0x80u
#define SUBTYPE_GEN3_PBS  0x08u
#define SUBTYPE_GEN3_HLOS 0x09u

#define TLMM_SOUTH      0x0F500000ULL
#define TLMM_MAP        0x00100000u
#define TLMM_OE         (1u << 9)
#define KTZ_ADDR        0x11
#define KTZ_BRT_LSB     0x04
#define KTZ_BRT_MSB     0x05
#define KTZ_LEVEL       1500u

typedef struct _KTZ_BUS {
    ULONG Sda;
    ULONG Scl;
} KTZ_BUS;

static const KTZ_BUS gBus[2] = { { 60, 61 }, { 125, 126 } };

static PUCHAR gCore;
static PUCHAR gObs;
static PUCHAR gCnfg;
static PUCHAR gTlmm;
static PVOID gCoreMap;
static PVOID gObsMap;
static PVOID gCnfgMap;
static PVOID gTlmmMap;
static KEVENT gStop;
static HANDLE gThreadHandle;
static PKTHREAD gThread;
static ULONG gApid;
static ULONG gBit;
static BOOLEAN gBlank;

static ULONG
Rd(PUCHAR Base, ULONG Off)
{
    return READ_REGISTER_ULONG((PULONG)(Base + Off));
}

static VOID
Wr(PUCHAR Base, ULONG Off, ULONG Val)
{
    WRITE_REGISTER_ULONG((PULONG)(Base + Off), Val);
}

static BOOLEAN
FindApid(VOID)
{
    ULONG ver, count, i, off, reg, ppid, owner, fallback;

    ver = Rd(gCore, ARB_VERSION);
    if (ver < ARB_V5_MIN || ver >= ARB_V7_MIN)
        return FALSE;
    count = Rd(gCore, ARB_FEATURES) & 0x7FFu;
    if (count == 0 || count > 512)
        count = 512;
    fallback = 0xFFFFFFFFu;
    for (i = 0; i < count; i++) {
        off = 0x900u + 4u * i;
        if (off >= CORE_LIMIT)
            break;
        reg = Rd(gCore, off);
        if (reg == 0)
            continue;
        ppid = (reg >> 8) & 0xFFFu;
        if (ppid != PON_PPID)
            continue;
        owner = Rd(gCnfg, 0x700u + 4u * i) & 7u;
        if (owner == 0) {
            gApid = i;
            return TRUE;
        }
        if (fallback == 0xFFFFFFFFu)
            fallback = i;
    }
    if (fallback == 0xFFFFFFFFu)
        return FALSE;
    gApid = fallback;
    return TRUE;
}

/* One observer-channel extended read. Returns FALSE without writing CMD
 * when the previous transaction has not finished. */
static BOOLEAN
SpmiRead(USHORT Addr, UCHAR *Out)
{
    ULONG offset, cmd, spins, st;

    offset = 0x80u * gApid;
    if (offset + ARB_RDATA0 >= OBS_SIZE)
        return FALSE;
    st = Rd(gObs, offset + ARB_STATUS);
    if ((st & 1u) == 0 && st != 0)
        return FALSE;
    cmd = (ARB_OP_EXT_READ << 27) | (((ULONG)Addr & 0xFFu) << 4);
    Wr(gObs, offset + ARB_CMD, cmd);
    for (spins = 0; spins < 1000; spins++) {
        st = Rd(gObs, offset + ARB_STATUS);
        if (st & 1u) {
            if (st & 0xEu)
                return FALSE;
            *Out = (UCHAR)Rd(gObs, offset + ARB_RDATA0);
            return TRUE;
        }
        KeStallExecutionProcessor(1);
    }
    return FALSE;
}

static ULONG
CfgAddr(ULONG Gpio)
{
    return 0x1000u * Gpio;
}

static VOID
Line(ULONG Gpio, BOOLEAN High)
{
    ULONG cfg = CfgAddr(Gpio);

    if (High)
        Wr(gTlmm, cfg, Rd(gTlmm, cfg) & ~TLMM_OE);
    else
        Wr(gTlmm, cfg, Rd(gTlmm, cfg) | TLMM_OE);
    KeStallExecutionProcessor(5);
}

static BOOLEAN
GetLine(ULONG Gpio)
{
    return (Rd(gTlmm, CfgAddr(Gpio) + 4u) & 1u) != 0;
}

static BOOLEAN
SclHigh(const KTZ_BUS *Bus)
{
    ULONG n;

    Line(Bus->Scl, TRUE);
    for (n = 0; n < 1000 && !GetLine(Bus->Scl); n++)
        KeStallExecutionProcessor(1);
    return GetLine(Bus->Scl);
}

static VOID
I2cStart(const KTZ_BUS *Bus)
{
    Line(Bus->Sda, TRUE);
    SclHigh(Bus);
    Line(Bus->Sda, FALSE);
    Line(Bus->Scl, FALSE);
}

static VOID
I2cStop(const KTZ_BUS *Bus)
{
    Line(Bus->Sda, FALSE);
    SclHigh(Bus);
    Line(Bus->Sda, TRUE);
}

static BOOLEAN
I2cWrite(const KTZ_BUS *Bus, UCHAR Byte)
{
    LONG bit;
    BOOLEAN ack;

    for (bit = 7; bit >= 0; bit--) {
        Line(Bus->Sda, (Byte >> bit) & 1);
        SclHigh(Bus);
        Line(Bus->Scl, FALSE);
    }
    Line(Bus->Sda, TRUE);
    SclHigh(Bus);
    ack = !GetLine(Bus->Sda);
    Line(Bus->Scl, FALSE);
    return ack;
}

static BOOLEAN
KtzWrite(const KTZ_BUS *Bus, UCHAR Reg, UCHAR Val)
{
    BOOLEAN ok;

    I2cStart(Bus);
    ok = I2cWrite(Bus, KTZ_ADDR << 1) && I2cWrite(Bus, Reg) && I2cWrite(Bus, Val);
    I2cStop(Bus);
    return ok;
}

static VOID
SetBacklight(BOOLEAN Blank)
{
    ULONG level, i, sda, scl;
    UCHAR lsb, msb;

    level = Blank ? 0 : KTZ_LEVEL;
    lsb = (UCHAR)(level & 7u);
    msb = (UCHAR)((level >> 3) & 0xFFu);
    for (i = 0; i < 2; i++) {
        sda = CfgAddr(gBus[i].Sda);
        scl = CfgAddr(gBus[i].Scl);
        {
            ULONG savedSda = Rd(gTlmm, sda);
            ULONG savedScl = Rd(gTlmm, scl);

            Wr(gTlmm, sda + 4u, 0);
            Wr(gTlmm, scl + 4u, 0);
            Wr(gTlmm, sda, 0);
            Wr(gTlmm, scl, 0);
            KeStallExecutionProcessor(20);
            KtzWrite(&gBus[i], KTZ_BRT_LSB, lsb);
            KtzWrite(&gBus[i], KTZ_BRT_MSB, msb);
            Wr(gTlmm, sda, savedSda);
            Wr(gTlmm, scl, savedScl);
        }
    }
    gBlank = Blank;
}

static VOID
ThreadMain(PVOID Context)
{
    LARGE_INTEGER wait;
    UCHAR subtype, sts;
    BOOLEAN down, have, last;

    UNREFERENCED_PARAMETER(Context);
    wait.QuadPart = -20 * 1000 * 10;
    have = FALSE;
    last = FALSE;
    gBit = PON_BIT_GEN1;
    if (SpmiRead(PON_BASE + PON_SUBTYPE, &subtype) &&
        (subtype == SUBTYPE_GEN3_PBS || subtype == SUBTYPE_GEN3_HLOS))
        gBit = PON_BIT_GEN3;

    while (KeWaitForSingleObject(&gStop, Executive, KernelMode, FALSE, &wait) == STATUS_TIMEOUT) {
        if (!SpmiRead(PON_BASE + PON_RT_STS, &sts))
            continue;
        down = (sts & gBit) != 0;
        if (have && down && !last)
            SetBacklight(!gBlank);
        last = down;
        have = TRUE;
    }
    PsTerminateSystemThread(STATUS_SUCCESS);
}

static VOID
StopThread(VOID)
{
    if (gThreadHandle == NULL)
        return;
    KeSetEvent(&gStop, IO_NO_INCREMENT, FALSE);
    if (gThread)
        KeWaitForSingleObject(gThread, Executive, KernelMode, FALSE, NULL);
    if (gThread)
        ObDereferenceObject(gThread);
    ZwClose(gThreadHandle);
    gThread = NULL;
    gThreadHandle = NULL;
}

static VOID
UnmapAll(VOID)
{
    if (gCoreMap)
        MmUnmapIoSpace(gCoreMap, CORE_SIZE);
    if (gObsMap)
        MmUnmapIoSpace(gObsMap, OBS_SIZE);
    if (gCnfgMap)
        MmUnmapIoSpace(gCnfgMap, CNFG_SIZE);
    if (gTlmmMap)
        MmUnmapIoSpace(gTlmmMap, TLMM_MAP);
    gCoreMap = gObsMap = gCnfgMap = gTlmmMap = NULL;
    gCore = gObs = gCnfg = gTlmm = NULL;
}

static VOID
Unload(_In_ PDRIVER_OBJECT DriverObject)
{
    UNREFERENCED_PARAMETER(DriverObject);
    StopThread();
    UnmapAll();
}

NTSTATUS
DriverEntry(_In_ PDRIVER_OBJECT DriverObject, _In_ PUNICODE_STRING RegistryPath)
{
    PHYSICAL_ADDRESS pa;
    OBJECT_ATTRIBUTES oa;
    NTSTATUS status;

    UNREFERENCED_PARAMETER(RegistryPath);
    DriverObject->DriverUnload = Unload;
    pa.QuadPart = CORE_PHYS;
    gCoreMap = MmMapIoSpaceEx(pa, CORE_SIZE, PAGE_READWRITE | PAGE_NOCACHE);
    pa.QuadPart = OBS_PHYS;
    gObsMap = MmMapIoSpaceEx(pa, OBS_SIZE, PAGE_READWRITE | PAGE_NOCACHE);
    pa.QuadPart = CNFG_PHYS;
    gCnfgMap = MmMapIoSpaceEx(pa, CNFG_SIZE, PAGE_READWRITE | PAGE_NOCACHE);
    pa.QuadPart = TLMM_SOUTH;
    gTlmmMap = MmMapIoSpaceEx(pa, TLMM_MAP, PAGE_READWRITE | PAGE_NOCACHE);
    if (!gCoreMap || !gObsMap || !gCnfgMap || !gTlmmMap) {
        UnmapAll();
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    gCore = gCoreMap;
    gObs = gObsMap;
    gCnfg = gCnfgMap;
    gTlmm = gTlmmMap;
    if (!FindApid()) {
        UnmapAll();
        return STATUS_DEVICE_NOT_READY;
    }
    KeInitializeEvent(&gStop, NotificationEvent, FALSE);
    InitializeObjectAttributes(&oa, NULL, OBJ_KERNEL_HANDLE, NULL, NULL);
    status = PsCreateSystemThread(&gThreadHandle, THREAD_ALL_ACCESS, &oa,
                                  NULL, NULL, ThreadMain, NULL);
    if (!NT_SUCCESS(status)) {
        UnmapAll();
        return status;
    }
    ObReferenceObjectByHandle(gThreadHandle, THREAD_ALL_ACCESS, *PsThreadType,
                              KernelMode, (PVOID *)&gThread, NULL);
    return STATUS_SUCCESS;
}
