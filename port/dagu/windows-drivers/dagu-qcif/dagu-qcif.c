/* SPDX-License-Identifier: MIT
 * dagu-qcif: publish the device interfaces qcdx waits on after SMMU setup.
 *
 * FUN_14029ba78, on the success path past the SMMU callbacks, calls
 * FUN_14029ac00 then FUN_14029ae70. Each one registers for a device
 * interface and KeWaitForSingleObject's for 30000 ms (qcdx RVA 0x284e38,
 * timeout = milliseconds * -10000). A timeout returns 0xC0000001, and
 * DxgkDdiStartDevice fails with that status about 31 s after PnP start
 * (DxgKrnl event 549, StartAdapter_DdiStartDeviceFailed).
 *
 * The first GUID is the SCM interface qcscm8250.sys publishes
 * ({41c66d2a-a9f1-40ca-a329-ae096c03ee68}). The next three are TrEE
 * secure services from QcTrEE8250.inf: PassThrough, WinSecApp, MemSharing.
 * None of those ACPI nodes (QCOM250B / QCOM2576) exist on dagu, so the
 * interfaces never arrive.
 *
 * Arrival only has to let FUN_140285988 open the link and set the event.
 * The follow-up version query (0xC3514100, then 0xC35140D4) treats
 * STATUS_INVALID_DEVICE_REQUEST as "this version is not implemented" and
 * continues. A real SCM/TrEE stack would answer that query; this driver
 * does not issue SMCs and does not touch either SMMU.
 */
#include <ntddk.h>

#define IFACE_COUNT 4

static const GUID kScm = {
    0x41C66D2A, 0xA9F1, 0x40CA, { 0xA3, 0x29, 0xAE, 0x09, 0x6C, 0x03, 0xEE, 0x68 }
};
static const GUID kTreePass = {
    0xAE865C08, 0x4A07, 0x404D, { 0xBE, 0x51, 0xD9, 0xA0, 0x46, 0x5E, 0x23, 0xE5 }
};
static const GUID kTreeWinsec = {
    0x16A1AB50, 0x7413, 0x4875, { 0x89, 0x3D, 0x2E, 0x5A, 0xA0, 0xB7, 0x98, 0x88 }
};
static const GUID kTreeMem = {
    0xEB3C7242, 0x1B1A, 0x4D51, { 0xAB, 0x55, 0xF2, 0x68, 0xF0, 0x18, 0xF8, 0x60 }
};

typedef struct _QCIF_EXT {
    PDEVICE_OBJECT Lower;
    PDEVICE_OBJECT Pdo;
    UNICODE_STRING Link[IFACE_COUNT];
    BOOLEAN Started;
} QCIF_EXT, *PQCIF_EXT;

static HANDLE gKey;

static VOID
Put(PCWSTR name, ULONG v)
{
    UNICODE_STRING n;

    if (!gKey || KeGetCurrentIrql() != PASSIVE_LEVEL)
        return;
    RtlInitUnicodeString(&n, name);
    ZwSetValueKey(gKey, &n, 0, REG_DWORD, &v, sizeof(v));
}

static VOID
Step(ULONG s)
{
    Put(L"step", s);
    if (gKey && KeGetCurrentIrql() == PASSIVE_LEVEL)
        ZwFlushKey(gKey);
}

static NTSTATUS
SyncComplete(PDEVICE_OBJECT dev, PIRP irp, PVOID ctx)
{
    UNREFERENCED_PARAMETER(dev);
    UNREFERENCED_PARAMETER(irp);
    KeSetEvent((PKEVENT)ctx, IO_NO_INCREMENT, FALSE);
    return STATUS_MORE_PROCESSING_REQUIRED;
}

static NTSTATUS
ForwardAndWait(PDEVICE_OBJECT dev, PIRP irp)
{
    KEVENT ev;
    NTSTATUS st;
    PQCIF_EXT ext = dev->DeviceExtension;

    KeInitializeEvent(&ev, NotificationEvent, FALSE);
    IoCopyCurrentIrpStackLocationToNext(irp);
    IoSetCompletionRoutine(irp, SyncComplete, &ev, TRUE, TRUE, TRUE);
    st = IoCallDriver(ext->Lower, irp);
    if (st == STATUS_PENDING) {
        KeWaitForSingleObject(&ev, Executive, KernelMode, FALSE, NULL);
        st = irp->IoStatus.Status;
    }
    return st;
}

