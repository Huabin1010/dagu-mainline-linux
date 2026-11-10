/** @file
  Hand the Type-C controller to kernel-debug networking.

  Installs one Debug Port Table 2 entry for the Synopsys USB3 controller
  at 0x0A600000 (interrupt 165 lives in the companion SSDT, not in DBG2)
  and a minimal \_SB.URS0, because the Windows DSDT built with the default
  DSDT_ONLY set does not include usb.asl. At ExitBootServices the driver
  calls EFI_USBFN_IO_PROTOCOL.StopController so UsbfnDwc3Dxe does not keep
  the port. It does not touch DWC3 registers and it does not implement
  Ethernet Emulation.

  SPDX-License-Identifier: BSD-2-Clause-Patent
**/
#include <Uefi.h>
#include <Guid/EventGroup.h>
#include <Protocol/AcpiTable.h>
#include <Protocol/UsbFunctionIo.h>
#include <Library/BaseMemoryLib.h>
#include <Library/DebugLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiDriverEntryPoint.h>

STATIC CONST UINT8  mDbg2[] = {
  #include "Dbg2.inc"
};

STATIC CONST UINT8  mUrs0Ssdt[] = {
  #include "Urs0Ssdt.inc"
};

STATIC
VOID
EFIAPI
DaguKdnetExitBoot (
  IN EFI_EVENT  Event,
  IN VOID       *Context
  )
{
  EFI_STATUS              Status;
  EFI_USBFN_IO_PROTOCOL   *UsbFn;

  (VOID)Event;
  (VOID)Context;

  Status = gBS->LocateProtocol (
                  &gEfiUsbFunctionIoProtocolGuid,
                  NULL,
                  (VOID **)&UsbFn
                  );
  if (EFI_ERROR (Status) || UsbFn == NULL || UsbFn->StopController == NULL) {
    DEBUG ((DEBUG_ERROR, "DaguKdnet: UsbFn not stopped (%r)\n", Status));
    return;
  }

  Status = UsbFn->StopController (UsbFn);
  DEBUG ((DEBUG_ERROR, "DaguKdnet: UsbFn StopController %r\n", Status));
}

STATIC
VOID
DaguKdnetPublish (
  VOID
  )
{
  EFI_STATUS                   Status;
  EFI_ACPI_TABLE_PROTOCOL      *Acpi;
  UINTN                        Key;

  Status = gBS->LocateProtocol (
                  &gEfiAcpiTableProtocolGuid,
                  NULL,
                  (VOID **)&Acpi
                  );
  if (EFI_ERROR (Status)) {
    DEBUG ((DEBUG_ERROR, "DaguKdnet: no ACPI table protocol %r\n", Status));
    return;
  }

  Status = Acpi->InstallAcpiTable (Acpi, (VOID *)mDbg2, sizeof (mDbg2), &Key);
  DEBUG ((DEBUG_ERROR, "DaguKdnet: DBG2 (%u bytes) %r\n", (UINT32)sizeof (mDbg2), Status));
  Status = Acpi->InstallAcpiTable (Acpi, (VOID *)mUrs0Ssdt, sizeof (mUrs0Ssdt), &Key);
  DEBUG ((DEBUG_ERROR, "DaguKdnet: URS0 SSDT (%u bytes) %r\n", (UINT32)sizeof (mUrs0Ssdt), Status));
}

EFI_STATUS
EFIAPI
DaguKdnetDxeInitialize (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
  EFI_STATUS  Status;
  EFI_EVENT   ExitEvent;

  (VOID)ImageHandle;
  (VOID)SystemTable;

  DEBUG ((DEBUG_ERROR, "\n=== DAGU KDNET / URS0 ===\n"));
  DaguKdnetPublish ();

  Status = gBS->CreateEventEx (
                  EVT_NOTIFY_SIGNAL,
                  TPL_CALLBACK,
                  DaguKdnetExitBoot,
                  NULL,
                  &gEfiEventExitBootServicesGuid,
                  &ExitEvent
                  );
  if (EFI_ERROR (Status)) {
    DEBUG ((DEBUG_ERROR, "DaguKdnet: ExitBootServices event %r\n", Status));
  }

  return EFI_SUCCESS;
}
