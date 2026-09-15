/* SimpleFbDxe: Simple FrameBuffer */
#include <Library/BaseLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/CacheMaintenanceLib.h>
#include <Library/DebugLib.h>
#include <Library/DxeServicesTableLib.h>
#include <Library/FrameBufferBltLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/PcdLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiLib.h>
#include <PiDxe.h>
#include <Protocol/GraphicsOutput.h>
#include <Uefi.h>

#define VNBYTES(bpix) (1 << (bpix)) / 8
#define VNBITS(bpix) (1 << (bpix))

#define FB_BITS_PER_PIXEL (32)
#define FB_BYTES_PER_PIXEL (FB_BITS_PER_PIXEL / 8)

enum video_log2_bpp {
  VIDEO_BPP1 = 0,
  VIDEO_BPP2,
  VIDEO_BPP4,
  VIDEO_BPP8,
  VIDEO_BPP16,
  VIDEO_BPP32,
};

typedef struct {
  VENDOR_DEVICE_PATH DisplayDevicePath;
  EFI_DEVICE_PATH    EndDevicePath;
} DISPLAY_DEVICE_PATH;

DISPLAY_DEVICE_PATH mDisplayDevicePath = {
    {{HARDWARE_DEVICE_PATH,
      HW_VENDOR_DP,
      {
          (UINT8)(sizeof(VENDOR_DEVICE_PATH)),
          (UINT8)((sizeof(VENDOR_DEVICE_PATH)) >> 8),
      }},
     EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID},
    {END_DEVICE_PATH_TYPE,
     END_ENTIRE_DEVICE_PATH_SUBTYPE,
     {sizeof(EFI_DEVICE_PATH_PROTOCOL), 0}}};

STATIC FRAME_BUFFER_CONFIGURE *mFrameBufferBltLibConfigure;
STATIC UINTN                   mFrameBufferBltLibConfigureSize;

STATIC UINT32 mPhysWidth;
STATIC UINT32 mPhysHeight;
STATIC UINT32 mVisWidth;
STATIC UINT32 mVisHeight;
STATIC UINT32 mPanelWidth;
STATIC UINT32 mPanelHeight;
STATIC UINT32 mConsoleScale;
STATIC UINT32 mRotation;
STATIC BOOLEAN mUseShadow;
STATIC EFI_GRAPHICS_OUTPUT_BLT_PIXEL *mShadowBuffer;
STATIC UINTN mPhysFrameBufferSize;

STATIC
EFI_STATUS
EFIAPI
DisplayQueryMode(
    IN EFI_GRAPHICS_OUTPUT_PROTOCOL *This, IN UINT32 ModeNumber,
    OUT UINTN *SizeOfInfo, OUT EFI_GRAPHICS_OUTPUT_MODE_INFORMATION **Info);

STATIC
EFI_STATUS
EFIAPI
DisplaySetMode(IN EFI_GRAPHICS_OUTPUT_PROTOCOL *This, IN UINT32 ModeNumber);

STATIC
EFI_STATUS
EFIAPI
DisplayBlt(
    IN EFI_GRAPHICS_OUTPUT_PROTOCOL *This,
    IN EFI_GRAPHICS_OUTPUT_BLT_PIXEL *            BltBuffer,
    OPTIONAL IN EFI_GRAPHICS_OUTPUT_BLT_OPERATION BltOperation,
    IN UINTN SourceX, IN UINTN SourceY, IN UINTN DestinationX,
    IN UINTN DestinationY, IN UINTN Width, IN UINTN Height,
    IN UINTN Delta OPTIONAL);

STATIC EFI_GRAPHICS_OUTPUT_PROTOCOL mDisplay = {
    DisplayQueryMode, DisplaySetMode, DisplayBlt, NULL};

