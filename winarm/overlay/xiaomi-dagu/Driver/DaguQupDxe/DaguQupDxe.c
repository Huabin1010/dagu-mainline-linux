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

// PMIC voltage-regulator protocol from edk2-msm EFIPmicVreg.h. Inlined for the
// same reason as the clock protocol: QcomPkg is not on the Mu package path.
// Consumed by this firmware's own UFSDxe/UsbConfigDxe, so it is published at
// runtime. Used read-only here to learn which QCA6390 (Wi-Fi/BT) rails XBL
// already left on and how the PMIC device index / LDO-SMPS id map, before any
// enable sequence is written. Layout must match the binary vtable exactly.
#define EFI_PMICVREG_PROTOCOL_GUID \
  { 0x22d38d3d, 0xe8b6, 0x4f8f, { 0x9c, 0x26, 0xbc, 0xeb, 0x07, 0xd6, 0xcb, 0x68 } }

typedef enum { EFI_PM_OFF, EFI_PM_ON, EFI_PM_INVALID } EFI_PM_ON_OFF_TYPE;
typedef enum {
  EFI_PM_PWR_SW_MODE_PFM = 0, EFI_PM_PWR_SW_MODE_BYPASS = 1,
  EFI_PM_PWR_SW_MODE_AUTO = 2, EFI_PM_PWR_SW_MODE_NPM = 4,
  EFI_PM_PWR_SW_MODE_INVALID
} EFI_PM_PWR_SW_MODE_TYPE;

typedef struct {
  EFI_PM_ON_OFF_TYPE      PullDown;
  EFI_PM_PWR_SW_MODE_TYPE SwMode;
  EFI_PM_ON_OFF_TYPE      PinCtrled;
  EFI_PM_ON_OFF_TYPE      SwEnable;
  BOOLEAN                 VregOk;
} EFI_PM_VREG_STATUS_TYPE;

typedef struct _EFI_QCOM_PMIC_VREG_PROTOCOL EFI_QCOM_PMIC_VREG_PROTOCOL;

typedef EFI_STATUS (EFIAPI *EFI_PM_VREG_CONTROL)(UINT32, UINT32, BOOLEAN);
typedef EFI_STATUS (EFIAPI *EFI_PM_VREG_SET_LEVEL)(UINT32, UINT32, UINT32);
typedef EFI_STATUS (EFIAPI *EFI_PM_VREG_GET_LEVEL)(UINT32, UINT32, UINT32 *);
typedef EFI_STATUS (EFIAPI *EFI_PM_VREG_SET_PWR_MODE)(UINT32, UINT32, EFI_PM_PWR_SW_MODE_TYPE);
typedef EFI_STATUS (EFIAPI *EFI_PM_VREG_MULTIPHASE_CTRL)(UINT32, UINT32, UINT32);
typedef EFI_STATUS (EFIAPI *EFI_PM_VREG_GET_STATUS)(UINT32, UINT32, EFI_PM_VREG_STATUS_TYPE *);
typedef EFI_STATUS (EFIAPI *EFI_PM_VREG_SET_LEVEL_UV)(UINT32, UINT32, UINT32);

struct _EFI_QCOM_PMIC_VREG_PROTOCOL {
  UINT64                      Revision;
  EFI_PM_VREG_CONTROL         VregControl;
  EFI_PM_VREG_SET_LEVEL       VregSetLevel;
  EFI_PM_VREG_GET_LEVEL       VregGetLevel;
  EFI_PM_VREG_SET_PWR_MODE    VregSetPwrMode;
  EFI_PM_VREG_MULTIPHASE_CTRL VregMultiphaseCtrl;
  EFI_PM_VREG_GET_STATUS      VregGetStatus;
  EFI_PM_VREG_SET_LEVEL_UV    VregSetLevelUv;
};

STATIC EFI_GUID  mVregProtocolGuid = EFI_PMICVREG_PROTOCOL_GUID;

// 1 = run ProbeWcnPower() on this boot. build-dagu-uefi.sh rewrites this line
// in the build copy when DAGU_WCN_PROBE=1; the committed default is off.
#define DAGU_WCN_PROBE  0

// EFI_PM_VREG_ID_TYPE: LDO_1..33 are 0..32, then LDO_INVALID (33), then
// SMPS_1.. starts at 34. Index the enum arithmetically to avoid pasting all
// 60 names. dagu QCA6390 rails (sm8250-xiaomi-dagu.dts): vreg_s5a (2.0V
// override), vreg_s4a_1p8, vreg_s6a_0p95, vreg_s8c_1p35, vreg_l16a_3p0
// (antenna switch vddasd, Linux enables it by hand). "a" = PM8150 primary,
// "c" = PM8009. Which PMIC device index those map to is exactly what the
// probe prints.
#define VREG_LDO(n)   ((UINT32)((n) - 1))          // LDO_1 == 0
#define VREG_SMPS(n)  ((UINT32)(33 + (n)))         // SMPS_1 == 34

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

