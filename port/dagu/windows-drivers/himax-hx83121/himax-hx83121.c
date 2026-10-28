/* SPDX-License-Identifier: MIT
 * Himax HX83121 on dagu, GENI SPI FIFO, no Qualcomm PEP and no GPI DMA.
 *
 * The UEFI driver DaguQupDxe has already turned the QUP clocks on, loaded the
 * SPI firmware into SE4 and muxed gpio8-11 / gpio39. This minidriver only
 * runs the same FIFO transfer the Linux himax-dagu driver uses:
 *   mode 3, 8-bit, 4 MHz, read command [0xF3, 0x30, 0x00] + 56 byte payload.
 * GPIO100 is the panel reset. Do not touch it.
 */
#include <ntddk.h>
#include <hidport.h>

#ifndef IOCTL_HID_GET_FEATURE
#define IOCTL_HID_GET_FEATURE HID_CTL_CODE(11)
#define IOCTL_HID_SET_FEATURE HID_CTL_CODE(12)
#endif

#define SE4_PHYS            0x00990000ULL
#define SE4_SIZE            0x4000u
#define IRQ_PHYS            0x0F527000ULL
#define IRQ_SIZE            0x1000u
#define IRQ_OFF             4u

/*
 * The GENI SE4 engine never clocks this in-cell Himax correctly (it returns
 * all-0xFF); the production Linux drives it as a bit-banged "spi-gpio" on the
 * CAF pins, and so do we. TLMM NORTH tile, gpio g register block at
 * 0x0F900000 + g*0x1000 (cfg at +0, bit1=OUT / bit0=IN at +4). gpio8=MISO,
 * gpio9=MOSI, gpio10=SCK, gpio11=CS(active low). Mode 3: SCK idles high, MOSI
 * shifted on the falling edge, MISO sampled on the rising edge, MSB first.
 */
#define GP_PHYS             0x0F908000ULL   /* gpio8 cfg base (NORTH) */
#define GP_SIZE             0x4000u         /* covers gpio8..11 */
#define BB_MISO             8u
#define BB_MOSI             9u
#define BB_SCK              10u
#define BB_CS               11u
#define GP_CFG(g)           (((g) - 8u) * 0x1000u)
#define GP_IO(g)            (((g) - 8u) * 0x1000u + 4u)

#define SE_GENI_M_CMD0          0x600
#define SE_GENI_M_CMD_CTRL      0x604
#define SE_GENI_M_IRQ_STATUS    0x610
#define SE_GENI_M_IRQ_CLEAR     0x618
#define SE_GENI_TX_FIFO         0x700
#define SE_GENI_RX_FIFO         0x780
#define SE_GENI_TX_FIFO_STATUS  0x800
#define SE_GENI_RX_FIFO_STATUS  0x804
#define SE_GENI_TX_WATERMARK    0x80c
#define GENI_SER_M_CLK_CFG      0x48
#define SE_GENI_CLK_SEL         0x7c
#define SE_GENI_BYTE_GRAN       0x254
#define SE_SPI_CPHA             0x224
#define SE_SPI_LOOPBACK         0x22c
#define SE_SPI_CPOL             0x230
#define SE_SPI_DEMUX_INV        0x24c
#define SE_SPI_DEMUX_SEL        0x250
#define SE_SPI_TRANS_CFG        0x25c
#define SE_TX_PACK0             0x260
#define SE_TX_PACK1             0x264
#define SE_RX_PACK0             0x284
#define SE_RX_PACK1             0x288
#define SE_SPI_WORD_LEN         0x268
#define SE_SPI_TX_LEN           0x26c
#define SE_SPI_RX_LEN           0x270
#define SE_HW_PARAM_0           0xe24
#define QUP_VER                 0x009C0004ULL

#define HIMAX_FINGERS   10
#define HIMAX_PAYLOAD   56
#define HIMAX_XFER      59
#define HIMAX_COUNT_AT  52

/*
 * Parallel-mode Windows touch screen, 10 contacts, logical 1600 x 2560.
 * Microsoft's touchscreen HID spec requires X and Y to declare Physical
 * Min/Max, Unit and Unit Exponent; without them Windows reads the reports
 * but will not treat the device as a functional touchscreen. The ~12.4"
 * 1600x2560 panel is about 6.57" x 10.51", i.e. 657 x 1051 in 0.01" units
 * (same 0.625 aspect ratio as the logical range).
 */
#define HIMAX_FINGER_TLC \
    0x05, 0x0D, 0x09, 0x22, 0xA1, 0x02, \
    0x09, 0x42, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x01, 0x81, 0x02, \
    0x95, 0x07, 0x81, 0x03, \
    0x09, 0x51, 0x25, 0x09, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02, \
    0x05, 0x01, 0x55, 0x0E, 0x65, 0x13, 0x35, 0x00, 0x75, 0x10, 0x95, 0x01, \
    0x26, 0x40, 0x06, 0x46, 0x91, 0x02, 0x09, 0x30, 0x81, 0x02, \
    0x26, 0x00, 0x0A, 0x46, 0x1B, 0x04, 0x09, 0x31, 0x81, 0x02, \
    0xC0

