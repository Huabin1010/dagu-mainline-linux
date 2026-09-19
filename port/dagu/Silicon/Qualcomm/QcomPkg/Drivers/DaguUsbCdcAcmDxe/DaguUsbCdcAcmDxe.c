/** @file
  Replay the UEFI debug ring over USB CDC-ACM via UsbfnDwc3Dxe.

  Does not program DWC3 CSRs. Does not start Mass Storage.
  VID/PID 0525:a4a7 matches Linux g_serial so the same host tool works.
**/

#include <Library/BaseLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/DaguDebugLog.h>
#include <Library/DebugLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiDriverEntryPoint.h>
#include <Library/UefiLib.h>
#include <IndustryStandard/Usb.h>
#include <Protocol/UsbFunctionIo.h>
#include <Protocol/UsbIo.h>
#include <Uefi.h>

#define DAGU_CDC_VID           0x0525
#define DAGU_CDC_PID           0xA4A7
#define DAGU_CDC_TX_EP         1
#define DAGU_CDC_RX_EP         1
#define DAGU_CDC_PKT           512
#define DAGU_CDC_TICK_MS       20
#define DAGU_USB_REQ_TYPE_MASK 0x60
#define DAGU_CDC_SET_LINE      0x20
#define DAGU_CDC_GET_LINE      0x21
#define DAGU_CDC_SET_CTRL      0x22

#pragma pack(1)
typedef struct {
  UINT32  DwDTERate;
  UINT8   BCharFormat;
  UINT8   BParityType;
  UINT8   BDataBits;
} DAGU_CDC_LINE_CODING;
#pragma pack()

STATIC EFI_USBFN_IO_PROTOCOL  *mUsbFn;
STATIC EFI_EVENT               mTimer;
STATIC BOOLEAN                 mConfigured;
STATIC BOOLEAN                 mTxBusy;
STATIC UINT8                  *mTxBuf;
STATIC UINT8                  *mRxBuf;
STATIC UINTN                   mTxCap;
STATIC DAGU_CDC_LINE_CODING    mLine = { 115200, 0, 0, 8 };

STATIC EFI_USB_DEVICE_DESCRIPTOR mDev = {
  sizeof (EFI_USB_DEVICE_DESCRIPTOR),
  USB_DESC_TYPE_DEVICE,
  0x0200,
  0x02,
  0x00,
  0x00,
  64,
  DAGU_CDC_VID,
  DAGU_CDC_PID,
  0x0100,
  1,
  2,
  3,
  1
};

STATIC EFI_USB_CONFIG_DESCRIPTOR mCfg = {
  sizeof (EFI_USB_CONFIG_DESCRIPTOR),
  USB_DESC_TYPE_CONFIG,
  sizeof (EFI_USB_CONFIG_DESCRIPTOR) +
    sizeof (EFI_USB_INTERFACE_DESCRIPTOR) +
    2 * sizeof (EFI_USB_ENDPOINT_DESCRIPTOR),
  1,
  1,
  0,
  0x80,
  50
};

STATIC EFI_USB_INTERFACE_DESCRIPTOR mIf = {
  sizeof (EFI_USB_INTERFACE_DESCRIPTOR),
  USB_DESC_TYPE_INTERFACE,
  0,
  0,
  2,
  0x02,
  0x02,
  0x01,
  0
};

STATIC EFI_USB_ENDPOINT_DESCRIPTOR mEpIn = {
  sizeof (EFI_USB_ENDPOINT_DESCRIPTOR),
  USB_DESC_TYPE_ENDPOINT,
  (UINT8)(0x80 | DAGU_CDC_TX_EP),
  USB_ENDPOINT_BULK,
  DAGU_CDC_PKT,
  0
};

STATIC EFI_USB_ENDPOINT_DESCRIPTOR mEpOut = {
  sizeof (EFI_USB_ENDPOINT_DESCRIPTOR),
  USB_DESC_TYPE_ENDPOINT,
  DAGU_CDC_RX_EP,
  USB_ENDPOINT_BULK,
  DAGU_CDC_PKT,
  0
};

STATIC EFI_USB_ENDPOINT_DESCRIPTOR *mEps[] = { &mEpIn, &mEpOut };
STATIC EFI_USB_INTERFACE_INFO      mIfInfo;
STATIC EFI_USB_INTERFACE_INFO     *mIfTable[2];
STATIC EFI_USB_CONFIG_INFO         mCfgInfo;
STATIC EFI_USB_CONFIG_INFO        *mCfgTable[2];
STATIC EFI_USB_DEVICE_INFO         mDevInfo;

