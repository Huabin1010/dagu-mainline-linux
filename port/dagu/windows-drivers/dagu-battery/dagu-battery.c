/* SPDX-License-Identifier: MIT
 * dagu battery: Windows Battery class miniport for the two BQ27Z561 gauges
 * of the Xiaomi Pad 5 Pro 12.4 (two 5000 mAh cells, 3.4-4.45 V).
 *
 * Gauges (address 0x55, standard commands, little-endian words):
 *   right cell: gpio28 SDA / gpio29 SCL, TLMM NORTH (Linux i2c-0, SE0)
 *   left cell:  gpio36 SDA / gpio37 SCL, TLMM SOUTH (Linux i2c-13, SE13)
 * Windows has no GENI/GPI/SMMU stack on dagu, so like nanosic-803 this
 * driver bit-bangs I2C through the TLMM pin registers. The ACPI node
 * (DAGUB001, battery.asl) declares no resources on purpose.
 *
 * Combination follows linux xiaomi-dual-fg.c: SoC from summed RM/FCC,
 * > 96.00 % shows 100, otherwise (raw + 95) / 96 capped at 99; voltage is
 * the larger cell; current and capacities are summed; energy uses 3.87 V.
 *
 * Charger presence comes from PM8150B (SPMI SID 2) USBIN_INT_RT_STS and
 * POWER_PATH_STATUS, read through the SPMI arbiter observer channel the
 * same way dagu-pwrkey reads PON. This driver never writes a PMIC register
 * and never drives the fg-disable pins (gpio117/gpio91); it only reports
 * their level in the diagnostics file \SystemRoot\dagu-battery.txt.
 *
 * Any read failure keeps the last good snapshot; with no good snapshot the
 * miniport reports no battery. Nothing here can block the boot.
 */
#include <ntddk.h>
#include <batclass.h>

/* ------------------------------ hardware -------------------------------- */
#define TLMM_NORTH      0x0F900000ULL
#define TLMM_SOUTH      0x0F500000ULL
#define PIN_PA(t, g)    ((t) + 0x1000ULL * (g))
#define PIN_SIZE        0x1000u
#define CFG_PULLUP      3u
#define CFG_OE          (1u << 9)

#define FG_ADDR         0x55u
#define FG_TEMP         0x06u   /* 0.1 K */
#define FG_VOLT         0x08u   /* mV */
#define FG_FLAGS        0x0Au
#define FG_RM           0x10u   /* mAh */
#define FG_FCC          0x12u   /* mAh */
#define FG_AI           0x14u   /* signed mA, + = charging */
#define FG_CYC          0x2Au
#define FG_SOC          0x2Cu   /* % */
#define FG_DCAP         0x3Cu   /* mAh */
#define FG_FLAG_FDC     (1u << 4)
#define FG_FLAG_FC      (1u << 5)

#define SOC_RAW_FULL    9600u
#define NOMINAL_MV      3870u

/* SPMI arbiter v5 observer channel (see dagu-pwrkey.c). */
#define CORE_PHYS       0x0C440000ULL
#define CORE_SIZE       0x2000u
#define CORE_LIMIT      0x1100u
#define OBS_PHYS        0x0E600000ULL
#define OBS_SIZE        0x10000u
#define CNFG_PHYS       0x0C40A000ULL
#define CNFG_SIZE       0x2000u
#define ARB_VERSION     0x0000u
#define ARB_FEATURES    0x0004u
#define ARB_CMD         0x00u
#define ARB_STATUS      0x08u
#define ARB_RDATA0      0x18u
#define ARB_V5_MIN      0x50000000u
#define ARB_V7_MIN      0x70000000u
#define ARB_OP_EXT_READ 13u
#define PMIC_SID        2u
#define CHGR_STATUS_1   0x1006u     /* bits 2:0 charger state */
#define POWER_PATH_STS  0x110Bu     /* bit0 valid input source */
#define USBIN_RT_STS    0x1310u     /* bit4 USBIN plugged in */
#define APSD_RESULT     0x1308u     /* bit0 SDP, 2 CDP, 3 DCP, 4 float */
#define USBIN_ICL_CFG   0x1370u     /* input current limit, 50 mA steps */
#define CHGR_FCC_CFG    0x1061u     /* fast charge current, 50 mA steps */
#define CHGR_FV_CFG     0x1070u     /* float voltage, 3.6 V + 10 mV steps */

#define BAT_TAG         1u
#define POLL_MS         1000
#define FG_EVERY        5           /* gauges every 5 polls */
#define NOTIFY_EVERY    60
#define DIAG_EVERY      10
#define STALE_TICKS     (60ULL * 10000000ULL)

enum { SP_CHGR, SP_DCDC, SP_USBIN, SP_APSD, SP_ICL, SP_FCC, SP_FV, SP_N };
static const USHORT gSpAddr[SP_N] = {
    CHGR_STATUS_1, POWER_PATH_STS, USBIN_RT_STS,
    APSD_RESULT, USBIN_ICL_CFG, CHGR_FCC_CFG, CHGR_FV_CFG,
};
static const char *const gSpName[SP_N] = {
    " chgr_sts1=", " pwr_path=", " usbin_rt=",
    " apsd=", " icl_cfg=", " fcc_cfg=", " fv_cfg=",
};

typedef struct _BUS {
    PUCHAR Sda;
    PUCHAR Scl;
    BOOLEAN Fail;           /* clock stretch timeout in this transaction */
    ULONG SdaCfg0, SclCfg0; /* cfg before we took the pins (diag) */
} BUS, *PBUS;

typedef struct _CELL {
    BOOLEAN Ok;
    USHORT Temp, Mv, Flags, Rm, Fcc, Cyc, Soc, Dcap;
    SHORT Ma;
    ULONG Reads, Errs;
} CELL;