STATIC
VOID
SyncShadowRegionToPhysical(
    IN UINTN RegionX, IN UINTN RegionY, IN UINTN RegionW, IN UINTN RegionH)
{
  EFI_GRAPHICS_OUTPUT_BLT_PIXEL *Physical;
  EFI_GRAPHICS_OUTPUT_BLT_PIXEL *Shadow;
  UINTN                          EndX;
  UINTN                          EndY;
  UINTN                          Lx;
  UINTN                          Ly;
  UINT32                         Px;
  UINT32                         Py;
  UINT32                         MinPx;
  UINT32                         MaxPx;
  UINT32                         MinPy;
  UINT32                         MaxPy;

  if (!mUseShadow || mShadowBuffer == NULL || RegionW == 0 || RegionH == 0) {
    return;
  }

  if (RegionX >= mVisWidth || RegionY >= mVisHeight) {
    return;
  }

  EndX = RegionX + RegionW;
  EndY = RegionY + RegionH;
  if (EndX > mVisWidth) {
    EndX = mVisWidth;
  }
  if (EndY > mVisHeight) {
    EndY = mVisHeight;
  }

  Physical = (EFI_GRAPHICS_OUTPUT_BLT_PIXEL *)(UINTN)mDisplay.Mode->FrameBufferBase;
  Shadow   = mShadowBuffer;

  if (mRotation == 90) {
    UINTN PanelX;
    UINTN PanelX0;
    UINTN PanelX1;
    UINTN PanelY;
    UINTN PanelY0;
    UINTN PanelY1;

    PanelX0 = RegionX * mPanelWidth / mVisWidth;
    PanelX1 = (EndX * mPanelWidth + mVisWidth - 1) / mVisWidth;
    PanelY0 = RegionY * mPanelHeight / mVisHeight;
    PanelY1 = (EndY * mPanelHeight + mVisHeight - 1) / mVisHeight;

    MinPx = mPhysWidth - 1 - (UINT32)(PanelY1 - 1);
    MaxPx = mPhysWidth - 1 - (UINT32)PanelY0;
    MinPy = (UINT32)PanelX0;
    MaxPy = (UINT32)(PanelX1 - 1);
    for (PanelY = PanelY0; PanelY < PanelY1; PanelY++) {
      Ly = PanelY * mVisHeight / mPanelHeight;
      for (PanelX = PanelX0; PanelX < PanelX1; PanelX++) {
        Lx = PanelX * mVisWidth / mPanelWidth;
        Px = mPhysWidth - 1 - (UINT32)PanelY;
        Py = (UINT32)PanelX;
        Physical[Py * mPhysWidth + Px] = Shadow[Ly * mVisWidth + Lx];
      }
    }
  } else if (mRotation == 270) {
    MinPx = (UINT32)RegionY;
    MaxPx = (UINT32)(EndY - 1);
    MinPy = mPhysHeight - 1 - (UINT32)(EndX - 1);
    MaxPy = mPhysHeight - 1 - (UINT32)RegionX;
    for (Ly = RegionY; Ly < EndY; Ly++) {
      for (Lx = RegionX; Lx < EndX; Lx++) {
        Px = (UINT32)Ly;
        Py = mPhysHeight - 1 - (UINT32)Lx;
        Physical[Py * mPhysWidth + Px] = Shadow[Ly * mVisWidth + Lx];
      }
    }
  } else if (mRotation == 180) {
    MinPx = mVisWidth - (UINT32)EndX;
    MaxPx = mVisWidth - 1 - (UINT32)RegionX;
    MinPy = mVisHeight - (UINT32)EndY;
    MaxPy = mVisHeight - 1 - (UINT32)RegionY;
    for (Ly = RegionY; Ly < EndY; Ly++) {
      for (Lx = RegionX; Lx < EndX; Lx++) {
        Px = mVisWidth - 1 - (UINT32)Lx;
        Py = mVisHeight - 1 - (UINT32)Ly;
        Physical[Py * mPhysWidth + Px] = Shadow[Ly * mVisWidth + Lx];
      }
    }
  } else {
    MinPx = 0;
    MaxPx = mVisWidth - 1;
    MinPy = (UINT32)RegionY;
    MaxPy = (UINT32)(EndY - 1);
    for (Ly = RegionY; Ly < EndY; Ly++) {
      CopyMem(
          &Physical[Ly * mPhysWidth + RegionX],
          &Shadow[Ly * mVisWidth + RegionX],
          (EndX - RegionX) * sizeof(*Shadow));
    }
  }

  for (Py = MinPy; Py <= MaxPy; Py++) {
    WriteBackInvalidateDataCacheRange(
        (VOID *)&Physical[Py * mPhysWidth + MinPx],
        (MaxPx - MinPx + 1) * sizeof(*Physical));
  }
}

STATIC
VOID
SyncShadowToPhysical(VOID)
{
  SyncShadowRegionToPhysical(0, 0, mVisWidth, mVisHeight);
}

STATIC
EFI_STATUS
EFIAPI
DisplayQueryMode(
    IN EFI_GRAPHICS_OUTPUT_PROTOCOL *This, IN UINT32 ModeNumber,
    OUT UINTN *SizeOfInfo, OUT EFI_GRAPHICS_OUTPUT_MODE_INFORMATION **Info)
{
  EFI_STATUS Status;
  Status = gBS->AllocatePool(
      EfiBootServicesData, sizeof(EFI_GRAPHICS_OUTPUT_MODE_INFORMATION),
      (VOID **)Info);

  ASSERT_EFI_ERROR(Status);

  *SizeOfInfo                   = sizeof(EFI_GRAPHICS_OUTPUT_MODE_INFORMATION);
  (*Info)->Version              = This->Mode->Info->Version;
  (*Info)->HorizontalResolution = This->Mode->Info->HorizontalResolution;
  (*Info)->VerticalResolution   = This->Mode->Info->VerticalResolution;
  (*Info)->PixelFormat          = This->Mode->Info->PixelFormat;
  (*Info)->PixelsPerScanLine    = This->Mode->Info->PixelsPerScanLine;

  return EFI_SUCCESS;
}