STATIC
VOID
DaguCdcArmRx (
  VOID
  )
{
  UINTN  Size;

  if (mUsbFn == NULL || mRxBuf == NULL) {
    return;
  }

  Size = mTxCap;
  mUsbFn->Transfer (
            mUsbFn,
            DAGU_CDC_RX_EP,
            EfiUsbEndpointDirectionDeviceRx,
            &Size,
            mRxBuf
            );
}

STATIC
VOID
DaguCdcPumpTx (
  VOID
  )
{
  UINTN  Size;

  if (mUsbFn == NULL || !mConfigured || mTxBusy || mTxBuf == NULL) {
    return;
  }

  Size = DaguDebugLogRead (mTxBuf, mTxCap);
  if (Size == 0) {
    return;
  }

  mTxBusy = TRUE;
  if (EFI_ERROR (mUsbFn->Transfer (
                           mUsbFn,
                           DAGU_CDC_TX_EP,
                           EfiUsbEndpointDirectionDeviceTx,
                           &Size,
                           mTxBuf
                           )))
  {
    mTxBusy = FALSE;
  }
}

STATIC
VOID
DaguCdcHandleSetup (
  IN EFI_USB_DEVICE_REQUEST  *Req
  )
{
  UINTN   Size;
  UINT8   Status[2];
  UINT16  Value;

  if (Req == NULL || mUsbFn == NULL) {
    return;
  }

  Value = Req->Value;
  if (Req->Request == USB_REQ_SET_CONFIG) {
    mConfigured = TRUE;
    DaguCdcArmRx ();
    DaguCdcPumpTx ();
    return;
  }

  /* CDC SET_LINE_CODING / SET_CONTROL_LINE_STATE / GET_LINE_CODING */
  if ((Req->RequestType & DAGU_USB_REQ_TYPE_MASK) == USB_REQ_TYPE_CLASS) {
    mConfigured = TRUE;
    if (Req->Request == DAGU_CDC_SET_LINE && Req->Length >= sizeof (mLine)) {
      Size = sizeof (mLine);
      mUsbFn->Transfer (
                mUsbFn,
                0,
                EfiUsbEndpointDirectionDeviceRx,
                &Size,
                &mLine
                );
      return;
    }

    if (Req->Request == DAGU_CDC_GET_LINE) {
      Size = sizeof (mLine);
      mUsbFn->Transfer (
                mUsbFn,
                0,
                EfiUsbEndpointDirectionDeviceTx,
                &Size,
                &mLine
                );
      return;
    }

    if (Req->Request == DAGU_CDC_SET_CTRL) {
      DaguCdcArmRx ();
      DaguCdcPumpTx ();
      return;
    }
  }

  if (Req->Request == USB_REQ_GET_STATUS) {
    Status[0] = 0;
    Status[1] = 0;
    Size      = 2;
    mUsbFn->Transfer (
              mUsbFn,
              0,
              EfiUsbEndpointDirectionDeviceTx,
              &Size,
              Status
              );
    return;
  }

  (VOID)Value;
}

STATIC
VOID
EFIAPI
DaguCdcTick (
  IN EFI_EVENT  Event,
  IN VOID       *Context
  )
{
  EFI_STATUS                 Status;
  EFI_USBFN_MESSAGE          Msg;
  UINTN                      Size;
  EFI_USBFN_MESSAGE_PAYLOAD  Payload;

  if (mUsbFn == NULL) {
    return;
  }

  for ( ; ;) {
    Size   = sizeof (Payload);
    Status = mUsbFn->EventHandler (mUsbFn, &Msg, &Size, &Payload);
    if (EFI_ERROR (Status) || Msg == EfiUsbMsgNone) {
      break;
    }

    switch (Msg) {
      case EfiUsbMsgSetupPacket:
        DaguCdcHandleSetup (&Payload.udr);
        break;
      case EfiUsbMsgEndpointStatusChangedTx:
        if (Payload.utr.EndpointIndex == DAGU_CDC_TX_EP) {
          mTxBusy = FALSE;
        }
        break;
      case EfiUsbMsgEndpointStatusChangedRx:
        if (Payload.utr.EndpointIndex == DAGU_CDC_RX_EP) {
          DaguCdcArmRx ();
        }
        break;
      case EfiUsbMsgBusEventReset:
      case EfiUsbMsgBusEventDetach:
        mConfigured = FALSE;
        mTxBusy     = FALSE;
        if (mUsbFn != NULL) {
          mUsbFn->AbortTransfer (
                    mUsbFn,
                    DAGU_CDC_TX_EP,
                    EfiUsbEndpointDirectionDeviceTx
                    );
          mUsbFn->AbortTransfer (
                    mUsbFn,
                    DAGU_CDC_RX_EP,
                    EfiUsbEndpointDirectionDeviceRx
                    );
        }
        break;
      case EfiUsbMsgBusEventAttach:
        break;
      default:
        break;
    }
  }

  DaguCdcPumpTx ();
}