static const UCHAR gReportDesc[] = {
    0x05, 0x0D, 0x09, 0x04, 0xA1, 0x01, 0x85, 0x01,
    HIMAX_FINGER_TLC, HIMAX_FINGER_TLC, HIMAX_FINGER_TLC, HIMAX_FINGER_TLC,
    HIMAX_FINGER_TLC, HIMAX_FINGER_TLC, HIMAX_FINGER_TLC, HIMAX_FINGER_TLC,
    HIMAX_FINGER_TLC, HIMAX_FINGER_TLC,
    0x05, 0x0D, 0x09, 0x54, 0x15, 0x00, 0x25, 0x0A, 0x75, 0x08, 0x95, 0x01,
    0x81, 0x02,
    /*
     * The Contact Count Maximum feature report MUST use its own report ID,
     * distinct from the input report's ID 1. Sharing the input report ID
     * makes both the Linux hid-multitouch driver and the Windows HID touch
     * stack refuse to instantiate a touchscreen device (verified via uhid):
     * HIDCLASS loads and reads reports but never creates the top-level
     * collection child. Give the feature report ID 2.
     */
    0x85, 0x02,
    0x09, 0x55, 0x25, 0x0A, 0xB1, 0x02,
    0xC0
};

#pragma pack(push, 1)
typedef struct _HIMAX_CONTACT {
    UCHAR Tip;
    UCHAR Id;
    USHORT X;
    USHORT Y;
} HIMAX_CONTACT;

typedef struct _HIMAX_REPORT {
    UCHAR Id;
    HIMAX_CONTACT C[HIMAX_FINGERS];
    UCHAR Count;
} HIMAX_REPORT, *PHIMAX_REPORT;
#pragma pack(pop)

typedef struct _HIMAX_EXT {
    PDEVICE_OBJECT Fdo;
    PUCHAR Se;
    PUCHAR Irq;
    PUCHAR Gp;
    PVOID SeMap;
    PVOID IrqMap;
    PVOID GpMap;
    HANDLE ThreadHandle;
    PKTHREAD Thread;
    KEVENT Stop;
    KSPIN_LOCK Lock;
    PIRP Pending;
    BOOLEAN Down;
    BOOLEAN Run;
    ULONG Depth;
    ULONG ClkDiv;
    /* Diagnostics, dumped to \SystemRoot\himax-diag.txt by the poll thread. */
    ULONG StartFlags;
    ULONG DiagIter;
    ULONG DiagIrqLow;
    ULONG DiagSpiOk;
    ULONG DiagEvtOk;
    ULONG DiagReadIrp;
    ULONG DiagComplete;
    ULONG DiagActive;
    ULONG DiagTouch;
    ULONG DiagFeature;
    ULONG PnpLogN;
    UCHAR PnpLog[40];
    ULONG QdrBusSeen;
    ULONG QdrInStatus;
    ULONG QdrInInfo;
    ULONG LowerStart;
    ULONG PowerIrps;
    USHORT LastRawX;
    USHORT LastRawY;
    UCHAR LastTN;
    USHORT TouchX;
    USHORT TouchY;
    USHORT MinX;
    USHORT MaxX;
    USHORT MinY;
    USHORT MaxY;
    UCHAR LastPayload[HIMAX_PAYLOAD];
    UCHAR TouchPayload[HIMAX_PAYLOAD];
} HIMAX_EXT, *PHIMAX_EXT;

static const HID_DESCRIPTOR gHidDesc = {
    0x09, 0x21, 0x0111, 0x00, 0x01,
    { { 0x22, sizeof(gReportDesc) } }
};

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

static ULONG
FifoDepth(PUCHAR Se)
{
    PHYSICAL_ADDRESS verPa;
    PVOID map;
    ULONG ver, major, minor, mask, depth;

    verPa.QuadPart = QUP_VER;
    map = MmMapIoSpaceEx(verPa, 4, PAGE_READWRITE | PAGE_NOCACHE);
    ver = 0;
    if (map) {
        ver = READ_REGISTER_ULONG((PULONG)map);
        MmUnmapIoSpace(map, 4);
    }
    major = (ver >> 28) & 0xF;
    minor = (ver >> 16) & 0xFFF;
    mask = ((major == 3 && minor >= 10) || major > 3) ? (0xFFu << 16) : (0x3Fu << 16);
    depth = (Rd(Se, SE_HW_PARAM_0) & mask) >> 16;
    if (depth < 4 || depth > 64)
        depth = 16;
    return depth;
}

static VOID
Pack(PUCHAR Se)
{
    ULONG cfg[4], i, idx, c0, c1;

    idx = 7;
    for (i = 0; i < 4; i++) {
        cfg[i] = (idx << 5) | (1u << 4) | (7u << 1);
        idx = ((i + 1) * 8) + 7;
    }
    cfg[3] |= 1u;
    c0 = cfg[0] | (cfg[1] << 10);
    c1 = cfg[2] | (cfg[3] << 10);
    Wr(Se, SE_TX_PACK0, c0);
    Wr(Se, SE_TX_PACK1, c1);
    Wr(Se, SE_RX_PACK0, c0);
    Wr(Se, SE_RX_PACK1, c1);
    Wr(Se, SE_GENI_BYTE_GRAN, 0);
}

static VOID
BbCfg(PHIMAX_EXT Ext, ULONG Gpio, ULONG Out, ULONG Pull)
{
    WRITE_REGISTER_ULONG((PULONG)(Ext->Gp + GP_CFG(Gpio)),
                         Pull | (0u << 2) | (0u << 6) | (Out ? (1u << 9) : 0u));
}

static VOID
BbSet(PHIMAX_EXT Ext, ULONG Gpio, ULONG Level)
{
    WRITE_REGISTER_ULONG((PULONG)(Ext->Gp + GP_IO(Gpio)), Level ? 2u : 0u);
}