typedef struct _SNAP {
    BOOLEAN Valid;
    BOOLEAN Online;
    BOOLEAN Full;
    ULONG Soc;              /* mapped, 0-100 */
    ULONG Mv;
    LONG Ma;
    ULONG RmMah, FccMah, DcapMah, Cyc, TempDk;
    ULONG64 Stamp;          /* KeQueryInterruptTime of the last gauge read */
} SNAP;

typedef struct _BAT_EXT {
    PDEVICE_OBJECT Fdo, Pdo, Lower;
    PVOID Class;
    KSPIN_LOCK Lock;
    SNAP Snap;
    CELL Cell[2];
    BUS Bus[2];
    PUCHAR Pin[4];          /* gpio28, 29, 36, 37 */
    PUCHAR Dis[2];          /* gpio117, gpio91 (read only) */
    PUCHAR Core, Obs, Cnfg;
    ULONG Apid[SP_N];
    BOOLEAN ApidOk[SP_N];
    UCHAR Sp[SP_N];
    BOOLEAN SpOk;
    KEVENT Stop;
    HANDLE ThreadHandle;
    PKTHREAD Thread;
    BOOLEAN Run;
    ULONG Iter, Notifies, SpErr;
} BAT_EXT, *PBAT_EXT;

static ULONG64 gTicksPerUs = 19;
#define HALF_US     10u             /* 50 kHz */
#define STRETCH_US  5000u

/* ======================= bit-banged I2C (open drain) ==================== */
static __forceinline ULONG64
Cnt(VOID)
{
    ULONG64 v;

    __asm__ volatile("isb; mrs %0, cntvct_el0" : "=r"(v));
    return v;
}

static VOID
DelayUs(ULONG Us)
{
    ULONG64 end = Cnt() + Us * gTicksPerUs + 1;

    while (Cnt() < end)
        ;
}

static __forceinline VOID
PinDrive(PUCHAR P, BOOLEAN Low)
{
    /* func 0 (gpio), 2 mA, pull-up; OE=1 drives the latched 0. */
    WRITE_REGISTER_ULONG((PULONG)P, CFG_PULLUP | (Low ? CFG_OE : 0u));
}

static __forceinline ULONG
PinIn(PUCHAR P)
{
    return READ_REGISTER_ULONG((PULONG)(P + 4)) & 1u;
}

static BOOLEAN
PinRelease(PUCHAR P, ULONG MaxUs)
{
    ULONG64 end;

    PinDrive(P, FALSE);
    if (PinIn(P))
        return TRUE;
    end = Cnt() + MaxUs * gTicksPerUs;
    while (Cnt() < end)
        if (PinIn(P))
            return TRUE;
    return FALSE;
}

#define HALF()      DelayUs(HALF_US)
static VOID SdaLo(PBUS B) { PinDrive(B->Sda, TRUE); }
static VOID SdaHi(PBUS B) { PinRelease(B->Sda, 2); }
static VOID SclLo(PBUS B) { PinDrive(B->Scl, TRUE); }
/* After the first stretch timeout the transaction is lost; stop waiting so a
 * stuck bus costs at most one STRETCH_US at DISPATCH_LEVEL per transaction. */
static VOID SclHi(PBUS B) { if (!PinRelease(B->Scl, B->Fail ? 2 : STRETCH_US)) B->Fail = TRUE; }

static VOID
I2cStart(PBUS B)
{
    SdaHi(B);
    SclHi(B);
    HALF();
    SdaLo(B);
    HALF();
    SclLo(B);
}

static VOID
I2cStop(PBUS B)
{
    SclLo(B);
    SdaLo(B);
    HALF();
    SclHi(B);
    HALF();
    SdaHi(B);
    HALF();
}

static BOOLEAN
I2cPut(PBUS B, UCHAR V)
{
    ULONG i;
    BOOLEAN ack;

    for (i = 0; i < 8; i++) {
        if (V & 0x80)
            SdaHi(B);
        else
            SdaLo(B);
        V <<= 1;
        HALF();
        SclHi(B);
        HALF();
        SclLo(B);
    }
    SdaHi(B);
    HALF();
    SclHi(B);
    ack = PinIn(B->Sda) == 0;
    HALF();
    SclLo(B);
    return ack && !B->Fail;
}

static UCHAR
I2cGet(PBUS B, BOOLEAN Ack)
{
    ULONG i;
    UCHAR v = 0;

    SdaHi(B);
    for (i = 0; i < 8; i++) {
        HALF();
        SclHi(B);
        v = (UCHAR)((v << 1) | PinIn(B->Sda));
        HALF();
        SclLo(B);
    }
    if (Ack)
        SdaLo(B);
    HALF();
    SclHi(B);
    HALF();
    SclLo(B);
    SdaHi(B);
    return v;
}

/* Free a gauge that holds SDA low mid-byte (e.g. after a warm reboot). */
static VOID
I2cRecover(PBUS B)
{
    ULONG i;

    B->Fail = FALSE;
    SdaHi(B);
    for (i = 0; i < 9 && !PinIn(B->Sda); i++) {
        SclLo(B);
        HALF();
        SclHi(B);
        HALF();
    }
    I2cStart(B);
    I2cStop(B);
}

static VOID
I2cInitPins(PBUS B)
{
    B->SdaCfg0 = READ_REGISTER_ULONG((PULONG)B->Sda);
    B->SclCfg0 = READ_REGISTER_ULONG((PULONG)B->Scl);
    /* Output latch 0 once; the lines are then only ever driven low. */
    WRITE_REGISTER_ULONG((PULONG)(B->Sda + 4), 0);
    WRITE_REGISTER_ULONG((PULONG)(B->Scl + 4), 0);
    SdaHi(B);
    SclHi(B);
    I2cRecover(B);
}

