#include <PiDxe.h>

#include <Library/ArmLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/CacheMaintenanceLib.h>
#include <Library/HobLib.h>
#include <Library/PcdLib.h>
#include <Library/SerialPortLib.h>

#include <Resources/FbColor.h>
#include <Resources/font5x12.h>

#include "Library/FrameBufferSerialPortLib.h"
#include <Library/DaguDebugLog.h>
#include <Library/TimerLib.h>

FBCON_POSITION m_Position;
FBCON_POSITION m_MaxPosition;
FBCON_COLOR    m_Color;
BOOLEAN        m_Initialized = FALSE;

STATIC UINT32 mPhysWidth;
STATIC UINT32 mPhysHeight;
STATIC UINT32 mVisWidth;
STATIC UINT32 mVisHeight;
STATIC UINT32 mPanelWidth;
STATIC UINT32 mPanelHeight;
STATIC UINT32 mConsoleScale;
STATIC UINT32 mRotation;
STATIC UINT32 mDrawScale;

UINTN gWidth;
UINTN gHeight;
UINTN gBpp    = FixedPcdGet32(PcdMipiFrameBufferPixelBpp);
UINTN delay   = FixedPcdGet32(PcdMipiFrameBufferDelay);

void FbConPutCharWithFactor(char c, int type, unsigned scale_factor);
void FbConDrawglyph(
    unsigned base_x, unsigned base_y, unsigned *glyph, unsigned scale_factor);
void FbConReset(void);
void FbConScrollUp(void);
void FbConFlush(void);

STATIC
VOID
FbPutPixelPhysical(UINT32 Px, UINT32 Py, UINT32 Color)
{
  CHAR8 *Pixels;
  UINTN  BppBytes;
  UINTN  i;

  if (Px >= mPhysWidth || Py >= mPhysHeight) {
    return;
  }

  BppBytes = gBpp / 8;
  Pixels   = (CHAR8 *)(UINTN)FixedPcdGet32(PcdMipiFrameBufferAddress);
  Pixels  += ((UINTN)Py * mPhysWidth + Px) * BppBytes;
  for (i = 0; i < BppBytes; i++) {
    Pixels[i] = (CHAR8)Color;
    Color     = Color >> 8;
  }
}

STATIC
VOID
FbPutPixelLogical(UINTN Lx, UINTN Ly, UINT32 Color)
{
  UINT32 Px;
  UINT32 Py;
  UINTN  PanelX;
  UINTN  PanelY;

  if (Lx >= mVisWidth || Ly >= mVisHeight) {
    return;
  }

  if (mRotation == 90) {
    PanelX = Lx * mPanelWidth / mVisWidth;
    PanelY = Ly * mPanelHeight / mVisHeight;
    Px     = mPhysWidth - 1 - (UINT32)PanelY;
    Py     = (UINT32)PanelX;
  } else if (mRotation == 270) {
    PanelX = Lx * mPanelWidth / mVisWidth;
    PanelY = Ly * mPanelHeight / mVisHeight;
    Px     = (UINT32)PanelY;
    Py     = mPhysHeight - 1 - (UINT32)PanelX;
  } else if (mRotation == 180) {
    Px = mVisWidth - 1 - (UINT32)Lx;
    Py = mVisHeight - 1 - (UINT32)Ly;
  } else {
    Px = (UINT32)Lx;
    Py = (UINT32)Ly;
  }

  FbPutPixelPhysical(Px, Py, Color);
}

STATIC
VOID
FbFillLogicalRect(UINTN Lx, UINTN Ly, UINTN W, UINTN H, UINT32 Color)
{
  UINTN x;
  UINTN y;

  for (y = Ly; y < Ly + H; y++) {
    for (x = Lx; x < Lx + W; x++) {
      FbPutPixelLogical(x, y, Color);
    }
  }
}

STATIC
VOID
FbInitGeometry(VOID)
{
  mPhysWidth    = FixedPcdGet32(PcdMipiFrameBufferWidth);
  mPhysHeight   = FixedPcdGet32(PcdMipiFrameBufferHeight);
  mVisWidth     = FixedPcdGet32(PcdMipiFrameBufferVisibleWidth);
  mVisHeight    = FixedPcdGet32(PcdMipiFrameBufferVisibleHeight);
  mRotation     = FixedPcdGet32(PcdMipiFrameBufferRotation);
  mConsoleScale = FixedPcdGet32(PcdMipiFrameBufferConsoleScale);
  if (mConsoleScale == 0) {
    mConsoleScale = 100;
  }

  mDrawScale = SCALE_FACTOR * mConsoleScale / 100;
  if (mDrawScale == 0) {
    mDrawScale = SCALE_FACTOR;
  }

  if (mRotation != 0 && mVisWidth != 0 && mVisHeight != 0) {
    gWidth       = mVisWidth;
    gHeight      = mVisHeight;
    mPanelWidth  = mVisWidth * mConsoleScale / 100;
    mPanelHeight = mVisHeight * mConsoleScale / 100;
  } else {
    gWidth       = mPhysWidth;
    gHeight      = mPhysHeight;
    mVisWidth    = mPhysWidth;
    mVisHeight   = mPhysHeight;
    mPanelWidth  = mPhysWidth;
    mPanelHeight = mPhysHeight;
  }
}

