/* SPDX-License-Identifier: MIT
 * Combine two BQ27Z561 into one BMS. From xiaomi-dual-fg.c:
 * SoC = FCC-weighted; display 100 when RM/FCC > 96%; V = max; I = sum.
 * Design 2x 5000 mAh, 3.4-4.45 V. fg-disable GPIO 117/91 stay inactive.
 */
#include <ntddk.h>
#include <wdf.h>

#define DAGU_SOC_RAW_FULL 9600
#define DAGU_FG_DIS0      117
#define DAGU_FG_DIS1      91

typedef struct _DFG_CONTEXT {
    ULONG Soc;
    ULONG Mv;
} DFG_CONTEXT, *PDFG_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(DFG_CONTEXT, DfgGetContext)

ULONG
DaguDualFgSoc(_In_ ULONG SocL, _In_ ULONG SocR, _In_ ULONG FccL, _In_ ULONG FccR)
{
    ULONG tot = FccL + FccR;

    if (tot == 0)
        return (SocL + SocR) / 2;
    return (FccL * SocL + FccR * SocR + tot / 2) / tot;
}

NTSTATUS
DriverEntry(_In_ PDRIVER_OBJECT DriverObject, _In_ PUNICODE_STRING RegistryPath)
{
    UNREFERENCED_PARAMETER(DriverObject);
    UNREFERENCED_PARAMETER(RegistryPath);
    return STATUS_SUCCESS;
}
