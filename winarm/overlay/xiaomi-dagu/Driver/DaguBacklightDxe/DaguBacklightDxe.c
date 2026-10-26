/** @file
  dagu (Xiaomi Pad 5 Pro 12.4) panel backlight.

  The L81A panel is lit by two Kinetic KTZ8866 LED drivers (I2C 0x11), one on
  each half of the panel:
    chip A: gpio60 SDA / gpio61 SCL   (CAF qupv3_se11)
    chip B: gpio125 SDA / gpio126 SCL (CAF qupv3_se9)
  XBL/ABL leave them in CAF PWM mode at the boot-splash level, and nothing in
  this chain-loaded UEFI (SimpleFbDxe, no DisplayDxe) or in Windows (no panel
  driver yet) ever raises it, so the panel stays almost black.

  Program both chips the way the dagu Linux ktz8866 driver does (same pins,
  bit-banged open-drain like Linux's i2c-gpio nodes, same register values),
  then hand the pins back to their original TLMM configuration.

  SPDX-License-Identifier: BSD-2-Clause-Patent
**/
#include <Uefi.h>
#include <Library/DebugLib.h>
#include <Library/IoLib.h>
#include <Library/TimerLib.h>
#include <Library/UefiDriverEntryPoint.h>

// SM8250 TLMM: gpio 60/61/125/126 are all in the SOUTH tile.
#define TLMM_SOUTH        0x0F500000UL
#define TLMM_CFG(g)       (TLMM_SOUTH + 0x1000UL * (g))
#define TLMM_IO(g)        (TLMM_CFG (g) + 4)
#define TLMM_CFG_OE       BIT9
// func_sel 0 (gpio), drive 2 mA, bias-disable: Linux ktz_i2c_*_default.
#define TLMM_CFG_GPIO_OD  0x0

#define KTZ_ADDR          0x11
#define KTZ_DEVICE_ID     0x01
#define KTZ_BL_CFG1       0x02
#define KTZ_BL_CFG2       0x03
#define KTZ_BL_BRT_LSB    0x04
#define KTZ_BL_BRT_MSB    0x05
#define KTZ_BL_EN         0x08
#define KTZ_BL_DIMMING    0x14
#define KTZ_PWM_RAMP_TIME 0x15

// 0..2047. Same as the Linux driver's DEFAULT_BRIGHTNESS.
#define DAGU_BACKLIGHT_LEVEL  1500

#define HALF_PERIOD_US    5           // ~100 kHz

typedef struct {
  UINT32       Sda;
  UINT32       Scl;
  CONST CHAR8  *Name;
} KTZ_BUS;

STATIC CONST KTZ_BUS  mBuses[] = {
  { 60,  61,  "A (se11)" },
  { 125, 126, "B (se9)"  },
};

// Open drain: release = input (external pull-up), low = drive the 0 latched in IN_OUT.
STATIC VOID
Line (UINT32 Gpio, BOOLEAN High)
{
  if (High) {
    MmioAnd32 (TLMM_CFG (Gpio), ~(UINT32)TLMM_CFG_OE);
  } else {
    MmioOr32 (TLMM_CFG (Gpio), TLMM_CFG_OE);
  }
  MicroSecondDelay (HALF_PERIOD_US);
}

STATIC BOOLEAN
Get (UINT32 Gpio)
{
  return (MmioRead32 (TLMM_IO (Gpio)) & 1) != 0;
}

STATIC BOOLEAN
SclHigh (CONST KTZ_BUS *Bus)
{
  UINTN  Wait;

  Line (Bus->Scl, TRUE);
  for (Wait = 0; Wait < 1000 && !Get (Bus->Scl); Wait++) {   // clock stretching
    MicroSecondDelay (1);
  }
  return Get (Bus->Scl);
}

STATIC VOID
Start (CONST KTZ_BUS *Bus)
{
  Line (Bus->Sda, TRUE);
  SclHigh (Bus);
  Line (Bus->Sda, FALSE);
  Line (Bus->Scl, FALSE);
}

STATIC VOID
Stop (CONST KTZ_BUS *Bus)
{
  Line (Bus->Sda, FALSE);
  SclHigh (Bus);
  Line (Bus->Sda, TRUE);
}

// Returns TRUE on ACK.
STATIC BOOLEAN
WriteByte (CONST KTZ_BUS *Bus, UINT8 Byte)
{
  INTN     Bit;
  BOOLEAN  Ack;

  for (Bit = 7; Bit >= 0; Bit--) {
    Line (Bus->Sda, (Byte >> Bit) & 1);
    SclHigh (Bus);
    Line (Bus->Scl, FALSE);
  }
  Line (Bus->Sda, TRUE);
  SclHigh (Bus);
  Ack = !Get (Bus->Sda);
  Line (Bus->Scl, FALSE);
  return Ack;
}

STATIC UINT8
ReadByte (CONST KTZ_BUS *Bus)
{
  INTN   Bit;
  UINT8  Byte = 0;

  Line (Bus->Sda, TRUE);
  for (Bit = 7; Bit >= 0; Bit--) {
    SclHigh (Bus);
    Byte |= (UINT8)(Get (Bus->Sda) << Bit);
    Line (Bus->Scl, FALSE);
  }
  SclHigh (Bus);                       // NACK: single-byte read
  Line (Bus->Scl, FALSE);
  return Byte;
}

