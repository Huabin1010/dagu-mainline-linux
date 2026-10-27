/** @file
  dagu QUP0 serial engines used by the keyboard, the touch panel and
  the Bluetooth UART.

  SE2 (0x988000) is the Nanosic 803 keyboard, I2C. SE4 (0x990000) is the
  Himax HX83121 touch panel, SPI. SE6 (0x998000) is the QCA6390 Bluetooth
  UART. XBL does not leave a protocol firmware in these engines
  (GENI_FW_REVISION_RO reads 0xFF), and Windows has no PEP to turn the
  clocks on, so this driver does both before ExitBootServices. After the
  SPI firmware is in, it programs mode 3 / 8-bit / 4 MHz and reads one
  Himax event so the PStore log shows whether the panel answered.

  Firmware comes from the stock qupv3fw.elf. Each engine gets only its own
  protocol image, written to its own IRAM, FIFO mode. The QUP wrapper CSRs
  (QUPV3_COMMON_CFG, QUPV3_SE_AHB_M_CFG, QUPV3_COMMON_CGC_CTRL) are never
  written: on this QHEE those writes drop the device to fastboot. GPI DMA
  and the interconnect voter are not used either. Same rule as the Linux
  qcom,skip-wrapper-fw-init path.

  SPDX-License-Identifier: BSD-2-Clause-Patent
**/
#include <Uefi.h>
#include <Guid/EventGroup.h>
#include <Library/BaseLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/DebugLib.h>
#include <Library/IoLib.h>
#include <Library/TimerLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiDriverEntryPoint.h>

// Clock protocol from edk2-msm EFIClock.h. Inlined so this driver does not
// depend on QcomPkg being on the Mu package path. Layout is the binary
// ClockDxe vtable: Version, GetClockID, Enable, Disable, IsEnabled, IsOn,
// SetClockFreqHz.
#define EFI_CLOCK_PROTOCOL_GUID \
  { 0x241AFAE6, 0x885F, 0x4F6C, { 0xA7, 0xEA, 0xC2, 0x8E, 0xAB, 0x79, 0xC3, 0xE5 } }

typedef enum {
  EfiClockFreqHzAtLeast = 0,
  EfiClockFreqHzAtMost  = 1,
  EfiClockFreqHzClosest = 2,
  EfiClockFreqHzExact   = 3,
} EFI_CLOCK_FREQUENCY_TYPE;

typedef struct _EFI_CLOCK_PROTOCOL EFI_CLOCK_PROTOCOL;

typedef
EFI_STATUS
(EFIAPI *EFI_CLOCK_GET_ID)(
  IN  EFI_CLOCK_PROTOCOL  *This,
  IN  CONST CHAR8         *ClockName,
  OUT UINTN               *ClockId
  );

typedef
EFI_STATUS
(EFIAPI *EFI_CLOCK_ENABLE)(
  IN EFI_CLOCK_PROTOCOL  *This,
  IN UINTN               ClockId
  );

typedef
EFI_STATUS
(EFIAPI *EFI_CLOCK_IS_ON)(
  IN  EFI_CLOCK_PROTOCOL  *This,
  IN  UINTN               ClockId,
  OUT BOOLEAN             *IsOn
  );

typedef
EFI_STATUS
(EFIAPI *EFI_CLOCK_SET_FREQ_HZ)(
  IN  EFI_CLOCK_PROTOCOL        *This,
  IN  UINTN                     ClockId,
  IN  UINT32                    Freq,
  IN  EFI_CLOCK_FREQUENCY_TYPE  Match,
  OUT UINT32                    *ResultFreq
  );

struct _EFI_CLOCK_PROTOCOL {
  UINT64                    Version;
  EFI_CLOCK_GET_ID          GetClockID;
  EFI_CLOCK_ENABLE          EnableClock;
  VOID                      *DisableClock;
  VOID                      *IsClockEnabled;
  EFI_CLOCK_IS_ON           IsClockOn;
  EFI_CLOCK_SET_FREQ_HZ     SetClockFreqHz;
};

STATIC EFI_GUID  mClockProtocolGuid = EFI_CLOCK_PROTOCOL_GUID;

// Stock ELF, generated into DaguQupFw.inc by build-dagu-uefi.sh.
STATIC CONST UINT8  mQupFw[] = {
  #include "DaguQupFw.inc"
};

#define SEFW_MAGIC  0x57464553u   // 'SEFW'
#define PT_LOAD     1u

#define PROTO_SPI   1u
#define PROTO_UART  2u
#define PROTO_I2C   3u

#define SE2_BASE    0x00988000u   // QUP0 SE2, keyboard I2C
#define SE4_BASE    0x00990000u   // QUP0 SE4, touch SPI
#define SE6_BASE    0x00998000u   // QUP0 SE6, Bluetooth UART
#define QUP0_WRAP   0x009C0000u   // read-only HW version; never write this