RETURN_STATUS
EFIAPI
SerialPortInitialize(VOID)
{
  UINTN InterruptState = 0;

  if (m_Initialized) {
    return RETURN_SUCCESS;
  }

  FbInitGeometry();

  InterruptState = ArmGetInterruptState();
  ArmDisableInterrupts();

  FbConReset();
  DaguDebugLogInit();

  m_Initialized = TRUE;

  if (InterruptState) {
    ArmEnableInterrupts();
  }
  return RETURN_SUCCESS;
}

void
ResetFb(void)
{
  UINT32 Px;
  UINT32 Py;

  for (Py = 0; Py < mPhysHeight; Py++) {
    for (Px = 0; Px < mPhysWidth; Px++) {
      FbPutPixelPhysical(Px, Py, FB_BGRA8888_BLACK);
    }
  }
  FbConFlush();
}

void
FbConReset(void)
{
  m_Position.x = 0;
  m_Position.y = 0;

  m_MaxPosition.x = gWidth / ((FONT_WIDTH + 1) * mDrawScale);
  if (m_MaxPosition.x == 0) {
    m_MaxPosition.x = 1;
  }
  m_MaxPosition.y = (gHeight - 1) / (FONT_HEIGHT * mDrawScale);

  m_Color.Foreground = FB_BGRA8888_WHITE;
  m_Color.Background = FB_BGRA8888_BLACK;

  ResetFb();
}

void
FbConPutCharWithFactor(char c, int type, unsigned scale_factor)
{
  unsigned base_x;
  unsigned base_y;

  if (!m_Initialized) {
    return;
  }

paint:

  if ((unsigned char)c > 127) {
    return;
  }

  if ((unsigned char)c < 32) {
    if (c == '\n') {
      goto newline;
    } else if (c == '\r') {
      m_Position.x = 0;
      return;
    } else {
      return;
    }
  }

  if (m_Position.x == 0 && (unsigned char)c == ' ' &&
      type != FBCON_SUBTITLE_MSG && type != FBCON_TITLE_MSG) {
    return;
  }

  BOOLEAN intstate = ArmGetInterruptState();
  ArmDisableInterrupts();

  base_x = (unsigned)(m_Position.x * (FONT_WIDTH + 1) * scale_factor);
  base_y = (unsigned)(m_Position.y * FONT_HEIGHT * scale_factor);
  FbConDrawglyph(base_x, base_y, font5x12 + (c - 32) * 2, scale_factor);

  m_Position.x++;

  if (m_Position.x >= (int)(m_MaxPosition.x / scale_factor)) {
    goto newline;
  }

  if (intstate) {
    ArmEnableInterrupts();
  }
  return;

newline:
  MicroSecondDelay(delay);
  m_Position.y += scale_factor;
  m_Position.x = 0;
  if (m_Position.y >= m_MaxPosition.y - scale_factor) {
    FbConFlush();
    m_Position.y = 0;

    if (intstate) {
      ArmEnableInterrupts();
    }
    goto paint;
  } else {
    base_y = (unsigned)(m_Position.y * FONT_HEIGHT * scale_factor);
    FbFillLogicalRect(
        0, base_y, (UINTN)gWidth, (UINTN)(FONT_HEIGHT * scale_factor),
        m_Color.Background);
    FbConFlush();
    if (intstate) {
      ArmEnableInterrupts();
    }
  }
}