static NTSTATUS
Publish(PQCIF_EXT ext)
{
    const GUID *guids[IFACE_COUNT];
    ULONG i;
    NTSTATUS st;

    guids[0] = &kScm;
    guids[1] = &kTreePass;
    guids[2] = &kTreeWinsec;
    guids[3] = &kTreeMem;
    for (i = 0; i < IFACE_COUNT; i++) {
        st = IoRegisterDeviceInterface(ext->Pdo, guids[i], NULL, &ext->Link[i]);
        if (!NT_SUCCESS(st)) {
            Put(L"regif", st);
            Put(L"which", i);
            Step(0x31);
            return st;
        }
        st = IoSetDeviceInterfaceState(&ext->Link[i], TRUE);
        if (!NT_SUCCESS(st)) {
            Put(L"enif", st);
            Put(L"which", i);
            Step(0x32);
            return st;
        }
    }
    ext->Started = TRUE;
    Step(0x30);
    return STATUS_SUCCESS;
}

static VOID
Drop(PQCIF_EXT ext)
{
    ULONG i;

    for (i = 0; i < IFACE_COUNT; i++) {
        if (ext->Link[i].Buffer) {
            IoSetDeviceInterfaceState(&ext->Link[i], FALSE);
            RtlFreeUnicodeString(&ext->Link[i]);
        }
    }
    ext->Started = FALSE;
}

static LONG gCreates;

static NTSTATUS
DispatchOk(PDEVICE_OBJECT dev, PIRP irp)
{
    UNREFERENCED_PARAMETER(dev);
    Put(L"creates", (ULONG)InterlockedIncrement(&gCreates));
    irp->IoStatus.Status = STATUS_SUCCESS;
    irp->IoStatus.Information = 0;
    IoCompleteRequest(irp, IO_NO_INCREMENT);
    return STATUS_SUCCESS;
}

static NTSTATUS
DispatchReject(PDEVICE_OBJECT dev, PIRP irp)
{
    PIO_STACK_LOCATION sp = IoGetCurrentIrpStackLocation(irp);

    UNREFERENCED_PARAMETER(dev);
    /* 0xC0000010. qcdx treats this as "interface version not implemented"
     * and goes on, for both 0xC3514100 and the older 0xC35140D4.
     * IRP_MN_QUERY_INTERFACE must not be failed here: WdfIoTargetOpen sends
     * one while opening the link, and failing it aborts the open before the
     * version query. That one is passed down. */
    if (sp->MajorFunction == IRP_MJ_DEVICE_CONTROL ||
        sp->MajorFunction == IRP_MJ_INTERNAL_DEVICE_CONTROL)
        Put(L"ioctl", sp->Parameters.DeviceIoControl.IoControlCode);
    irp->IoStatus.Status = STATUS_INVALID_DEVICE_REQUEST;
    irp->IoStatus.Information = 0;
    IoCompleteRequest(irp, IO_NO_INCREMENT);
    return STATUS_INVALID_DEVICE_REQUEST;
}

static NTSTATUS
DispatchPass(PDEVICE_OBJECT dev, PIRP irp)
{
    PQCIF_EXT ext = dev->DeviceExtension;

    IoSkipCurrentIrpStackLocation(irp);
    return IoCallDriver(ext->Lower, irp);
}

static NTSTATUS
DispatchPower(PDEVICE_OBJECT dev, PIRP irp)
{
    PQCIF_EXT ext = dev->DeviceExtension;

    PoStartNextPowerIrp(irp);
    IoSkipCurrentIrpStackLocation(irp);
    return PoCallDriver(ext->Lower, irp);
}

