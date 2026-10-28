/* SPDX-License-Identifier: MIT
 * Xiaomi Pad 5 Pro 12.4 (dagu) folio keyboard: Nanosic 803 MCU, I2C 0x4c.
 *
 * Same model as the Himax touch driver: a self-contained HIDCLASS
 * minidriver, no SPB/GENI/PEP. It bit-bangs I2C on gpio115 (SDA) / gpio116
 * (SCL) through the TLMM registers (the Linux "i2c-gpio" fallback node of
 * the same bus) and polls the GPIO83 data line (low = the MCU has a packet).
 * DaguQupDxe (UEFI) already powered the MCU (vdd 127, reset 141, sleep 155).
 *
 * Protocol is linux-mainline/overlays/linux/drivers/input/keyboard/
 * nanosic-dagu.c:
 *   read : S 4C/W [4C] Sr 4C/R <68 bytes> P
 *   write: S 4C/W [4C] <66 bytes> P
 *   packet [0x57, seq, len(0x39/4A/5B/6C), records...]; a record's type byte
 *   is the HID report ID: 0x05 keyboard (9), 0x06 consumer (5),
 *   0x02 mouse (8), 0x19 touchpad (21), 0x22/0x23 vendor.
 *   Host->176x command [32 00 4E 31 80 38 op a b sum(2..8)].
 *
 * Windows sees one HID device with three top-level collections: the MCU's
 * own keyboard (ID 5) and consumer (ID 6) descriptors, and its relative
 * mouse (ID 2). The touchpad record (0x19) is not a Windows Precision
 * Touchpad, so it is translated here into mouse reports: one finger moves,
 * two fingers scroll, a short tap clicks, the pad button is the left button.
 */
#include <ntddk.h>
#include <hidport.h>

#ifndef IOCTL_HID_GET_FEATURE
#define IOCTL_HID_GET_FEATURE       HID_CTL_CODE(11)
#define IOCTL_HID_SET_FEATURE       HID_CTL_CODE(12)
#endif
#ifndef IOCTL_HID_SET_OUTPUT_REPORT
#define IOCTL_HID_SET_OUTPUT_REPORT HID_CTL_CODE(14)
#endif

/* TLMM NORTH: gpio g at 0x0F900000 + g*0x1000; +0 cfg, +4 IO (bit0 IN,
 * bit1 OUT). cfg: pull[1:0] (3 = up), func[5:2], drv[8:6], OE bit9. */
#define I2C_PHYS        0x0F973000ULL   /* gpio115 cfg; gpio116 = +0x1000 */
#define I2C_SIZE        0x2000u
#define SDA_OFF         0x0000u
#define SCL_OFF         0x1000u
#define IRQ_PHYS        0x0F953000ULL   /* gpio83 */
#define IRQ_SIZE        0x1000u
/* TLMM per-pin interrupt block (pinctrl-sm8250.c / pinctrl-msm.c):
 * +0x8 INTR_CFG: bit0 enable (to the GIC), bit1 polarity, bits3:2 detection
 * (2 = edge), bit4 RAW_STATUS (latch into STATUS even when not enabled),
 * bits7:5 target. +0xC INTR_STATUS bit0, cleared by writing 0. Falling edge
 * = detection 2 + polarity 1. Enable stays 0: nothing is routed to Windows'
 * GIC, the latch is only polled. */
#define INTR_CFG        0x8u
#define INTR_STATUS     0xCu
#define INTR_EN         (1u << 0)
#define INTR_POL        (1u << 1)
#define INTR_DET_MASK   (3u << 2)
#define INTR_DET_EDGE   (2u << 2)
#define INTR_RAW        (1u << 4)
#define CFG_PULLUP      3u
#define CFG_OE          (1u << 9)

#define NANO_ADDR       0x4Cu
#define NANO_WRITE_LEN  66
#define NANO_READ_LEN   68
#define NANO_SYNC       0x57
#define T_KBD           0x05
#define T_CONS          0x06
#define T_MOUSE         0x02
#define T_TOUCH         0x19
#define T_V16           0x22
#define T_V32           0x23
#define T_V24           0x24
#define T_V26           0x26

#define RPT_MAX         9
#define RPT_RING        32
#define PEND_RING       16
#define KHIST           32              /* keyboard record history (diag) */
#define DRAIN_MAX       4               /* back-to-back reads per wakeup */

/* ---- report descriptor: the MCU's own (live Android dump, VID 15d9) ---- */
static const UCHAR gReportDesc[] = {
    /* Keyboard, report ID 5 */
    0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x85, 0x05, 0x05, 0x07, 0x19, 0xe0,
    0x29, 0xe7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
    0x81, 0x03, 0x95, 0x05, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02,
    0x95, 0x01, 0x75, 0x03, 0x91, 0x01, 0x95, 0x06, 0x75, 0x08, 0x15, 0x00,
    0x26, 0xa4, 0x00, 0x05, 0x07, 0x19, 0x00, 0x2a, 0xa4, 0x00, 0x81, 0x00,
    0xc0,
    /* Consumer control, report ID 6, one 16-bit usage */
    0x05, 0x0c, 0x09, 0x01, 0xa1, 0x01, 0x85, 0x06, 0x15, 0x00, 0x26, 0x80,
    0x03, 0x19, 0x00, 0x2a, 0x80, 0x03, 0x75, 0x10, 0x95, 0x01, 0x81, 0x00,
    0xc0,
    /* Mouse, report ID 2: 5 buttons, 16-bit relative X / Y / wheel */
    0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, 0x85, 0x02, 0x09, 0x01, 0xa1, 0x00,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x05, 0x15, 0x00, 0x25, 0x01, 0x95, 0x05,
    0x75, 0x01, 0x81, 0x02, 0x95, 0x01, 0x75, 0x03, 0x81, 0x01, 0x05, 0x01,
    0x09, 0x30, 0x09, 0x31, 0x09, 0x38, 0x16, 0x00, 0x80, 0x26, 0xff, 0x7f,
    0x75, 0x10, 0x95, 0x03, 0x81, 0x06, 0xc0, 0xc0,
};

