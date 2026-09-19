/* SPDX-License-Identifier: MIT
 * PM8150B SMB5 5 V path. From pm8150b-charger-dagu.c.
 * APSD/ICL live on SPMI SID2 charger@1000. PPS is BQ25970, not this file.
 */
#include <ntddk.h>
#include <wdf.h>

typedef struct _SMB_CONTEXT {
    BOOLEAN Online;
} SMB_CONTEXT, *PSMB_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(SMB_CONTEXT, SmbGetContext)

NTSTATUS
DriverEntry(_In_ PDRIVER_OBJECT DriverObject, _In_ PUNICODE_STRING RegistryPath)
{
    UNREFERENCED_PARAMETER(DriverObject);
    UNREFERENCED_PARAMETER(RegistryPath);
    return STATUS_SUCCESS;
}
