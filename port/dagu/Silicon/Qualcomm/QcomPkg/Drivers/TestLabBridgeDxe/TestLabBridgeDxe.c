/** @file
  TestLab USB debug bridge v2 for dagu UEFI bring-up.
**/

#include <Guid/TestLabBridgeGuid.h>
#include <Library/BaseLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/DebugLib.h>
#include <Library/DevicePathLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/PrintLib.h>
#include <Library/SerialPortLib.h>
#include <Library/TimerLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiLib.h>
#include <Protocol/BlockIo.h>
#include <Protocol/DevicePath.h>
#include <Protocol/Shell.h>
#include <Protocol/SimpleFileSystem.h>
#include <Protocol/SimpleTextOut.h>
#include <TestLabFatDiskImage.h>

typedef struct {
  UINT32                          Signature;
  EFI_HANDLE                      Handle;
  EFI_DEVICE_PATH_PROTOCOL       *DevicePath;
  EFI_BLOCK_IO_PROTOCOL           BlockIo;
  EFI_BLOCK_IO_MEDIA              Media;
  UINT8                          *Disk;
  UINTN                           DiskSize;
  TESTLAB_BRIDGE_PROTOCOL         Protocol;
  CHAR8                           ConsoleRing[TESTLAB_CONSOLE_RING_SIZE];
  UINTN                           ConsoleHead;
  UINTN                           ConsoleTail;
  EFI_EVENT                       TimerEvent;
  EFI_EVENT                       ReadyToBootEvent;
  EFI_FILE_PROTOCOL              *RootDir;
  BOOLEAN                         LateInitDone;
#if TESTLAB_ENABLE_CONOUT_HOOK
  EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *OriginalConOut;
  EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL  WrappedConOut;
  EFI_EVENT                       ConOutHookEvent;
  BOOLEAN                         ConOutHookDone;
  UINTN                           ConOutHookTicks;
#endif
} TESTLAB_BRIDGE_PRIVATE;

#define TESTLAB_BRIDGE_SIGNATURE  SIGNATURE_32('T', 'L', 'B', '2')
#define TESTLAB_BRIDGE_FROM_BLKIO(BlkIo) \
  CR(BlkIo, TESTLAB_BRIDGE_PRIVATE, BlockIo, TESTLAB_BRIDGE_SIGNATURE)

#if TESTLAB_ENABLE_CONOUT_HOOK
#define TESTLAB_CONOUT_HOOK_DELAY_SEC  5U
#define TESTLAB_BRIDGE_FROM_CONOUT(ConOut) \
  CR(ConOut, TESTLAB_BRIDGE_PRIVATE, WrappedConOut, TESTLAB_BRIDGE_SIGNATURE)
#endif

STATIC TESTLAB_BRIDGE_PRIVATE *mBridge = NULL;

STATIC
EFI_STATUS
TestLabStartServices(
  IN TESTLAB_BRIDGE_PRIVATE *Private);

STATIC
EFI_STATUS
TestLabOpenVolume(
  IN TESTLAB_BRIDGE_PRIVATE *Private);

STATIC
VOID
TestLabAppendLog(
  IN TESTLAB_BRIDGE_PRIVATE *Private,
  IN CHAR16                 *Text,
  IN UINTN                   Count)
{
  UINTN i;

  if (Private == NULL || Text == NULL || Count == 0) {
    return;
  }

  for (i = 0; i < Count; i++) {
    CHAR16 ch = Text[i];
    CHAR8  c8;

    if (ch == L'\r') {
      continue;
    }
    if (ch == L'\n') {
      c8 = '\n';
    } else if (ch > 0x7E) {
      c8 = '?';
    } else {
      c8 = (CHAR8)ch;
    }

    Private->ConsoleRing[Private->ConsoleTail] = c8;
    Private->ConsoleTail = (Private->ConsoleTail + 1) % TESTLAB_CONSOLE_RING_SIZE;
    if (Private->ConsoleTail == Private->ConsoleHead) {
      Private->ConsoleHead = (Private->ConsoleHead + 1) % TESTLAB_CONSOLE_RING_SIZE;
    }
  }
}