static const HID_DESCRIPTOR gHidDesc = {
    0x09, 0x21, 0x0111, 0x00, 0x01,
    { { 0x22, sizeof(gReportDesc) } }
};

typedef struct _RPT {
    UCHAR Len;
    UCHAR B[RPT_MAX];
} RPT;

typedef struct _NANO_EXT {
    PDEVICE_OBJECT Fdo;
    PUCHAR I2c;
    PUCHAR Irq;
    HANDLE ThreadHandle;
    PKTHREAD Thread;
    KEVENT Stop;
    BOOLEAN Run;
    /* Read IRPs waiting for a report, and reports waiting for a read IRP.
     * Keyboard key-ups must not be dropped, so reports queue when HIDCLASS
     * has no read outstanding. */
    KSPIN_LOCK Lock;
    PIRP Pend[PEND_RING];
    ULONG PendHead, PendTail;
    RPT Ring[RPT_RING];
    ULONG RingHead, RingTail;
    /* LED output report (Caps Lock), sent by the poll thread. */
    volatile LONG LedPending;
    UCHAR LedWant;
    /* Protocol state. */
    UCHAR LastSeq;
    BOOLEAN HaveSeq;
    UCHAR LastKbd[9];
    /* Touchpad -> mouse. */
    BOOLEAN TpDown;
    LONG TpX, TpY, TpScroll;
    LONG TpTravel;
    LARGE_INTEGER TpDownAt;
    UCHAR TpFingers;
    UCHAR TpBtn;
    /* Diagnostics (\SystemRoot\nanosic-diag.txt when NanosicDiag=1). */
    ULONG Iter, IrqLow, Reads, ReadErr, Nak, Sync, Stale, Kbd, Cons, Mouse,
          Touch, Vendor, Queued, Dropped, InitErr, ReadIrps, Edges, Empty,
          SeqGap, Drain;
    ULONG IntCfg;
    /* Last KHIST keyboard records as [seq, mods, k1, k2] (diag). */
    UCHAR KHist[KHIST][4];
    ULONG KHistN;
    UCHAR Version[21];
    UCHAR Hall;
    UCHAR LastPkt[24];
} NANO_EXT, *PNANO_EXT;

static BOOLEAN gDiag = FALSE;

/* ======================= bit-banged I2C (open drain) ==================== */
static __forceinline VOID
Cfg(PNANO_EXT X, ULONG Off, BOOLEAN DriveLow)
{
    /* func 0 (gpio), 2 mA, pull-up; OE=1 drives the latched 0, OE=0 lets
     * the pull-ups take the line high. */
    WRITE_REGISTER_ULONG((PULONG)(X->I2c + Off), CFG_PULLUP | (DriveLow ? CFG_OE : 0u));
}

static __forceinline ULONG
Lvl(PNANO_EXT X, ULONG Off)
{
    return READ_REGISTER_ULONG((PULONG)(X->I2c + Off + 4)) & 1u;
}

#define HALF()  KeStallExecutionProcessor(3)

static VOID SdaLo(PNANO_EXT X) { Cfg(X, SDA_OFF, TRUE); }
static VOID SdaHi(PNANO_EXT X) { Cfg(X, SDA_OFF, FALSE); }
static VOID SclLo(PNANO_EXT X) { Cfg(X, SCL_OFF, TRUE); }

static BOOLEAN
SclHi(PNANO_EXT X)
{
    ULONG n;

    Cfg(X, SCL_OFF, FALSE);
    for (n = 0; n < 1000 && !Lvl(X, SCL_OFF); n++)   /* clock stretching */
        KeStallExecutionProcessor(1);
    return Lvl(X, SCL_OFF) != 0;
}

static VOID
I2cInitPins(PNANO_EXT X)
{
    /* Output latch 0 once; the line is then only ever driven low. */
    WRITE_REGISTER_ULONG((PULONG)(X->I2c + SDA_OFF + 4), 0);
    WRITE_REGISTER_ULONG((PULONG)(X->I2c + SCL_OFF + 4), 0);
    SdaHi(X);
    SclHi(X);
}

static VOID
I2cStart(PNANO_EXT X)
{
    SdaHi(X);
    SclHi(X);
    HALF();
    SdaLo(X);
    HALF();
    SclLo(X);
}

static VOID
I2cStop(PNANO_EXT X)
{
    SclLo(X);
    SdaLo(X);
    HALF();
    SclHi(X);
    HALF();
    SdaHi(X);
    HALF();
}

/* Free a slave that is holding SDA low mid-byte (e.g. after a reboot). */
static VOID
I2cRecover(PNANO_EXT X)
{
    ULONG i;

    SdaHi(X);
    for (i = 0; i < 9 && !Lvl(X, SDA_OFF); i++) {
        SclLo(X);
        HALF();
        SclHi(X);
        HALF();
    }
    I2cStart(X);
    I2cStop(X);
}