// Delay that does not depend on the firmware TimerLib (MicroSecondDelay is a
// no-op this early in DXE, which made the touch probe flash past). Busy-wait on
// the ARM generic timer counter (CNTVCT_EL0), which is always running.
STATIC VOID
DaguStallMs (
  IN UINT32  Ms
  )
{
  UINT64  Freq, Now, Target;

  __asm__ volatile ("mrs %0, cntfrq_el0" : "=r" (Freq));
  __asm__ volatile ("mrs %0, cntvct_el0" : "=r" (Now));
  Target = Now + (Freq * (UINT64)Ms) / 1000ULL;
  do {
    __asm__ volatile ("mrs %0, cntvct_el0" : "=r" (Now));
  } while (Now < Target);
}

// Bit-banged SPI on the CAF pins, like the Linux production "spi-gpio" node
// (the GENI engine is the disabled experiment and only ever returns 0xFF).
// gpio8=MISO gpio9=MOSI gpio10=SCK gpio11=CS(active-low), all NORTH tile.
// Mode 3: SCK idles high, MOSI shifted on the falling edge, MISO sampled on
// the rising edge, MSB first. TLMM: +0 cfg, +4 bit1=OUT / bit0=IN.
#define BB_MISO  8u
#define BB_MOSI  9u
#define BB_SCK   10u
#define BB_CS    11u
#define BB_IO(g) (TLMM_NORTH + 0x1000u * (g) + 4u)

STATIC VOID
BbOut (
  UINT32  Gpio,
  UINT32  Level
  )
{
  MmioWrite32 (BB_IO (Gpio), Level ? BIT1 : 0);
}

STATIC VOID
BitBangXfer (
  CONST UINT8  *Tx,
  UINT8        *Rx,
  UINT32       Len
  )
{
  UINT32  I, B, Out, In;

  GpioCfg (TLMM_NORTH, BB_MOSI, 0, 0, GPIO_DRV_2MA, TRUE, TRUE);
  GpioCfg (TLMM_NORTH, BB_SCK, 0, 0, GPIO_DRV_2MA, TRUE, TRUE);     // idle high
  GpioCfg (TLMM_NORTH, BB_CS, 0, 0, GPIO_DRV_2MA, TRUE, TRUE);      // idle high
  GpioCfg (TLMM_NORTH, BB_MISO, GPIO_PULL_UP, 0, GPIO_DRV_2MA, FALSE, FALSE);

  BbOut (BB_SCK, 1);
  BbOut (BB_CS, 1);
  BbOut (BB_CS, 0);                               // assert CS (active low)
  for (I = 0; I < Len; I++) {
    Out = Tx[I];
    In = 0;
    for (B = 0; B < 8; B++) {
      BbOut (BB_SCK, 0);                          // falling edge: shift
      BbOut (BB_MOSI, (Out & 0x80u) ? 1u : 0u);
      Out <<= 1;
      BbOut (BB_SCK, 1);                          // rising edge: sample
      In = (In << 1) | (MmioRead32 (BB_IO (BB_MISO)) & BIT0);
    }
    Rx[I] = (UINT8)In;
  }
  BbOut (BB_CS, 1);                               // deassert CS
}

