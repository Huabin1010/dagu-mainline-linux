/* SPDX-License-Identifier: MIT
 * CS35L41 I2C identity on dagu. Audio PCM is ADSP, not this driver.
 * Do not use map220v/cs35l41_win (HDA / ACPI\10133541 / x64).
 * DEVID is the Cirrus 0x00003541 family; exact register map stays in
 * the Linux cirrus/cs35l41 driver when we wire firmware load.
 */
#include <ntddk.h>
#include <wdf.h>
#include "../common/dagu-spb.h"

#define CS35L41_DEVID   0x00

typedef struct _CS35_CONTEXT {
    DAGU_SPB Spb;
    UCHAR Id0;
} CS35_CONTEXT, *PCS35_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(CS35_CONTEXT, Cs35GetContext)

NTSTATUS
Cs35Probe(_In_ PCS35_CONTEXT Ctx)
{
    return DaguSpbReadReg(&Ctx->Spb, CS35L41_DEVID, &Ctx->Id0);
}

NTSTATUS
DriverEntry(_In_ PDRIVER_OBJECT DriverObject, _In_ PUNICODE_STRING RegistryPath)
{
    UNREFERENCED_PARAMETER(DriverObject);
    UNREFERENCED_PARAMETER(RegistryPath);
    return STATUS_SUCCESS;
}