static ULONG
BbGet(PHIMAX_EXT Ext, ULONG Gpio)
{
    return READ_REGISTER_ULONG((PULONG)(Ext->Gp + GP_IO(Gpio))) & 1u;
}

/*
 * Bit-banged SPI mode 3 on gpio8-11, mirroring the Linux "spi-gpio" node and
 * the proven DaguQupDxe UEFI probe. MSB first, CS active low. Full duplex:
 * send [0xF3,0x30,0x00] + zeros, keep the 56-byte payload after the 3-byte
 * header.
 */
static BOOLEAN
SpiRead(PHIMAX_EXT Ext, UCHAR *Payload)
{
    UCHAR tx[HIMAX_XFER];
    UCHAR rx[HIMAX_XFER];
    ULONG i, b, out, in;

    if (!Ext->Gp)
        return FALSE;
    RtlZeroMemory(tx, sizeof(tx));
    RtlZeroMemory(rx, sizeof(rx));
    tx[0] = 0xF3;
    tx[1] = 0x30;

    BbCfg(Ext, BB_MOSI, 1, 0);
    BbCfg(Ext, BB_SCK, 1, 0);
    BbCfg(Ext, BB_CS, 1, 0);
    BbCfg(Ext, BB_MISO, 0, 3);
    BbSet(Ext, BB_SCK, 1);
    BbSet(Ext, BB_CS, 1);
    BbSet(Ext, BB_CS, 0);
    for (i = 0; i < HIMAX_XFER; i++) {
        out = tx[i];
        in = 0;
        for (b = 0; b < 8; b++) {
            BbSet(Ext, BB_SCK, 0);
            BbSet(Ext, BB_MOSI, (out & 0x80u) ? 1u : 0u);
            out <<= 1;
            BbSet(Ext, BB_SCK, 1);
            in = (in << 1) | BbGet(Ext, BB_MISO);
        }
        rx[i] = (UCHAR)in;
    }
    BbSet(Ext, BB_CS, 1);
    RtlCopyMemory(Payload, rx + 3, HIMAX_PAYLOAD);
    return TRUE;
}

static BOOLEAN
SpiReadGeni(PHIMAX_EXT Ext, UCHAR *Payload)
{
    PUCHAR Se = Ext->Se;
    UCHAR tx[HIMAX_XFER];
    UCHAR rx[HIMAX_XFER];
    ULONG depth, txOff, rxOff, spins, irq, word, n, i;

    RtlZeroMemory(tx, sizeof(tx));
    RtlZeroMemory(rx, sizeof(rx));
    tx[0] = 0xF3;
    tx[1] = 0x30;

    depth = Ext->Depth;
    Wr(Se, SE_SPI_LOOPBACK, 0);
    Wr(Se, SE_SPI_DEMUX_SEL, 0);
    Wr(Se, SE_SPI_DEMUX_INV, 0);
    Wr(Se, SE_SPI_CPHA, 1u);
    Wr(Se, SE_SPI_CPOL, 4u);
    Wr(Se, SE_SPI_TRANS_CFG, Rd(Se, SE_SPI_TRANS_CFG) & ~2u);
    Wr(Se, SE_SPI_WORD_LEN, 4);
    Pack(Se);
    Wr(Se, SE_GENI_CLK_SEL, 0);
    Wr(Se, GENI_SER_M_CLK_CFG, (Ext->ClkDiv << 4) | 1u);
    Wr(Se, SE_GENI_TX_WATERMARK, 0);
    Wr(Se, SE_SPI_TX_LEN, HIMAX_XFER);
    Wr(Se, SE_SPI_RX_LEN, HIMAX_XFER);
    Wr(Se, SE_GENI_M_IRQ_CLEAR, 0xFFFFFFFFu);
    Wr(Se, SE_GENI_M_CMD0, (1u | 2u) << 27);

    txOff = 0;
    rxOff = 0;
    for (spins = 0; spins < 5000; spins++) {
        while (txOff < HIMAX_XFER) {
            ULONG wc = Rd(Se, SE_GENI_TX_FIFO_STATUS) & 0x0FFFFFFFu;
            if (wc + 1 >= depth)
                break;
            word = 0;
            n = HIMAX_XFER - txOff;
            if (n > 4)
                n = 4;
            for (i = 0; i < n; i++)
                word |= ((ULONG)tx[txOff + i]) << (8 * i);
            Wr(Se, SE_GENI_TX_FIFO, word);
            txOff += n;
        }
        {
            ULONG st = Rd(Se, SE_GENI_RX_FIFO_STATUS);
            ULONG bytes = (st & 0x01FFFFFFu) * 4u;
            if (st & 0x80000000u) {
                ULONG valid = (st >> 28) & 7u;
                if (valid && valid < 4 && bytes >= 4)
                    bytes -= 4u - valid;
            }
            if (rxOff + bytes > HIMAX_XFER)
                bytes = HIMAX_XFER - rxOff;
            for (i = 0; i < bytes;) {
                ULONG got = Rd(Se, SE_GENI_RX_FIFO);
                n = bytes - i;
                if (n > 4)
                    n = 4;
                while (n--) {
                    rx[rxOff + i] = (UCHAR)(got & 0xFF);
                    got >>= 8;
                    i++;
                }
            }
            rxOff += bytes;
        }
        irq = Rd(Se, SE_GENI_M_IRQ_STATUS);
        if (irq & (4u | 8u)) {
            Wr(Se, SE_GENI_M_CMD_CTRL, 2u);
            return FALSE;
        }
        if ((irq & 1u) && rxOff >= HIMAX_XFER) {
            Wr(Se, SE_GENI_M_IRQ_CLEAR, irq);
            RtlCopyMemory(Payload, rx + 3, HIMAX_PAYLOAD);
            return TRUE;
        }
        KeStallExecutionProcessor(10);
    }
    Wr(Se, SE_GENI_M_CMD_CTRL, 2u);
    return FALSE;
}