STATIC
VOID
TestLabMirrorToSerial(
  IN CHAR8  *Buffer,
  IN UINTN   Size)
{
  if (Buffer != NULL && Size > 0) {
    SerialPortWrite((UINT8 *)Buffer, Size);
  }
}

#if TESTLAB_ENABLE_CONOUT_HOOK

STATIC
EFI_STATUS
EFIAPI
TestLabConOutReset(
  IN EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *This,
  IN BOOLEAN                          ExtendedVerification)
{
  TESTLAB_BRIDGE_PRIVATE *Private = TESTLAB_BRIDGE_FROM_CONOUT(This);
  return Private->OriginalConOut->Reset(Private->OriginalConOut, ExtendedVerification);
}

STATIC
EFI_STATUS
EFIAPI
TestLabConOutOutputString(
  IN EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *This,
  IN CHAR16                          *String)
{
  TESTLAB_BRIDGE_PRIVATE *Private = TESTLAB_BRIDGE_FROM_CONOUT(This);
  EFI_STATUS              Status;

  if (String != NULL) {
    TestLabAppendLog(Private, String, StrLen(String));
  }
  Status = Private->OriginalConOut->OutputString(Private->OriginalConOut, String);
  return Status;
}

STATIC
EFI_STATUS
EFIAPI
TestLabConOutTestString(
  IN EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *This,
  IN CHAR16                          *String)
{
  TESTLAB_BRIDGE_PRIVATE *Private = TESTLAB_BRIDGE_FROM_CONOUT(This);
  return Private->OriginalConOut->TestString(Private->OriginalConOut, String);
}

STATIC
EFI_STATUS
EFIAPI
TestLabConOutQueryMode(
  IN EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *This,
  IN UINTN                            ModeNumber,
  OUT UINTN                          *Columns,
  OUT UINTN                          *Rows)
{
  TESTLAB_BRIDGE_PRIVATE *Private = TESTLAB_BRIDGE_FROM_CONOUT(This);
  return Private->OriginalConOut->QueryMode(
      Private->OriginalConOut, ModeNumber, Columns, Rows);
}

STATIC
EFI_STATUS
EFIAPI
TestLabConOutSetMode(
  IN EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *This,
  IN UINTN                            ModeNumber)
{
  TESTLAB_BRIDGE_PRIVATE *Private = TESTLAB_BRIDGE_FROM_CONOUT(This);
  return Private->OriginalConOut->SetMode(Private->OriginalConOut, ModeNumber);
}

STATIC
EFI_STATUS
EFIAPI
TestLabConOutSetAttribute(
  IN EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *This,
  IN UINTN                            Attribute)
{
  TESTLAB_BRIDGE_PRIVATE *Private = TESTLAB_BRIDGE_FROM_CONOUT(This);
  return Private->OriginalConOut->SetAttribute(Private->OriginalConOut, Attribute);
}

STATIC
EFI_STATUS
EFIAPI
TestLabConOutClearScreen(
  IN EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *This)
{
  TESTLAB_BRIDGE_PRIVATE *Private = TESTLAB_BRIDGE_FROM_CONOUT(This);
  return Private->OriginalConOut->ClearScreen(Private->OriginalConOut);
}

STATIC
EFI_STATUS
EFIAPI
TestLabConOutSetCursorPosition(
  IN EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *This,
  IN UINTN                            Column,
  IN UINTN                            Row)
{
  TESTLAB_BRIDGE_PRIVATE *Private = TESTLAB_BRIDGE_FROM_CONOUT(This);
  return Private->OriginalConOut->SetCursorPosition(
      Private->OriginalConOut, Column, Row);
}