STATIC VOID
ProbeHimax (
  VOID
  )
{
  UINT8    Tx[HIMAX_XFER_LEN];
  UINT8    Rx[HIMAX_XFER_LEN];
  UINT8    Cap[HIMAX_EVENT_LEN];
  UINT32   Rev, Level, Round, I, J, Score, BestScore, IrqLowN;
  BOOLEAN  Ok, CapSeen;

  (VOID)SpiXfer;   // GENI path kept compiled but unused; bit-bang drives touch

  Rev = MmioRead32 (SE4_BASE + GENI_FW_REVISION_RO);
  if (((Rev >> 8) & 0xFFu) != PROTO_SPI) {
    DEBUG ((DEBUG_ERROR, "DaguQup touch: SE4 proto %u, skip\n", (Rev >> 8) & 0xFFu));
    return;
  }

  // Diagnostic: capture the himax event frame (bit-banged) with the most data
  // with the most data bytes and dump its 56 raw bytes, so the real coordinate
  // layout can be decoded (the parser's payload[0..3]/[52] gives 0xFFFF). Hold
  // the dump on screen 60 s. DaguStallMs since MicroSecondDelay is a no-op here.
  SetMem (Cap, sizeof (Cap), 0);
  CapSeen = FALSE;
  BestScore = 0;
  IrqLowN = 0;
  DEBUG ((DEBUG_ERROR, "\n=== DAGU TOUCH CAPTURE: press & hold a finger on the screen (~12s) ===\n"));
  for (Round = 0; Round < 240; Round++) {
    SetMem (Tx, sizeof (Tx), 0);
    SetMem (Rx, sizeof (Rx), 0);
    Tx[0] = 0xF3;
    Tx[1] = 0x30;
    BitBangXfer (Tx, Rx, HIMAX_XFER_LEN);
    Ok = TRUE;
    Level = MmioRead32 (TLMM_SOUTH + 0x1000u * 39u + 4u) & 1u;
    if (Level == 0) {
      IrqLowN++;
    }
    if (Ok) {
      Score = 0;
      for (I = 0; I < HIMAX_EVENT_LEN; I++) {
        if ((Rx[3 + I] != 0x00) && (Rx[3 + I] != 0xFF)) {
          Score++;
        }
      }
      if (Score >= BestScore) {
        BestScore = Score;
        for (I = 0; I < HIMAX_EVENT_LEN; I++) {
          Cap[I] = Rx[3 + I];
        }
        CapSeen = TRUE;
      }
    }
    DaguStallMs (50);
  }
  DEBUG ((
    DEBUG_ERROR,
    "\n=== DAGU TOUCH CAPTURE: seen=%u irqLowReads=%u dataBytes=%u (56-byte frame below, held 60s) ===\n",
    CapSeen, IrqLowN, BestScore
    ));
  for (J = 0; J < HIMAX_EVENT_LEN; J += 14) {
    DEBUG ((
      DEBUG_ERROR,
      "CAP[%02u]: %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x\n",
      J, Cap[J + 0], Cap[J + 1], Cap[J + 2], Cap[J + 3], Cap[J + 4], Cap[J + 5],
      Cap[J + 6], Cap[J + 7], Cap[J + 8], Cap[J + 9], Cap[J + 10], Cap[J + 11],
      Cap[J + 12], Cap[J + 13]
      ));
  }
  DaguStallMs (60000);
}

// Read-only census of the QCA6390 (Wi-Fi + BT) power rails. Prints, per PMIC
// device index, whether the candidate rails are enabled and at what level, so
// the enable sequence can be written against real indices instead of guesses.
// Also samples WLAN_EN gpio20 / BT_EN gpio21 before and after asserting them
// (asserting a PMU enable with its rail off only half-powers the chip, it does
// not damage it), so we can see the chip's own power-good feedback if any.
// Held on screen; run only on a dedicated probe boot.
STATIC VOID
ProbeWcnPower (
  VOID
  )
{
  EFI_QCOM_PMIC_VREG_PROTOCOL  *Vreg;
  EFI_STATUS                   Status;
  UINT32                       Dev;
  // (name, vreg-id) candidates for the WCN rails on SM8250 + dagu.
  STATIC CONST struct { CONST CHAR8 *Name; UINT32 Id; } Rails[] = {
    { "SMPS4", VREG_SMPS (4) },
    { "SMPS5", VREG_SMPS (5) },
    { "SMPS6", VREG_SMPS (6) },
    { "SMPS8", VREG_SMPS (8) },
    { "LDO9",  VREG_LDO (9)  },
    { "LDO16", VREG_LDO (16) },
  };
  UINTN  R;

  Status = gBS->LocateProtocol (&mVregProtocolGuid, NULL, (VOID **)&Vreg);
  if (EFI_ERROR (Status)) {
    DEBUG ((DEBUG_ERROR, "\n=== DAGU WCN POWER: no PMIC VREG protocol (%r) ===\n", Status));
    DEBUG ((DEBUG_ERROR, "    rails cannot be voted from UEFI; must rely on XBL leaving them on\n"));
  } else {
    DEBUG ((DEBUG_ERROR, "\n=== DAGU WCN POWER: PMIC VREG rev %016lx ===\n", Vreg->Revision));
    for (Dev = 0; Dev < 4; Dev++) {
      for (R = 0; R < ARRAY_SIZE (Rails); R++) {
        EFI_PM_VREG_STATUS_TYPE  St;
        UINT32                   Uv = 0;
        EFI_STATUS               Ss, Ls;

        Ss = Vreg->VregGetStatus (Dev, Rails[R].Id, &St);
        Ls = Vreg->VregGetLevel (Dev, Rails[R].Id, &Uv);
        if (EFI_ERROR (Ss) && EFI_ERROR (Ls)) {
          continue;
        }
        DEBUG ((
          DEBUG_ERROR,
          "  pmic%u %a: en=%u ok=%u mode=%u lvl=%u (st %r lvl %r)\n",
          Dev, Rails[R].Name,
          EFI_ERROR (Ss) ? 9 : St.SwEnable,
          EFI_ERROR (Ss) ? 9 : St.VregOk,
          EFI_ERROR (Ss) ? 9 : St.SwMode,
          Uv, Ss, Ls
          ));
      }
    }
  }

  // gpio20/21 live level before/after assert. BB_IO reads TLMM +4 bit0.
  DEBUG ((
    DEBUG_ERROR,
    "  gpio20=%u gpio21=%u (pre-assert)\n",
    MmioRead32 (TLMM_NORTH + 0x1000u * 20u + 4u) & 1u,
    MmioRead32 (TLMM_NORTH + 0x1000u * 21u + 4u) & 1u
    ));
  GpioCfg (TLMM_NORTH, 20, 0, 0, GPIO_DRV_2MA, TRUE, TRUE);   // WLAN_EN high
  GpioCfg (TLMM_NORTH, 21, 0, 0, GPIO_DRV_2MA, TRUE, TRUE);   // BT_EN high
  DaguStallMs (50);
  DEBUG ((
    DEBUG_ERROR,
    "  gpio20=%u gpio21=%u (post-assert) ===\n",
    MmioRead32 (TLMM_NORTH + 0x1000u * 20u + 4u) & 1u,
    MmioRead32 (TLMM_NORTH + 0x1000u * 21u + 4u) & 1u
    ));
  DEBUG ((DEBUG_ERROR, "=== DAGU WCN POWER: holding 90 s, then boot continues ===\n"));
  DaguStallMs (90000);
}