/* SMBus read word: S addr+W reg Sr addr+R lo(A) hi(N) P. About 1 ms. */
static BOOLEAN
FgReadWord(PBUS B, UCHAR Reg, USHORT *Out)
{
    UCHAR lo = 0, hi = 0;
    BOOLEAN ok;
    KIRQL old;

    KeRaiseIrql(DISPATCH_LEVEL, &old);
    B->Fail = FALSE;
    I2cStart(B);
    ok = I2cPut(B, FG_ADDR << 1) && I2cPut(B, Reg);
    if (ok) {
        I2cStart(B);
        ok = I2cPut(B, (FG_ADDR << 1) | 1);
    }
    if (ok) {
        lo = I2cGet(B, TRUE);
        hi = I2cGet(B, FALSE);
        ok = !B->Fail;
    }
    I2cStop(B);
    KeLowerIrql(old);
    DelayUs(100);               /* bus free time between gauge commands */
    if (ok)
        *Out = (USHORT)(lo | (hi << 8));
    return ok;
}

static BOOLEAN
ReadCell(PBUS B, CELL *C)
{
    CELL n = *C;
    USHORT ma = 0;
    ULONG tries;

    for (tries = 0; tries < 2; tries++) {
        if (FgReadWord(B, FG_VOLT, &n.Mv) &&
            FgReadWord(B, FG_AI, &ma) &&
            FgReadWord(B, FG_FLAGS, &n.Flags) &&
            FgReadWord(B, FG_RM, &n.Rm) &&
            FgReadWord(B, FG_FCC, &n.Fcc) &&
            FgReadWord(B, FG_SOC, &n.Soc) &&
            FgReadWord(B, FG_TEMP, &n.Temp) &&
            FgReadWord(B, FG_CYC, &n.Cyc) &&
            FgReadWord(B, FG_DCAP, &n.Dcap) &&
            n.Mv >= 2500 && n.Mv <= 5000 && n.Soc <= 100 && n.Fcc <= 12000) {
            n.Ma = (SHORT)ma;
            n.Ok = TRUE;
            n.Reads = C->Reads + 1;
            n.Errs = C->Errs;
            *C = n;
            return TRUE;
        }
        C->Errs++;
        I2cRecover(B);
    }
    C->Ok = FALSE;
    return FALSE;
}

/* ============================ SPMI (read only) ========================== */
static ULONG
Rd(PUCHAR Base, ULONG Off)
{
    return READ_REGISTER_ULONG((PULONG)(Base + Off));
}

static BOOLEAN
FindApid(PBAT_EXT X, USHORT Ppid, ULONG *Apid)
{
    ULONG ver, count, i, off, reg, fallback = 0xFFFFFFFFu;

    ver = Rd(X->Core, ARB_VERSION);
    if (ver < ARB_V5_MIN || ver >= ARB_V7_MIN)
        return FALSE;
    count = Rd(X->Core, ARB_FEATURES) & 0x7FFu;
    if (count == 0 || count > 512)
        count = 512;
    for (i = 0; i < count; i++) {
        off = 0x900u + 4u * i;
        if (off >= CORE_LIMIT)
            break;
        reg = Rd(X->Core, off);
        if (reg == 0 || ((reg >> 8) & 0xFFFu) != Ppid)
            continue;
        if ((Rd(X->Cnfg, 0x700u + 4u * i) & 7u) == 0) {
            *Apid = i;
            return TRUE;
        }
        if (fallback == 0xFFFFFFFFu)
            fallback = i;
    }
    if (fallback == 0xFFFFFFFFu)
        return FALSE;
    *Apid = fallback;
    return TRUE;
}

static BOOLEAN
SpmiRead(PBAT_EXT X, ULONG Apid, USHORT Addr, UCHAR *Out)
{
    ULONG offset = 0x80u * Apid, spins, st;

    if (offset + ARB_RDATA0 >= OBS_SIZE)
        return FALSE;
    st = Rd(X->Obs, offset + ARB_STATUS);
    if ((st & 1u) == 0 && st != 0)
        return FALSE;
    WRITE_REGISTER_ULONG((PULONG)(X->Obs + offset + ARB_CMD),
                         (ARB_OP_EXT_READ << 27) | (((ULONG)Addr & 0xFFu) << 4));
    for (spins = 0; spins < 1000; spins++) {
        st = Rd(X->Obs, offset + ARB_STATUS);
        if (st & 1u) {
            if (st & 0xEu)
                return FALSE;
            *Out = (UCHAR)Rd(X->Obs, offset + ARB_RDATA0);
            return TRUE;
        }
        KeStallExecutionProcessor(1);
    }
    return FALSE;
}

static VOID
ReadCharger(PBAT_EXT X)
{
    ULONG i;
    BOOLEAN ok = TRUE;

    if (!X->Core)
        return;
    /* Only the three status registers decide SpOk; the config registers
     * are diagnostics for the charge-power measurement. */
    for (i = 0; i < SP_N; i++)
        if (!X->ApidOk[i] || !SpmiRead(X, X->Apid[i], gSpAddr[i], &X->Sp[i]))
            if (i <= SP_USBIN)
                ok = FALSE;
    if (!ok)
        X->SpErr++;
    X->SpOk = ok;
}