STATIC
EFI_STATUS
EFIAPI
TestLabConOutEnableCursor(
  IN EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *This,
  IN BOOLEAN                          Visible)
{
  TESTLAB_BRIDGE_PRIVATE *Private = TESTLAB_BRIDGE_FROM_CONOUT(This);
  return Private->OriginalConOut->EnableCursor(Private->OriginalConOut, Visible);
}

STATIC
VOID
TestLabInstallConOutHook(
  IN TESTLAB_BRIDGE_PRIVATE *Private)
{
  CopyMem(&Private->WrappedConOut, Private->OriginalConOut, sizeof(Private->WrappedConOut));
  Private->WrappedConOut.Reset             = TestLabConOutReset;
  Private->WrappedConOut.OutputString      = TestLabConOutOutputString;
  Private->WrappedConOut.TestString        = TestLabConOutTestString;
  Private->WrappedConOut.QueryMode         = TestLabConOutQueryMode;
  Private->WrappedConOut.SetMode           = TestLabConOutSetMode;
  Private->WrappedConOut.SetAttribute      = TestLabConOutSetAttribute;
  Private->WrappedConOut.ClearScreen       = TestLabConOutClearScreen;
  Private->WrappedConOut.SetCursorPosition = TestLabConOutSetCursorPosition;
  Private->WrappedConOut.EnableCursor      = TestLabConOutEnableCursor;
  gST->ConOut = &Private->WrappedConOut;
}

STATIC
VOID
EFIAPI
TestLabConOutHookCallback(
  IN EFI_EVENT Event,
  IN VOID     *Context)
{
  TESTLAB_BRIDGE_PRIVATE              *Private = Context;
  EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL     *ConOut;

  if (Private == NULL || Private->ConOutHookDone) {
    return;
  }

  Private->ConOutHookTicks++;
  if (Private->ConOutHookTicks < TESTLAB_CONOUT_HOOK_DELAY_SEC) {
    return;
  }

  ConOut = gST->ConOut;
  if (ConOut == NULL || ConOut == &Private->WrappedConOut) {
    return;
  }

  if (ConOut->Mode != NULL && ConOut->Mode->Mode == -1) {
    if (Private->ConOutHookTicks >= TESTLAB_CONOUT_HOOK_DELAY_SEC + 10U) {
      DEBUG((EFI_D_ERROR, "TestLabBridge: ConOut hook skipped (mode invalid)\n"));
      Private->ConOutHookDone = TRUE;
      gBS->SetTimer(Private->ConOutHookEvent, TimerCancel, 0);
    }
    return;
  }

  Private->OriginalConOut = ConOut;
  TestLabInstallConOutHook(Private);
  Private->ConOutHookDone = TRUE;
  gBS->SetTimer(Private->ConOutHookEvent, TimerCancel, 0);
  DEBUG((EFI_D_ERROR, "TestLabBridge: ConOut hook installed\n"));
}

#endif // TESTLAB_ENABLE_CONOUT_HOOK

STATIC
EFI_STATUS
EFIAPI
TestLabBlkIoReset(
  IN EFI_BLOCK_IO_PROTOCOL *This,
  IN BOOLEAN                ExtendedVerification)
{
  return EFI_SUCCESS;
}

STATIC
EFI_STATUS
EFIAPI
TestLabBlkIoReadBlocks(
  IN EFI_BLOCK_IO_PROTOCOL *This,
  IN UINT32                 MediaId,
  IN EFI_LBA                Lba,
  IN UINTN                  BufferSize,
  OUT VOID                 *Buffer)
{
  TESTLAB_BRIDGE_PRIVATE *Private = TESTLAB_BRIDGE_FROM_BLKIO(This);
  UINTN                   Offset;

  if (MediaId != Private->Media.MediaId || Buffer == NULL) {
    return EFI_INVALID_PARAMETER;
  }
  if (BufferSize % Private->Media.BlockSize != 0) {
    return EFI_BAD_BUFFER_SIZE;
  }
  Offset = MultU64x32(Lba, Private->Media.BlockSize);
  if (Offset + BufferSize > Private->DiskSize) {
    return EFI_INVALID_PARAMETER;
  }
  CopyMem(Buffer, Private->Disk + Offset, BufferSize);
  return EFI_SUCCESS;
}