static BOOLEAN
I2cPut(PNANO_EXT X, UCHAR B)
{
    ULONG i;
    BOOLEAN ack;

    for (i = 0; i < 8; i++) {
        if (B & 0x80)
            SdaHi(X);
        else
            SdaLo(X);
        B <<= 1;
        HALF();
        SclHi(X);
        HALF();
        SclLo(X);
    }
    SdaHi(X);
    HALF();
    SclHi(X);
    ack = Lvl(X, SDA_OFF) == 0;
    HALF();
    SclLo(X);
    return ack;
}

static UCHAR
I2cGet(PNANO_EXT X, BOOLEAN Ack)
{
    ULONG i;
    UCHAR b = 0;

    SdaHi(X);
    for (i = 0; i < 8; i++) {
        HALF();
        SclHi(X);
        b = (UCHAR)((b << 1) | Lvl(X, SDA_OFF));
        HALF();
        SclLo(X);
    }
    if (Ack)
        SdaLo(X);
    HALF();
    SclHi(X);
    HALF();
    SclLo(X);
    SdaHi(X);
    return b;
}

static BOOLEAN
NanoRead(PNANO_EXT X, UCHAR *Buf)
{
    ULONG i;
    BOOLEAN ok;

    I2cStart(X);
    ok = I2cPut(X, NANO_ADDR << 1) && I2cPut(X, NANO_ADDR);
    if (ok) {
        I2cStart(X);                                 /* repeated start */
        ok = I2cPut(X, (NANO_ADDR << 1) | 1);
    }
    if (ok)
        for (i = 0; i < NANO_READ_LEN; i++)
            Buf[i] = I2cGet(X, i + 1 < NANO_READ_LEN);
    I2cStop(X);
    if (!ok)
        X->Nak++;
    return ok;
}

static BOOLEAN
NanoWrite(PNANO_EXT X, const UCHAR *Payload, ULONG Len)
{
    ULONG i;
    BOOLEAN ok;

    I2cStart(X);
    ok = I2cPut(X, NANO_ADDR << 1) && I2cPut(X, NANO_ADDR);
    for (i = 0; ok && i < NANO_WRITE_LEN; i++)
        ok = I2cPut(X, i < Len ? Payload[i] : 0);
    I2cStop(X);
    if (!ok)
        X->Nak++;
    return ok;
}

static VOID
SleepMs(ULONG Ms)
{
    LARGE_INTEGER t;

    t.QuadPart = -(LONGLONG)Ms * 10000;
    KeDelayExecutionThread(KernelMode, FALSE, &t);
}

static BOOLEAN
Cmd176x(PNANO_EXT X, UCHAR Op, UCHAR A, UCHAR B)
{
    UCHAR c[10] = { 0x32, 0x00, 0x4e, 0x31, 0x80, 0x38, Op, A, B, 0 };
    ULONG i, try;

    for (i = 2; i < 9; i++)
        c[9] = (UCHAR)(c[9] + c[i]);
    for (try = 0; try < 5; try++) {
        if (NanoWrite(X, c, sizeof(c)))
            return TRUE;
        SleepMs(100);
    }
    X->InitErr++;
    return FALSE;
}

/* ============================ report queue ============================== */
static VOID
Emit(PNANO_EXT X, const UCHAR *B, UCHAR Len)
{
    KIRQL irql;
    PIRP irp = NULL;

    KeAcquireSpinLock(&X->Lock, &irql);
    if (X->PendHead != X->PendTail) {
        irp = X->Pend[X->PendHead];
        X->Pend[X->PendHead] = NULL;
        X->PendHead = (X->PendHead + 1) % PEND_RING;
    } else if ((X->RingTail + 1) % RPT_RING != X->RingHead) {
        X->Ring[X->RingTail].Len = Len;
        RtlCopyMemory(X->Ring[X->RingTail].B, B, Len);
        X->RingTail = (X->RingTail + 1) % RPT_RING;
        X->Queued++;
    } else {
        X->Dropped++;
    }
    KeReleaseSpinLock(&X->Lock, irql);
    if (irp) {
        RtlCopyMemory(irp->UserBuffer, B, Len);
        irp->IoStatus.Information = Len;
        irp->IoStatus.Status = STATUS_SUCCESS;
        IoCompleteRequest(irp, IO_NO_INCREMENT);
    }
}

static VOID
EmitMouse(PNANO_EXT X, UCHAR Btn, LONG Dx, LONG Dy, LONG Wheel)
{
    UCHAR m[8];

    if (Dx > 32767) Dx = 32767;
    if (Dx < -32767) Dx = -32767;
    if (Dy > 32767) Dy = 32767;
    if (Dy < -32767) Dy = -32767;
    m[0] = T_MOUSE;
    m[1] = Btn;
    m[2] = (UCHAR)Dx; m[3] = (UCHAR)(Dx >> 8);
    m[4] = (UCHAR)Dy; m[5] = (UCHAR)(Dy >> 8);
    m[6] = (UCHAR)Wheel; m[7] = (UCHAR)(Wheel >> 8);
    Emit(X, m, sizeof(m));
}

/* ======================= packet -> HID reports =========================== */
/* Touchpad record: [19, buttons, 3 x (flags, id, x16, y16), count].
 * flags bit0 = tip. Logical 2560 x 1600. */
