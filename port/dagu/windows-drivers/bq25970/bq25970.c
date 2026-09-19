/* SPDX-License-Identifier: MIT
 * TI BQ25970 / SC8551. From bq2597x-dagu.c + TI SLUAA33.
 * PPS policy stays in TCPM / userspace. This chip is the switched-cap pump.
 * Device ID @ 0x13: BQ25970=0x10, SC8551=0x00, SC8551A=0x51.
 */
#include <ntddk.h>
#include <wdf.h>
#include "../common/dagu-spb.h"

#define BQ2597X_REG_0C      0x0C
#define BQ2597X_CHG_EN      0x80
#define BQ2597X_REG_13      0x13
#define BQ25970_DEVICE_ID   0x10

typedef struct _BQ_CONTEXT {
    DAGU_SPB Spb;
    BOOLEAN Master;
    UCHAR ChipId;
} BQ_CONTEXT, *PBQ_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(BQ_CONTEXT, BqGetContext)

NTSTATUS
BqIdentify(_In_ PBQ_CONTEXT Ctx)
{
    return DaguSpbReadReg(&Ctx->Spb, BQ2597X_REG_13, &Ctx->ChipId);
}

NTSTATUS
BqSetCharge(_In_ PBQ_CONTEXT Ctx, _In_ BOOLEAN On)
{
    UCHAR v = 0;
    NTSTATUS s;

    s = DaguSpbReadReg(&Ctx->Spb, BQ2597X_REG_0C, &v);
    if (!NT_SUCCESS(s))
        return s;
    if (On)
        v |= BQ2597X_CHG_EN;
    else
        v &= (UCHAR)~BQ2597X_CHG_EN;
    return DaguSpbWriteReg(&Ctx->Spb, BQ2597X_REG_0C, v);
}

BOOLEAN
BqChargeOn(_In_ PBQ_CONTEXT Ctx)
{
    UCHAR v = 0;

    if (!NT_SUCCESS(DaguSpbReadReg(&Ctx->Spb, BQ2597X_REG_0C, &v)))
        return FALSE;
    return (v & BQ2597X_CHG_EN) != 0;
}

NTSTATUS
DriverEntry(_In_ PDRIVER_OBJECT DriverObject, _In_ PUNICODE_STRING RegistryPath)
{
    UNREFERENCED_PARAMETER(DriverObject);
    UNREFERENCED_PARAMETER(RegistryPath);
    return STATUS_SUCCESS;
}