/* =============================== snapshot =============================== */
static VOID
Combine(PBAT_EXT X, BOOLEAN GaugesRead)
{
    CELL *a = &X->Cell[0], *b = &X->Cell[1];
    SNAP s;
    KIRQL irql;
    ULONG rm, fcc, raw;

    KeAcquireSpinLock(&X->Lock, &irql);
    s = X->Snap;
    KeReleaseSpinLock(&X->Lock, irql);

    if (GaugesRead && a->Ok && b->Ok) {
        rm = (ULONG)a->Rm + b->Rm;
        fcc = (ULONG)a->Fcc + b->Fcc;
        if (fcc == 0) {
            s.Soc = ((ULONG)a->Soc + b->Soc) / 2;
        } else {
            raw = (ULONG)((ULONG64)rm * 10000 / fcc);
            if (raw > SOC_RAW_FULL) {
                s.Soc = 100;
            } else {
                s.Soc = (raw + 95) / 96;
                if (s.Soc > 99)
                    s.Soc = 99;
            }
        }
        s.Mv = a->Mv > b->Mv ? a->Mv : b->Mv;
        s.Ma = (LONG)a->Ma + b->Ma;
        s.RmMah = rm;
        s.FccMah = fcc;
        s.DcapMah = (ULONG)a->Dcap + b->Dcap;
        s.Cyc = a->Cyc > b->Cyc ? a->Cyc : b->Cyc;
        s.TempDk = ((ULONG)a->Temp + b->Temp) / 2;
        s.Full = (a->Flags & FG_FLAG_FC) && (b->Flags & FG_FLAG_FC);
        s.Stamp = KeQueryInterruptTime();
        s.Valid = TRUE;
    }
    if (X->SpOk)
        s.Online = (X->Sp[SP_USBIN] & 0x10u) || (X->Sp[SP_DCDC] & 0x01u);
    else
        s.Online = s.Valid && s.Ma > 0;

    KeAcquireSpinLock(&X->Lock, &irql);
    X->Snap = s;
    KeReleaseSpinLock(&X->Lock, irql);
}

static SNAP
GetSnap(PBAT_EXT X)
{
    SNAP s;
    KIRQL irql;

    KeAcquireSpinLock(&X->Lock, &irql);
    s = X->Snap;
    KeReleaseSpinLock(&X->Lock, irql);
    return s;
}

static ULONG
Mwh(ULONG Mah)
{
    return (ULONG)((ULONG64)Mah * NOMINAL_MV / 1000);
}

/* ============================= diagnostics =============================== */
static VOID
AppS(char **p, char *e, const char *s) { while (*s && *p < e) *(*p)++ = *s++; }

static VOID
AppU(char **p, char *e, ULONG v)
{
    char t[12];
    int n = 0;

    do { t[n++] = (char)('0' + v % 10); v /= 10; } while (v && n < 12);
    while (n && *p < e) *(*p)++ = t[--n];
}

static VOID
AppI(char **p, char *e, LONG v)
{
    if (v < 0) {
        AppS(p, e, "-");
        AppU(p, e, (ULONG)(-v));
    } else {
        AppU(p, e, (ULONG)v);
    }
}

static VOID
AppX(char **p, char *e, ULONG v)
{
    static const char h[] = "0123456789abcdef";
    int i;

    AppS(p, e, "0x");
    for (i = 28; i >= 0; i -= 4)
        if (*p < e)
            *(*p)++ = h[(v >> i) & 15];
}

static VOID
WriteDiag(PBAT_EXT X)
{
    static char buf[1536];
    char *p = buf, *e = buf + sizeof(buf);
    SNAP s = GetSnap(X);
    UNICODE_STRING name;
    OBJECT_ATTRIBUTES oa;
    IO_STATUS_BLOCK iosb;
    HANDLE h;
    ULONG i;

    AppS(&p, e, "iter=");
    AppU(&p, e, X->Iter);
    AppS(&p, e, " notifies=");
    AppU(&p, e, X->Notifies);
    AppS(&p, e, "\nsnap valid=");
    AppU(&p, e, s.Valid);
    AppS(&p, e, " online=");
    AppU(&p, e, s.Online);
    AppS(&p, e, " full=");
    AppU(&p, e, s.Full);
    AppS(&p, e, " soc=");
    AppU(&p, e, s.Soc);
    AppS(&p, e, " mv=");
    AppU(&p, e, s.Mv);
    AppS(&p, e, " ma=");
    AppI(&p, e, s.Ma);
    AppS(&p, e, " mw=");
    AppI(&p, e, (LONG)((LONGLONG)s.Mv * s.Ma / 1000));
    AppS(&p, e, " rm=");
    AppU(&p, e, s.RmMah);
    AppS(&p, e, " fcc=");
    AppU(&p, e, s.FccMah);
    AppS(&p, e, " dcap=");
    AppU(&p, e, s.DcapMah);
    AppS(&p, e, " cyc=");
    AppU(&p, e, s.Cyc);
    AppS(&p, e, " temp_dk=");
    AppU(&p, e, s.TempDk);
    for (i = 0; i < 2; i++) {
        CELL *c = &X->Cell[i];

        AppS(&p, e, i == 0 ? "\ncell_r(gpio28/29)" : "\ncell_l(gpio36/37)");
        AppS(&p, e, " ok=");
        AppU(&p, e, c->Ok);
        AppS(&p, e, " reads=");
        AppU(&p, e, c->Reads);
        AppS(&p, e, " errs=");
        AppU(&p, e, c->Errs);
        AppS(&p, e, " mv=");
        AppU(&p, e, c->Mv);
        AppS(&p, e, " ma=");
        AppI(&p, e, c->Ma);
        AppS(&p, e, " soc=");
        AppU(&p, e, c->Soc);
        AppS(&p, e, " rm=");
        AppU(&p, e, c->Rm);
        AppS(&p, e, " fcc=");
        AppU(&p, e, c->Fcc);
        AppS(&p, e, " dcap=");
        AppU(&p, e, c->Dcap);
        AppS(&p, e, " cyc=");
        AppU(&p, e, c->Cyc);
        AppS(&p, e, " temp_dk=");
        AppU(&p, e, c->Temp);
        AppS(&p, e, " flags=");
        AppX(&p, e, c->Flags);
        AppS(&p, e, " cfg0=");
        AppX(&p, e, X->Bus[i].SdaCfg0);
        AppS(&p, e, "/");
        AppX(&p, e, X->Bus[i].SclCfg0);
    }
    AppS(&p, e, "\nspmi ok=");
    AppU(&p, e, X->SpOk);
    AppS(&p, e, " err=");
    AppU(&p, e, X->SpErr);
    for (i = 0; i < SP_N; i++) {
        AppS(&p, e, gSpName[i]);
        AppX(&p, e, X->Sp[i]);
        AppS(&p, e, "@apid");
        AppI(&p, e, X->ApidOk[i] ? (LONG)X->Apid[i] : -1);
    }
    AppS(&p, e, "\nfg_dis gpio117 cfg=");
    AppX(&p, e, X->Dis[0] ? Rd(X->Dis[0], 0) : 0);
    AppS(&p, e, " io=");
    AppX(&p, e, X->Dis[0] ? Rd(X->Dis[0], 4) : 0);
    AppS(&p, e, " gpio91 cfg=");
    AppX(&p, e, X->Dis[1] ? Rd(X->Dis[1], 0) : 0);
    AppS(&p, e, " io=");
    AppX(&p, e, X->Dis[1] ? Rd(X->Dis[1], 4) : 0);
    AppS(&p, e, "\n");

    RtlInitUnicodeString(&name, L"\\SystemRoot\\dagu-battery.txt");
    InitializeObjectAttributes(&oa, &name, OBJ_KERNEL_HANDLE | OBJ_CASE_INSENSITIVE, NULL, NULL);
    if (NT_SUCCESS(ZwCreateFile(&h, GENERIC_WRITE | SYNCHRONIZE, &oa, &iosb, NULL,
                                FILE_ATTRIBUTE_NORMAL, FILE_SHARE_READ, FILE_OVERWRITE_IF,
                                FILE_SYNCHRONOUS_IO_NONALERT | FILE_NON_DIRECTORY_FILE,
                                NULL, 0))) {
        ZwWriteFile(h, NULL, NULL, NULL, &iosb, buf, (ULONG)(p - buf), NULL, NULL);
        ZwClose(h);
    }
}

