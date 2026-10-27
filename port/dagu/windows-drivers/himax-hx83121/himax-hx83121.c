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

/* Parallel-mode touch screen, 10 contacts, 1600 x 2560. */
static const UCHAR gReportDesc[] = {
    0x05, 0x0D, 0x09, 0x04, 0xA1, 0x01, 0x85, 0x01,
    0x09, 0x22, 0xA1, 0x02, 0x09, 0x42, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01,
    0x95, 0x01, 0x81, 0x02, 0x95, 0x07, 0x81, 0x03, 0x15, 0x00, 0x25, 0x09,
    0x75, 0x08, 0x09, 0x51,
    0x95, 0x01, 0x81, 0x02, 0x05, 0x01, 0x26, 0x40, 0x06, 0x75, 0x10, 0x09, 0x30,
    0x81, 0x02, 0x26, 0x00, 0x0A, 0x09, 0x31, 0x81, 0x02, 0xC0, 0x05, 0x0D,
    0x09, 0x22, 0xA1, 0x02, 0x09, 0x42, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01,
    0x95, 0x01, 0x81, 0x02, 0x95, 0x07, 0x81, 0x03, 0x15, 0x00, 0x25, 0x09,
    0x75, 0x08, 0x09, 0x51,
    0x95, 0x01, 0x81, 0x02, 0x05, 0x01, 0x26, 0x40, 0x06, 0x75, 0x10, 0x09, 0x30,
    0x81, 0x02, 0x26, 0x00, 0x0A, 0x09, 0x31, 0x81, 0x02, 0xC0, 0x05, 0x0D,
    0x09, 0x22, 0xA1, 0x02, 0x09, 0x42, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01,
    0x95, 0x01, 0x81, 0x02, 0x95, 0x07, 0x81, 0x03, 0x15, 0x00, 0x25, 0x09,
    0x75, 0x08, 0x09, 0x51,
    0x95, 0x01, 0x81, 0x02, 0x05, 0x01, 0x26, 0x40, 0x06, 0x75, 0x10, 0x09, 0x30,
    0x81, 0x02, 0x26, 0x00, 0x0A, 0x09, 0x31, 0x81, 0x02, 0xC0, 0x05, 0x0D,
    0x09, 0x22, 0xA1, 0x02, 0x09, 0x42, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01,
    0x95, 0x01, 0x81, 0x02, 0x95, 0x07, 0x81, 0x03, 0x15, 0x00, 0x25, 0x09,
    0x75, 0x08, 0x09, 0x51,
    0x95, 0x01, 0x81, 0x02, 0x05, 0x01, 0x26, 0x40, 0x06, 0x75, 0x10, 0x09, 0x30,
    0x81, 0x02, 0x26, 0x00, 0x0A, 0x09, 0x31, 0x81, 0x02, 0xC0, 0x05, 0x0D,
    0x09, 0x22, 0xA1, 0x02, 0x09, 0x42, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01,
    0x95, 0x01, 0x81, 0x02, 0x95, 0x07, 0x81, 0x03, 0x15, 0x00, 0x25, 0x09,
    0x75, 0x08, 0x09, 0x51,
    0x95, 0x01, 0x81, 0x02, 0x05, 0x01, 0x26, 0x40, 0x06, 0x75, 0x10, 0x09, 0x30,
    0x81, 0x02, 0x26, 0x00, 0x0A, 0x09, 0x31, 0x81, 0x02, 0xC0, 0x05, 0x0D,
    0x09, 0x22, 0xA1, 0x02, 0x09, 0x42, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01,
    0x95, 0x01, 0x81, 0x02, 0x95, 0x07, 0x81, 0x03, 0x15, 0x00, 0x25, 0x09,
    0x75, 0x08, 0x09, 0x51,
    0x95, 0x01, 0x81, 0x02, 0x05, 0x01, 0x26, 0x40, 0x06, 0x75, 0x10, 0x09, 0x30,
    0x81, 0x02, 0x26, 0x00, 0x0A, 0x09, 0x31, 0x81, 0x02, 0xC0, 0x05, 0x0D,
    0x09, 0x22, 0xA1, 0x02, 0x09, 0x42, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01,
    0x95, 0x01, 0x81, 0x02, 0x95, 0x07, 0x81, 0x03, 0x15, 0x00, 0x25, 0x09,
    0x75, 0x08, 0x09, 0x51,
    0x95, 0x01, 0x81, 0x02, 0x05, 0x01, 0x26, 0x40, 0x06, 0x75, 0x10, 0x09, 0x30,
    0x81, 0x02, 0x26, 0x00, 0x0A, 0x09, 0x31, 0x81, 0x02, 0xC0, 0x05, 0x0D,
    0x09, 0x22, 0xA1, 0x02, 0x09, 0x42, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01,
    0x95, 0x01, 0x81, 0x02, 0x95, 0x07, 0x81, 0x03, 0x15, 0x00, 0x25, 0x09,
    0x75, 0x08, 0x09, 0x51,
    0x95, 0x01, 0x81, 0x02, 0x05, 0x01, 0x26, 0x40, 0x06, 0x75, 0x10, 0x09, 0x30,
    0x81, 0x02, 0x26, 0x00, 0x0A, 0x09, 0x31, 0x81, 0x02, 0xC0, 0x05, 0x0D,
    0x09, 0x22, 0xA1, 0x02, 0x09, 0x42, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01,
    0x95, 0x01, 0x81, 0x02, 0x95, 0x07, 0x81, 0x03, 0x15, 0x00, 0x25, 0x09,
    0x75, 0x08, 0x09, 0x51,
    0x95, 0x01, 0x81, 0x02, 0x05, 0x01, 0x26, 0x40, 0x06, 0x75, 0x10, 0x09, 0x30,
    0x81, 0x02, 0x26, 0x00, 0x0A, 0x09, 0x31, 0x81, 0x02, 0xC0, 0x05, 0x0D,
    0x09, 0x22, 0xA1, 0x02, 0x09, 0x42, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01,
    0x95, 0x01, 0x81, 0x02, 0x95, 0x07, 0x81, 0x03, 0x15, 0x00, 0x25, 0x09,
    0x75, 0x08, 0x09, 0x51,
    0x95, 0x01, 0x81, 0x02, 0x05, 0x01, 0x26, 0x40, 0x06, 0x75, 0x10, 0x09, 0x30,
    0x81, 0x02, 0x26, 0x00, 0x0A, 0x09, 0x31, 0x81, 0x02, 0xC0, 0x05, 0x0D,
    0x09, 0x54, 0x15, 0x00, 0x25, 0x0A, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02,
    0x09, 0x55, 0xB1, 0x02, 0xC0
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
    PVOID SeMap;
    PVOID IrqMap;
    HANDLE ThreadHandle;
    PKTHREAD Thread;
    KEVENT Stop;
    KSPIN_LOCK Lock;
    PIRP Pending;
    BOOLEAN Down;
    BOOLEAN Run;
    ULONG Depth;
    ULONG ClkDiv;
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

static BOOLEAN
SpiRead(PHIMAX_EXT Ext, UCHAR *Payload)
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
    } else {
        irp->IoStatus.Status = STATUS_INVALID_PARAMETER;
        irp->IoStatus.Information = 0;
    }
    IoCompleteRequest(irp, IO_NO_INCREMENT);
}

