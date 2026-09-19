/* SPDX-License-Identifier: BSD-2-Clause-Patent
 * UEFI debug ring in the Log Buffer carveout (PlatformMemoryMapLib).
 * PrePI and DXE share this physical window so early SerialPortWrite
 * can be replayed after UsbfnDwc3 enumerates CDC-ACM.
 */
#ifndef DAGU_DEBUG_LOG_H
#define DAGU_DEBUG_LOG_H

#include <Base.h>
#include <Library/BaseMemoryLib.h>
#include <Library/CacheMaintenanceLib.h>

#define DAGU_DEBUG_LOG_BASE   0x9FFF7000ULL
#define DAGU_DEBUG_LOG_BYTES  0x00008000ULL
#define DAGU_DEBUG_LOG_MAGIC  0x55474431U

typedef struct {
  UINT32 Magic;
  UINT32 Head;
  UINT32 Tail;
  UINT32 Cap;
  UINT8  Data[1];
} DAGU_DEBUG_LOG;

STATIC inline DAGU_DEBUG_LOG *
DaguDebugLogPtr (
  VOID
  )
{
  return (DAGU_DEBUG_LOG *)(UINTN)DAGU_DEBUG_LOG_BASE;
}

STATIC inline VOID
DaguDebugLogInit (
  VOID
  )
{
  DAGU_DEBUG_LOG *Log;
  UINT32          Cap;

  Log = DaguDebugLogPtr ();
  Cap = (UINT32)(DAGU_DEBUG_LOG_BYTES - OFFSET_OF (DAGU_DEBUG_LOG, Data));
  if (Log->Magic == DAGU_DEBUG_LOG_MAGIC && Log->Cap == Cap) {
    return;
  }

  ZeroMem ((VOID *)(UINTN)DAGU_DEBUG_LOG_BASE, (UINTN)DAGU_DEBUG_LOG_BYTES);
  Log->Magic = DAGU_DEBUG_LOG_MAGIC;
  Log->Head  = 0;
  Log->Tail  = 0;
  Log->Cap   = Cap;
  WriteBackInvalidateDataCacheRange (
    (VOID *)(UINTN)DAGU_DEBUG_LOG_BASE,
    (UINTN)DAGU_DEBUG_LOG_BYTES
    );
}

STATIC inline VOID
DaguDebugLogAppend (
  IN CONST UINT8  *Buffer,
  IN UINTN         NumberOfBytes
  )
{
  DAGU_DEBUG_LOG *Log;
  UINTN           Index;
  UINT32          Next;

  if (Buffer == NULL || NumberOfBytes == 0) {
    return;
  }

  DaguDebugLogInit ();
  Log = DaguDebugLogPtr ();
  for (Index = 0; Index < NumberOfBytes; Index++) {
    Next = (Log->Tail + 1) % Log->Cap;
    if (Next == Log->Head) {
      Log->Head = (Log->Head + 1) % Log->Cap;
    }

    Log->Data[Log->Tail] = Buffer[Index];
    Log->Tail            = Next;
  }

  WriteBackInvalidateDataCacheRange (
    (VOID *)(UINTN)DAGU_DEBUG_LOG_BASE,
    (UINTN)DAGU_DEBUG_LOG_BYTES
    );
}

STATIC inline UINTN
DaguDebugLogRead (
  OUT UINT8  *Buffer,
  IN UINTN    NumberOfBytes
  )
{
  DAGU_DEBUG_LOG *Log;
  UINTN           Copied;

  if (Buffer == NULL || NumberOfBytes == 0) {
    return 0;
  }

  Log = DaguDebugLogPtr ();
  if (Log->Magic != DAGU_DEBUG_LOG_MAGIC) {
    return 0;
  }

  InvalidateDataCacheRange (
    (VOID *)(UINTN)DAGU_DEBUG_LOG_BASE,
    (UINTN)DAGU_DEBUG_LOG_BYTES
    );
  Copied = 0;
  while (Copied < NumberOfBytes && Log->Head != Log->Tail) {
    Buffer[Copied++] = Log->Data[Log->Head];
    Log->Head        = (Log->Head + 1) % Log->Cap;
  }

  WriteBackInvalidateDataCacheRange (
    (VOID *)(UINTN)DAGU_DEBUG_LOG_BASE,
    (UINTN)DAGU_DEBUG_LOG_BYTES
    );
  return Copied;
}

#endif
