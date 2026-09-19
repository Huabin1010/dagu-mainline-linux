/* SPDX-License-Identifier: MIT
 * Nanosic 803 MCU @ I2C 0x4c. Protocol from nanosic-dagu.c.
 *
 * 68-byte envelope after a dummy 7-bit address write. Sync 0x57.
 * Types: 0x05 keyboard / 0x02 mouse / 0x19 touch / 0x06 consumer.
 * Trim GENI leftover after the first 0x39 record (nabu filter is USB HID;
 * this board is I2C). Touch usage is 0x04 (Touch Screen) — nabu 22621+
 * BSOD was 0x05 Touch Pad; see Project-Aloha/NabuNanosicFilter.
 * VID 15d9 from live Android dump.
 */
#include <ntddk.h>
#include <wdf.h>
#include "../common/dagu-spb.h"

#define NANOSIC_READ_LEN    68
#define NANOSIC_PKT_SYNC    0x57
#define NANOSIC_TYPE_MOUSE  0x02
#define NANOSIC_TYPE_KBD    0x05
#define NANOSIC_TYPE_CONS   0x06
#define NANOSIC_TYPE_TOUCH  0x19
#define NANOSIC_TYPE_V16    0x22
#define NANOSIC_TYPE_V32    0x23

typedef struct _NANOSIC_CONTEXT {
    DAGU_SPB Spb;
    WDFINTERRUPT Irq;
    UCHAR LastSeq;
    BOOLEAN HaveSeq;
} NANOSIC_CONTEXT, *PNANOSIC_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(NANOSIC_CONTEXT, NanosicGetContext)

static size_t
NanosicRecLen(UCHAR Type)
{
    switch (Type) {
    case NANOSIC_TYPE_KBD:   return 9;
    case NANOSIC_TYPE_CONS:  return 5;
    case NANOSIC_TYPE_MOUSE: return 8;
    case NANOSIC_TYPE_TOUCH: return 21;
    case NANOSIC_TYPE_V16:   return 16;
    case NANOSIC_TYPE_V32:   return 32;
    default:                 return 0;
    }
}

static VOID
NanosicTrimGeni(_Inout_updates_(Len) PUCHAR Data, _In_ size_t Len)
{
    size_t rec;

    if (Len < 4 || Data[0] != NANOSIC_PKT_SYNC || Data[2] != 0x39)
        return;
    rec = NanosicRecLen(Data[3]);
    if (!rec || 3 + rec >= Len)
        return;
    RtlZeroMemory(Data + 3 + rec, Len - 3 - rec);
}

static NTSTATUS
NanosicRead(_In_ PNANOSIC_CONTEXT Ctx, _Out_writes_(NANOSIC_READ_LEN) PUCHAR Buf)
{
    UCHAR dummy = 0;
    NTSTATUS status;

    /* Dummy write of the 7-bit address, then 68-byte read (Linux comment). */
    status = DaguSpbWrite(&Ctx->Spb, &dummy, 0);
    if (!NT_SUCCESS(status) && status != STATUS_INVALID_PARAMETER)
        return status;
    return DaguSpbXfer(&Ctx->Spb, NULL, 0, Buf, NANOSIC_READ_LEN);
}

static BOOLEAN
NanosicSeqStale(_In_ PNANOSIC_CONTEXT Ctx, _In_reads_(NANOSIC_READ_LEN) const UCHAR *Data)
{
    if (Data[0] != NANOSIC_PKT_SYNC || !Ctx->HaveSeq)
        return FALSE;
    return (CHAR)(Data[1] - Ctx->LastSeq) <= 0;
}

/* Live Android report descriptors live in nanosic-dagu.c; Windows HID
 * miniport injects the same report IDs 0x05/0x02/0x19/0x06.
 */
static VOID
NanosicParse(_In_ PNANOSIC_CONTEXT Ctx, _Inout_updates_(Len) PUCHAR Data, _In_ size_t Len)
{
    if (Len < 4 || Data[0] != NANOSIC_PKT_SYNC)
        return;
    NanosicTrimGeni(Data, Len);
    if (NanosicSeqStale(Ctx, Data))
        return;
    Ctx->LastSeq = Data[1];
    Ctx->HaveSeq = TRUE;
    /* HID inject happens in the miniport report path (same as Linux hid_ll). */
    UNREFERENCED_PARAMETER(Ctx);
}

NTSTATUS
DriverEntry(_In_ PDRIVER_OBJECT DriverObject, _In_ PUNICODE_STRING RegistryPath)
{
    UNREFERENCED_PARAMETER(DriverObject);
    UNREFERENCED_PARAMETER(RegistryPath);
    return STATUS_SUCCESS;
}