STATIC
EFI_STATUS
EFIAPI
DisplaySetMode(IN EFI_GRAPHICS_OUTPUT_PROTOCOL *This, IN UINT32 ModeNumber)
{
  return EFI_SUCCESS;
}

STATIC
EFI_STATUS
EFIAPI
DisplayBlt(
    IN EFI_GRAPHICS_OUTPUT_PROTOCOL *This,
    IN EFI_GRAPHICS_OUTPUT_BLT_PIXEL *            BltBuffer,
    OPTIONAL IN EFI_GRAPHICS_OUTPUT_BLT_OPERATION BltOperation,
    IN UINTN SourceX, IN UINTN SourceY, IN UINTN DestinationX,
    IN UINTN DestinationY, IN UINTN Width, IN UINTN Height,
    IN UINTN Delta OPTIONAL)
{
  RETURN_STATUS Status;
  EFI_TPL       Tpl;
  VOID         *BltTarget;

  Tpl = gBS->RaiseTPL(TPL_NOTIFY);

  if (mUseShadow) {
    BltTarget = (VOID *)mShadowBuffer;
  } else {
    BltTarget = (VOID *)(UINTN)mDisplay.Mode->FrameBufferBase;
  }

  Status = FrameBufferBlt(
      mFrameBufferBltLibConfigure, BltBuffer, BltOperation, SourceX, SourceY,
      DestinationX, DestinationY, Width, Height, Delta);
  gBS->RestoreTPL(Tpl);

  if (RETURN_ERROR(Status)) {
    return EFI_INVALID_PARAMETER;
  }

  if (mUseShadow) {
    SyncShadowRegionToPhysical(DestinationX, DestinationY, Width, Height);
  } else {
    WriteBackInvalidateDataCacheRange(
        (VOID *)(UINTN)mDisplay.Mode->FrameBufferBase,
        mDisplay.Mode->FrameBufferSize);
  }

  return EFI_SUCCESS;
}

STATIC
EFI_STATUS
ConfigureFrameBufferBlt(
    IN VOID *FrameBuffer, IN EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *Info)
{
  EFI_STATUS Status;

  Status = FrameBufferBltConfigure(
      FrameBuffer, Info, mFrameBufferBltLibConfigure,
      &mFrameBufferBltLibConfigureSize);
  if (Status == RETURN_BUFFER_TOO_SMALL) {
    mFrameBufferBltLibConfigure = AllocatePool(mFrameBufferBltLibConfigureSize);
    if (mFrameBufferBltLibConfigure == NULL) {
      return EFI_OUT_OF_RESOURCES;
    }
    Status = FrameBufferBltConfigure(
        FrameBuffer, Info, mFrameBufferBltLibConfigure,
        &mFrameBufferBltLibConfigureSize);
  }

  return Status;
}

