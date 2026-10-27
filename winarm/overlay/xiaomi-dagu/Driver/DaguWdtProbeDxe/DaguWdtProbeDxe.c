/** @file
  dagu: read-only probe of the APSS (application processor subsystem)
  watchdog at 0x17c10000.

  HyperOS ABL leaves the KPSS watchdog armed (Linux has to stretch it in
  early_initcall or the board bites back to fastboot after ~6 s). Windows
  has no driver for ACPI QCOM24E2, so if the watchdog is still armed when
  QcomWDogDxe is done at ExitBootServices, nothing pets it and the SoC
  resets a few seconds into Windows.

  This driver only reads. It logs the enable / bark / bite / status
  registers at driver start and from two ExitBootServices handlers (one at
  TPL_NOTIFY, one at TPL_CALLBACK). Same-TPL handlers run in creation order
  and this driver loads after QcomWDogDxe, so the TPL that matches
  QcomWDogDxe's shows the state it leaves behind. Compare the lines with
  "driver start" to see whether the watchdog was changed. No write, no
  pet, no disable.

  Registers (qcom,kpss-wdt, see Linux drivers/watchdog/qcom-wdt.c):
    0x04 RST, 0x08 EN, 0x0c STS, 0x10 BARK_TIME, 0x14 BITE_TIME.
  Sleep clock is 32764 Hz, so ticks / 32764 = seconds.

  SPDX-License-Identifier: BSD-2-Clause-Patent
**/
#include <Uefi.h>
#include <Library/DebugLib.h>
#include <Library/IoLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiDriverEntryPoint.h>

#define APSS_WDT_BASE   0x17C10000UL
#define WDT_RST         0x04
#define WDT_EN          0x08
#define WDT_STS         0x0C
#define WDT_BARK_TIME   0x10
#define WDT_BITE_TIME   0x14
#define SLEEP_HZ        32764U

STATIC VOID
LogWdt (
  IN CONST CHAR8  *Tag
  )
{
  UINT32  En   = MmioRead32 (APSS_WDT_BASE + WDT_EN);
  UINT32  Sts  = MmioRead32 (APSS_WDT_BASE + WDT_STS);
  UINT32  Bark = MmioRead32 (APSS_WDT_BASE + WDT_BARK_TIME);
  UINT32  Bite = MmioRead32 (APSS_WDT_BASE + WDT_BITE_TIME);

  DEBUG ((
    DEBUG_ERROR,
    "DaguWdt %a: EN %u STS %08x BARK %u (%u ms) BITE %u (%u ms)\n",
    Tag, En, Sts, Bark, (UINT32)(((UINT64)Bark * 1000) / SLEEP_HZ),
    Bite, (UINT32)(((UINT64)Bite * 1000) / SLEEP_HZ)
    ));
}

STATIC VOID
EFIAPI
BeforeExitBs (
  IN EFI_EVENT  Event,
  IN VOID       *Context
  )
{
  LogWdt ("ExitBS at TPL_NOTIFY");
}

STATIC VOID
EFIAPI
AfterExitBs (
  IN EFI_EVENT  Event,
  IN VOID       *Context
  )
{
  LogWdt ("ExitBS at TPL_CALLBACK");
}

EFI_STATUS
EFIAPI
DaguWdtProbeDxeInitialize (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
  EFI_EVENT   Event;
  EFI_STATUS  Status;

  LogWdt ("driver start");

  Status = gBS->CreateEventEx (
                  EVT_NOTIFY_SIGNAL,
                  TPL_NOTIFY,
                  BeforeExitBs,
                  NULL,
                  &gEfiEventExitBootServicesGuid,
                  &Event
                  );
  if (EFI_ERROR (Status)) {
    DEBUG ((DEBUG_ERROR, "DaguWdt: notify event %r\n", Status));
  }

  Status = gBS->CreateEventEx (
                  EVT_NOTIFY_SIGNAL,
                  TPL_CALLBACK,
                  AfterExitBs,
                  NULL,
                  &gEfiEventExitBootServicesGuid,
                  &Event
                  );
  if (EFI_ERROR (Status)) {
    DEBUG ((DEBUG_ERROR, "DaguWdt: callback event %r\n", Status));
  }

  return EFI_SUCCESS;
}
