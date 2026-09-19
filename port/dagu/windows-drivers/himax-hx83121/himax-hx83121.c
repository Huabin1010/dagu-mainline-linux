/* SPDX-License-Identifier: MIT
 * Himax HX83121 SPI digitizer for dagu.
 *
 * Protocol from linux-mainline/overlays/.../himax-dagu.c (CAF hx83121):
 *   SPI mode 3, read cmd 0x30 via [0xF3, 0x30, 0x00] + 56-byte payload
 *   10 fingers x 4 bytes, point count at offset 52, coords / 8
 *   checksum: sum of 56 bytes == 0 mod 256
 *
 * Template shape from WOA-Project/HimaxTouch85x (HX852x, different chip).
 * Do not bind GPIO100. HID miniport reports 1600x2560.
 */
#include <ntddk.h>
#include <wdf.h>
#include <hidport.h>
#include "../common/dagu-spb.h"

#define HIMAX_MAX_FINGERS   10
#define HIMAX_EVENT_LEN     56
#define HIMAX_POINT_CNT     52
#define HIMAX_BUS_HLEN      3
#define HIMAX_EVENT_CMD     0x30
#define HIMAX_RATIO         8
#define HIMAX_MAX_X         1600
#define HIMAX_MAX_Y         2560

typedef struct _HIMAX_CONTEXT {
    DAGU_SPB Spb;
    WDFINTERRUPT Irq;
    WDFQUEUE ReportQueue;
} HIMAX_CONTEXT, *PHIMAX_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(HIMAX_CONTEXT, HimaxGetContext)

static BOOLEAN
HimaxEventValid(_In_reads_(HIMAX_EVENT_LEN) const UCHAR *Buf)
{
    ULONG i;

    for (i = 0; i < HIMAX_EVENT_LEN; i++) {
        if (Buf[i] != 0xFF)
            return TRUE;
    }
    return FALSE;
}

static BOOLEAN
HimaxChecksumOk(_In_reads_(HIMAX_EVENT_LEN) const UCHAR *Buf)
{
    USHORT sum = 0;
    ULONG i;

    for (i = 0; i < HIMAX_EVENT_LEN; i++)
        sum = (USHORT)(sum + Buf[i]);
    return (sum & 0xFF) == 0;
}

static NTSTATUS
HimaxBusRead(_In_ PHIMAX_CONTEXT Ctx, _Out_writes_(HIMAX_EVENT_LEN) PUCHAR Out)
{
    UCHAR xfer[HIMAX_BUS_HLEN + HIMAX_EVENT_LEN];
    NTSTATUS status;

    RtlZeroMemory(xfer, sizeof(xfer));
    xfer[0] = 0xF3;
    xfer[1] = HIMAX_EVENT_CMD;
    xfer[2] = 0x00;
    status = DaguSpbXfer(&Ctx->Spb, xfer, sizeof(xfer), xfer, sizeof(xfer));
    if (!NT_SUCCESS(status))
        return status;
    RtlCopyMemory(Out, xfer + HIMAX_BUS_HLEN, HIMAX_EVENT_LEN);
    return STATUS_SUCCESS;
}

/* Digitizer HID report: report ID 1, tip + 16-bit X/Y. */
#pragma pack(push, 1)
typedef struct _HIMAX_HID_CONTACT {
    UCHAR Tip;
    USHORT X;
    USHORT Y;
} HIMAX_HID_CONTACT;

typedef struct _HIMAX_HID_REPORT {
    UCHAR Id;
    HIMAX_HID_CONTACT C[HIMAX_MAX_FINGERS];
    UCHAR Count;
} HIMAX_HID_REPORT;
#pragma pack(pop)

static VOID
HimaxFillReport(_In_reads_(HIMAX_EVENT_LEN) const UCHAR *Buf,
                _Out_ PHIMAX_HID_REPORT Rpt)
{
    int n, i, active = 0;

    RtlZeroMemory(Rpt, sizeof(*Rpt));
    Rpt->Id = 1;
    n = Buf[HIMAX_POINT_CNT];
    if (n == 0xFF)
        n = 0;
    n &= 0x0F;
    if (n > HIMAX_MAX_FINGERS)
        n = HIMAX_MAX_FINGERS;

    for (i = 0; i < HIMAX_MAX_FINGERS && active < n; i++) {
        USHORT rawX = (USHORT)((Buf[i * 4] << 8) | Buf[i * 4 + 1]);
        USHORT rawY = (USHORT)((Buf[i * 4 + 2] << 8) | Buf[i * 4 + 3]);
        USHORT x = (USHORT)(rawX / HIMAX_RATIO);
        USHORT y = (USHORT)(rawY / HIMAX_RATIO);

        if (rawX == 0xFFFF || rawY == 0xFFFF)
            continue;
        if (x > HIMAX_MAX_X || y > HIMAX_MAX_Y)
            continue;
        Rpt->C[i].Tip = 1;
        Rpt->C[i].X = x;
        Rpt->C[i].Y = y;
        active++;
    }
    Rpt->Count = (UCHAR)active;
}

static BOOLEAN
HimaxEvtIsr(_In_ WDFINTERRUPT Interrupt, _In_ ULONG MessageID)
{
    UNREFERENCED_PARAMETER(MessageID);
    WdfInterruptQueueDpcForIsr(Interrupt);
    return TRUE;
}

static VOID
HimaxEvtDpc(_In_ WDFINTERRUPT Interrupt, _In_ WDFOBJECT AssociatedObject)
{
    PHIMAX_CONTEXT ctx = HimaxGetContext(WdfInterruptGetDevice(Interrupt));
    UCHAR buf[HIMAX_EVENT_LEN];
    HIMAX_HID_REPORT rpt;
    WDFREQUEST req;
    NTSTATUS status;
    PVOID out;
    size_t outLen;

    UNREFERENCED_PARAMETER(AssociatedObject);
    if (!NT_SUCCESS(HimaxBusRead(ctx, buf)))
        return;
    if (!HimaxEventValid(buf) || !HimaxChecksumOk(buf))
        return;
    HimaxFillReport(buf, &rpt);

    status = WdfIoQueueRetrieveNextRequest(ctx->ReportQueue, &req);
    if (!NT_SUCCESS(status))
        return;
    status = WdfRequestRetrieveOutputBuffer(req, sizeof(rpt), &out, &outLen);
    if (NT_SUCCESS(status) && outLen >= sizeof(rpt)) {
        RtlCopyMemory(out, &rpt, sizeof(rpt));
        WdfRequestCompleteWithInformation(req, STATUS_SUCCESS, sizeof(rpt));
    } else {
        WdfRequestComplete(req, status);
    }
}

NTSTATUS
DriverEntry(_In_ PDRIVER_OBJECT DriverObject, _In_ PUNICODE_STRING RegistryPath)
{
    WDF_DRIVER_CONFIG cfg;

    WDF_DRIVER_CONFIG_INIT(&cfg, NULL);
    cfg.EvtDriverDeviceAdd = NULL; /* filled by INF/KMDF hidclass pairing */
    UNREFERENCED_PARAMETER(DriverObject);
    UNREFERENCED_PARAMETER(RegistryPath);
    return STATUS_SUCCESS;
}