static VOID
Touchpad(PNANO_EXT X, const UCHAR *P)
{
    const UCHAR *f = P + 2;
    UCHAR tips = 0, btn = (UCHAR)(P[1] & 3u);
    LONG x, y, dx, dy, wheel = 0;
    LARGE_INTEGER now;
    ULONG i;

    for (i = 0; i < 3; i++)
        if (f[i * 6] & 1u)
            tips++;
    x = f[2] | (f[3] << 8);
    y = f[4] | (f[5] << 8);
    KeQuerySystemTimePrecise(&now);

    if (!(f[0] & 1u) || tips == 0) {
        /* Lift. A short, still, one-finger touch is a tap: left click. */
        if (X->TpDown && X->TpFingers == 1 && X->TpTravel < 40 &&
            now.QuadPart - X->TpDownAt.QuadPart < 2000000 && !btn) {
            EmitMouse(X, 1, 0, 0, 0);
            EmitMouse(X, 0, 0, 0, 0);
        } else if (btn != X->TpBtn) {
            EmitMouse(X, btn, 0, 0, 0);
        }
        X->TpDown = FALSE;
        X->TpBtn = btn;
        return;
    }
    if (!X->TpDown) {
        X->TpDown = TRUE;
        X->TpX = x;
        X->TpY = y;
        X->TpTravel = 0;
        X->TpScroll = 0;
        X->TpFingers = tips;
        X->TpDownAt = now;
        if (btn != X->TpBtn)
            EmitMouse(X, btn, 0, 0, 0);
        X->TpBtn = btn;
        return;
    }
    if (tips > X->TpFingers)
        X->TpFingers = tips;
    dx = x - X->TpX;
    dy = y - X->TpY;
    X->TpX = x;
    X->TpY = y;
    X->TpTravel += (dx < 0 ? -dx : dx) + (dy < 0 ? -dy : dy);
    if (tips >= 2) {
        /* Two-finger scroll: fingers down -> content down (wheel up). */
        X->TpScroll += dy;
        wheel = X->TpScroll / 48;
        X->TpScroll -= wheel * 48;
        dx = dy = 0;
    }
    if (dx || dy || wheel || btn != X->TpBtn)
        EmitMouse(X, btn, dx, dy, wheel);
    X->TpBtn = btn;
}

static VOID
Vendor(PNANO_EXT X, const UCHAR *P, ULONG Len)
{
    X->Vendor++;
    if (Len < 5)
        return;
    /* p[2] source, p[3] object, p[4] command. 803x version: 0x18->0x80. */
    if (P[4] == 0x01 && P[2] == 0x18 && P[3] == 0x80 && Len >= 26)
        RtlCopyMemory(X->Version, P + 6, 20);
    /* 176x hall: 0x38->0x80 cmd 0xA2, p[9] bit0 docked, bit1 powered. */
    if (P[4] == 0xA2 && P[2] == 0x38 && P[3] == 0x80 && Len >= 10)
        X->Hall = (UCHAR)(0x80 | P[9]);
}

static ULONG
RecLen(UCHAR T)
{
    switch (T) {
    case T_KBD:   return 9;
    case T_CONS:  return 5;
    case T_MOUSE: return 8;
    case T_TOUCH: return 21;
    case T_V16:   return 16;
    case T_V32:   return 32;
    default:      return 0;
    }
}