STATIC EFI_EVENT  mVregEvent;
STATIC VOID       *mVregReg;

STATIC VOID
EFIAPI
OnVregInstalled (
  IN EFI_EVENT  Event,
  IN VOID       *Context
  )
{
  VOID  *Vreg;

  if (EFI_ERROR (gBS->LocateProtocol (&mVregProtocolGuid, mVregReg, &Vreg))) {
    return;
  }
  gBS->CloseEvent (Event);
  ProbeWcnPower ();
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

  // The QUP wrapper AHB and core clocks are already running: SE MMIO reads
  // work (the clock/probe prints below are MMIO) and Android used these
  // engines. The UEFI clock protocol does not report them on by these exact
  // names, so ClockOn() for the AHB/core returned FALSE and skipped every
  // LoadSe -- which left SE4 without its SPI firmware, so the Himax saw no
  // real SPI and every read came back all-zero. Gate LoadSe on the per-SE
  // clock only (which the protocol does confirm); the AHB/core are on.
  Bus = TRUE;
  MuxQup ();

  if (Bus && ClockOn ("gcc_qupv3_wrap0_s2_clk")) {
    LoadSe (SE2_BASE, PROTO_I2C, "SE2");
    PowerKeyboard ();
  } else {
    DEBUG ((DEBUG_ERROR, "DaguQup SE2: clocks off, MMIO skipped\n"));
  }

  if (Bus && ClockOn ("gcc_qupv3_wrap0_s4_clk")) {
    LoadSe (SE4_BASE, PROTO_SPI, "SE4");
  } else {
    DEBUG ((DEBUG_ERROR, "DaguQup SE4: clocks off, MMIO skipped\n"));
  }
  // ProbeHimax ();  // held touch diagnostic (bit-bang confirmed working); disabled for normal boot
  (VOID)ProbeHimax; // keep compiled without -Werror unused-function

  if (Bus && ClockOn ("gcc_qupv3_wrap0_s6_clk")) {
    LoadSe (SE6_BASE, PROTO_UART, "SE6");
  } else {
    DEBUG ((DEBUG_ERROR, "DaguQup SE6: clocks off, MMIO skipped\n"));
  }

  // Wi-Fi/BT rail census, only in a probe build (DAGU_WCN_PROBE=1 in
  // build-dagu-uefi.sh). This driver is APRIORI-dispatched before PmicDxe, so
  // the VREG protocol does not exist yet: wait for PmicDxe to install it.
  // That also runs the probe before QcomWDogDxe arms the HW watchdog, so the
  // long on-screen hold cannot get bitten.
  if (DAGU_WCN_PROBE) {
    VOID  *Probe;

    if (!EFI_ERROR (gBS->LocateProtocol (&mVregProtocolGuid, NULL, &Probe))) {
      ProbeWcnPower ();
    } else {
      Status = gBS->CreateEvent (EVT_NOTIFY_SIGNAL, TPL_CALLBACK,
                                 OnVregInstalled, NULL, &mVregEvent);
      if (!EFI_ERROR (Status)) {
        Status = gBS->RegisterProtocolNotify (&mVregProtocolGuid, mVregEvent,
                                              &mVregReg);
      }
      DEBUG ((DEBUG_ERROR, "DaguQup WCN probe: waiting for PMIC VREG (%r)\n", Status));
    }
  }

  return EFI_SUCCESS;
}