static NTSTATUS
DispatchPnp(PDEVICE_OBJECT dev, PIRP irp)
{
    PQCIF_EXT ext = dev->DeviceExtension;
    PIO_STACK_LOCATION sp = IoGetCurrentIrpStackLocation(irp);
    NTSTATUS st;

    switch (sp->MinorFunction) {
    case IRP_MN_START_DEVICE:
        st = ForwardAndWait(dev, irp);
        if (NT_SUCCESS(st))
            st = Publish(ext);
        irp->IoStatus.Status = st;
        IoCompleteRequest(irp, IO_NO_INCREMENT);
        return st;
    case IRP_MN_QUERY_INTERFACE:
        if (sp->Parameters.QueryInterface.InterfaceType)
            Put(L"qguid", sp->Parameters.QueryInterface.InterfaceType->Data1);
        Put(L"qsize", sp->Parameters.QueryInterface.Size);
        return DispatchPass(dev, irp);
    case IRP_MN_REMOVE_DEVICE:
        Drop(ext);
        IoSkipCurrentIrpStackLocation(irp);
        st = IoCallDriver(ext->Lower, irp);
        IoDetachDevice(ext->Lower);
        IoDeleteDevice(dev);
        Step(0x70);
        return st;
    default:
        return DispatchPass(dev, irp);
    }
}

static NTSTATUS
AddDevice(PDRIVER_OBJECT drv, PDEVICE_OBJECT pdo)
{
    PDEVICE_OBJECT fdo = NULL;
    PQCIF_EXT ext;
    NTSTATUS st;

    st = IoCreateDevice(drv, sizeof(QCIF_EXT), NULL, FILE_DEVICE_UNKNOWN,
                        FILE_DEVICE_SECURE_OPEN, FALSE, &fdo);
    if (!NT_SUCCESS(st))
        return st;
    ext = fdo->DeviceExtension;
    RtlZeroMemory(ext, sizeof(*ext));
    ext->Pdo = pdo;
    ext->Lower = IoAttachDeviceToDeviceStack(fdo, pdo);
    if (!ext->Lower) {
        IoDeleteDevice(fdo);
        Step(0x21);
        return STATUS_NO_SUCH_DEVICE;
    }
    fdo->Flags |= DO_BUFFERED_IO | DO_POWER_PAGABLE;
    fdo->Flags &= ~DO_DEVICE_INITIALIZING;
    Step(0x20);
    return STATUS_SUCCESS;
}

static VOID
Unload(PDRIVER_OBJECT drv)
{
    UNREFERENCED_PARAMETER(drv);
    if (gKey) {
        ZwClose(gKey);
        gKey = NULL;
    }
}

static VOID
OpenParams(PUNICODE_STRING reg)
{
    OBJECT_ATTRIBUTES oa;
    UNICODE_STRING sub;
    HANDLE svc;
    ULONG disp;

    InitializeObjectAttributes(&oa, reg, OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE, NULL, NULL);
    if (!NT_SUCCESS(ZwOpenKey(&svc, KEY_CREATE_SUB_KEY, &oa)))
        return;
    RtlInitUnicodeString(&sub, L"Parameters");
    InitializeObjectAttributes(&oa, &sub, OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE, svc, NULL);
    ZwCreateKey(&gKey, KEY_SET_VALUE | KEY_QUERY_VALUE, &oa, 0, NULL, REG_OPTION_NON_VOLATILE, &disp);
    ZwClose(svc);
}

NTSTATUS
DriverEntry(PDRIVER_OBJECT drv, PUNICODE_STRING reg)
{
    ULONG i;

    OpenParams(reg);
    Step(0x10);
    drv->DriverExtension->AddDevice = AddDevice;
    drv->DriverUnload = Unload;
    for (i = 0; i <= IRP_MJ_MAXIMUM_FUNCTION; i++)
        drv->MajorFunction[i] = DispatchPass;
    drv->MajorFunction[IRP_MJ_PNP] = DispatchPnp;
    drv->MajorFunction[IRP_MJ_POWER] = DispatchPower;
    drv->MajorFunction[IRP_MJ_CREATE] = DispatchOk;
    drv->MajorFunction[IRP_MJ_CLOSE] = DispatchOk;
    drv->MajorFunction[IRP_MJ_CLEANUP] = DispatchOk;
    drv->MajorFunction[IRP_MJ_DEVICE_CONTROL] = DispatchReject;
    drv->MajorFunction[IRP_MJ_INTERNAL_DEVICE_CONTROL] = DispatchReject;
    return STATUS_SUCCESS;
}