static VOID
Parse(PNANO_EXT X, const UCHAR *D, BOOLEAN HostCmd)
{
    const UCHAR *p = D + 3;
    ULONG left, n, i;
    UCHAR len = D[2];

    if (D[0] != NANO_SYNC)
        return;
    X->Sync++;
    if (!len)
        return;
    if (len != 0x39 && len != 0x4a && len != 0x5b && len != 0x6c)
        return;
    if (!HostCmd) {
        /*
         * Only an exact replay (re-reading the same MCU buffer) is stale.
         * The MCU numbers every packet, keepalives included, so the counter
         * can jump forward by any amount between two reads. The old
         * "(CHAR)(seq - last) <= 0" test called every jump of more than 127
         * stale and then dropped every packet after it -- key-ups and
         * modifier changes included -- until the counter wrapped: keys
         * auto-repeated and Win/Ctrl/Alt chords broke.
         */
        if (X->HaveSeq && D[1] == X->LastSeq) {
            X->Stale++;
            return;
        }
        if (X->HaveSeq && (UCHAR)(D[1] - X->LastSeq) != 1)
            X->SeqGap++;
        X->LastSeq = D[1];
        X->HaveSeq = TRUE;
    }
    left = len - 3u;
    if (left > NANO_READ_LEN - 3u)
        left = NANO_READ_LEN - 3u;
    while (left) {
        UCHAR t = p[0];

        if (t == T_V24 || t == T_V26) {
            Vendor(X, p, left);
            return;
        }
        n = RecLen(t);
        if (!n || n > left)
            return;                         /* unknown type ends the walk */
        if (t == T_V16 || t == T_V32) {
            Vendor(X, p, n);
        } else if (!HostCmd) {
            switch (t) {
            case T_KBD: {
                UCHAR *h = X->KHist[X->KHistN++ % KHIST];

                h[0] = D[1]; h[1] = p[1]; h[2] = p[3]; h[3] = p[4];
                /* All six slots 0x01 = ErrorRollOver: keep current keys. */
                for (i = 3; i < 9 && p[i] == 0x01; i++)
                    ;
                if (i == 9)
                    break;
                /* The record is the whole keyboard state (boot protocol), so
                 * forwarding the newest one always resyncs Windows. Byte 2
                 * is reserved; do not let it hide a change or fake one. */
                if (p[1] == X->LastKbd[1] &&
                    RtlCompareMemory(p + 3, X->LastKbd + 3, 6) == 6)
                    break;
                RtlCopyMemory(X->LastKbd, p, 9);
                X->LastKbd[2] = 0;
                X->Kbd++;
                {
                    UCHAR k[9];

                    RtlCopyMemory(k, p, 9);
                    k[2] = 0;
                    Emit(X, k, 9);
                }
                if (!p[1] && !p[3])
                    X->Empty++;
                break;
            }
            case T_CONS: {
                UCHAR c[3] = { T_CONS, p[1], p[2] };   /* 16-bit usage */
                X->Cons++;
                Emit(X, c, 3);
                break;
            }
            case T_MOUSE:
                X->Mouse++;
                Emit(X, p, 8);
                break;
            case T_TOUCH:
                X->Touch++;
                Touchpad(X, p);
                break;
            }
        }
        /* A 0x39 envelope carries one record; the rest is padding. */
        if (len == 0x39)
            return;
        p += n;
        left -= n;
    }
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
AppX(char **p, char *e, UCHAR b)
{
    static const char h[] = "0123456789ABCDEF";

    if (*p + 3 <= e) { *(*p)++ = h[b >> 4]; *(*p)++ = h[b & 15]; *(*p)++ = ' '; }
}

static VOID
WriteDiag(PNANO_EXT X)
{
    static const struct { const char *N; SIZE_T O; } f[] = {
        { " iter=", FIELD_OFFSET(NANO_EXT, Iter) },
        { " irqlow=", FIELD_OFFSET(NANO_EXT, IrqLow) },
        { " reads=", FIELD_OFFSET(NANO_EXT, Reads) },
        { " nak=", FIELD_OFFSET(NANO_EXT, Nak) },
        { " sync=", FIELD_OFFSET(NANO_EXT, Sync) },
        { " stale=", FIELD_OFFSET(NANO_EXT, Stale) },
        { " kbd=", FIELD_OFFSET(NANO_EXT, Kbd) },
        { " cons=", FIELD_OFFSET(NANO_EXT, Cons) },
        { " mouse=", FIELD_OFFSET(NANO_EXT, Mouse) },
        { " touch=", FIELD_OFFSET(NANO_EXT, Touch) },
        { " vendor=", FIELD_OFFSET(NANO_EXT, Vendor) },
        { " queued=", FIELD_OFFSET(NANO_EXT, Queued) },
        { " dropped=", FIELD_OFFSET(NANO_EXT, Dropped) },
        { " initerr=", FIELD_OFFSET(NANO_EXT, InitErr) },
        { " readirp=", FIELD_OFFSET(NANO_EXT, ReadIrps) },
        { " edges=", FIELD_OFFSET(NANO_EXT, Edges) },
        { " drain=", FIELD_OFFSET(NANO_EXT, Drain) },
        { " seqgap=", FIELD_OFFSET(NANO_EXT, SeqGap) },
        { " kbdempty=", FIELD_OFFSET(NANO_EXT, Empty) },
        { " intcfg=", FIELD_OFFSET(NANO_EXT, IntCfg) },
    };
    UNICODE_STRING name;
    OBJECT_ATTRIBUTES oa;
    IO_STATUS_BLOCK iosb;
    HANDLE h;
    char buf[1024], *p = buf, *e = buf + sizeof(buf);
    ULONG i, j, n;

    AppS(&p, e, "nanosic diag v2\n");
    for (i = 0; i < ARRAYSIZE(f); i++) {
        AppS(&p, e, f[i].N);
        AppU(&p, e, *(PULONG)((PUCHAR)X + f[i].O));
    }
    AppS(&p, e, "\n version=");
    for (i = 0; i < 20 && X->Version[i]; i++)
        if (p < e) *p++ = (X->Version[i] >= 0x20 && X->Version[i] < 0x7f) ? (char)X->Version[i] : '.';
    AppS(&p, e, " hall=");
    AppX(&p, e, X->Hall);
    AppS(&p, e, "\n last=");
    for (i = 0; i < sizeof(X->LastPkt); i++)
        AppX(&p, e, X->LastPkt[i]);
    /* Keyboard records, oldest first: seq mods k1 k2 | ... */
    AppS(&p, e, "\n khist=");
    n = X->KHistN < KHIST ? X->KHistN : KHIST;
    for (i = 0; i < n; i++) {
        const UCHAR *h = X->KHist[(X->KHistN - n + i) % KHIST];

        for (j = 0; j < 4; j++)
            AppX(&p, e, h[j]);
        AppS(&p, e, "| ");
    }
    AppS(&p, e, "\n");

    RtlInitUnicodeString(&name, L"\\SystemRoot\\nanosic-diag.txt");
    InitializeObjectAttributes(&oa, &name, OBJ_KERNEL_HANDLE | OBJ_CASE_INSENSITIVE, NULL, NULL);
    if (NT_SUCCESS(ZwCreateFile(&h, GENERIC_WRITE | SYNCHRONIZE, &oa, &iosb, NULL,
                                FILE_ATTRIBUTE_NORMAL, 0, FILE_OVERWRITE_IF,
                                FILE_SYNCHRONOUS_IO_NONALERT | FILE_NON_DIRECTORY_FILE,
                                NULL, 0))) {
        ZwWriteFile(h, NULL, NULL, NULL, &iosb, buf, (ULONG)(p - buf), NULL, NULL);
        ZwClose(h);
    }
}

/* ============================== poll thread ============================== */
static VOID
InitMcu(PNANO_EXT X)
{
    static const UCHAR ver[9] = { 0x32, 0x00, 0x4f, 0x30, 0x80, 0x18, 0x01, 0x00, 0x18 };
    UCHAR rsp[NANO_READ_LEN];

    I2cInitPins(X);
    I2cRecover(X);
    /* nanosic_init_mcu: enable 0x26, enable 0x23, screen on, version, hall. */
    Cmd176x(X, 0x26, 0x01, 0x00);
    Cmd176x(X, 0x23, 0x01, 0x00);
    Cmd176x(X, 0x25, 0x01, 0x01);
    if (NanoWrite(X, ver, sizeof(ver))) {
        SleepMs(2);
        if (NanoRead(X, rsp))
            Parse(X, rsp, TRUE);
    }
    if (Cmd176x(X, 0x52, 0x00, 0x00)) {
        SleepMs(20);
        if (NanoRead(X, rsp))
            Parse(X, rsp, TRUE);
    }
}

/* GPIO83 falling edge since the last call? Reads and clears the TLMM latch. */
static BOOLEAN
EdgeLatched(PNANO_EXT X)
{
    if (!(READ_REGISTER_ULONG((PULONG)(X->Irq + INTR_STATUS)) & 1u))
        return FALSE;
    WRITE_REGISTER_ULONG((PULONG)(X->Irq + INTR_STATUS), 0);
    X->Edges++;
    return TRUE;
}

static BOOLEAN
LineLow(PNANO_EXT X)
{
    return (READ_REGISTER_ULONG((PULONG)(X->Irq + 4)) & 1u) == 0;
}

static BOOLEAN
KeyHeld(PNANO_EXT X)
{
    return X->LastKbd[1] != 0 || X->LastKbd[3] != 0;
}

static VOID
ReadOne(PNANO_EXT X)
{
    UCHAR buf[NANO_READ_LEN];

    X->Reads++;
    RtlZeroMemory(buf, sizeof(buf));
    if (NanoRead(X, buf)) {
        RtlCopyMemory(X->LastPkt, buf, sizeof(X->LastPkt));
        Parse(X, buf, FALSE);
    } else {
        X->ReadErr++;
        I2cRecover(X);
    }
}

static VOID
ThreadMain(PVOID Ctx)
{
    PNANO_EXT X = Ctx;
    LARGE_INTEGER wait;
    ULONG idle = 0, n;
    ULONG cfg;

    ExSetTimerResolution(10000, TRUE);
    /* GPIO83: gpio, input, no pull (DT bias-disable); low = packet ready. */
    WRITE_REGISTER_ULONG((PULONG)X->Irq, 0);
    /*
     * The MCU signals each packet with a falling edge on GPIO83 (Linux:
     * IRQ_TYPE_EDGE_FALLING). Sampling the level every few ms misses short
     * pulses, and a missed key-up packet leaves the key down in Windows,
     * which then auto-repeats it. Let the TLMM latch the edge instead:
     * falling-edge detection with RAW_STATUS on and the GIC enable off, so
     * INTR_STATUS records every edge and nothing is delivered to Windows.
     */
    cfg = READ_REGISTER_ULONG((PULONG)(X->Irq + INTR_CFG));
    cfg &= ~(INTR_EN | INTR_DET_MASK | INTR_POL);
    cfg |= INTR_RAW | INTR_DET_EDGE | INTR_POL;
    WRITE_REGISTER_ULONG((PULONG)(X->Irq + INTR_CFG), cfg);
    X->IntCfg = READ_REGISTER_ULONG((PULONG)(X->Irq + INTR_CFG));
    WRITE_REGISTER_ULONG((PULONG)(X->Irq + INTR_STATUS), 0);

    InitMcu(X);
    EdgeLatched(X);                   /* edges from the init replies */
    if (gDiag)
        WriteDiag(X);

    wait.QuadPart = -1 * 10000;       /* 1 ms */
    while (KeWaitForSingleObject(&X->Stop, Executive, KernelMode, FALSE, &wait) == STATUS_TIMEOUT) {
        X->Iter++;
        if (InterlockedExchange(&X->LedPending, 0))
            Cmd176x(X, 0x26, 0x01, (X->LedWant & 2u) ? 1 : 0);   /* Caps Lock */
        if (LineLow(X))
            X->IrqLow++;
        if (EdgeLatched(X) || LineLow(X)) {
            /* Read; if another edge came in meanwhile or the line is still
             * low, the MCU has the next packet ready: drain it now. */
            ReadOne(X);
            for (n = 1; n < DRAIN_MAX && (EdgeLatched(X) || LineLow(X)); n++) {
                X->Drain++;
                ReadOne(X);
            }
            idle = 0;
        } else if (++idle >= (KeyHeld(X) ? 25u : 200u)) {
            /*
             * Safety read: every 25 ms while a key or modifier is down,
             * every 200 ms otherwise. An exact replay is dropped by Parse;
             * a newer packet (the lost key-up) resyncs the keyboard state.
             */
            ReadOne(X);
            idle = 0;
        }
        if (gDiag && (X->Iter & 2047) == 0)
            WriteDiag(X);
    }
    ExSetTimerResolution(0, FALSE);
    PsTerminateSystemThread(STATUS_SUCCESS);
}

/* ============================== HID plumbing ============================= */
static NTSTATUS
StartDevice(PNANO_EXT X)
{
    PHYSICAL_ADDRESS pa;
    OBJECT_ATTRIBUTES oa;
    NTSTATUS st;

    if (X->Run)
        return STATUS_SUCCESS;
    pa.QuadPart = I2C_PHYS;
    X->I2c = MmMapIoSpaceEx(pa, I2C_SIZE, PAGE_READWRITE | PAGE_NOCACHE);
    pa.QuadPart = IRQ_PHYS;
    X->Irq = MmMapIoSpaceEx(pa, IRQ_SIZE, PAGE_READWRITE | PAGE_NOCACHE);
    if (!X->I2c || !X->Irq) {
        if (X->I2c) MmUnmapIoSpace(X->I2c, I2C_SIZE);
        if (X->Irq) MmUnmapIoSpace(X->Irq, IRQ_SIZE);
        X->I2c = X->Irq = NULL;
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    KeInitializeEvent(&X->Stop, NotificationEvent, FALSE);
    InitializeObjectAttributes(&oa, NULL, OBJ_KERNEL_HANDLE, NULL, NULL);
    st = PsCreateSystemThread(&X->ThreadHandle, THREAD_ALL_ACCESS, &oa, NULL, NULL,
                              ThreadMain, X);
    if (!NT_SUCCESS(st))
        return st;
    st = ObReferenceObjectByHandle(X->ThreadHandle, THREAD_ALL_ACCESS, *PsThreadType,
                                   KernelMode, (PVOID *)&X->Thread, NULL);
    X->Run = TRUE;
    return st;
}

static VOID
StopDevice(PNANO_EXT X)
{
    KIRQL irql;
    PIRP irp;

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
    for (;;) {
        KeAcquireSpinLock(&X->Lock, &irql);
        if (X->PendHead == X->PendTail) {
            X->RingHead = X->RingTail = 0;
            KeReleaseSpinLock(&X->Lock, irql);
            break;
        }
        irp = X->Pend[X->PendHead];
        X->Pend[X->PendHead] = NULL;
        X->PendHead = (X->PendHead + 1) % PEND_RING;
        KeReleaseSpinLock(&X->Lock, irql);
        irp->IoStatus.Status = STATUS_DEVICE_REMOVED;
        irp->IoStatus.Information = 0;
        IoCompleteRequest(irp, IO_NO_INCREMENT);
    }
    if (X->I2c) MmUnmapIoSpace(X->I2c, I2C_SIZE);
    if (X->Irq) MmUnmapIoSpace(X->Irq, IRQ_SIZE);
    X->I2c = X->Irq = NULL;
}

static PNANO_EXT
ExtOf(PDEVICE_OBJECT Fdo)
{
    return (PNANO_EXT)((PHID_DEVICE_EXTENSION)Fdo->DeviceExtension)->MiniDeviceExtension;
}

static PDEVICE_OBJECT
LowerOf(PDEVICE_OBJECT Fdo)
{
    return ((PHID_DEVICE_EXTENSION)Fdo->DeviceExtension)->NextDeviceObject;
}

static NTSTATUS
AddDevice(_In_ PDRIVER_OBJECT Drv, _In_ PDEVICE_OBJECT Fdo)
{
    PNANO_EXT X = ExtOf(Fdo);

    UNREFERENCED_PARAMETER(Drv);
    RtlZeroMemory(X, sizeof(*X));
    X->Fdo = Fdo;
    KeInitializeSpinLock(&X->Lock);
    Fdo->Flags &= ~DO_DEVICE_INITIALIZING;
    return STATUS_SUCCESS;
}

/* HID minidriver PnP contract: every PnP IRP goes down to the ACPI PDO;
 * START is forwarded first and the hardware started on the way back up. */
static NTSTATUS
PnpDispatch(_In_ PDEVICE_OBJECT Fdo, _In_ PIRP Irp)
{
    PNANO_EXT X = ExtOf(Fdo);
    NTSTATUS st;

    switch (IoGetCurrentIrpStackLocation(Irp)->MinorFunction) {
    case IRP_MN_START_DEVICE:
        st = IoForwardIrpSynchronously(LowerOf(Fdo), Irp) ? Irp->IoStatus.Status
                                                           : STATUS_UNSUCCESSFUL;
        if (NT_SUCCESS(st))
            st = StartDevice(X);
        Irp->IoStatus.Status = st;
        IoCompleteRequest(Irp, IO_NO_INCREMENT);
        return st;
    case IRP_MN_STOP_DEVICE:
    case IRP_MN_REMOVE_DEVICE:
    case IRP_MN_SURPRISE_REMOVAL:
        StopDevice(X);
        break;
    default:
        break;
    }
    IoSkipCurrentIrpStackLocation(Irp);
    return IoCallDriver(LowerOf(Fdo), Irp);
}

static NTSTATUS
PowerDispatch(_In_ PDEVICE_OBJECT Fdo, _In_ PIRP Irp)
{
    PoStartNextPowerIrp(Irp);
    IoSkipCurrentIrpStackLocation(Irp);
    return PoCallDriver(LowerOf(Fdo), Irp);
}

static NTSTATUS
InternalIoctl(_In_ PDEVICE_OBJECT Fdo, _In_ PIRP Irp)
{
    PNANO_EXT X = ExtOf(Fdo);
    PIO_STACK_LOCATION sp = IoGetCurrentIrpStackLocation(Irp);
    ULONG outLen = sp->Parameters.DeviceIoControl.OutputBufferLength;
    PVOID buf = Irp->UserBuffer;
    NTSTATUS st = STATUS_SUCCESS;
    ULONG len = 0;
    KIRQL irql;

    switch (sp->Parameters.DeviceIoControl.IoControlCode) {
    case IOCTL_HID_GET_DEVICE_DESCRIPTOR:
        if (!buf || outLen < sizeof(gHidDesc)) { st = STATUS_BUFFER_TOO_SMALL; break; }
        RtlCopyMemory(buf, &gHidDesc, sizeof(gHidDesc));
        len = sizeof(gHidDesc);
        break;
    case IOCTL_HID_GET_REPORT_DESCRIPTOR:
        if (!buf || outLen < sizeof(gReportDesc)) { st = STATUS_BUFFER_TOO_SMALL; break; }
        RtlCopyMemory(buf, gReportDesc, sizeof(gReportDesc));
        len = sizeof(gReportDesc);
        break;
    case IOCTL_HID_GET_DEVICE_ATTRIBUTES: {
        PHID_DEVICE_ATTRIBUTES a = buf;

        if (!a || outLen < sizeof(*a)) { st = STATUS_BUFFER_TOO_SMALL; break; }
        RtlZeroMemory(a, sizeof(*a));
        a->Size = sizeof(*a);
        a->VendorID = 0x15D9;
        a->ProductID = 0x00A3;
        a->VersionNumber = 1;
        len = sizeof(*a);
        break;
    }
    case IOCTL_HID_READ_REPORT:
        if (!buf || outLen < RPT_MAX) { st = STATUS_BUFFER_TOO_SMALL; break; }
        KeAcquireSpinLock(&X->Lock, &irql);
        X->ReadIrps++;
        if (X->RingHead != X->RingTail) {          /* a report is waiting */
            RPT *r = &X->Ring[X->RingHead];

            RtlCopyMemory(buf, r->B, r->Len);
            len = r->Len;
            X->RingHead = (X->RingHead + 1) % RPT_RING;
            KeReleaseSpinLock(&X->Lock, irql);
            break;
        }
        if ((X->PendTail + 1) % PEND_RING == X->PendHead) {
            KeReleaseSpinLock(&X->Lock, irql);
            st = STATUS_DEVICE_BUSY;
            break;
        }
        IoMarkIrpPending(Irp);
        X->Pend[X->PendTail] = Irp;
        X->PendTail = (X->PendTail + 1) % PEND_RING;
        KeReleaseSpinLock(&X->Lock, irql);
        return STATUS_PENDING;
    case IOCTL_HID_WRITE_REPORT:
    case IOCTL_HID_SET_OUTPUT_REPORT: {
        /* Keyboard LED output report: [5, leds]; bit1 = Caps Lock. */
        PHID_XFER_PACKET pk = buf;

        if (pk && pk->reportBuffer && pk->reportBufferLen >= 2 &&
            pk->reportBuffer[0] == T_KBD) {
            X->LedWant = pk->reportBuffer[1];
            InterlockedExchange(&X->LedPending, 1);
        } else if (pk && pk->reportBuffer && pk->reportBufferLen == 1 && pk->reportId == T_KBD) {
            X->LedWant = pk->reportBuffer[0];
            InterlockedExchange(&X->LedPending, 1);
        }
        break;
    }
    case IOCTL_HID_ACTIVATE_DEVICE:
        st = StartDevice(X);
        break;
    case IOCTL_HID_DEACTIVATE_DEVICE:
        StopDevice(X);
        break;
    default:
        st = STATUS_NOT_SUPPORTED;
        break;
    }
    Irp->IoStatus.Status = st;
    Irp->IoStatus.Information = len;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return st;
}

static VOID
ReadDiagFlag(PUNICODE_STRING RegistryPath)
{
    OBJECT_ATTRIBUTES oa;
    UNICODE_STRING v;
    HANDLE key;
    UCHAR b[sizeof(KEY_VALUE_PARTIAL_INFORMATION) + sizeof(ULONG)];
    PKEY_VALUE_PARTIAL_INFORMATION info = (PKEY_VALUE_PARTIAL_INFORMATION)b;
    ULONG got;

    InitializeObjectAttributes(&oa, RegistryPath, OBJ_KERNEL_HANDLE | OBJ_CASE_INSENSITIVE,
                               NULL, NULL);
    if (!NT_SUCCESS(ZwOpenKey(&key, KEY_READ, &oa)))
        return;
    RtlInitUnicodeString(&v, L"NanosicDiag");
    if (NT_SUCCESS(ZwQueryValueKey(key, &v, KeyValuePartialInformation, info, sizeof(b), &got)) &&
        info->Type == REG_DWORD && info->DataLength >= sizeof(ULONG) && *(PULONG)info->Data)
        gDiag = TRUE;
    ZwClose(key);
}

static VOID
Unload(_In_ PDRIVER_OBJECT Drv)
{
    UNREFERENCED_PARAMETER(Drv);
}

NTSTATUS
DriverEntry(_In_ PDRIVER_OBJECT Drv, _In_ PUNICODE_STRING RegistryPath)
{
    HID_MINIDRIVER_REGISTRATION reg;

    ReadDiagFlag(RegistryPath);
    Drv->MajorFunction[IRP_MJ_INTERNAL_DEVICE_CONTROL] = InternalIoctl;
    Drv->MajorFunction[IRP_MJ_PNP] = PnpDispatch;
    Drv->MajorFunction[IRP_MJ_POWER] = PowerDispatch;
    Drv->DriverUnload = Unload;
    Drv->DriverExtension->AddDevice = AddDevice;

    RtlZeroMemory(&reg, sizeof(reg));
    reg.Revision = HID_REVISION;
    reg.DriverObject = Drv;
    reg.RegistryPath = RegistryPath;
    reg.DeviceExtensionSize = sizeof(NANO_EXT);
    reg.DevicesArePolled = FALSE;
    return HidRegisterMinidriver(&reg);
}