static BOOLEAN
EventOk(const UCHAR *Buf)
{
    ULONG i, sum, any;

    any = 0;
    sum = 0;
    for (i = 0; i < HIMAX_PAYLOAD; i++) {
        if (Buf[i] != 0xFF)
            any = 1;
        sum += Buf[i];
    }
    return any && ((sum & 0xFF) == 0);
}

static VOID
FillReport(const UCHAR *Buf, PHIMAX_REPORT Rpt, BOOLEAN *Down)
{
    ULONG n, i, active;

    RtlZeroMemory(Rpt, sizeof(*Rpt));
    Rpt->Id = 1;
    n = Buf[HIMAX_COUNT_AT];
    if (n == 0xFF)
        n = 0;
    n &= 0x0F;
    if (n > HIMAX_FINGERS)
        n = HIMAX_FINGERS;
    active = 0;
    for (i = 0; i < HIMAX_FINGERS && active < n; i++) {
        USHORT rawX = (USHORT)((Buf[i * 4] << 8) | Buf[i * 4 + 1]);
        USHORT rawY = (USHORT)((Buf[i * 4 + 2] << 8) | Buf[i * 4 + 3]);
        USHORT x, y;
        if (rawX == 0xFFFF || rawY == 0xFFFF)
            continue;
        x = (USHORT)(rawX / 8);
        y = (USHORT)(rawY / 8);
        if (x > 1600 || y > 2560)
            continue;
        Rpt->C[i].Tip = 1;
        Rpt->C[i].Id = (UCHAR)i;
        Rpt->C[i].X = x;
        Rpt->C[i].Y = y;
        active++;
    }
    Rpt->Count = (UCHAR)active;
    *Down = active != 0;
}

static VOID
CompleteRead(PHIMAX_EXT Ext, const HIMAX_REPORT *Rpt)
{
    PIRP irp;
    KIRQL irql;
    PVOID buf;

    KeAcquireSpinLock(&Ext->Lock, &irql);
    irp = Ext->Pending;
    Ext->Pending = NULL;
    KeReleaseSpinLock(&Ext->Lock, irql);
    if (!irp)
        return;
    buf = irp->UserBuffer;
    if (buf) {
        RtlCopyMemory(buf, Rpt, sizeof(*Rpt));
        irp->IoStatus.Information = sizeof(*Rpt);
        irp->IoStatus.Status = STATUS_SUCCESS;
        Ext->DiagComplete++;
    } else {
        irp->IoStatus.Status = STATUS_INVALID_PARAMETER;
        irp->IoStatus.Information = 0;
    }
    IoCompleteRequest(irp, IO_NO_INCREMENT);
}

static VOID
DAppendS(char **p, char *end, const char *s)
{
    while (*s && *p < end)
        *(*p)++ = *s++;
}

static VOID
DAppendU(char **p, char *end, ULONG v)
{
    char tmp[12];
    int n = 0;

    if (v == 0) {
        if (*p < end)
            *(*p)++ = '0';
        return;
    }
    while (v && n < 12) {
        tmp[n++] = (char)('0' + (v % 10));
        v /= 10;
    }
    while (n > 0 && *p < end)
        *(*p)++ = tmp[--n];
}

static VOID
DAppendHex(char **p, char *end, UCHAR b)
{
    static const char h[] = "0123456789ABCDEF";

    if (*p < end)
        *(*p)++ = h[b >> 4];
    if (*p < end)
        *(*p)++ = h[b & 0xF];
}

/*
 * Dump driver state to \SystemRoot\himax-diag.txt. Touch never worked in
 * Windows (the GENI path returned all-0xFF), and the box exposes no USB for a
 * live debugger, so this file is read back offline from Linux to see exactly
 * where the runtime path breaks: did StartDevice map the GPIO block, is the
 * poll thread running, does the bit-bang produce a valid event, and is
 * HIDCLASS asking for reports.
 */
