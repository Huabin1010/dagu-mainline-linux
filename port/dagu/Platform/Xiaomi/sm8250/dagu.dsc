[Defines]
  VENDOR_NAME                    = Xiaomi
  PLATFORM_NAME                  = dagu
  PLATFORM_GUID                  = 8c4f2e1a-6b3d-4a9e-9f2c-0d0082500001
  PLATFORM_VERSION               = 0.1
  DSC_SPECIFICATION              = 0x00010019
  OUTPUT_DIRECTORY               = Build/$(PLATFORM_NAME)
  SUPPORTED_ARCHITECTURES        = AARCH64
  BUILD_TARGETS                  = DEBUG|RELEASE
  SKUID_IDENTIFIER               = DEFAULT
  FLASH_DEFINITION               = Platform/Qualcomm/sm8250/sm8250.fdf
  DEVICE_DXE_FV_COMPONENTS       = Platform/Xiaomi/sm8250/dagu.fdf.inc

!include Platform/Qualcomm/sm8250/sm8250.dsc

[BuildOptions.common]
  GCC:*_*_AARCH64_CC_FLAGS = -DENABLE_SIMPLE_INIT

[LibraryClasses.common]
  # Force on-screen early boot log (PrePI DEBUG text on framebuffer).
  SerialPortLib|Silicon/Qualcomm/QcomPkg/Library/FrameBufferSerialPortLib/FrameBufferSerialPortLib.inf

[Components.common]
  Silicon/Qualcomm/QcomPkg/Drivers/TestLabBridgeDxe/TestLabBridgeDxe.inf
  MdeModulePkg/Application/BootManagerMenuApp/BootManagerMenuApp.inf
  Silicon/Qualcomm/QcomPkg/PrePi/PrePi.inf {
    <LibraryClasses>
      SerialPortLib|Silicon/Qualcomm/QcomPkg/Library/FrameBufferSerialPortLib/FrameBufferSerialPortLib.inf
  }

[PcdsFixedAtBuild.common]
  # L81A ABL framebuffer (portrait stride in memory)
  gQcomTokenSpaceGuid.PcdMipiFrameBufferWidth|1600
  gQcomTokenSpaceGuid.PcdMipiFrameBufferHeight|2560
  # Logical landscape 1706x1066, rotate 90 + upscale 150% -> fill 2560x1600 panel
  gQcomTokenSpaceGuid.PcdMipiFrameBufferVisibleWidth|1706
  gQcomTokenSpaceGuid.PcdMipiFrameBufferVisibleHeight|1066
  gQcomTokenSpaceGuid.PcdMipiFrameBufferRotation|90
  gQcomTokenSpaceGuid.PcdMipiFrameBufferConsoleScale|150
  gQcomTokenSpaceGuid.PcdDebugUartPortBase|0x988000

  # No auto-boot timeout — PlatformBm forces BootManagerMenuApp.
  gEfiMdePkgTokenSpaceGuid.PcdPlatformBootTimeOut|0

  # Use popup Boot Manager (not UiApp FrontPage) so Vol/Power can pick Simple Init / Shell.
  # FILE_GUID of BootManagerMenuApp.inf
  gEfiMdeModulePkgTokenSpaceGuid.PcdBootManagerMenuFile|{ 0xdc, 0x5b, 0xc2, 0xee, 0xf2, 0x67, 0x95, 0x4d, 0xb1, 0xd5, 0xf8, 0x1b, 0x20, 0x39, 0xd1, 0x1d }

  gSimpleInitTokenSpaceGuid.PcdGuiDefaultDPI|450

  gRenegadePkgTokenSpaceGuid.PcdDeviceVendor|"Xiaomi"
  gRenegadePkgTokenSpaceGuid.PcdDeviceProduct|"Mi Pad 5 Pro 12.4"
  gRenegadePkgTokenSpaceGuid.PcdDeviceCodeName|"dagu"

[PcdsDynamicDefault.common]
  gEfiMdeModulePkgTokenSpaceGuid.PcdVideoHorizontalResolution|0
  gEfiMdeModulePkgTokenSpaceGuid.PcdVideoVerticalResolution|0
  gEfiMdeModulePkgTokenSpaceGuid.PcdSetupVideoHorizontalResolution|0
  gEfiMdeModulePkgTokenSpaceGuid.PcdSetupVideoVerticalResolution|0
  gEfiMdeModulePkgTokenSpaceGuid.PcdSetupConOutRow|0
  gEfiMdeModulePkgTokenSpaceGuid.PcdSetupConOutColumn|0
  gEfiMdeModulePkgTokenSpaceGuid.PcdConOutColumn|206
  gEfiMdeModulePkgTokenSpaceGuid.PcdConOutRow|53