/* ============================== poll thread ============================== */
static VOID
ThreadMain(PVOID Context)
{
    PBAT_EXT X = Context;
    LARGE_INTEGER t;
    SNAP prev, cur;
    BOOLEAN read;

    I2cInitPins(&X->Bus[0]);
    I2cInitPins(&X->Bus[1]);
    RtlZeroMemory(&prev, sizeof(prev));
    t.QuadPart = -(LONGLONG)POLL_MS * 10000;
    for (;;) {
        read = (X->Iter % FG_EVERY) == 0;
        if (read) {
            ReadCell(&X->Bus[0], &X->Cell[0]);
            ReadCell(&X->Bus[1], &X->Cell[1]);
        }
        ReadCharger(X);
        Combine(X, read);
        cur = GetSnap(X);
        if (X->Class &&
            (cur.Valid != prev.Valid || cur.Online != prev.Online || cur.Soc != prev.Soc ||
             cur.Full != prev.Full || (X->Iter % NOTIFY_EVERY) == NOTIFY_EVERY - 1)) {
            X->Notifies++;
            BatteryClassStatusNotify(X->Class);
        }
        prev = cur;
        if ((X->Iter % DIAG_EVERY) == 0)
            WriteDiag(X);
        X->Iter++;
        if (KeWaitForSingleObject(&X->Stop, Executive, KernelMode, FALSE, &t) == STATUS_SUCCESS)
            break;
    }
    PsTerminateSystemThread(STATUS_SUCCESS);
}

/* ========================= Battery class callbacks ======================= */
static NTSTATUS
QueryTag(_In_ PVOID Context, _Out_ PULONG BatteryTag)
{
    SNAP s = GetSnap(Context);

    if (!s.Valid) {
        *BatteryTag = BATTERY_TAG_INVALID;
        return STATUS_NO_SUCH_DEVICE;
    }
    *BatteryTag = BAT_TAG;
    return STATUS_SUCCESS;
}

static NTSTATUS
CopyOut(const VOID *Src, ULONG Len, PVOID Buffer, ULONG BufferLength, PULONG ReturnedLength)
{
    *ReturnedLength = Len;
    if (Len > BufferLength)
        return STATUS_BUFFER_TOO_SMALL;
    if (Buffer && Len)
        RtlCopyMemory(Buffer, Src, Len);
    return STATUS_SUCCESS;
}

