/* SPDX-License-Identifier: MIT
 * PM8150B LRA @ SPMI 0xC000. Linux: pmi632-vib (same 0x46 enable / 0x40 drive).
 * Vmax 3600 mV. SPMI parent is QCOM0C09, not GENI.
 */
#include <ntddk.h>
#include <wdf.h>

#define VIB_REG_DRIVE   0x40
#define VIB_REG_EN      0x46

typedef struct _VIB_CONTEXT {
    BOOLEAN Armed;
} VIB_CONTEXT, *PVIB_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(VIB_CONTEXT, VibGetContext)

NTSTATUS
DriverEntry(_In_ PDRIVER_OBJECT DriverObject, _In_ PUNICODE_STRING RegistryPath)
{
    UNREFERENCED_PARAMETER(DriverObject);
    UNREFERENCED_PARAMETER(RegistryPath);
    return STATUS_SUCCESS;
}