STATIC
EFI_STATUS
EFIAPI
TestLabBlkIoWriteBlocks(
  IN EFI_BLOCK_IO_PROTOCOL *This,
  IN UINT32                 MediaId,
  IN EFI_LBA                Lba,
  IN UINTN                  BufferSize,
  IN VOID                  *Buffer)
{
  TESTLAB_BRIDGE_PRIVATE *Private = TESTLAB_BRIDGE_FROM_BLKIO(This);
  UINTN                   Offset;

  if (MediaId != Private->Media.MediaId || Buffer == NULL) {
    return EFI_INVALID_PARAMETER;
  }
  if (BufferSize % Private->Media.BlockSize != 0) {
    return EFI_BAD_BUFFER_SIZE;
  }
  Offset = MultU64x32(Lba, Private->Media.BlockSize);
  if (Offset + BufferSize > Private->DiskSize) {
    return EFI_INVALID_PARAMETER;
  }
  CopyMem(Private->Disk + Offset, Buffer, BufferSize);
  return EFI_SUCCESS;
}

STATIC
EFI_STATUS
EFIAPI
TestLabBlkIoFlushBlocks(
  IN EFI_BLOCK_IO_PROTOCOL *This)
{
  return EFI_SUCCESS;
}

STATIC
EFI_STATUS
TestLabWriteFile(
  IN TESTLAB_BRIDGE_PRIVATE *Private,
  IN CHAR16                 *Path,
  IN VOID                   *Data,
  IN UINTN                   Size)
{
  EFI_STATUS         Status;
  EFI_FILE_PROTOCOL *File;
  UINTN              Written;

  if (Private->RootDir == NULL) {
    return EFI_NOT_READY;
  }

  Status = Private->RootDir->Open(
      Private->RootDir, &File, Path,
      EFI_FILE_MODE_READ | EFI_FILE_MODE_WRITE | EFI_FILE_MODE_CREATE, 0);
  if (EFI_ERROR(Status)) {
    return Status;
  }

  Status = File->SetPosition(File, 0);
  if (!EFI_ERROR(Status)) {
    Written = Size;
    Status  = File->Write(File, &Written, Data);
  }
  File->Close(File);
  return Status;
}

STATIC
EFI_STATUS
TestLabReadFile(
  IN TESTLAB_BRIDGE_PRIVATE *Private,
  IN CHAR16                 *Path,
  OUT VOID                  *Data,
  IN OUT UINTN              *Size)
{
  EFI_STATUS         Status;
  EFI_FILE_PROTOCOL *File;
  UINTN              ReadSize;

  if (Private->RootDir == NULL || Size == NULL) {
    return EFI_INVALID_PARAMETER;
  }

  Status = Private->RootDir->Open(Private->RootDir, &File, Path, EFI_FILE_MODE_READ, 0);
  if (EFI_ERROR(Status)) {
    return Status;
  }

  ReadSize = *Size;
  Status   = File->Read(File, &ReadSize, Data);
  File->Close(File);
  *Size = ReadSize;
  return Status;
}