static NTSTATUS
QueryInformation(_In_ PVOID Context, _In_ ULONG BatteryTag,
                 _In_ BATTERY_QUERY_INFORMATION_LEVEL Level, _In_ LONG AtRate,
                 _Out_writes_bytes_to_(BufferLength, *ReturnedLength) PVOID Buffer,
                 _In_ ULONG BufferLength, _Out_ PULONG ReturnedLength)
{
    static const WCHAR devName[] = L"dagu dual BQ27Z561";
    static const WCHAR mfgName[] = L"Xiaomi";
    static const WCHAR uniqueId[] = L"DAGU-BMS0";
    static const WCHAR serial[] = L"0";
    SNAP s = GetSnap(Context);
    BATTERY_INFORMATION bi;
    BATTERY_REPORTING_SCALE scale;
    ULONG v;

    *ReturnedLength = 0;
    if (!s.Valid || BatteryTag != BAT_TAG)
        return STATUS_NO_SUCH_DEVICE;

    switch (Level) {
    case BatteryInformation:
        RtlZeroMemory(&bi, sizeof(bi));
        bi.Capabilities = BATTERY_SYSTEM_BATTERY;
        bi.Technology = 1;              /* rechargeable */
        bi.Chemistry[0] = 'L';
        bi.Chemistry[1] = 'I';
        bi.Chemistry[2] = 'O';
        bi.Chemistry[3] = 'N';
        bi.DesignedCapacity = Mwh(s.DcapMah ? s.DcapMah : 10000);
        bi.FullChargedCapacity = Mwh(s.FccMah ? s.FccMah : s.DcapMah);
        bi.DefaultAlert1 = bi.DesignedCapacity * 5 / 100;   /* low */
        bi.DefaultAlert2 = bi.DesignedCapacity * 10 / 100;  /* warning */
        bi.CriticalBias = 0;
        bi.CycleCount = s.Cyc;
        return CopyOut(&bi, sizeof(bi), Buffer, BufferLength, ReturnedLength);
    case BatteryGranularityInformation:
        scale.Granularity = 1;
        scale.Capacity = Mwh(s.DcapMah ? s.DcapMah : 10000);
        return CopyOut(&scale, sizeof(scale), Buffer, BufferLength, ReturnedLength);
    case BatteryTemperature:
        v = s.TempDk;                   /* tenths of a kelvin */
        return CopyOut(&v, sizeof(v), Buffer, BufferLength, ReturnedLength);
    case BatteryEstimatedTime: {
        LONG ma = s.Ma;

        if (AtRate < 0 && s.Mv)
            ma = (LONG)((LONGLONG)AtRate * 1000 / (LONG)s.Mv);  /* mW -> mA */
        if (s.Online || ma >= 0)
            v = BATTERY_UNKNOWN_TIME;
        else
            v = (ULONG)((ULONG64)s.RmMah * 3600 / (ULONG)(-ma));
        return CopyOut(&v, sizeof(v), Buffer, BufferLength, ReturnedLength);
    }
    case BatteryDeviceName:
        return CopyOut(devName, sizeof(devName), Buffer, BufferLength, ReturnedLength);
    case BatteryManufactureName:
        return CopyOut(mfgName, sizeof(mfgName), Buffer, BufferLength, ReturnedLength);
    case BatteryUniqueID:
        return CopyOut(uniqueId, sizeof(uniqueId), Buffer, BufferLength, ReturnedLength);
    case BatterySerialNumber:
        return CopyOut(serial, sizeof(serial), Buffer, BufferLength, ReturnedLength);
    default:
        return STATUS_INVALID_DEVICE_REQUEST;
    }
}

static NTSTATUS
QueryStatus(_In_ PVOID Context, _In_ ULONG BatteryTag, _Out_ PBATTERY_STATUS St)
{
    SNAP s = GetSnap(Context);
    ULONG fullMwh;

    RtlZeroMemory(St, sizeof(*St));
    if (!s.Valid || BatteryTag != BAT_TAG)
        return STATUS_NO_SUCH_DEVICE;

    if (s.Online) {
        St->PowerState = BATTERY_POWER_ON_LINE;
        if (s.Ma > 0 && !s.Full && s.Soc < 100)
            St->PowerState |= BATTERY_CHARGING;
    } else {
        St->PowerState = BATTERY_DISCHARGING;
        if (s.Soc <= 3)
            St->PowerState |= BATTERY_CRITICAL;
    }
    if (KeQueryInterruptTime() - s.Stamp > STALE_TICKS) {
        St->Capacity = BATTERY_UNKNOWN_CAPACITY;
        St->Voltage = BATTERY_UNKNOWN_VOLTAGE;
        St->Rate = BATTERY_UNKNOWN_RATE;
        return STATUS_SUCCESS;
    }
    /* Report the mapped SoC (Linux dual-fg rule) against the full charge
     * capacity, so Windows shows the same percentage as Linux. */
    fullMwh = Mwh(s.FccMah ? s.FccMah : s.DcapMah);
    /* Round up: Windows floors Capacity / FullChargedCapacity again, so a
     * floored value here would show 98 % for a 99 % snapshot. */
    St->Capacity = (ULONG)(((ULONG64)fullMwh * s.Soc + 99) / 100);
    St->Voltage = s.Mv;
    St->Rate = (LONG)((LONGLONG)s.Mv * s.Ma / 1000);
    return STATUS_SUCCESS;
}

static NTSTATUS
SetStatusNotify(_In_ PVOID Context, _In_ ULONG BatteryTag, _In_ PBATTERY_NOTIFY Notify)
{
    SNAP s = GetSnap(Context);

    UNREFERENCED_PARAMETER(Notify);
    /* The poll thread notifies on every SoC / power source change. */
    if (!s.Valid || BatteryTag != BAT_TAG)
        return STATUS_NO_SUCH_DEVICE;
    return STATUS_SUCCESS;
}

static NTSTATUS
DisableStatusNotify(_In_ PVOID Context)
{
    UNREFERENCED_PARAMETER(Context);
    return STATUS_SUCCESS;
}

static NTSTATUS
SetInformation(_In_ PVOID Context, _In_ ULONG BatteryTag,
               _In_ BATTERY_SET_INFORMATION_LEVEL Level, _In_opt_ PVOID Buffer)
{
    UNREFERENCED_PARAMETER(Context);
    UNREFERENCED_PARAMETER(BatteryTag);
    UNREFERENCED_PARAMETER(Level);
    UNREFERENCED_PARAMETER(Buffer);
    return STATUS_NOT_SUPPORTED;
}

