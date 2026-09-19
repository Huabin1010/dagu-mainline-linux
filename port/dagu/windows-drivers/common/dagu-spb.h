/* SPDX-License-Identifier: MIT
 * Shared SPB helpers. Microsoft: Connection IDs for SPB-connected peripherals.
 * https://learn.microsoft.com/en-us/windows-hardware/drivers/spb/connection-ids-for-spb-connected-peripheral-devices
 */
#pragma once

#include <ntddk.h>
#include <wdf.h>
#include <spb.h>
#include <reshub.h>

typedef struct _DAGU_SPB {
    WDFIOTARGET Target;
    LARGE_INTEGER ConnectionId;
} DAGU_SPB, *PDAGU_SPB;

static inline NTSTATUS
DaguSpbOpen(_In_ WDFDEVICE Device, _In_ PCM_PARTIAL_RESOURCE_DESCRIPTOR Conn,
            _Out_ PDAGU_SPB Spb)
{
    NTSTATUS status;
    UNICODE_STRING path;
    WCHAR buf[RESOURCE_HUB_PATH_SIZE];
    WDF_IO_TARGET_OPEN_PARAMS open;

    RtlZeroMemory(Spb, sizeof(*Spb));
    Spb->ConnectionId.LowPart = Conn->u.Connection.IdLowPart;
    Spb->ConnectionId.HighPart = Conn->u.Connection.IdHighPart;

    RtlInitEmptyUnicodeString(&path, buf, sizeof(buf));
    status = RESOURCE_HUB_CREATE_PATH_FROM_ID(&path,
                                              Spb->ConnectionId.LowPart,
                                              Spb->ConnectionId.HighPart);
    if (!NT_SUCCESS(status))
        return status;

    status = WdfIoTargetCreate(Device, WDF_NO_OBJECT_ATTRIBUTES, &Spb->Target);
    if (!NT_SUCCESS(status))
        return status;

    WDF_IO_TARGET_OPEN_PARAMS_INIT_OPEN_BY_NAME(&open, &path,
                                                GENERIC_READ | GENERIC_WRITE);
    return WdfIoTargetOpen(Spb->Target, &open);
}

static inline NTSTATUS
DaguSpbXfer(_In_ PDAGU_SPB Spb, _In_reads_bytes_opt_(TxLen) PVOID Tx,
            _In_ ULONG TxLen, _Out_writes_bytes_opt_(RxLen) PVOID Rx,
            _In_ ULONG RxLen)
{
    SPB_TRANSFER_LIST_AND_ENTRIES(2) list;
    WDF_MEMORY_DESCRIPTOR mem;
    ULONG_PTR done = 0;
    ULONG n = 0;

    if (Tx && TxLen)
        n++;
    if (Rx && RxLen)
        n++;
    if (n == 0)
        return STATUS_INVALID_PARAMETER;

    SPB_TRANSFER_LIST_INIT(&(list.List), n);
    n = 0;
    if (Tx && TxLen) {
        list.List.Transfers[n++] = SPB_TRANSFER_LIST_ENTRY_INIT_SIMPLE(
            SpbTransferDirectionToDevice, 0, Tx, TxLen);
    }
    if (Rx && RxLen) {
        list.List.Transfers[n++] = SPB_TRANSFER_LIST_ENTRY_INIT_SIMPLE(
            SpbTransferDirectionFromDevice, 0, Rx, RxLen);
    }

    WDF_MEMORY_DESCRIPTOR_INIT_BUFFER(&mem, &list, sizeof(list));
    return WdfIoTargetSendIoctlSynchronously(Spb->Target, NULL,
                                             IOCTL_SPB_EXECUTE_SEQUENCE,
                                             &mem, NULL, NULL, &done);
}

static inline NTSTATUS
DaguSpbWrite(_In_ PDAGU_SPB Spb, _In_reads_bytes_(Len) PVOID Buf, _In_ ULONG Len)
{
    return DaguSpbXfer(Spb, Buf, Len, NULL, 0);
}

static inline NTSTATUS
DaguSpbWriteReg(_In_ PDAGU_SPB Spb, _In_ UCHAR Reg, _In_ UCHAR Val)
{
    UCHAR pkt[2] = { Reg, Val };

    return DaguSpbXfer(Spb, pkt, 2, NULL, 0);
}

static inline NTSTATUS
DaguSpbReadReg(_In_ PDAGU_SPB Spb, _In_ UCHAR Reg, _Out_ PUCHAR Val)
{
    return DaguSpbXfer(Spb, &Reg, 1, Val, 1);
}
