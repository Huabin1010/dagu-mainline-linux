/* SPDX-License-Identifier: MIT
 * Dual KTZ8866. Registers from linux-mainline overlay ktz8866.c
 * and upstream drivers/video/backlight/ktz8866.c.
 *
 * BL_CFG1 = 0x52 (clear PWM_ENABLE — Himax PWM duty is 0).
 * Brightness 11-bit in 0x04/0x05. Floor 32. Never drop GPIO139 HWEN.
 */
#include <ntddk.h>
#include <wdf.h>
#include "../common/dagu-spb.h"

#define BL_CFG1         0x02
#define BL_CFG2         0x03
#define BL_BRT_LSB      0x04
#define BL_BRT_MSB      0x05
#define BL_EN           0x08
#define BL_DIMMING      0x14
#define PWM_RAMP_TIME   0x15
#define BL_CFG1_I2C     0x52
#define BL_IFS_CAF      0x91
#define BL_EN_BIT       0x40
#define KTZ_MIN         32
#define KTZ_MAX         2047

typedef struct _KTZ_CONTEXT {
    DAGU_SPB Spb;
    BOOLEAN LedOn;
} KTZ_CONTEXT, *PKTZ_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(KTZ_CONTEXT, KtzGetContext)

NTSTATUS
KtzInit(_In_ PKTZ_CONTEXT Ctx)
{
    NTSTATUS s;

    s = DaguSpbWriteReg(&Ctx->Spb, BL_CFG1, BL_CFG1_I2C);
    if (!NT_SUCCESS(s))
        return s;
    s = DaguSpbWriteReg(&Ctx->Spb, BL_CFG2, (UCHAR)(0x80 | 0x05));
    if (!NT_SUCCESS(s))
        return s;
    s = DaguSpbWriteReg(&Ctx->Spb, PWM_RAMP_TIME, BL_IFS_CAF);
    if (!NT_SUCCESS(s))
        return s;
    s = DaguSpbWriteReg(&Ctx->Spb, BL_DIMMING, 0);
    if (!NT_SUCCESS(s))
        return s;
    /* current-num-sinks = 5 → bits 0..4 + BL_EN */
    return DaguSpbWriteReg(&Ctx->Spb, BL_EN, (UCHAR)(0x1F | BL_EN_BIT));
}

NTSTATUS
KtzSetBrightness(_In_ PKTZ_CONTEXT Ctx, _In_ ULONG Brightness)
{
    NTSTATUS s;

    if (Brightness > KTZ_MAX)
        Brightness = KTZ_MAX;
    if (Brightness < KTZ_MIN)
        Brightness = KTZ_MIN;
    if (!Ctx->LedOn) {
        s = DaguSpbWriteReg(&Ctx->Spb, BL_EN, (UCHAR)(0x1F | BL_EN_BIT));
        if (!NT_SUCCESS(s))
            return s;
        Ctx->LedOn = TRUE;
    }
    s = DaguSpbWriteReg(&Ctx->Spb, BL_BRT_LSB, (UCHAR)(Brightness & 0x07));
    if (!NT_SUCCESS(s))
        return s;
    return DaguSpbWriteReg(&Ctx->Spb, BL_BRT_MSB, (UCHAR)((Brightness >> 3) & 0xFF));
}

NTSTATUS
DriverEntry(_In_ PDRIVER_OBJECT DriverObject, _In_ PUNICODE_STRING RegistryPath)
{
    UNREFERENCED_PARAMETER(DriverObject);
    UNREFERENCED_PARAMETER(RegistryPath);
    return STATUS_SUCCESS;
}