// spi-geni-qcom.c FIFO path. Mode 3, 8-bit, full duplex is opcode 1|2.
#define SE_GENI_M_CMD0              0x600
#define SE_GENI_M_CMD_CTRL_REG      0x604
#define SE_GENI_M_IRQ_STATUS        0x610
#define SE_GENI_M_IRQ_CLEAR         0x618
#define SE_GENI_TX_FIFOn            0x700
#define SE_GENI_RX_FIFOn            0x780
#define SE_GENI_TX_FIFO_STATUS      0x800
#define SE_GENI_RX_FIFO_STATUS      0x804
#define SE_GENI_TX_WATERMARK_REG    0x80c
#define GENI_SER_M_CLK_CFG          0x48
#define SE_GENI_CLK_SEL             0x7c
#define SE_GENI_BYTE_GRAN           0x254
#define SE_SPI_CPHA                 0x224
#define SE_SPI_LOOPBACK             0x22c
#define SE_SPI_CPOL                 0x230
#define SE_SPI_DEMUX_OUTPUT_INV     0x24c
#define SE_SPI_DEMUX_SEL            0x250
#define SE_SPI_TRANS_CFG            0x25c
#define SE_GENI_TX_PACKING_CFG0     0x260
#define SE_GENI_TX_PACKING_CFG1     0x264
#define SE_GENI_RX_PACKING_CFG0     0x284
#define SE_GENI_RX_PACKING_CFG1     0x288
#define SE_SPI_WORD_LEN             0x268
#define SE_SPI_TX_TRANS_LEN         0x26c
#define SE_SPI_RX_TRANS_LEN         0x270
#define SE_HW_PARAM_0               0xe24
#define QUPV3_HW_VER                0x4
#define M_OPCODE_SHIFT              27
#define M_CMD_DONE                  BIT0
#define M_CMD_FAILURE               (BIT2 | BIT3)
#define M_CMD_ABORT                 BIT1
#define SPI_TX_ONLY                 1u
#define SPI_RX_ONLY                 2u
#define SPI_CPHA_BIT                BIT0
#define SPI_CPOL_BIT                BIT2
#define SER_CLK_EN                  BIT0
#define CLK_DIV_SHIFT               4
#define RX_LAST                     BIT31
#define RX_LAST_BYTE_VALID_SHIFT    28
#define RX_FIFO_WC_MASK             0x01FFFFFFu
#define TX_FIFO_WC_MASK             0x0FFFFFFFu
#define HIMAX_XFER_LEN              59u
#define HIMAX_EVENT_LEN             56u

// geni-se.h / qcom-geni-se.c. SE-local only.
#define GENI_FORCE_DEFAULT_REG          0x20
#define GENI_OUTPUT_CTRL                0x24
#define SE_GENI_INIT_CFG_REVISION       0x00
#define SE_GENI_S_INIT_CFG_REVISION     0x04
#define SE_GENI_CGC_CTRL                0x28
#define GENI_FW_REVISION_RO             0x68
#define SE_GENI_CFG_REG0                0x100
#define SE_GENI_DMA_MODE_EN             0x258
#define SE_GENI_M_IRQ_EN                0x614
#define SE_GENI_S_IRQ_ENABLE            0x644
#define SE_GENI_RX_RFR_WATERMARK_REG    0x814
#define SE_DMA_TX_IRQ_EN_SET            0xc4c
#define SE_DMA_RX_IRQ_EN_SET            0xd4c
#define SE_HW_PARAM_1                   0xe28
#define SE_HW_PARAM_2                   0xe2c
#define SE_GSI_EVENT_EN                 0xe18
#define SE_IRQ_EN                       0xe1c
#define SE_DMA_GENERAL_CFG              0xe30
#define SE_GENI_FW_REVISION             0x1000
#define SE_GENI_S_FW_REVISION           0x1004
#define SE_GENI_CFG_RAMN                0x1010
#define SE_GENI_CLK_CTRL                0x2000
#define SE_DMA_IF_EN                    0x2004
#define SE_FIFO_IF_DISABLE              0x2008

#define PROG_RAM_HCLK_OFF   BIT8
#define PROG_RAM_SCLK_OFF   BIT9
#define DEFAULT_CGC_EN      0x7Fu
#define DEFAULT_IO_OUTPUT   0x7Fu
#define M_COMMON_IRQ_EN     0x33C0007Eu
#define S_COMMON_IRQ_EN     0x03001E36u
#define DMA_TX_IRQ_EN       (BIT0 | BIT2 | BIT3)
#define DMA_RX_IRQ_EN       (BIT0 | BIT2 | BIT3 | BIT4)
#define DMA_CSR_CGC_ON      (BIT0 | BIT1 | BIT2 | BIT3)
#define FIFO_IRQ_EN         (BIT0 | BIT1 | BIT2 | BIT3)