/* ============================== device start ============================= */
static PUCHAR
MapPage(ULONG64 Pa, ULONG Size)
{
    PHYSICAL_ADDRESS pa;

    pa.QuadPart = (LONGLONG)Pa;
    return MmMapIoSpaceEx(pa, Size, PAGE_READWRITE | PAGE_NOCACHE);
}

static VOID
UnmapAll(PBAT_EXT X)
{
    ULONG i;

    for (i = 0; i < 4; i++)
        if (X->Pin[i]) { MmUnmapIoSpace(X->Pin[i], PIN_SIZE); X->Pin[i] = NULL; }
    for (i = 0; i < 2; i++)
        if (X->Dis[i]) { MmUnmapIoSpace(X->Dis[i], PIN_SIZE); X->Dis[i] = NULL; }
    if (X->Core) { MmUnmapIoSpace(X->Core, CORE_SIZE); X->Core = NULL; }
    if (X->Obs) { MmUnmapIoSpace(X->Obs, OBS_SIZE); X->Obs = NULL; }
    if (X->Cnfg) { MmUnmapIoSpace(X->Cnfg, CNFG_SIZE); X->Cnfg = NULL; }
}

static VOID
StopDevice(PBAT_EXT X)
{
    if (X->Run) {
        KeSetEvent(&X->Stop, IO_NO_INCREMENT, FALSE);
        if (X->Thread) {
            KeWaitForSingleObject(X->Thread, Executive, KernelMode, FALSE, NULL);
            ObDereferenceObject(X->Thread);
        }
        if (X->ThreadHandle)
            ZwClose(X->ThreadHandle);
        X->Thread = NULL;
        X->ThreadHandle = NULL;
        X->Run = FALSE;
    }
    if (X->Class) {
        BatteryClassUnload(X->Class);
        X->Class = NULL;
    }
    UnmapAll(X);
}