static VOID
ThreadMain(PVOID Context)
{
    PHIMAX_EXT ext = Context;
    LARGE_INTEGER wait;
    HIMAX_REPORT rpt;
    UCHAR payload[HIMAX_PAYLOAD];
    ULONG level;

    wait.QuadPart = -2 * 1000 * 10; /* 2 ms */
    while (KeWaitForSingleObject(&ext->Stop, Executive, KernelMode, FALSE, &wait) == STATUS_TIMEOUT) {
        if (!ext->Se || !ext->Irq)
            continue;
        level = READ_REGISTER_ULONG((PULONG)(ext->Irq + IRQ_OFF)) & 1u;
        if (level != 0 && !ext->Down)
            continue;
        if (!SpiRead(ext, payload) || !EventOk(payload)) {
            if (ext->Down && level != 0) {
                RtlZeroMemory(&rpt, sizeof(rpt));
                rpt.Id = 1;
                ext->Down = FALSE;
                CompleteRead(ext, &rpt);
            }
            continue;
        }
        FillReport(payload, &rpt, &ext->Down);
        CompleteRead(ext, &rpt);
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
    pa.QuadPart = SE4_PHYS;
    Ext->SeMap = MmMapIoSpaceEx(pa, SE4_SIZE, PAGE_READWRITE | PAGE_NOCACHE);
    pa.QuadPart = IRQ_PHYS;
    Ext->IrqMap = MmMapIoSpaceEx(pa, IRQ_SIZE, PAGE_READWRITE | PAGE_NOCACHE);
    if (!Ext->SeMap || !Ext->IrqMap) {
        if (Ext->SeMap)
            MmUnmapIoSpace(Ext->SeMap, SE4_SIZE);
        if (Ext->IrqMap)
            MmUnmapIoSpace(Ext->IrqMap, IRQ_SIZE);
        Ext->SeMap = NULL;
        Ext->IrqMap = NULL;
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    Ext->Se = Ext->SeMap;
    Ext->Irq = Ext->IrqMap;
    Ext->Depth = FifoDepth(Ext->Se);
    {
        PHYSICAL_ADDRESS verPa;
        PVOID map;
        ULONG ver;

        verPa.QuadPart = QUP_VER;
        map = MmMapIoSpaceEx(verPa, 4, PAGE_READWRITE | PAGE_NOCACHE);
        ver = map ? READ_REGISTER_ULONG((PULONG)map) : 0;
        if (map)
            MmUnmapIoSpace(map, 4);
        Ext->ClkDiv = ((((ver >> 28) & 0xF) == 1) && (((ver >> 16) & 0xFFF) == 0)) ? 3u : 5u;
    }
    KeInitializeEvent(&Ext->Stop, NotificationEvent, FALSE);
    InitializeObjectAttributes(&oa, NULL, OBJ_KERNEL_HANDLE, NULL, NULL);
    status = PsCreateSystemThread(&Ext->ThreadHandle, THREAD_ALL_ACCESS, &oa,
                                  NULL, NULL, ThreadMain, Ext);
    if (!NT_SUCCESS(status))
        return status;
    status = ObReferenceObjectByHandle(Ext->ThreadHandle, THREAD_ALL_ACCESS,
                                       *PsThreadType, KernelMode,
                                       (PVOID *)&Ext->Thread, NULL);
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
    Ext->SeMap = NULL;
    Ext->IrqMap = NULL;
    Ext->Se = NULL;
    Ext->Irq = NULL;
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
    return STATUS_SUCCESS;
}

static NTSTATUS
PnpDispatch(_In_ PDEVICE_OBJECT Fdo, _In_ PIRP Irp)
{
    PHID_DEVICE_EXTENSION hid = (PHID_DEVICE_EXTENSION)Fdo->DeviceExtension;
    PHIMAX_EXT ext = (PHIMAX_EXT)hid->MiniDeviceExtension;
    PIO_STACK_LOCATION sp = IoGetCurrentIrpStackLocation(Irp);
    NTSTATUS status = STATUS_SUCCESS;

    switch (sp->MinorFunction) {
    case IRP_MN_START_DEVICE:
        status = StartDevice(ext);
        break;
    case IRP_MN_STOP_DEVICE:
    case IRP_MN_REMOVE_DEVICE:
    case IRP_MN_SURPRISE_REMOVAL:
        StopDevice(ext);
        break;
    default:
        status = Irp->IoStatus.Status;
        break;
    }
    Irp->IoStatus.Status = status;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return status;
}

static NTSTATUS
PowerDispatch(_In_ PDEVICE_OBJECT Fdo, _In_ PIRP Irp)
{
    UNREFERENCED_PARAMETER(Fdo);
    PoStartNextPowerIrp(Irp);
    Irp->IoStatus.Status = STATUS_SUCCESS;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return STATUS_SUCCESS;
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
        KeReleaseSpinLock(&ext->Lock, irql);
        return STATUS_PENDING;
    case IOCTL_HID_ACTIVATE_DEVICE:
        status = StartDevice(ext);
        break;
    case IOCTL_HID_DEACTIVATE_DEVICE:
        StopDevice(ext);
        break;
    case IOCTL_HID_GET_FEATURE:
        if (!buf || sp->Parameters.DeviceIoControl.OutputBufferLength < 2) {
            status = STATUS_BUFFER_TOO_SMALL;
            break;
        }
        ((PUCHAR)buf)[0] = 1;
        ((PUCHAR)buf)[1] = HIMAX_FINGERS;
        len = 2;
        break;
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