// SM8250 TLMM. Register offset is 0x1000 * global gpio, plus the tile.
#define TLMM_WEST   0x0F100000u
#define TLMM_SOUTH  0x0F500000u
#define TLMM_NORTH  0x0F900000u

#define GPIO_PULL_UP  3u
#define GPIO_FUNC_QUP 1u
#define GPIO_DRV_2MA  0u
#define GPIO_DRV_6MA  2u
#define GPIO_DRV_8MA  3u

typedef struct {
  CONST CHAR8  *Name;
  UINT32       Hz;
  UINTN        Id;
  BOOLEAN      Ok;
} QUP_CLK;

STATIC QUP_CLK  mClocks[] = {
  { "gcc_qupv3_wrap0_core_2x_clk",  0,          0, FALSE },
  { "gcc_qupv3_wrap0_core_clk",     0,          0, FALSE },
  { "gcc_qupv3_wrap_0_m_ahb_clk",   0,          0, FALSE },
  { "gcc_qupv3_wrap_0_s_ahb_clk",   0,          0, FALSE },
  { "gcc_qupv3_wrap0_s2_clk",       19200000u,  0, FALSE },
  { "gcc_qupv3_wrap0_s4_clk",       19200000u,  0, FALSE },
  { "gcc_qupv3_wrap0_s6_clk",       19200000u,  0, FALSE },
};

STATIC EFI_CLOCK_PROTOCOL  *mClock;

STATIC UINT32
Rd32 (
  CONST UINT8  *P
  )
{
  UINT32  V;

  CopyMem (&V, P, sizeof (V));
  return V;
}

STATIC UINT16
Rd16 (
  CONST UINT8  *P
  )
{
  UINT16  V;

  CopyMem (&V, P, sizeof (V));
  return V;
}

STATIC VOID
SetBits (
  UINTN  Addr,
  UINT32 Mask
  )
{
  MmioWrite32 (Addr, MmioRead32 (Addr) | Mask);
}

STATIC VOID
ClrBits (
  UINTN  Addr,
  UINT32 Mask
  )
{
  MmioWrite32 (Addr, MmioRead32 (Addr) & ~Mask);
}

// Find the PT_LOAD segment whose SEFW header matches Protocol.
// Returns the header pointer and the word count Linux writes into IRAM
// (fw_size_in_items rounded up to even).
STATIC CONST UINT8 *
FindFw (
  UINT32  Protocol,
  UINT32  *Words
  )
{
  UINT32  PhOff, PhEnt, PhNum, I;

  if (mQupFw[0] != 0x7F || mQupFw[4] != 1) {
    return NULL;
  }

  PhOff = Rd32 (mQupFw + 28);
  PhEnt = Rd16 (mQupFw + 42);
  PhNum = Rd16 (mQupFw + 44);
  if (PhEnt < 32 || PhNum < 2 || PhOff + PhNum * PhEnt > sizeof (mQupFw)) {
    return NULL;
  }

  for (I = 0; I < PhNum; I++) {
    CONST UINT8  *Ph = mQupFw + PhOff + I * PhEnt;
    UINT32       Type = Rd32 (Ph + 0);
    UINT32       Off = Rd32 (Ph + 4);
    UINT32       FileSz = Rd32 (Ph + 16);
    UINT32       MemSz = Rd32 (Ph + 20);
    UINT32       Flags = Rd32 (Ph + 24);
    CONST UINT8  *Hdr;
    UINT32       FwWords, FwEnd, CfgIdxEnd, CfgValEnd, CfgItems;

    if (Type != PT_LOAD || MemSz == 0) {
      continue;
    }
    // MI_PBT: page mode must be non-paged (0); drop hash / unused / shared.
    if (((Flags >> 20) & 1u) != 0) {
      continue;
    }
    if (((Flags >> 24) & 7u) == 2u) {
      continue;
    }
    if (((Flags >> 21) & 7u) == 3u || ((Flags >> 21) & 7u) == 4u) {
      continue;
    }
    if (FileSz < 28 || Off > sizeof (mQupFw) || FileSz > sizeof (mQupFw) - Off) {
      continue;
    }

    Hdr = mQupFw + Off;
    if (Rd32 (Hdr + 0) != SEFW_MAGIC || Rd32 (Hdr + 4) != 1) {
      continue;
    }
    if (Rd16 (Hdr + 12) != Protocol) {
      continue;
    }

    // se_fw_hdr: proto@12 fwver@14 cfgver@16 fw_items@18 fw_off@20
    // cfg_items@22 cfg_idx@24 cfg_val@26. All little endian.
    FwWords = Rd16 (Hdr + 18);
    if (FwWords & 1u) {
      FwWords++;
    }
    CfgItems = Rd16 (Hdr + 22);
    FwEnd = (UINT32)Rd16 (Hdr + 20) + FwWords * 4u;
    CfgIdxEnd = (UINT32)Rd16 (Hdr + 24) + CfgItems;
    CfgValEnd = (UINT32)Rd16 (Hdr + 26) + CfgItems * 4u;
    if (FwEnd > FileSz || CfgIdxEnd > FileSz || CfgValEnd > FileSz) {
      continue;
    }

    *Words = FwWords;
    return Hdr;
  }

  return NULL;
}