static NTSTATUS
StartDevice(PBAT_EXT X)
{
    static const ULONG pins[4] = { 28, 29, 36, 37 };
    BATTERY_MINIPORT_INFO mi;
    OBJECT_ATTRIBUTES oa;
    NTSTATUS st;
    ULONG i;

    if (X->Run)
        return STATUS_SUCCESS;
    for (i = 0; i < 4; i++)
        X->Pin[i] = MapPage(PIN_PA(i < 2 ? TLMM_NORTH : TLMM_SOUTH, pins[i]), PIN_SIZE);
    X->Dis[0] = MapPage(PIN_PA(TLMM_NORTH, 117), PIN_SIZE);
    X->Dis[1] = MapPage(PIN_PA(TLMM_SOUTH, 91), PIN_SIZE);
    if (!X->Pin[0] || !X->Pin[1] || !X->Pin[2] || !X->Pin[3]) {
        UnmapAll(X);
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    X->Bus[0].Sda = X->Pin[0];
    X->Bus[0].Scl = X->Pin[1];
    X->Bus[1].Sda = X->Pin[2];
    X->Bus[1].Scl = X->Pin[3];

    /* SPMI is optional: without it "on line" falls back to current > 0. */
    X->Core = MapPage(CORE_PHYS, CORE_SIZE);
    X->Obs = MapPage(OBS_PHYS, OBS_SIZE);
    X->Cnfg = MapPage(CNFG_PHYS, CNFG_SIZE);
    if (X->Core && X->Obs && X->Cnfg) {
        for (i = 0; i < SP_N; i++)
            X->ApidOk[i] = FindApid(X, (USHORT)((PMIC_SID << 8) | (gSpAddr[i] >> 8)),
                                    &X->Apid[i]);
    } else {
        if (X->Core) { MmUnmapIoSpace(X->Core, CORE_SIZE); X->Core = NULL; }
        if (X->Obs) { MmUnmapIoSpace(X->Obs, OBS_SIZE); X->Obs = NULL; }
        if (X->Cnfg) { MmUnmapIoSpace(X->Cnfg, CNFG_SIZE); X->Cnfg = NULL; }
    }

    RtlZeroMemory(&mi, sizeof(mi));
    mi.MajorVersion = BATTERY_CLASS_MAJOR_VERSION;
    mi.MinorVersion = BATTERY_CLASS_MINOR_VERSION;
    mi.Context = X;
    mi.QueryTag = QueryTag;
    mi.QueryInformation = QueryInformation;
    mi.SetInformation = SetInformation;
    mi.QueryStatus = QueryStatus;
    mi.SetStatusNotify = SetStatusNotify;
    mi.DisableStatusNotify = DisableStatusNotify;
    mi.Pdo = X->Pdo;
    mi.DeviceName = NULL;
    st = BatteryClassInitializeDevice(&mi, &X->Class);
    if (!NT_SUCCESS(st)) {
        X->Class = NULL;
        UnmapAll(X);
        return st;
    }

    KeInitializeEvent(&X->Stop, NotificationEvent, FALSE);
    InitializeObjectAttributes(&oa, NULL, OBJ_KERNEL_HANDLE, NULL, NULL);
    st = PsCreateSystemThread(&X->ThreadHandle, THREAD_ALL_ACCESS, &oa, NULL, NULL,
                              ThreadMain, X);
    if (!NT_SUCCESS(st)) {
        BatteryClassUnload(X->Class);
        X->Class = NULL;
        UnmapAll(X);
        return st;
    }
    ObReferenceObjectByHandle(X->ThreadHandle, THREAD_ALL_ACCESS, *PsThreadType,
                              KernelMode, (PVOID *)&X->Thread, NULL);
    X->Run = TRUE;
    return STATUS_SUCCESS;
}

/* ================================ WDM glue =============================== */
static NTSTATUS
AddDevice(_In_ PDRIVER_OBJECT Drv, _In_ PDEVICE_OBJECT Pdo)
{
    PDEVICE_OBJECT fdo;
    PBAT_EXT X;
    NTSTATUS st;

    st = IoCreateDevice(Drv, sizeof(BAT_EXT), NULL, FILE_DEVICE_BATTERY,
                        FILE_DEVICE_SECURE_OPEN, FALSE, &fdo);
    if (!NT_SUCCESS(st))
        return st;
    X = fdo->DeviceExtension;
    RtlZeroMemory(X, sizeof(*X));
    X->Fdo = fdo;
    X->Pdo = Pdo;
    KeInitializeSpinLock(&X->Lock);
    X->Lower = IoAttachDeviceToDeviceStack(fdo, Pdo);
    if (!X->Lower) {
        IoDeleteDevice(fdo);
        return STATUS_NO_SUCH_DEVICE;
    }
    fdo->Flags |= DO_POWER_PAGABLE | DO_BUFFERED_IO;
    fdo->Flags &= ~DO_DEVICE_INITIALIZING;
    return STATUS_SUCCESS;
}

static NTSTATUS
Forward(PBAT_EXT X, PIRP Irp)
{
    IoSkipCurrentIrpStackLocation(Irp);
    return IoCallDriver(X->Lower, Irp);
}

static NTSTATUS
Complete(PIRP Irp, NTSTATUS St)
{
    Irp->IoStatus.Status = St;
    Irp->IoStatus.Information = 0;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return St;
}

static NTSTATUS
PnpDispatch(_In_ PDEVICE_OBJECT Fdo, _In_ PIRP Irp)
{
    PBAT_EXT X = Fdo->DeviceExtension;
    NTSTATUS st;

    switch (IoGetCurrentIrpStackLocation(Irp)->MinorFunction) {
    case IRP_MN_START_DEVICE:
        st = IoForwardIrpSynchronously(X->Lower, Irp) ? Irp->IoStatus.Status
                                                        : STATUS_UNSUCCESSFUL;
        if (NT_SUCCESS(st))
            st = StartDevice(X);
        return Complete(Irp, st);
    case IRP_MN_QUERY_STOP_DEVICE:
    case IRP_MN_QUERY_REMOVE_DEVICE:
    case IRP_MN_CANCEL_STOP_DEVICE:
    case IRP_MN_CANCEL_REMOVE_DEVICE:
        Irp->IoStatus.Status = STATUS_SUCCESS;
        return Forward(X, Irp);
    case IRP_MN_STOP_DEVICE:
    case IRP_MN_SURPRISE_REMOVAL:
        StopDevice(X);
        Irp->IoStatus.Status = STATUS_SUCCESS;
        return Forward(X, Irp);
    case IRP_MN_REMOVE_DEVICE: {
        PDEVICE_OBJECT lower = X->Lower;

        StopDevice(X);
        Irp->IoStatus.Status = STATUS_SUCCESS;
        IoSkipCurrentIrpStackLocation(Irp);
        st = IoCallDriver(lower, Irp);
        IoDetachDevice(lower);
        IoDeleteDevice(Fdo);
        return st;
    }
    default:
        return Forward(X, Irp);
    }
}

static NTSTATUS
PowerDispatch(_In_ PDEVICE_OBJECT Fdo, _In_ PIRP Irp)
{
    PBAT_EXT X = Fdo->DeviceExtension;

    PoStartNextPowerIrp(Irp);
    IoSkipCurrentIrpStackLocation(Irp);
    return PoCallDriver(X->Lower, Irp);
}

static NTSTATUS
CreateClose(_In_ PDEVICE_OBJECT Fdo, _In_ PIRP Irp)
{
    UNREFERENCED_PARAMETER(Fdo);
    return Complete(Irp, STATUS_SUCCESS);
}

static NTSTATUS
DeviceControl(_In_ PDEVICE_OBJECT Fdo, _In_ PIRP Irp)
{
    PBAT_EXT X = Fdo->DeviceExtension;
    NTSTATUS st = STATUS_NOT_SUPPORTED;

    if (X->Class)
        st = BatteryClassIoctl(X->Class, Irp);   /* completes the IRP itself */
    if (st == STATUS_NOT_SUPPORTED)
        return Forward(X, Irp);
    return st;
}

static NTSTATUS
SystemControl(_In_ PDEVICE_OBJECT Fdo, _In_ PIRP Irp)
{
    return Forward(Fdo->DeviceExtension, Irp);
}

static VOID
Unload(_In_ PDRIVER_OBJECT Drv)
{
    UNREFERENCED_PARAMETER(Drv);
}

NTSTATUS
DriverEntry(_In_ PDRIVER_OBJECT Drv, _In_ PUNICODE_STRING RegistryPath)
{
    ULONG64 frq;

    UNREFERENCED_PARAMETER(RegistryPath);
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(frq));
    if (frq >= 1000000)
        gTicksPerUs = frq / 1000000;
    Drv->MajorFunction[IRP_MJ_CREATE] = CreateClose;
    Drv->MajorFunction[IRP_MJ_CLOSE] = CreateClose;
    Drv->MajorFunction[IRP_MJ_CLEANUP] = CreateClose;
    Drv->MajorFunction[IRP_MJ_DEVICE_CONTROL] = DeviceControl;
    Drv->MajorFunction[IRP_MJ_SYSTEM_CONTROL] = SystemControl;
    Drv->MajorFunction[IRP_MJ_PNP] = PnpDispatch;
    Drv->MajorFunction[IRP_MJ_POWER] = PowerDispatch;
    Drv->DriverUnload = Unload;
    Drv->DriverExtension->AddDevice = AddDevice;
    return STATUS_SUCCESS;
}