static VOID
WriteDiag(PHIMAX_EXT ext)
{
    UNICODE_STRING name;
    OBJECT_ATTRIBUTES oa;
    IO_STATUS_BLOCK iosb;
    HANDLE h;
    NTSTATUS st;
    char buf[1536];
    char *p = buf;
    char *end = buf + sizeof(buf);
    ULONG i;

    DAppendS(&p, end, "himax diag v2\n flags=");
    DAppendU(&p, end, ext->StartFlags);
    DAppendS(&p, end, " iter=");
    DAppendU(&p, end, ext->DiagIter);
    DAppendS(&p, end, " irqlow=");
    DAppendU(&p, end, ext->DiagIrqLow);
    DAppendS(&p, end, " spiok=");
    DAppendU(&p, end, ext->DiagSpiOk);
    DAppendS(&p, end, " evtok=");
    DAppendU(&p, end, ext->DiagEvtOk);
    DAppendS(&p, end, " readirp=");
    DAppendU(&p, end, ext->DiagReadIrp);
    DAppendS(&p, end, " complete=");
    DAppendU(&p, end, ext->DiagComplete);
    DAppendS(&p, end, " feat=");
    DAppendU(&p, end, ext->DiagFeature);
    DAppendS(&p, end, " active=");
    DAppendU(&p, end, ext->DiagActive);
    DAppendS(&p, end, " rawxy=");
    DAppendU(&p, end, ext->LastRawX);
    DAppendS(&p, end, ",");
    DAppendU(&p, end, ext->LastRawY);
    DAppendS(&p, end, "\n pnpN=");
    DAppendU(&p, end, ext->PnpLogN);
    DAppendS(&p, end, " pnp=");
    for (i = 0; i < ext->PnpLogN && i < sizeof(ext->PnpLog); i++) {
        DAppendHex(&p, end, ext->PnpLog[i]);
        if (p < end)
            *p++ = ' ';
    }
    DAppendS(&p, end, "\n qdrBus=");
    DAppendU(&p, end, ext->QdrBusSeen);
    DAppendS(&p, end, " qdrInStatus=0x");
    for (i = 0; i < 4; i++)
        DAppendHex(&p, end, (UCHAR)(ext->QdrInStatus >> (24 - 8 * i)));
    DAppendS(&p, end, " qdrInInfo=");
    DAppendU(&p, end, ext->QdrInInfo);
    DAppendS(&p, end, " lowerStart=0x");
    for (i = 0; i < 4; i++)
        DAppendHex(&p, end, (UCHAR)(ext->LowerStart >> (24 - 8 * i)));
    DAppendS(&p, end, " power=");
    DAppendU(&p, end, ext->PowerIrps);
    DAppendS(&p, end, "\n touch=");
    DAppendU(&p, end, ext->DiagTouch);
    DAppendS(&p, end, " lastN=");
    DAppendU(&p, end, ext->LastTN);
    DAppendS(&p, end, " xy=");
    DAppendU(&p, end, ext->TouchX);
    DAppendS(&p, end, ",");
    DAppendU(&p, end, ext->TouchY);
    DAppendS(&p, end, " xrange=");
    DAppendU(&p, end, ext->MinX);
    DAppendS(&p, end, "-");
    DAppendU(&p, end, ext->MaxX);
    DAppendS(&p, end, " yrange=");
    DAppendU(&p, end, ext->MinY);
    DAppendS(&p, end, "-");
    DAppendU(&p, end, ext->MaxY);
    DAppendS(&p, end, "\n idle=");
    for (i = 0; i < HIMAX_PAYLOAD; i++) {
        DAppendHex(&p, end, ext->LastPayload[i]);
        if (p < end)
            *p++ = ' ';
    }
    DAppendS(&p, end, "\n touchpl=");
    for (i = 0; i < HIMAX_PAYLOAD; i++) {
        DAppendHex(&p, end, ext->TouchPayload[i]);
        if (p < end)
            *p++ = ' ';
    }
    DAppendS(&p, end, "\n");

    RtlInitUnicodeString(&name, L"\\SystemRoot\\himax-diag.txt");
    InitializeObjectAttributes(&oa, &name, OBJ_KERNEL_HANDLE | OBJ_CASE_INSENSITIVE,
                               NULL, NULL);
    st = ZwCreateFile(&h, GENERIC_WRITE | SYNCHRONIZE, &oa, &iosb, NULL,
                      FILE_ATTRIBUTE_NORMAL, 0, FILE_OVERWRITE_IF,
                      FILE_SYNCHRONOUS_IO_NONALERT | FILE_NON_DIRECTORY_FILE,
                      NULL, 0);
    if (NT_SUCCESS(st)) {
        ZwWriteFile(h, NULL, NULL, NULL, &iosb, buf, (ULONG)(p - buf), NULL, NULL);
        ZwClose(h);
    }
}

static VOID
ThreadMain(PVOID Context)
{
    PHIMAX_EXT ext = Context;
    LARGE_INTEGER wait;
    HIMAX_REPORT rpt;
    UCHAR payload[HIMAX_PAYLOAD];
    BOOLEAN down;

    wait.QuadPart = -2 * 1000 * 10; /* 2 ms */
    while (KeWaitForSingleObject(&ext->Stop, Executive, KernelMode, FALSE, &wait) == STATUS_TIMEOUT) {
        ext->DiagIter++;
        if (!ext->Gp) {
            if ((ext->DiagIter & 127) == 0)
                WriteDiag(ext);
            continue;
        }
        if (ext->Irq &&
            (READ_REGISTER_ULONG((PULONG)(ext->Irq + IRQ_OFF)) & 1u) == 0)
            ext->DiagIrqLow++;
        /*
         * Poll the chip over bit-bang every 2 ms and let the frame itself
         * decide: the Himax only returns a checksum-correct, non-0xFF event
         * when it has data. Do not gate on gpio39 level -- that pin's mux
         * state at Windows runtime is not under our control and a wrong
         * reading would wedge the whole path.
         */
        if (SpiRead(ext, payload)) {
            ext->DiagSpiOk++;
            RtlCopyMemory(ext->LastPayload, payload, HIMAX_PAYLOAD);
            ext->LastRawX = (USHORT)((payload[0] << 8) | payload[1]);
            ext->LastRawY = (USHORT)((payload[2] << 8) | payload[3]);
            if (EventOk(payload)) {
                ext->DiagEvtOk++;
                FillReport(payload, &rpt, &down);
                if (down) {
                    ULONG c;
                    BOOLEAN fresh = !ext->Down;

                    ext->DiagActive += rpt.Count;
                    ext->DiagTouch++;
                    ext->LastTN = payload[HIMAX_COUNT_AT];
                    RtlCopyMemory(ext->TouchPayload, payload, HIMAX_PAYLOAD);
                    for (c = 0; c < HIMAX_FINGERS; c++) {
                        if (!rpt.C[c].Tip)
                            continue;
                        ext->TouchX = rpt.C[c].X;
                        ext->TouchY = rpt.C[c].Y;
                        if (rpt.C[c].X < ext->MinX)
                            ext->MinX = rpt.C[c].X;
                        if (rpt.C[c].X > ext->MaxX)
                            ext->MaxX = rpt.C[c].X;
                        if (rpt.C[c].Y < ext->MinY)
                            ext->MinY = rpt.C[c].Y;
                        if (rpt.C[c].Y > ext->MaxY)
                            ext->MaxY = rpt.C[c].Y;
                        break;
                    }
                    ext->Down = TRUE;
                    if (fresh)
                        WriteDiag(ext);
                    CompleteRead(ext, &rpt);
                } else if (ext->Down) {
                    ext->Down = FALSE;
                    CompleteRead(ext, &rpt); /* Count==0: a lift */
                }
            }
        }
        if ((ext->DiagIter & 127) == 0)
            WriteDiag(ext);
    }
    PsTerminateSystemThread(STATUS_SUCCESS);
}

