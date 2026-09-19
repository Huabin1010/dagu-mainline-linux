/* SPDX-License-Identifier: MIT
 * IDT/Renesas P9418 Smart Pen TX. From p9418-dagu.c.
 * Side-rail coil, not tablet Qi. ONLINE = GPIO145 det.
 * I2C 0x3b; IRQ GPIO113. Linux product path was i2c-gpio se8;
 * ACPI now describes CAF GENI i2c8 so Windows SPB can attach.
 */
#include <ntddk.h>
#include <wdf.h>
#include "../common/dagu-spb.h"

typedef struct _P9418_CONTEXT {
    DAGU_SPB Spb;
    WDFINTERRUPT Irq;
    BOOLEAN Present;
} P9418_CONTEXT, *PP9418_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(P9418_CONTEXT, P9418GetContext)

BOOLEAN
P9418Online(_In_ PP9418_CONTEXT Ctx)
{
    return Ctx->Present;
}

static BOOLEAN
P9418EvtIsr(_In_ WDFINTERRUPT Interrupt, _In_ ULONG MessageID)
{
    UNREFERENCED_PARAMETER(MessageID);
    WdfInterruptQueueDpcForIsr(Interrupt);
    return TRUE;
}

static VOID
P9418EvtDpc(_In_ WDFINTERRUPT Interrupt, _In_ WDFOBJECT AssociatedObject)
{
    UNREFERENCED_PARAMETER(AssociatedObject);
    UNREFERENCED_PARAMETER(Interrupt);
    /* Re-read det GPIO in PrepareHardware GPIO resource; flip Present. */
}

NTSTATUS
DriverEntry(_In_ PDRIVER_OBJECT DriverObject, _In_ PUNICODE_STRING RegistryPath)
{
    UNREFERENCED_PARAMETER(DriverObject);
    UNREFERENCED_PARAMETER(RegistryPath);
    return STATUS_SUCCESS;
}