STATIC
EFI_STATUS
TestLabEnsureLayout(
  IN TESTLAB_BRIDGE_PRIVATE *Private)
{
  EFI_STATUS         Status;
  EFI_FILE_PROTOCOL *Dir;
  EFI_FILE_PROTOCOL *File;

  if (Private->RootDir == NULL) {
    return EFI_NOT_READY;
  }

  Status = Private->RootDir->Open(
      Private->RootDir, &Dir, L"TESTLAB",
      EFI_FILE_MODE_READ | EFI_FILE_MODE_WRITE | EFI_FILE_MODE_CREATE,
      EFI_FILE_DIRECTORY);
  if (!EFI_ERROR(Status)) {
    Dir->Close(Dir);
  }

  Status = TestLabWriteFile(Private, TESTLAB_BOOT_LOG, "", 0);
  if (EFI_ERROR(Status)) {
    return Status;
  }
  Status = TestLabWriteFile(Private, TESTLAB_BOOT_SEQ, "0", 1);
  if (EFI_ERROR(Status)) {
    return Status;
  }
  Status = TestLabWriteFile(Private, TESTLAB_STATUS_JSON,
      "{\"seq\":0,\"usb\":\"waiting\",\"bridge\":\"v2\"}", 39);
  if (EFI_ERROR(Status)) {
    return Status;
  }
  Status = TestLabWriteFile(Private, TESTLAB_COMMAND_IN, "", 0);
  if (EFI_ERROR(Status)) {
    return Status;
  }
  Status = TestLabWriteFile(Private, TESTLAB_COMMAND_ACK, "OK", 2);
  return Status;
}

STATIC
EFI_STATUS
TestLabFlushBootLog(
  IN TESTLAB_BRIDGE_PRIVATE *Private)
{
  CHAR8  Buffer[TESTLAB_CONSOLE_RING_SIZE + 1];
  CHAR8  Seq[32];
  UINTN  Len = 0;

  if (Private->ConsoleHead <= Private->ConsoleTail) {
    Len = Private->ConsoleTail - Private->ConsoleHead;
    CopyMem(Buffer, &Private->ConsoleRing[Private->ConsoleHead], Len);
  } else {
    Len = TESTLAB_CONSOLE_RING_SIZE - Private->ConsoleHead;
    CopyMem(Buffer, &Private->ConsoleRing[Private->ConsoleHead], Len);
    CopyMem(Buffer + Len, &Private->ConsoleRing[0], Private->ConsoleTail);
    Len += Private->ConsoleTail;
  }
  Buffer[Len] = '\0';

  Private->Protocol.BootSeq++;
  AsciiSPrint(Seq, sizeof(Seq), "%llu", Private->Protocol.BootSeq);

  TestLabMirrorToSerial(Buffer, Len);
  TestLabWriteFile(Private, TESTLAB_BOOT_LOG, Buffer, Len);
  TestLabWriteFile(Private, TESTLAB_BOOT_SEQ, Seq, AsciiStrLen(Seq));
  return EFI_SUCCESS;
}

STATIC
EFI_STATUS
TestLabExecuteShellCommand(
  IN TESTLAB_BRIDGE_PRIVATE *Private,
  IN CHAR8                  *CommandAscii)
{
  EFI_SHELL_PROTOCOL *Shell;
  EFI_STATUS          Status;
  EFI_STATUS          CmdStatus;
  CHAR16             *Command;
  CHAR8               Ack[256];

  Status = gBS->LocateProtocol(
      &gEfiShellProtocolGuid, NULL, (VOID **)&Shell);
  if (EFI_ERROR(Status)) {
    AsciiSPrint(Ack, sizeof(Ack), "ERR no shell");
    TestLabWriteFile(Private, TESTLAB_COMMAND_ACK, Ack, AsciiStrLen(Ack));
    return Status;
  }

  Command = AllocateZeroPool((AsciiStrLen(CommandAscii) + 1) * sizeof(CHAR16));
  if (Command == NULL) {
    return EFI_OUT_OF_RESOURCES;
  }
  AsciiStrToUnicodeStrS(CommandAscii, Command, AsciiStrLen(CommandAscii) + 1);

  Status = Shell->Execute(&gImageHandle, Command, NULL, &CmdStatus);
  if (EFI_ERROR(Status) || EFI_ERROR(CmdStatus)) {
    AsciiSPrint(Ack, sizeof(Ack), "ERR 0x%llx", (UINT64)(EFI_ERROR(Status) ? Status : CmdStatus));
  } else {
    AsciiSPrint(Ack, sizeof(Ack), "OK");
  }

  TestLabWriteFile(Private, TESTLAB_COMMAND_ACK, Ack, AsciiStrLen(Ack));
  TestLabWriteFile(Private, TESTLAB_COMMAND_IN, "", 0);
  FreePool(Command);
  return Status;
}