STATIC VOID
LoadSe (
  UINTN         Base,
  UINT32        Protocol,
  CONST CHAR8   *Name
  )
{
  CONST UINT8  *Hdr;
  UINT32       Words, CfgItems, I, Depth, Before, After;

  Hdr = FindFw (Protocol, &Words);
  if (Hdr == NULL) {
    DEBUG ((DEBUG_ERROR, "DaguQup %a: no proto %u segment\n", Name, Protocol));
    return;
  }

  Depth = (MmioRead32 (Base + SE_HW_PARAM_2) & 0x7FFu);
  if (Words >= Depth) {
    DEBUG ((
      DEBUG_ERROR,
      "DaguQup %a: fw %u words does not fit in %u\n",
      Name, Words, Depth
      ));
    return;
  }

  Before = MmioRead32 (Base + GENI_FW_REVISION_RO);

  // Same sequence as geni_load_se_fw(), without the wrapper CSR writes,
  // the interconnect vote, or the clock-off at the end.
  MmioWrite32 (Base + GENI_OUTPUT_CTRL, 0);
  SetBits (Base + SE_GENI_CGC_CTRL, PROG_RAM_SCLK_OFF | PROG_RAM_HCLK_OFF);
  MmioWrite32 (Base + SE_GENI_CLK_CTRL, 0);
  ClrBits (Base + SE_GENI_CGC_CTRL, PROG_RAM_SCLK_OFF | PROG_RAM_HCLK_OFF);

  SetBits (Base + SE_DMA_GENERAL_CFG, DMA_CSR_CGC_ON);
  MmioWrite32 (Base + SE_GENI_CGC_CTRL, DEFAULT_CGC_EN);

  MmioWrite32 (Base + SE_GENI_INIT_CFG_REVISION, Rd16 (Hdr + 16));
  MmioWrite32 (Base + SE_GENI_S_INIT_CFG_REVISION, Rd16 (Hdr + 16));

  CfgItems = Rd16 (Hdr + 22);
  for (I = 0; I < CfgItems; I++) {
    UINT8   Idx = Hdr[Rd16 (Hdr + 24) + I];
    UINT32  Val = Rd32 (Hdr + Rd16 (Hdr + 26) + I * 4u);

    MmioWrite32 (Base + SE_GENI_CFG_REG0 + (UINTN)Idx * 4u, Val);
  }

  Depth = (MmioRead32 (Base + SE_HW_PARAM_1) >> 16) & 0x3Fu;
  if (Depth >= 2) {
    MmioWrite32 (Base + SE_GENI_RX_RFR_WATERMARK_REG, Depth - 2);
  }

  SetBits (Base + GENI_OUTPUT_CTRL, DEFAULT_IO_OUTPUT);

  ClrBits (Base + SE_GENI_DMA_MODE_EN, BIT0);
  MmioWrite32 (Base + SE_IRQ_EN, FIFO_IRQ_EN);
  MmioWrite32 (Base + SE_GSI_EVENT_EN, 0);

  MmioWrite32 (Base + SE_GENI_M_IRQ_EN, M_COMMON_IRQ_EN);
  MmioWrite32 (Base + SE_GENI_S_IRQ_ENABLE, S_COMMON_IRQ_EN);
  MmioWrite32 (Base + SE_DMA_TX_IRQ_EN_SET, DMA_TX_IRQ_EN);
  MmioWrite32 (Base + SE_DMA_RX_IRQ_EN_SET, DMA_RX_IRQ_EN);

  {
    UINT32  Rev = ((UINT32)(Rd16 (Hdr + 12) & 0xFFu) << 8) |
                  (Rd16 (Hdr + 14) & 0xFFu);

    MmioWrite32 (Base + SE_GENI_FW_REVISION, Rev);
    MmioWrite32 (Base + SE_GENI_S_FW_REVISION, Rev);
  }

  for (I = 0; I < Words; I++) {
    MmioWrite32 (
      Base + SE_GENI_CFG_RAMN + (UINTN)I * 4u,
      Rd32 (Hdr + Rd16 (Hdr + 20) + I * 4u)
      );
  }

  MmioWrite32 (Base + GENI_FORCE_DEFAULT_REG, BIT0);
  SetBits (Base + SE_GENI_CGC_CTRL, PROG_RAM_SCLK_OFF | PROG_RAM_HCLK_OFF);
  SetBits (Base + SE_GENI_CLK_CTRL, BIT0);
  ClrBits (Base + SE_GENI_CGC_CTRL, PROG_RAM_SCLK_OFF | PROG_RAM_HCLK_OFF);
  SetBits (Base + SE_DMA_IF_EN, BIT0);
  ClrBits (Base + SE_FIFO_IF_DISABLE, BIT0);

  After = MmioRead32 (Base + GENI_FW_REVISION_RO);
  DEBUG ((
    DEBUG_ERROR,
    "DaguQup %a: proto %u fw 0x%x cfg %u  rev %08x -> %08x\n",
    Name, Protocol, Rd16 (Hdr + 14), Rd16 (Hdr + 16), Before, After
    ));
}