void
FbConDrawglyph(
    unsigned base_x, unsigned base_y, unsigned *glyph, unsigned scale_factor)
{
  unsigned x;
  unsigned y;
  unsigned i;
  unsigned j;
  unsigned data;
  unsigned temp;
  unsigned fg_color;
  unsigned bg_color;

  for (y = 0; y < FONT_HEIGHT / 2; ++y) {
    for (i = 0; i < scale_factor; i++) {
      for (x = 0; x < FONT_WIDTH; ++x) {
        for (j = 0; j < scale_factor; j++) {
          FbPutPixelLogical(
              base_x + x * scale_factor + j,
              base_y + y * scale_factor + i,
              m_Color.Background);
        }
      }
    }
  }

  for (y = 0; y < FONT_HEIGHT / 2; ++y) {
    for (i = 0; i < scale_factor; i++) {
      for (x = 0; x < FONT_WIDTH; ++x) {
        for (j = 0; j < scale_factor; j++) {
          FbPutPixelLogical(
              base_x + x * scale_factor + j,
              base_y + (FONT_HEIGHT / 2 + y) * scale_factor + i,
              m_Color.Background);
        }
      }
    }
  }

  data = glyph[0];
  for (y = 0; y < FONT_HEIGHT / 2; ++y) {
    temp = data;
    for (i = 0; i < scale_factor; i++) {
      data = temp;
      for (x = 0; x < FONT_WIDTH; ++x) {
        if (data & 1) {
          fg_color = m_Color.Foreground;
          for (j = 0; j < scale_factor; j++) {
            FbPutPixelLogical(
                base_x + x * scale_factor + j,
                base_y + y * scale_factor + i,
                fg_color);
          }
        } else {
          bg_color = m_Color.Background;
          for (j = 0; j < scale_factor; j++) {
            FbPutPixelLogical(
                base_x + x * scale_factor + j,
                base_y + y * scale_factor + i,
                bg_color);
          }
        }
        data >>= 1;
      }
    }
  }

  data = glyph[1];
  for (y = 0; y < FONT_HEIGHT / 2; ++y) {
    temp = data;
    for (i = 0; i < scale_factor; i++) {
      data = temp;
      for (x = 0; x < FONT_WIDTH; ++x) {
        if (data & 1) {
          fg_color = m_Color.Foreground;
          for (j = 0; j < scale_factor; j++) {
            FbPutPixelLogical(
                base_x + x * scale_factor + j,
                base_y + (FONT_HEIGHT / 2 + y) * scale_factor + i,
                fg_color);
          }
        } else {
          bg_color = m_Color.Background;
          for (j = 0; j < scale_factor; j++) {
            FbPutPixelLogical(
                base_x + x * scale_factor + j,
                base_y + (FONT_HEIGHT / 2 + y) * scale_factor + i,
                bg_color);
          }
        }
        data >>= 1;
      }
    }
  }
}

void
FbConScrollUp(void)
{
  FbConFlush();
}

void
FbConFlush(void)
{
  WriteBackInvalidateDataCacheRange(
      (void *)(UINTN)FixedPcdGet32(PcdMipiFrameBufferAddress),
      (UINTN)mPhysWidth * mPhysHeight * (gBpp / 8));
}

UINTN
EFIAPI
SerialPortWrite(IN UINT8 *Buffer, IN UINTN NumberOfBytes)
{
  UINT8 *CONST Final          = &Buffer[NumberOfBytes];
  UINTN        InterruptState = ArmGetInterruptState();
  ArmDisableInterrupts();

  DaguDebugLogAppend(Buffer, NumberOfBytes);
  while (Buffer < Final) {
    FbConPutCharWithFactor(*Buffer++, FBCON_COMMON_MSG, mDrawScale);
  }

  if (InterruptState) {
    ArmEnableInterrupts();
  }
  return NumberOfBytes;
}

UINTN
EFIAPI
SerialPortWriteCritical(IN UINT8 *Buffer, IN UINTN NumberOfBytes)
{
  UINT8 *CONST Final             = &Buffer[NumberOfBytes];
  UINTN        CurrentForeground = m_Color.Foreground;
  UINTN        InterruptState    = ArmGetInterruptState();

  ArmDisableInterrupts();
  m_Color.Foreground = FB_BGRA8888_YELLOW;

  DaguDebugLogAppend(Buffer, NumberOfBytes);
  while (Buffer < Final) {
    FbConPutCharWithFactor(*Buffer++, FBCON_COMMON_MSG, mDrawScale);
  }

  m_Color.Foreground = CurrentForeground;

  if (InterruptState) {
    ArmEnableInterrupts();
  }
  return NumberOfBytes;
}

UINTN
EFIAPI
SerialPortRead(OUT UINT8 *Buffer, IN UINTN NumberOfBytes)
{
  return 0;
}

BOOLEAN
EFIAPI
SerialPortPoll(VOID)
{
  return FALSE;
}

RETURN_STATUS
EFIAPI
SerialPortSetControl(IN UINT32 Control)
{
  return RETURN_UNSUPPORTED;
}

RETURN_STATUS
EFIAPI
SerialPortGetControl(OUT UINT32 *Control)
{
  return RETURN_UNSUPPORTED;
}

RETURN_STATUS
EFIAPI
SerialPortSetAttributes(
    IN OUT UINT64 *BaudRate, IN OUT UINT32 *ReceiveFifoDepth,
    IN OUT UINT32 *Timeout, IN OUT EFI_PARITY_TYPE *Parity,
    IN OUT UINT8 *DataBits, IN OUT EFI_STOP_BITS_TYPE *StopBits)
{
  return RETURN_UNSUPPORTED;
}

UINTN
SerialPortFlush(VOID)
{
  return 0;
}

VOID
EnableSynchronousSerialPortIO(VOID)
{
}