EFI_STATUS
EFIAPI
SimpleFbDxeInitialize(
    IN EFI_HANDLE ImageHandle, IN EFI_SYSTEM_TABLE *SystemTable)
{
  EFI_STATUS             Status             = EFI_SUCCESS;
  EFI_HANDLE             hUEFIDisplayHandle = NULL;
  UINT32                 MipiFrameBufferAddr;
  UINT32                 VisibleWidth;
  UINT32                 VisibleHeight;
  UINT32                 LineLength;
  UINT32                 VisibleFrameBufferSize;
  EFI_PHYSICAL_ADDRESS   FrameBufferAddress;

  DEBUG(
      (EFI_D_ERROR,
       "SimpleFbDxe: Retrieve MIPI FrameBuffer parameters from PCD\n"));

  MipiFrameBufferAddr = FixedPcdGet32(PcdMipiFrameBufferAddress);
  mPhysWidth          = FixedPcdGet32(PcdMipiFrameBufferWidth);
  mPhysHeight         = FixedPcdGet32(PcdMipiFrameBufferHeight);
  VisibleWidth        = FixedPcdGet32(PcdMipiFrameBufferVisibleWidth);
  VisibleHeight       = FixedPcdGet32(PcdMipiFrameBufferVisibleHeight);
  mRotation           = FixedPcdGet32(PcdMipiFrameBufferRotation);
  mConsoleScale       = FixedPcdGet32(PcdMipiFrameBufferConsoleScale);
  if (mConsoleScale == 0) {
    mConsoleScale = 100;
  }

  if (MipiFrameBufferAddr == 0 || mPhysWidth == 0 || mPhysHeight == 0) {
    DEBUG((EFI_D_ERROR, "SimpleFbDxe: Invalid FrameBuffer parameters\n"));
    return EFI_DEVICE_ERROR;
  }

  mUseShadow = (mRotation != 0);
  if (mUseShadow) {
    if (VisibleWidth == 0 || VisibleHeight == 0) {
      DEBUG((EFI_D_ERROR, "SimpleFbDxe: Rotation requires visible dimensions\n"));
      return EFI_DEVICE_ERROR;
    }
    mVisWidth  = VisibleWidth;
    mVisHeight = VisibleHeight;
    mPanelWidth  = mVisWidth * mConsoleScale / 100;
    mPanelHeight = mVisHeight * mConsoleScale / 100;
  } else {
    mVisWidth  = mPhysWidth;
    mVisHeight = mPhysHeight;
    mPanelWidth  = mPhysWidth;
    mPanelHeight = mPhysHeight;
  }

  DEBUG(
      (EFI_D_ERROR,
       "SimpleFbDxe: phys %ux%u visible %ux%u panel %ux%u scale %u rotation %u shadow %u\n",
       mPhysWidth, mPhysHeight, mVisWidth, mVisHeight, mPanelWidth, mPanelHeight,
       mConsoleScale, mRotation, mUseShadow));

  if (mDisplay.Mode == NULL) {
    Status = gBS->AllocatePool(
        EfiBootServicesData, sizeof(EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE),
        (VOID **)&mDisplay.Mode);
    ASSERT_EFI_ERROR(Status);
    if (EFI_ERROR(Status)) {
      return Status;
    }
    ZeroMem(mDisplay.Mode, sizeof(EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE));
  }

  if (mDisplay.Mode->Info == NULL) {
    Status = gBS->AllocatePool(
        EfiBootServicesData, sizeof(EFI_GRAPHICS_OUTPUT_MODE_INFORMATION),
        (VOID **)&mDisplay.Mode->Info);
    ASSERT_EFI_ERROR(Status);
    if (EFI_ERROR(Status)) {
      return Status;
    }
    ZeroMem(mDisplay.Mode->Info, sizeof(EFI_GRAPHICS_OUTPUT_MODE_INFORMATION));
  }

  mDisplay.Mode->MaxMode       = 1;
  mDisplay.Mode->Mode          = 0;
  mDisplay.Mode->Info->Version = 0;

  mDisplay.Mode->Info->HorizontalResolution = mVisWidth;
  mDisplay.Mode->Info->VerticalResolution   = mVisHeight;
  mDisplay.Mode->Info->PixelsPerScanLine      = mVisWidth;
  mDisplay.Mode->Info->PixelFormat = PixelBlueGreenRedReserved8BitPerColor;
  mDisplay.Mode->SizeOfInfo        = sizeof(EFI_GRAPHICS_OUTPUT_MODE_INFORMATION);

  LineLength            = mPhysWidth * VNBYTES(VIDEO_BPP32);
  mPhysFrameBufferSize  = LineLength * mPhysHeight;
  VisibleFrameBufferSize = mVisWidth * VNBYTES(VIDEO_BPP32) * mVisHeight;
  FrameBufferAddress    = MipiFrameBufferAddr;

  mDisplay.Mode->FrameBufferBase = FrameBufferAddress;
  mDisplay.Mode->FrameBufferSize = mUseShadow ? VisibleFrameBufferSize :
                                                mPhysFrameBufferSize;

  if (mUseShadow) {
    mShadowBuffer = AllocateZeroPool(VisibleFrameBufferSize);
    if (mShadowBuffer == NULL) {
      return EFI_OUT_OF_RESOURCES;
    }
    Status = ConfigureFrameBufferBlt((VOID *)mShadowBuffer, mDisplay.Mode->Info);
  } else {
    Status = ConfigureFrameBufferBlt(
        (VOID *)(UINTN)FrameBufferAddress, mDisplay.Mode->Info);
  }

  if (EFI_ERROR(Status)) {
    DEBUG((EFI_D_ERROR, "SimpleFbDxe: FrameBufferBltConfigure failed\n"));
    return Status;
  }

  if (mUseShadow) {
    ZeroMem(mShadowBuffer, VisibleFrameBufferSize);
    SyncShadowToPhysical();
  } else {
    ZeroMem((VOID *)(UINTN)FrameBufferAddress, mPhysFrameBufferSize);
    WriteBackInvalidateDataCacheRange(
        (VOID *)(UINTN)FrameBufferAddress, mPhysFrameBufferSize);
  }

  Status = gBS->InstallMultipleProtocolInterfaces(
      &hUEFIDisplayHandle, &gEfiDevicePathProtocolGuid, &mDisplayDevicePath,
      &gEfiGraphicsOutputProtocolGuid, &mDisplay, NULL);

  ASSERT_EFI_ERROR(Status);

  return Status;
}