STATIC VOID
ApplyClock (
  EFI_CLOCK_PROTOCOL  *Clock,
  QUP_CLK             *Item
  )
{
  EFI_STATUS  Status;
  UINT32      Got = 0;
  BOOLEAN     On = FALSE;

  Status = Clock->GetClockID (Clock, Item->Name, &Item->Id);
  if (EFI_ERROR (Status)) {
    DEBUG ((DEBUG_ERROR, "DaguQup clk %a: id %r\n", Item->Name, Status));
    return;
  }

  if (Item->Hz != 0) {
    Status = Clock->SetClockFreqHz (
                      Clock, Item->Id, Item->Hz,
                      EfiClockFreqHzExact, &Got
                      );
    if (EFI_ERROR (Status)) {
      Status = Clock->SetClockFreqHz (
                        Clock, Item->Id, Item->Hz,
                        EfiClockFreqHzAtLeast, &Got
                        );
    }
    if (EFI_ERROR (Status)) {
      DEBUG ((DEBUG_ERROR, "DaguQup clk %a: freq %r\n", Item->Name, Status));
    } else {
      DEBUG ((DEBUG_ERROR, "DaguQup clk %a: %u Hz\n", Item->Name, Got));
    }
  }

  Status = Clock->EnableClock (Clock, Item->Id);
  if (EFI_ERROR (Status)) {
    DEBUG ((DEBUG_ERROR, "DaguQup clk %a: enable %r\n", Item->Name, Status));
    return;
  }

  Clock->IsClockOn (Clock, Item->Id, &On);
  Item->Ok = On;
  DEBUG ((DEBUG_ERROR, "DaguQup clk %a: on=%u\n", Item->Name, On));
}

STATIC VOID
EFIAPI
KeepClocks (
  IN EFI_EVENT  Event,
  IN VOID       *Context
  )
{
  UINTN  I;

  if (mClock == NULL) {
    return;
  }
  for (I = 0; I < ARRAY_SIZE (mClocks); I++) {
    if (mClocks[I].Ok) {
      mClock->EnableClock (mClock, mClocks[I].Id);
    }
  }
}

STATIC VOID
GpioCfg (
  UINTN   Tile,
  UINT32  Gpio,
  UINT32  Pull,
  UINT32  Func,
  UINT32  Drv,
  BOOLEAN Output,
  BOOLEAN High
  )
{
  UINTN  Cfg = Tile + 0x1000u * Gpio;

  MmioWrite32 (Cfg + 4, High ? BIT1 : 0);
  MmioWrite32 (Cfg, Pull | (Func << 2) | (Drv << 6) | (Output ? BIT9 : 0));
}

STATIC UINT32
FifoDepth (
  UINTN  Base
  )
{
  UINT32  Ver, Major, Minor, Mask, Val;

  Ver = MmioRead32 (QUP0_WRAP + QUPV3_HW_VER);
  Major = (Ver >> 28) & 0xFu;
  Minor = (Ver >> 16) & 0xFFFu;
  if ((Major == 3 && Minor >= 10) || Major > 3) {
    Mask = 0xFFu << 16;
  } else {
    Mask = 0x3Fu << 16;
  }
  Val = (MmioRead32 (Base + SE_HW_PARAM_0) & Mask) >> 16;
  if (Val < 4 || Val > 64) {
    Val = 16;
  }
  return Val;
}

