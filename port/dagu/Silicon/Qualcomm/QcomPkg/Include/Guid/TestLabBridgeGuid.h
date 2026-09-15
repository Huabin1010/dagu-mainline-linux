/** @file
  TestLab USB debug bridge v2 for dagu UEFI bring-up.

  RAM FAT volume (TESTLAB) for BOOT.LOG / COMMAND.* when the driver is enabled.
  LinuxSimpleMassStorage / USB MSC export was removed — do not re-enable.
**/

#ifndef TESTLAB_BRIDGE_GUID_H_
#define TESTLAB_BRIDGE_GUID_H_

#include <Uefi.h>

#define TESTLAB_BRIDGE_PROTOCOL_GUID \
  { 0x7c9f2a11, 0x4b6e, 0x4d2a, { 0x9e, 0x31, 0x44, 0x8d, 0x20, 0x11, 0xab, 0x7f } }

#define TESTLAB_BRIDGE_RAM_DISK_GUID \
  { 0x8d0e3b22, 0x5c4f, 0x4a8e, { 0xbf, 0x12, 0x55, 0x6c, 0x90, 0x21, 0x3e, 0x44 } }

extern EFI_GUID gTestLabBridgeProtocolGuid;
extern EFI_GUID gTestLabBridgeRamDiskGuid;

#define TESTLAB_BOOT_LOG        L"\\TESTLAB\\BOOT.LOG"
#define TESTLAB_BOOT_SEQ        L"\\TESTLAB\\BOOT.SEQ"
#define TESTLAB_COMMAND_IN      L"\\TESTLAB\\COMMAND.IN"
#define TESTLAB_COMMAND_ACK     L"\\TESTLAB\\COMMAND.ACK"
#define TESTLAB_STATUS_JSON     L"\\TESTLAB\\STATUS.JSON"

#define TESTLAB_CONSOLE_RING_SIZE (128 * 1024)
#define TESTLAB_DISK_SIZE         (1U * 1024U * 1024U)
#define TESTLAB_SECTOR_SIZE       512U

// HARD OFF. Ramdisk alloc was EFI_OUT_OF_RESOURCES on this tablet.
#define TESTLAB_ENABLE_CONOUT_HOOK  0
#define TESTLAB_ENABLE_BRIDGE       0

typedef struct _TESTLAB_BRIDGE_PROTOCOL TESTLAB_BRIDGE_PROTOCOL;

struct _TESTLAB_BRIDGE_PROTOCOL {
  EFI_HANDLE  Handle;
  BOOLEAN     Ready;
  UINT64      BootSeq;
};

#endif // TESTLAB_BRIDGE_GUID_H_