STATIC EFI_STATUS
KtzWrite (CONST KTZ_BUS *Bus, UINT8 Reg, UINT8 Val)
{
  BOOLEAN  Ok;

  Start (Bus);
  Ok = WriteByte (Bus, KTZ_ADDR << 1) && WriteByte (Bus, Reg) && WriteByte (Bus, Val);
  Stop (Bus);
  return Ok ? EFI_SUCCESS : EFI_DEVICE_ERROR;
}

STATIC EFI_STATUS
KtzRead (CONST KTZ_BUS *Bus, UINT8 Reg, UINT8 *Val)
{
  BOOLEAN  Ok;

  Start (Bus);
  Ok = WriteByte (Bus, KTZ_ADDR << 1) && WriteByte (Bus, Reg);
  if (Ok) {
    Start (Bus);                       // repeated start
    Ok = WriteByte (Bus, (KTZ_ADDR << 1) | 1);
    if (Ok) {
      *Val = ReadByte (Bus);
    }
  }
  Stop (Bus);
  return Ok ? EFI_SUCCESS : EFI_DEVICE_ERROR;
}

STATIC VOID
BusRecover (CONST KTZ_BUS *Bus)
{
  UINTN  i;

  // A slave left mid-byte holds SDA low; nine clocks let it finish.
  for (i = 0; i < 9 && !Get (Bus->Sda); i++) {
    Line (Bus->Scl, FALSE);
    SclHigh (Bus);
  }
  Stop (Bus);
}

STATIC EFI_STATUS
ProgramChip (CONST KTZ_BUS *Bus)
{
  EFI_STATUS  Status;
  UINT8       Id = 0, Cfg1 = 0, Lsb = 0, Msb = 0;
  UINT32      Level = DAGU_BACKLIGHT_LEVEL;

  Status = KtzRead (Bus, KTZ_DEVICE_ID, &Id);
  if (EFI_ERROR (Status)) {
    DEBUG ((DEBUG_ERROR, "DaguBacklight %a: no ACK at 0x%02x\n", Bus->Name, KTZ_ADDR));
    return Status;
  }
  KtzRead (Bus, KTZ_BL_CFG1, &Cfg1);
  KtzRead (Bus, KTZ_BL_BRT_LSB, &Lsb);
  KtzRead (Bus, KTZ_BL_BRT_MSB, &Msb);
  DEBUG ((
    DEBUG_WARN,
    "DaguBacklight %a: id 0x%02x cfg1 0x%02x level %u -> %u\n",
    Bus->Name, Id, Cfg1, ((UINT32)Msb << 3) | (Lsb & 7), Level
    ));

  // ktz8866_init() + ktz8866_apply() from the dagu Linux driver.
  Status  = KtzWrite (Bus, KTZ_BL_CFG1, 0x52);          // I2C brightness only (PWM off), OVP 31.5 V
  Status |= KtzWrite (Bus, KTZ_BL_CFG2, BIT7 | 0x5);    // 1 us ramp, PWM hysteresis
  Status |= KtzWrite (Bus, KTZ_PWM_RAMP_TIME, 0x91);    // CAF dual full-scale current
  Status |= KtzWrite (Bus, KTZ_BL_DIMMING, 0x00);
  Status |= KtzWrite (Bus, KTZ_BL_EN, BIT6 | 0x1F);     // LED enable, 5 sinks
  Status |= KtzWrite (Bus, KTZ_BL_BRT_LSB, Level & 0x7);
  Status |= KtzWrite (Bus, KTZ_BL_BRT_MSB, (Level >> 3) & 0xFF);
  return EFI_ERROR (Status) ? EFI_DEVICE_ERROR : EFI_SUCCESS;
}

EFI_STATUS
EFIAPI
DaguBacklightDxeInitialize (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
  UINTN       i;
  UINT32      SavedSda, SavedScl;
  EFI_STATUS  Status;

  for (i = 0; i < ARRAY_SIZE (mBuses); i++) {
    CONST KTZ_BUS  *Bus = &mBuses[i];

    SavedSda = MmioRead32 (TLMM_CFG (Bus->Sda));
    SavedScl = MmioRead32 (TLMM_CFG (Bus->Scl));

    // Latch output 0, then switch both pins to released open-drain GPIO.
    MmioWrite32 (TLMM_IO (Bus->Sda), 0);
    MmioWrite32 (TLMM_IO (Bus->Scl), 0);
    MmioWrite32 (TLMM_CFG (Bus->Sda), TLMM_CFG_GPIO_OD);
    MmioWrite32 (TLMM_CFG (Bus->Scl), TLMM_CFG_GPIO_OD);
    MicroSecondDelay (20);
    BusRecover (Bus);

    Status = ProgramChip (Bus);
    if (EFI_ERROR (Status)) {
      BusRecover (Bus);
      Status = ProgramChip (Bus);     // one retry after recovery
    }
    DEBUG ((DEBUG_WARN, "DaguBacklight %a: %r\n", Bus->Name, Status));

    // Give the pins back to the QUP function XBL configured.
    MmioWrite32 (TLMM_CFG (Bus->Sda), SavedSda);
    MmioWrite32 (TLMM_CFG (Bus->Scl), SavedScl);
  }
  return EFI_SUCCESS;
}