STATIC VOID
ConfigPacking (
  UINTN  Base
  )
{
  // 8-bit, 4 words per FIFO entry, MSB first. Same result as
  // geni_se_config_packing(se, 8, 4, true, true, true).
  UINT32  Cfg[4];
  INT32   Idx, I;
  UINT32  Cfg0, Cfg1;

  // bpw 8 always takes the temp_bpw <= 8 arm: idx walks 7, 15, 23, 31.
  Idx = 7;
  for (I = 0; I < 4; I++) {
    Cfg[I] = ((UINT32)Idx << 5) | (1u << 4) | (7u << 1);
    Idx = ((I + 1) * 8) + 7;
  }
  Cfg[3] |= 1u;
  Cfg0 = Cfg[0] | (Cfg[1] << 10);
  Cfg1 = Cfg[2] | (Cfg[3] << 10);
  MmioWrite32 (Base + SE_GENI_TX_PACKING_CFG0, Cfg0);
  MmioWrite32 (Base + SE_GENI_TX_PACKING_CFG1, Cfg1);
  MmioWrite32 (Base + SE_GENI_RX_PACKING_CFG0, Cfg0);
  MmioWrite32 (Base + SE_GENI_RX_PACKING_CFG1, Cfg1);
  MmioWrite32 (Base + SE_GENI_BYTE_GRAN, 0);
}

STATIC VOID
SpiPump (
  UINTN         Base,
  CONST UINT8   *Tx,
  UINT8         *Rx,
  UINT32        Len,
  UINT32        Depth,
  UINT32        *TxOff,
  UINT32        *RxOff
  )
{
  UINT32  TxWc, RxSt, RxWords, RxBytes, Valid, I, Word, N;
  UINT8   *Bytes;

  TxWc = MmioRead32 (Base + SE_GENI_TX_FIFO_STATUS) & TX_FIFO_WC_MASK;
  while (*TxOff < Len && TxWc + 1u < Depth) {
    Word = 0;
    N = Len - *TxOff;
    if (N > 4) {
      N = 4;
    }
    for (I = 0; I < N; I++) {
      Word |= ((UINT32)Tx[*TxOff + I]) << (8u * I);
    }
    MmioWrite32 (Base + SE_GENI_TX_FIFOn, Word);
    *TxOff += N;
    TxWc++;
  }

  RxSt = MmioRead32 (Base + SE_GENI_RX_FIFO_STATUS);
  RxWords = RxSt & RX_FIFO_WC_MASK;
  RxBytes = RxWords * 4u;
  if ((RxSt & RX_LAST) != 0) {
    Valid = (RxSt >> RX_LAST_BYTE_VALID_SHIFT) & 7u;
    if (Valid != 0 && Valid < 4 && RxBytes >= 4) {
      RxBytes -= 4u - Valid;
    }
  }
  if (*RxOff + RxBytes > Len) {
    RxBytes = Len - *RxOff;
  }
  Bytes = Rx + *RxOff;
  for (I = 0; I < RxBytes; ) {
    Word = MmioRead32 (Base + SE_GENI_RX_FIFOn);
    N = RxBytes - I;
    if (N > 4) {
      N = 4;
    }
    while (N-- != 0) {
      Bytes[I++] = (UINT8)(Word & 0xFFu);
      Word >>= 8;
    }
  }
  *RxOff += RxBytes;
}