STATIC
EFI_STATUS
DaguCdcStart (
  VOID
  )
{
  EFI_STATUS  Status;
  UINT16      Mps;

  mIfInfo.InterfaceDescriptor     = &mIf;
  mIfInfo.EndpointDescriptorTable = mEps;
  mIfTable[0]                     = &mIfInfo;
  mIfTable[1]                     = NULL;
  mCfgInfo.ConfigDescriptor       = &mCfg;
  mCfgInfo.InterfaceInfoTable     = mIfTable;
  mCfgTable[0]                    = &mCfgInfo;
  mCfgTable[1]                    = NULL;
  mDevInfo.DeviceDescriptor       = &mDev;
  mDevInfo.ConfigInfoTable        = mCfgTable;

  Status = mUsbFn->StartController (mUsbFn);
  if (EFI_ERROR (Status) && Status != EFI_ALREADY_STARTED) {
    return Status;
  }

  Status = mUsbFn->GetEndpointMaxPacketSize (
                     mUsbFn,
                     UsbEndpointBulk,
                     UsbBusSpeedHigh,
                     &Mps
                     );
  if (!EFI_ERROR (Status) && Mps != 0) {
    mEpIn.MaxPacketSize  = Mps;
    mEpOut.MaxPacketSize = Mps;
  }

  Status = mUsbFn->ConfigureEnableEndpoints (mUsbFn, &mDevInfo);
  if (EFI_ERROR (Status)) {
    return Status;
  }

  mTxCap = DAGU_CDC_PKT;
  Status = mUsbFn->AllocateTransferBuffer (mUsbFn, mTxCap, (VOID **)&mTxBuf);
  if (EFI_ERROR (Status)) {
    return Status;
  }

  Status = mUsbFn->AllocateTransferBuffer (mUsbFn, mTxCap, (VOID **)&mRxBuf);
  if (EFI_ERROR (Status)) {
    return Status;
  }

  return EFI_SUCCESS;
}

EFI_STATUS
EFIAPI
DaguUsbCdcAcmInitialize (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
  EFI_STATUS  Status;

  (VOID)ImageHandle;
  (VOID)SystemTable;

  DaguDebugLogInit ();
  DaguDebugLogAppend ((CONST UINT8 *)"dagu USB CDC-ACM probe\r\n", 24);

  Status = gBS->LocateProtocol (
                  &gEfiUsbFunctionIoProtocolGuid,
                  NULL,
                  (VOID **)&mUsbFn
                  );
  if (EFI_ERROR (Status)) {
    DEBUG ((DEBUG_ERROR, "dagu CDC-ACM: no UsbfnDwc3 (%r)\n", Status));
    return EFI_SUCCESS;
  }

  Status = DaguCdcStart ();
  if (EFI_ERROR (Status)) {
    DEBUG ((DEBUG_ERROR, "dagu CDC-ACM: start %r\n", Status));
    return EFI_SUCCESS;
  }

  Status = gBS->CreateEvent (
                  EVT_TIMER | EVT_NOTIFY_SIGNAL,
                  TPL_CALLBACK,
                  DaguCdcTick,
                  NULL,
                  &mTimer
                  );
  if (EFI_ERROR (Status)) {
    return Status;
  }

  Status = gBS->SetTimer (
                  mTimer,
                  TimerPeriodic,
                  EFI_TIMER_PERIOD_MILLISECONDS (DAGU_CDC_TICK_MS)
                  );
  DEBUG ((DEBUG_ERROR, "dagu CDC-ACM: 0525:a4a7 on UsbfnDwc3\n"));
  return EFI_SUCCESS;
}