STATIC
EFI_STATUS
TestLabHandleCommand(
  IN TESTLAB_BRIDGE_PRIVATE *Private,
  IN CHAR8                  *CommandAscii)
{
  CHAR8 Ack[64];

  if (AsciiStrCmp(CommandAscii, "usb-on") == 0) {
    AsciiSPrint(Ack, sizeof(Ack), "ERR msc-removed");
    TestLabWriteFile(Private, TESTLAB_COMMAND_ACK, Ack, AsciiStrLen(Ack));
    TestLabWriteFile(Private, TESTLAB_COMMAND_IN, "", 0);
    return EFI_UNSUPPORTED;
  }

  return TestLabExecuteShellCommand(Private, CommandAscii);
}

STATIC
EFI_STATUS
TestLabPollCommand(
  IN TESTLAB_BRIDGE_PRIVATE *Private)
{
  CHAR8  Buffer[512];
  UINTN  Size = sizeof(Buffer) - 1;
  EFI_STATUS Status;

  Status = TestLabReadFile(Private, TESTLAB_COMMAND_IN, Buffer, &Size);
  if (EFI_ERROR(Status) || Size == 0) {
    return EFI_SUCCESS;
  }
  Buffer[Size] = '\0';
  while (Size > 0 && (Buffer[Size - 1] == '\n' || Buffer[Size - 1] == '\r')) {
    Buffer[--Size] = '\0';
  }
  if (Size == 0) {
    return EFI_SUCCESS;
  }
  return TestLabHandleCommand(Private, Buffer);
}

STATIC
VOID
TestLabUsbStatusString(
  IN TESTLAB_BRIDGE_PRIVATE *Private,
  OUT CHAR8                 *Buffer,
  IN UINTN                   BufferSize)
{
  AsciiSPrint(
      Buffer, BufferSize,
      "{\"seq\":%llu,\"usb\":\"disabled\",\"bridge\":\"v2\"}",
      Private->Protocol.BootSeq);
}

STATIC
BOOLEAN
TestLabPathHasRamDiskGuid(
  IN EFI_DEVICE_PATH_PROTOCOL *DevicePath)
{
  while (!IsDevicePathEnd(DevicePath)) {
    if (DevicePathType(DevicePath) == HARDWARE_DEVICE_PATH &&
        DevicePathSubType(DevicePath) == HW_VENDOR_DP) {
      VENDOR_DEVICE_PATH *Vendor = (VENDOR_DEVICE_PATH *)DevicePath;

      if (CompareGuid(&Vendor->Guid, &gTestLabBridgeRamDiskGuid)) {
        return TRUE;
      }
    }
    DevicePath = NextDevicePathNode(DevicePath);
  }
  return FALSE;
}

STATIC
EFI_STATUS
TestLabOpenVolume(
  IN TESTLAB_BRIDGE_PRIVATE *Private)
{
  EFI_STATUS                     Status;
  EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *Fs;
  UINTN                          HandleCount;
  EFI_HANDLE                    *Handles;
  UINTN                          i;
  EFI_DEVICE_PATH_PROTOCOL      *DevicePath;

  if (Private->RootDir != NULL) {
    return EFI_SUCCESS;
  }

  Status = gBS->LocateHandleBuffer(
      ByProtocol, &gEfiSimpleFileSystemProtocolGuid,
      NULL, &HandleCount, &Handles);
  if (EFI_ERROR(Status)) {
    return Status;
  }

  for (i = 0; i < HandleCount; i++) {
    DevicePath = DevicePathFromHandle(Handles[i]);
    if (DevicePath == NULL || !TestLabPathHasRamDiskGuid(DevicePath)) {
      continue;
    }
    Status = gBS->HandleProtocol(
        Handles[i], &gEfiSimpleFileSystemProtocolGuid, (VOID **)&Fs);
    if (EFI_ERROR(Status)) {
      continue;
    }
    Status = Fs->OpenVolume(Fs, &Private->RootDir);
    if (!EFI_ERROR(Status)) {
      FreePool(Handles);
      return EFI_SUCCESS;
    }
  }

  FreePool(Handles);
  return EFI_NOT_FOUND;
}