STATIC BOOLEAN
SpiXfer (
  UINTN         Base,
  CONST UINT8   *Tx,
  UINT8         *Rx,
  UINT32        Len
  )
{
  UINT32  Depth, Div, TxOff, RxOff, Irq, Spins, Ver, Major, Minor;
  UINT32  Cmd;

  if (Len == 0 || Len > 256) {
    return FALSE;
  }

  Ver = MmioRead32 (QUP0_WRAP + QUPV3_HW_VER);
  Major = (Ver >> 28) & 0xFu;
  Minor = (Ver >> 16) & 0xFFFu;
  // GENI 1.0 oversamples by 2. Everything later, including this QUP, by 1.
  Div = (Major == 1 && Minor == 0) ? 3u : 5u;
  Depth = FifoDepth (Base);

  MmioWrite32 (Base + SE_SPI_LOOPBACK, 0);
  MmioWrite32 (Base + SE_SPI_DEMUX_SEL, 0);
  MmioWrite32 (Base + SE_SPI_DEMUX_OUTPUT_INV, 0);
  MmioWrite32 (Base + SE_SPI_CPHA, SPI_CPHA_BIT);
  MmioWrite32 (Base + SE_SPI_CPOL, SPI_CPOL_BIT);
  MmioWrite32 (Base + SE_SPI_TRANS_CFG,
               MmioRead32 (Base + SE_SPI_TRANS_CFG) & ~BIT1);
  MmioWrite32 (Base + SE_SPI_WORD_LEN, 4);
  ConfigPacking (Base);
  MmioWrite32 (Base + SE_GENI_CLK_SEL, 0);
  MmioWrite32 (Base + GENI_SER_M_CLK_CFG, (Div << CLK_DIV_SHIFT) | SER_CLK_EN);
  MmioWrite32 (Base + SE_GENI_TX_WATERMARK_REG, 0);
  MmioWrite32 (Base + SE_SPI_TX_TRANS_LEN, Len);
  MmioWrite32 (Base + SE_SPI_RX_TRANS_LEN, Len);
  MmioWrite32 (Base + SE_GENI_M_IRQ_CLEAR, 0xFFFFFFFFu);

  Cmd = ((SPI_TX_ONLY | SPI_RX_ONLY) << M_OPCODE_SHIFT);
  MmioWrite32 (Base + SE_GENI_M_CMD0, Cmd);

  TxOff = 0;
  RxOff = 0;
  for (Spins = 0; Spins < 5000; Spins++) {
    SpiPump (Base, Tx, Rx, Len, Depth, &TxOff, &RxOff);
    Irq = MmioRead32 (Base + SE_GENI_M_IRQ_STATUS);
    if ((Irq & M_CMD_FAILURE) != 0) {
      MmioWrite32 (Base + SE_GENI_M_CMD_CTRL_REG, M_CMD_ABORT);
      DEBUG ((DEBUG_ERROR, "DaguQup SPI: cmd fail irq %08x\n", Irq));
      return FALSE;
    }
    if ((Irq & M_CMD_DONE) != 0 && RxOff >= Len) {
      MmioWrite32 (Base + SE_GENI_M_IRQ_CLEAR, Irq);
      return TRUE;
    }
    MicroSecondDelay (10);
  }

  MmioWrite32 (Base + SE_GENI_M_CMD_CTRL_REG, M_CMD_ABORT);
  DEBUG ((
    DEBUG_ERROR,
    "DaguQup SPI: timeout tx %u rx %u irq %08x\n",
    TxOff, RxOff, MmioRead32 (Base + SE_GENI_M_IRQ_STATUS)
    ));
  return FALSE;
}

STATIC VOID
ProbeHimax (
  VOID
  )
{
  UINT8    Tx[HIMAX_XFER_LEN];
  UINT8    Rx[HIMAX_XFER_LEN];
  UINT32   Sum, I, Rev, Level;
  BOOLEAN  Ok;

  Rev = MmioRead32 (SE4_BASE + GENI_FW_REVISION_RO);
  if (((Rev >> 8) & 0xFFu) != PROTO_SPI) {
    DEBUG ((DEBUG_ERROR, "DaguQup touch: SE4 proto %u, skip\n", (Rev >> 8) & 0xFFu));
    return;
  }

  SetMem (Tx, sizeof (Tx), 0);
  SetMem (Rx, sizeof (Rx), 0);
  Tx[0] = 0xF3;
  Tx[1] = 0x30;
  Ok = SpiXfer (SE4_BASE, Tx, Rx, HIMAX_XFER_LEN);
  Sum = 0;
  for (I = 3; I < HIMAX_XFER_LEN; I++) {
    Sum += Rx[I];
  }
  Level = MmioRead32 (TLMM_SOUTH + 0x1000u * 39u + 4u) & 1u;
  DEBUG ((
    DEBUG_ERROR,
    "DaguQup touch: %a irq=%u n52=%02x xy=%02x%02x %02x%02x sum=%02x\n",
    Ok ? "read" : "fail", Level, Rx[3 + 52],
    Rx[3], Rx[4], Rx[5], Rx[6], Sum & 0xFFu
    ));
}

STATIC VOID
MuxQup (
  VOID
  )
{
  UINT32  Gpio;

  // gpio8-11 function qup4, 6 mA, no pull. NORTH tile.
  for (Gpio = 8; Gpio <= 11; Gpio++) {
    GpioCfg (TLMM_NORTH, Gpio, 0, GPIO_FUNC_QUP, GPIO_DRV_6MA, FALSE, FALSE);
  }
  // gpio115/116 function qup2, 2 mA, no pull. NORTH tile.
  GpioCfg (TLMM_NORTH, 115, 0, GPIO_FUNC_QUP, GPIO_DRV_2MA, FALSE, FALSE);
  GpioCfg (TLMM_NORTH, 116, 0, GPIO_FUNC_QUP, GPIO_DRV_2MA, FALSE, FALSE);
  // gpio16-19 function qup6, UART6 to the QCA6390 Bluetooth port.
  for (Gpio = 16; Gpio <= 19; Gpio++) {
    GpioCfg (TLMM_NORTH, Gpio, GPIO_PULL_UP, GPIO_FUNC_QUP, GPIO_DRV_2MA, FALSE, FALSE);
  }
  // WLAN_EN gpio20 and BT_EN gpio21 stay low until the rails are voted.
  // Driving them high with S5 / L16 off leaves the chip half-powered.
  GpioCfg (TLMM_NORTH, 20, 0, 0, GPIO_DRV_2MA, TRUE, FALSE);
  GpioCfg (TLMM_NORTH, 21, 0, 0, GPIO_DRV_2MA, TRUE, FALSE);

  // Himax IRQ gpio39, input, pull-up. SOUTH tile. Do not touch gpio100.
  GpioCfg (TLMM_SOUTH, 39, GPIO_PULL_UP, 0, GPIO_DRV_8MA, FALSE, FALSE);
  // Keyboard IRQ gpio83 and status gpio46, inputs.
  GpioCfg (TLMM_NORTH, 83, 0, 0, GPIO_DRV_2MA, FALSE, FALSE);
  GpioCfg (TLMM_SOUTH, 46, 0, 0, GPIO_DRV_2MA, FALSE, FALSE);
}