static NTSTATUS
StartDevice(PHIMAX_EXT Ext)
{
    PHYSICAL_ADDRESS pa;
    OBJECT_ATTRIBUTES oa;
    NTSTATUS status;

    if (Ext->Run)
        return STATUS_SUCCESS;
    /* SE4 (GENI) is only used by the dead GENI path; it is optional now. The
     * bit-bang transfer needs the gpio8-11 block (Gp); the poll loop reads
     * gpio39 from the IRQ block. Require those two. */
    pa.QuadPart = SE4_PHYS;
    Ext->SeMap = MmMapIoSpaceEx(pa, SE4_SIZE, PAGE_READWRITE | PAGE_NOCACHE);
    pa.QuadPart = IRQ_PHYS;
    Ext->IrqMap = MmMapIoSpaceEx(pa, IRQ_SIZE, PAGE_READWRITE | PAGE_NOCACHE);
    pa.QuadPart = GP_PHYS;
    Ext->GpMap = MmMapIoSpaceEx(pa, GP_SIZE, PAGE_READWRITE | PAGE_NOCACHE);
    Ext->Se = Ext->SeMap;
    Ext->Irq = Ext->IrqMap;
    Ext->Gp = Ext->GpMap;
    Ext->StartFlags = (Ext->SeMap ? 1u : 0u) | (Ext->IrqMap ? 2u : 0u) |
                      (Ext->GpMap ? 4u : 0u);
    if (!Ext->GpMap || !Ext->IrqMap) {
        if (Ext->SeMap)
            MmUnmapIoSpace(Ext->SeMap, SE4_SIZE);
        if (Ext->IrqMap)
            MmUnmapIoSpace(Ext->IrqMap, IRQ_SIZE);
        if (Ext->GpMap)
            MmUnmapIoSpace(Ext->GpMap, GP_SIZE);
        Ext->SeMap = Ext->IrqMap = Ext->GpMap = NULL;
        Ext->Se = Ext->Irq = Ext->Gp = NULL;
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    /* gpio39 = Himax attention, active low. Own it: GPIO func (0), input
     * (OE=0), pull-up so it idles high when the chip releases. The ACPI node
     * exposes no GpioInt, so no other driver claims this pin. */
    WRITE_REGISTER_ULONG((PULONG)(Ext->Irq + 0), 3u);
    if (Ext->Se) {
        PHYSICAL_ADDRESS verPa;
        PVOID map;
        ULONG ver;

        Ext->Depth = FifoDepth(Ext->Se);
        verPa.QuadPart = QUP_VER;
        map = MmMapIoSpaceEx(verPa, 4, PAGE_READWRITE | PAGE_NOCACHE);
        ver = map ? READ_REGISTER_ULONG((PULONG)map) : 0;
        if (map)
            MmUnmapIoSpace(map, 4);
        Ext->ClkDiv = ((((ver >> 28) & 0xF) == 1) && (((ver >> 16) & 0xFFF) == 0)) ? 3u : 5u;
    }
    Ext->MinX = 0xFFFF;
    Ext->MinY = 0xFFFF;
    Ext->MaxX = 0;
    Ext->MaxY = 0;
    KeInitializeEvent(&Ext->Stop, NotificationEvent, FALSE);
    InitializeObjectAttributes(&oa, NULL, OBJ_KERNEL_HANDLE, NULL, NULL);
    status = PsCreateSystemThread(&Ext->ThreadHandle, THREAD_ALL_ACCESS, &oa,
                                  NULL, NULL, ThreadMain, Ext);
    if (!NT_SUCCESS(status))
        return status;
    status = ObReferenceObjectByHandle(Ext->ThreadHandle, THREAD_ALL_ACCESS,
                                       *PsThreadType, KernelMode,
                                       (PVOID *)&Ext->Thread, NULL);
    Ext->StartFlags |= 8u;
    Ext->Run = TRUE;
    return status;
}

static VOID
StopDevice(PHIMAX_EXT Ext)
{
    PIRP irp;
    KIRQL irql;

    if (Ext->Run) {
        KeSetEvent(&Ext->Stop, IO_NO_INCREMENT, FALSE);
        if (Ext->Thread)
            KeWaitForSingleObject(Ext->Thread, Executive, KernelMode, FALSE, NULL);
        if (Ext->Thread)
            ObDereferenceObject(Ext->Thread);
        if (Ext->ThreadHandle)
            ZwClose(Ext->ThreadHandle);
        Ext->Thread = NULL;
        Ext->ThreadHandle = NULL;
        Ext->Run = FALSE;
    }
    KeAcquireSpinLock(&Ext->Lock, &irql);
    irp = Ext->Pending;
    Ext->Pending = NULL;
    KeReleaseSpinLock(&Ext->Lock, irql);
    if (irp) {
        irp->IoStatus.Status = STATUS_DEVICE_REMOVED;
        irp->IoStatus.Information = 0;
        IoCompleteRequest(irp, IO_NO_INCREMENT);
    }
    if (Ext->SeMap)
        MmUnmapIoSpace(Ext->SeMap, SE4_SIZE);
    if (Ext->IrqMap)
        MmUnmapIoSpace(Ext->IrqMap, IRQ_SIZE);
    if (Ext->GpMap)
        MmUnmapIoSpace(Ext->GpMap, GP_SIZE);
    Ext->SeMap = NULL;
    Ext->IrqMap = NULL;
    Ext->GpMap = NULL;
    Ext->Se = NULL;
    Ext->Irq = NULL;
    Ext->Gp = NULL;
}

static NTSTATUS
AddDevice(_In_ PDRIVER_OBJECT DriverObject, _In_ PDEVICE_OBJECT Fdo)
{
    PHID_DEVICE_EXTENSION hid;
    PHIMAX_EXT ext;

    UNREFERENCED_PARAMETER(DriverObject);
    hid = (PHID_DEVICE_EXTENSION)Fdo->DeviceExtension;
    ext = (PHIMAX_EXT)hid->MiniDeviceExtension;
    RtlZeroMemory(ext, sizeof(*ext));
    ext->Fdo = Fdo;
    KeInitializeSpinLock(&ext->Lock);
    Fdo->Flags &= ~DO_DEVICE_INITIALIZING;
    return STATUS_SUCCESS;
}

static VOID
PnpLog(PHIMAX_EXT Ext, UCHAR Minor)
{
    if (Ext->PnpLogN < sizeof(Ext->PnpLog))
        Ext->PnpLog[Ext->PnpLogN] = Minor;
    Ext->PnpLogN++;
}

/*
 * HID minidriver PnP contract (hidport.h: "IRPs are sent [to
 * NextDeviceObject] by the minidriver"): every PnP IRP goes down to the ACPI
 * PDO. START is forwarded first and the hardware started on the way back up;
 * everything else is passed down untouched. Completing PnP IRPs here instead
 * (the old code) hid them from the lower stack and returned the PnP manager's
 * default STATUS_NOT_SUPPORTED for queries such as QUERY_DEVICE_RELATIONS.
 */
static NTSTATUS
PnpDispatch(_In_ PDEVICE_OBJECT Fdo, _In_ PIRP Irp)
{
    PHID_DEVICE_EXTENSION hid = (PHID_DEVICE_EXTENSION)Fdo->DeviceExtension;
    PHIMAX_EXT ext = (PHIMAX_EXT)hid->MiniDeviceExtension;
    PIO_STACK_LOCATION sp = IoGetCurrentIrpStackLocation(Irp);
    NTSTATUS status;
    UCHAR minor = sp->MinorFunction;

    PnpLog(ext, minor);
    if (minor == IRP_MN_QUERY_DEVICE_RELATIONS &&
        sp->Parameters.QueryDeviceRelations.Type == BusRelations) {
        ext->QdrBusSeen++;
        ext->QdrInStatus = (ULONG)Irp->IoStatus.Status;
        ext->QdrInInfo = Irp->IoStatus.Information ? 1u : 0u;
    }

    switch (minor) {
    case IRP_MN_START_DEVICE:
        if (IoForwardIrpSynchronously(hid->NextDeviceObject, Irp))
            status = Irp->IoStatus.Status;
        else
            status = STATUS_UNSUCCESSFUL;
        ext->LowerStart = (ULONG)status;
        if (NT_SUCCESS(status))
            status = StartDevice(ext);
        Irp->IoStatus.Status = status;
        IoCompleteRequest(Irp, IO_NO_INCREMENT);
        return status;
    case IRP_MN_STOP_DEVICE:
    case IRP_MN_REMOVE_DEVICE:
    case IRP_MN_SURPRISE_REMOVAL:
        StopDevice(ext);
        break;
    default:
        break;
    }
    IoSkipCurrentIrpStackLocation(Irp);
    return IoCallDriver(hid->NextDeviceObject, Irp);
}

static NTSTATUS
PowerDispatch(_In_ PDEVICE_OBJECT Fdo, _In_ PIRP Irp)
{
    PHID_DEVICE_EXTENSION hid = (PHID_DEVICE_EXTENSION)Fdo->DeviceExtension;
    PHIMAX_EXT ext = (PHIMAX_EXT)hid->MiniDeviceExtension;

    ext->PowerIrps++;
    PoStartNextPowerIrp(Irp);
    IoSkipCurrentIrpStackLocation(Irp);
    return PoCallDriver(hid->NextDeviceObject, Irp);
}

static NTSTATUS
InternalIoctl(_In_ PDEVICE_OBJECT Fdo, _In_ PIRP Irp)
{
    PHID_DEVICE_EXTENSION hid = (PHID_DEVICE_EXTENSION)Fdo->DeviceExtension;
    PHIMAX_EXT ext = (PHIMAX_EXT)hid->MiniDeviceExtension;
    PIO_STACK_LOCATION sp = IoGetCurrentIrpStackLocation(Irp);
    ULONG code = sp->Parameters.DeviceIoControl.IoControlCode;
    NTSTATUS status = STATUS_SUCCESS;
    ULONG len = 0;
    PVOID buf = Irp->UserBuffer;
    KIRQL irql;

    switch (code) {
    case IOCTL_HID_GET_DEVICE_DESCRIPTOR:
        if (!buf || sp->Parameters.DeviceIoControl.OutputBufferLength < sizeof(gHidDesc)) {
            status = STATUS_BUFFER_TOO_SMALL;
            break;
        }
        RtlCopyMemory(buf, &gHidDesc, sizeof(gHidDesc));
        len = sizeof(gHidDesc);
        break;
    case IOCTL_HID_GET_REPORT_DESCRIPTOR:
        if (!buf || sp->Parameters.DeviceIoControl.OutputBufferLength < sizeof(gReportDesc)) {
            status = STATUS_BUFFER_TOO_SMALL;
            break;
        }
        RtlCopyMemory(buf, gReportDesc, sizeof(gReportDesc));
        len = sizeof(gReportDesc);
        break;
    case IOCTL_HID_GET_DEVICE_ATTRIBUTES: {
        PHID_DEVICE_ATTRIBUTES attr = buf;
        if (!attr || sp->Parameters.DeviceIoControl.OutputBufferLength < sizeof(*attr)) {
            status = STATUS_BUFFER_TOO_SMALL;
            break;
        }
        attr->Size = sizeof(*attr);
        attr->VendorID = 0x4858;
        attr->ProductID = 0x8312;
        attr->VersionNumber = 1;
        len = sizeof(*attr);
        break;
    }
    case IOCTL_HID_READ_REPORT:
        if (!buf || sp->Parameters.DeviceIoControl.OutputBufferLength < sizeof(HIMAX_REPORT)) {
            status = STATUS_BUFFER_TOO_SMALL;
            break;
        }
        KeAcquireSpinLock(&ext->Lock, &irql);
        if (ext->Pending) {
            KeReleaseSpinLock(&ext->Lock, irql);
            status = STATUS_DEVICE_BUSY;
            break;
        }
        IoMarkIrpPending(Irp);
        ext->Pending = Irp;
        ext->DiagReadIrp++;
        KeReleaseSpinLock(&ext->Lock, irql);
        return STATUS_PENDING;
    case IOCTL_HID_ACTIVATE_DEVICE:
        status = StartDevice(ext);
        break;
    case IOCTL_HID_DEACTIVATE_DEVICE:
        StopDevice(ext);
        break;
    case IOCTL_HID_GET_FEATURE: {
        /*
         * HIDCLASS passes a HID_XFER_PACKET here, NOT a raw buffer. The touch
         * stack reads the Contact Count Maximum feature report (report ID 1)
         * during init; if it comes back as 0/garbage Windows treats every
         * input frame as "more contacts than the maximum" and discards it, so
         * touch is read but never acted on. Fill the packet's reportBuffer.
         */
        PHID_XFER_PACKET pkt = (PHID_XFER_PACKET)Irp->UserBuffer;
        ext->DiagFeature++;
        if (!pkt || !pkt->reportBuffer || pkt->reportBufferLen < 2) {
            status = STATUS_BUFFER_TOO_SMALL;
            break;
        }
        pkt->reportBuffer[0] = pkt->reportId ? pkt->reportId : 2; /* feature report ID 2 */
        pkt->reportBuffer[1] = HIMAX_FINGERS;    /* contact count maximum */
        len = 2;
        break;
    }
    case IOCTL_HID_SET_FEATURE:
        break;
    case IOCTL_HID_SEND_IDLE_NOTIFICATION_REQUEST:
        status = STATUS_NOT_SUPPORTED;
        break;
    default:
        status = STATUS_NOT_SUPPORTED;
        break;
    }
    Irp->IoStatus.Status = status;
    Irp->IoStatus.Information = len;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return status;
}

static VOID
Unload(_In_ PDRIVER_OBJECT DriverObject)
{
    UNREFERENCED_PARAMETER(DriverObject);
}

NTSTATUS
DriverEntry(_In_ PDRIVER_OBJECT DriverObject, _In_ PUNICODE_STRING RegistryPath)
{
    HID_MINIDRIVER_REGISTRATION reg;

    DriverObject->MajorFunction[IRP_MJ_INTERNAL_DEVICE_CONTROL] = InternalIoctl;
    DriverObject->MajorFunction[IRP_MJ_PNP] = PnpDispatch;
    DriverObject->MajorFunction[IRP_MJ_POWER] = PowerDispatch;
    DriverObject->DriverUnload = Unload;
    DriverObject->DriverExtension->AddDevice = AddDevice;

    RtlZeroMemory(&reg, sizeof(reg));
    reg.Revision = HID_REVISION;
    reg.DriverObject = DriverObject;
    reg.RegistryPath = RegistryPath;
    reg.DeviceExtensionSize = sizeof(HIMAX_EXT);
    reg.DevicesArePolled = FALSE;
    return HidRegisterMinidriver(&reg);
}