STATIC
EFI_STATUS
TestLabInstallRamDisk(
  IN TESTLAB_BRIDGE_PRIVATE *Private)
{
  EFI_STATUS          Status;
  VENDOR_DEVICE_PATH  VendorNode;
  EFI_DEVICE_PATH     EndNode = {
    END_DEVICE_PATH_TYPE,
    END_ENTIRE_DEVICE_PATH_SUBTYPE,
    { END_DEVICE_PATH_LENGTH, 0 }
  };

  if (TestLabFatDiskEnd <= TestLabFatDisk) {
    return EFI_VOLUME_CORRUPTED;
  }

  Private->DiskSize = TESTLAB_DISK_SIZE;
  if ((UINTN)(TestLabFatDiskEnd - TestLabFatDisk) > Private->DiskSize) {
    return EFI_VOLUME_CORRUPTED;
  }

  Private->Disk = AllocateCopyPool(Private->DiskSize, TestLabFatDisk);
  if (Private->Disk == NULL) {
    return EFI_OUT_OF_RESOURCES;
  }

  ZeroMem(&Private->BlockIo, sizeof(Private->BlockIo));
  Private->BlockIo.Revision     = EFI_BLOCK_IO_PROTOCOL_REVISION;
  Private->BlockIo.Media        = &Private->Media;
  Private->BlockIo.Reset        = TestLabBlkIoReset;
  Private->BlockIo.ReadBlocks   = TestLabBlkIoReadBlocks;
  Private->BlockIo.WriteBlocks  = TestLabBlkIoWriteBlocks;
  Private->BlockIo.FlushBlocks  = TestLabBlkIoFlushBlocks;

  Private->Media.MediaId          = 1;
  Private->Media.RemovableMedia   = TRUE;
  Private->Media.MediaPresent     = TRUE;
  Private->Media.LogicalPartition = FALSE;
  Private->Media.ReadOnly         = FALSE;
  Private->Media.WriteCaching     = FALSE;
  Private->Media.BlockSize        = TESTLAB_SECTOR_SIZE;
  Private->Media.LastBlock        = (Private->DiskSize / TESTLAB_SECTOR_SIZE) - 1;

  VendorNode.Header.Type        = HARDWARE_DEVICE_PATH;
  VendorNode.Header.SubType     = HW_VENDOR_DP;
  VendorNode.Header.Length[0]   = (UINT8)(sizeof(VendorNode));
  VendorNode.Header.Length[1]   = (UINT8)(sizeof(VendorNode) >> 8);
  CopyGuid(&VendorNode.Guid, &gTestLabBridgeRamDiskGuid);

  Private->DevicePath = AppendDevicePath(
      (EFI_DEVICE_PATH_PROTOCOL *)&VendorNode,
      (EFI_DEVICE_PATH_PROTOCOL *)&EndNode);
  if (Private->DevicePath == NULL) {
    return EFI_OUT_OF_RESOURCES;
  }

  Status = gBS->InstallMultipleProtocolInterfaces(
      &Private->Handle,
      &gEfiDevicePathProtocolGuid, Private->DevicePath,
      &gEfiBlockIoProtocolGuid, &Private->BlockIo,
      &gTestLabBridgeProtocolGuid, &Private->Protocol,
      NULL);
  if (EFI_ERROR(Status)) {
    return Status;
  }

  //
  // Fat/DiskIo may bind later — do not fail the whole bridge if no consumer
  // attaches on the first ConnectController (was printing "ramdisk failed").
  //
  gBS->ConnectController(Private->Handle, NULL, NULL, TRUE);
  return EFI_SUCCESS;
}