STATIC VOID
PowerKeyboard (
  VOID
  )
{
  // reset gpio141 and sleep gpio155 are WEST. vdd gpio127 is SOUTH.
  // Linux nanosic_power_on: both low, vdd high, 2 ms, both high, 100 ms.
  GpioCfg (TLMM_WEST, 141, 0, 0, GPIO_DRV_2MA, TRUE, FALSE);
  GpioCfg (TLMM_WEST, 155, 0, 0, GPIO_DRV_2MA, TRUE, FALSE);
  GpioCfg (TLMM_SOUTH, 127, 0, 0, GPIO_DRV_2MA, TRUE, TRUE);
  MicroSecondDelay (2000);
  GpioCfg (TLMM_WEST, 141, 0, 0, GPIO_DRV_2MA, TRUE, TRUE);
  GpioCfg (TLMM_WEST, 155, 0, 0, GPIO_DRV_2MA, TRUE, TRUE);
  MicroSecondDelay (100 * 1000);
  DEBUG ((DEBUG_ERROR, "DaguQup keyboard: vdd on, reset released\n"));
}

STATIC BOOLEAN
ClockOn (
  CONST CHAR8  *Name
  )
{
  UINTN  I;

  for (I = 0; I < ARRAY_SIZE (mClocks); I++) {
    if (AsciiStrCmp (mClocks[I].Name, Name) == 0) {
      return mClocks[I].Ok;
    }
  }
  return FALSE;
}

EFI_STATUS
EFIAPI
DaguQupDxeInitialize (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
  EFI_STATUS  Status;
  EFI_EVENT   Event;
  UINTN       I;
  BOOLEAN     Bus;

  Status = gBS->LocateProtocol (&mClockProtocolGuid, NULL, (VOID **)&mClock);
  if (EFI_ERROR (Status)) {
    DEBUG ((DEBUG_ERROR, "DaguQup: clock protocol %r\n", Status));
    return EFI_SUCCESS;
  }

  for (I = 0; I < ARRAY_SIZE (mClocks); I++) {
    ApplyClock (mClock, &mClocks[I]);
  }

  Status = gBS->CreateEventEx (
                  EVT_NOTIFY_SIGNAL,
                  TPL_CALLBACK,
                  KeepClocks,
                  NULL,
                  &gEfiEventExitBootServicesGuid,
                  &Event
                  );
  if (EFI_ERROR (Status)) {
    DEBUG ((DEBUG_ERROR, "DaguQup: exit-boot event %r\n", Status));
  }

  Bus = ClockOn ("gcc_qupv3_wrap0_core_clk") &&
        ClockOn ("gcc_qupv3_wrap_0_s_ahb_clk");
  MuxQup ();

  if (Bus && ClockOn ("gcc_qupv3_wrap0_s2_clk")) {
    LoadSe (SE2_BASE, PROTO_I2C, "SE2");
    PowerKeyboard ();
  } else {
    DEBUG ((DEBUG_ERROR, "DaguQup SE2: clocks off, MMIO skipped\n"));
  }

  if (Bus && ClockOn ("gcc_qupv3_wrap0_s4_clk")) {
    LoadSe (SE4_BASE, PROTO_SPI, "SE4");
    ProbeHimax ();
  } else {
    DEBUG ((DEBUG_ERROR, "DaguQup SE4: clocks off, MMIO skipped\n"));
  }

  if (Bus && ClockOn ("gcc_qupv3_wrap0_s6_clk")) {
    LoadSe (SE6_BASE, PROTO_UART, "SE6");
  } else {
    DEBUG ((DEBUG_ERROR, "DaguQup SE6: clocks off, MMIO skipped\n"));
  }

  return EFI_SUCCESS;
}
