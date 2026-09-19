/* SPDX-License-Identifier: MIT
 * Parade PS5169 USB3/DP redriver @ 0x28, EN GPIO69.
 * Init from ps5169-dagu.c (CAF ps5169.c). Linux &i2c17 still disabled;
 * ACPI IC17/RDV0 _STA=0 until SuperSpeed PHY is trained.
 */
#include <ntddk.h>
#include <wdf.h>
#include "../common/dagu-spb.h"

#define PS5169_CHIP_ID_L    0xAC
#define PS5169_CHIP_ID_H    0xAD
#define PS5169_ID_L         0x87
#define PS5169_ID_H         0x69

typedef struct _PS_CONTEXT {
    DAGU_SPB Spb;
} PS_CONTEXT, *PPS_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(PS_CONTEXT, PsGetContext)

NTSTATUS
PsIdentify(_In_ PPS_CONTEXT Ctx)
{
    UCHAR lo = 0, hi = 0;
    NTSTATUS s;

    s = DaguSpbReadReg(&Ctx->Spb, PS5169_CHIP_ID_L, &lo);
    if (!NT_SUCCESS(s))
        return s;
    s = DaguSpbReadReg(&Ctx->Spb, PS5169_CHIP_ID_H, &hi);
    if (!NT_SUCCESS(s))
        return s;
    if (lo != PS5169_ID_L || hi != PS5169_ID_H)
        return STATUS_DEVICE_DOES_NOT_EXIST;
    return STATUS_SUCCESS;
}

NTSTATUS
DriverEntry(_In_ PDRIVER_OBJECT DriverObject, _In_ PUNICODE_STRING RegistryPath)
{
    UNREFERENCED_PARAMETER(DriverObject);
    UNREFERENCED_PARAMETER(RegistryPath);
    return STATUS_SUCCESS;
}