STATIC
VOID
EFIAPI
TestLabTimerCallback(
  IN EFI_EVENT Event,
  IN VOID     *Context)
{
  TESTLAB_BRIDGE_PRIVATE *Private = Context;
  CHAR8                   StatusJson[160];

  if (Private == NULL) {
    return;
  }

  if (Private->RootDir == NULL) {
    TestLabOpenVolume(Private);
  }

  TestLabFlushBootLog(Private);
  TestLabPollCommand(Private);

  TestLabUsbStatusString(Private, StatusJson, sizeof(StatusJson));
  TestLabWriteFile(
      Private, TESTLAB_STATUS_JSON, StatusJson, AsciiStrLen(StatusJson));
}

STATIC
VOID
EFIAPI
TestLabReadyToBootCallback(
  IN EFI_EVENT Event,
  IN VOID     *Context)
{
  TESTLAB_BRIDGE_PRIVATE *Private = Context;

  if (Private == NULL || Private->LateInitDone) {
    return;
  }

  TestLabStartServices(Private);
}

STATIC
EFI_STATUS
TestLabStartServices(
  IN TESTLAB_BRIDGE_PRIVATE *Private)
{
  EFI_STATUS Status;
  CHAR8      Banner[96];

  if (Private == NULL || Private->LateInitDone) {
    return EFI_ALREADY_STARTED;
  }

  Status = TestLabInstallRamDisk(Private);
  if (EFI_ERROR(Status)) {
    DEBUG((EFI_D_ERROR, "TestLabBridge: ramdisk failed %r\n", Status));
    return Status;
  }

  TestLabOpenVolume(Private);
  TestLabEnsureLayout(Private);
  Private->LateInitDone = TRUE;

  TestLabAppendLog(Private, L"TestLabBridge v2 ready (post-display)\r\n", 38);

  Status = gBS->CreateEvent(
      EVT_TIMER | EVT_NOTIFY_SIGNAL, TPL_CALLBACK,
      TestLabTimerCallback, Private, &Private->TimerEvent);
  if (!EFI_ERROR(Status)) {
    gBS->SetTimer(
        Private->TimerEvent, TimerPeriodic,
        EFI_TIMER_PERIOD_MILLISECONDS(500));
  }

  AsciiSPrint(
      Banner, sizeof(Banner),
      "\r\nTestLabBridge v2: log bridge ready (MSC removed)\r\n");
  TestLabMirrorToSerial(Banner, AsciiStrLen(Banner));
  DEBUG((EFI_D_ERROR, "%a", Banner));
  return EFI_SUCCESS;
}

EFI_STATUS
EFIAPI
TestLabBridgeDxeInitialize(
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE *SystemTable)
{
  EFI_STATUS              Status;
  TESTLAB_BRIDGE_PRIVATE *Private;

  if (mBridge != NULL) {
    return EFI_ALREADY_STARTED;
  }

  Private = AllocateZeroPool(sizeof(*Private));
  if (Private == NULL) {
    return EFI_OUT_OF_RESOURCES;
  }

  Private->Signature       = TESTLAB_BRIDGE_SIGNATURE;
  Private->Protocol.Ready  = TRUE;
  Private->Protocol.Handle = ImageHandle;
  mBridge = Private;

  Status = EfiCreateEventReadyToBootEx(
      TPL_CALLBACK, TestLabReadyToBootCallback, Private, &Private->ReadyToBootEvent);
  if (EFI_ERROR(Status)) {
    DEBUG((EFI_D_ERROR, "TestLabBridge: ReadyToBoot register failed %r\n", Status));
    mBridge = NULL;
    FreePool(Private);
    return Status;
  }

  DEBUG((EFI_D_ERROR, "TestLabBridge v2: deferred until ReadyToBoot\n"));
  return EFI_SUCCESS;
}
