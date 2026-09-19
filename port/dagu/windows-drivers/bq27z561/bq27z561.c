/* SPDX-License-Identifier: MIT
 * TI BQ27Z561 fuel gauge @ 0x55. Dual cells: IC13 left + IC00 right.
 * Combine in dual-fg (CAF weighted SoC, max V, sum I). Design 5000 mAh
 * each, 3.4–4.45 V. Do not hog fg-*-disable GPIO 117/91 high.
 */
#include <ntddk.h>
#include <wdf.h>
#include "../common/dagu-spb.h"

#define BQ_CMD_VOLT     0x08
#define BQ_CMD_CUR      0x0C
#define BQ_CMD_SOC      0x2C
#define BQ_CMD_RM       0x10
#define BQ_CMD_FCC      0x12

typedef struct _FG_CONTEXT {
    DAGU_SPB Spb;
    ULONG Uid;
} FG_CONTEXT, *PFG_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(FG_CONTEXT, FgGetContext)

static NTSTATUS
FgRead16(_In_ PFG_CONTEXT Ctx, _In_ UCHAR Cmd, _Out_ PUSHORT Val)
{
    UCHAR buf[2] = { 0, 0 };
    NTSTATUS s;

    s = DaguSpbXfer(&Ctx->Spb, &Cmd, 1, buf, 2);
    if (!NT_SUCCESS(s))
        return s;
    *Val = (USHORT)(buf[0] | (buf[1] << 8));
    return STATUS_SUCCESS;
}

NTSTATUS
FgSoc(_In_ PFG_CONTEXT Ctx, _Out_ PUSHORT Soc)
{
    return FgRead16(Ctx, BQ_CMD_SOC, Soc);
}

NTSTATUS
DriverEntry(_In_ PDRIVER_OBJECT DriverObject, _In_ PUNICODE_STRING RegistryPath)
{
    UNREFERENCED_PARAMETER(DriverObject);
    UNREFERENCED_PARAMETER(RegistryPath);
    return STATUS_SUCCESS;
}
