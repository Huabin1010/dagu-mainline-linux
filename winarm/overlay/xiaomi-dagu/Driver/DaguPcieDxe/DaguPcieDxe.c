/** @file
  dagu QCA6390 power-on and PCIe0 (Wi-Fi) bring-up for Windows.

  Windows on Snapdragon enumerates PCIe with the stock pci.sys over MCFG:
  the firmware must have trained the link and made config space ECAM-shaped
  before the OS starts (SM8250 MTP: MCFG 0x60000000, buses 0-1). dagu's
  Qualcomm UEFI has no PCIe driver and Windows runs without PEP, so this
  driver does what Linux pcie-qcom (ops_1_9_0) + phy-qcom-qmp-pcie (sm8250
  gen3x1) do:

    1. QCA6390 power: rails via the PMIC VREG protocol (only switched on if
       found off), VDD_ASD L16A, WLAN_EN gpio20 and BT_EN gpio21 high.
    2. PCIe0 GDSC, GCC clocks, controller and PHY block resets.
    3. PARF setup, QMP PHY tables (generated from Linux), PHY start.
    4. PERST# release, LTSSM enable, wait for the data link.
    5. Root port setup and iATU: region 0 = CFG0 in ECAM shift mode at
       0x60100000 (bus 1), region 1 = MEM 1:1 0x60200000-0x63FFFFFF.
       Unclaimed config/MEM reads complete as all-ones instead of an AXI
       error, so pci.sys can scan bus 0.
    6. Only if the link is up: install the PCI0 SSDT and an MCFG. If it is
       not, Windows sees no PCIe at all, exactly as before.

  Every step is logged (screen + PStore); the summary is held on screen.

  SPDX-License-Identifier: BSD-2-Clause-Patent
**/
#include <Uefi.h>
#include <IndustryStandard/Acpi.h>
#include <IndustryStandard/MemoryMappedConfigurationSpaceAccessTable.h>
#include <Protocol/AcpiTable.h>
#include <Library/BaseLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/DebugLib.h>
#include <Library/IoLib.h>
#include <Library/DxeServicesTableLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiDriverEntryPoint.h>

#define DAGU_PCIE_HOLD_S  30u

// ---- addresses (sm8250.dtsi pcie@1c00000 / phy@1c06000, gcc-sm8250.c) ----
#define PARF        0x01C00000u
#define PHY         0x01C06000u
#define PHY_PCS     (PHY + 0x800u)
#define DBI         0x60000000u
#define ATU         0x60001000u
#define CFG_WIN     0x60100000u
#define MEM_BASE    0x60200000u
#define MEM_LIMIT   0x63FFFFFFu
#define GCC         0x00100000u

#define GCC_PCIE_0_BCR          (GCC + 0x6B000u)
#define GCC_PCIE_0_GDSCR        (GCC + 0x6B004u)
#define GCC_PCIE_0_PHY_BCR      (GCC + 0x6C01Cu)
#define GCC_PCIE_VOTE           (GCC + 0x52008u)  // pcie_0: slv0 mstr1 cfg2 aux3 pipe4 q2a5
#define GCC_PCIE_PHY_AUX_CBCR   (GCC + 0x6F004u)
#define GCC_PCIE0_REFGEN_CBCR   (GCC + 0x6F02Cu)
#define GCC_PCIE_WIFI_CLKREF    (GCC + 0x8C004u)
#define GCC_AGGRE_NOC_TBU_CBCR  (GCC + 0x9000Cu)
#define GCC_DDRSS_PCIE_TBU_CBCR (GCC + 0x8D058u)

// PARF (pcie-qcom.c)
#define PARF_SYS_CTRL                 0x000
#define PARF_PM_CTRL                  0x020
#define PARF_PHY_CTRL                 0x040
#define PARF_MHI_CLOCK_RESET_CTRL     0x174
#define PARF_AXI_MSTR_WR_ADDR_HALT_V2 0x1A8
#define PARF_LTSSM                    0x1B0
#define PARF_DBI_BASE_ADDR_V2         0x350
#define PARF_DBI_BASE_ADDR_V2_HI      0x354
#define PARF_SLV_ADDR_SPACE_SIZE_V2   0x358
#define PARF_SLV_ADDR_SPACE_SIZE_V2_HI 0x35C
#define PARF_ATU_BASE_ADDR            0x634
#define PARF_ATU_BASE_ADDR_HI         0x638
#define PARF_DEVICE_TYPE              0x1000

// DWC port logic (pcie-designware.h)
#define DBI_PORT_DEBUG0         0x728
#define DBI_PORT_DEBUG1         0x72C
#define DBI_LINK_WIDTH_SPEED    0x80C
#define DBI_MISC_CONTROL_1      0x8BC
#define DBI_AMBA_ERR_RESP       0x8D0   // AMBA_ERROR_RESPONSE_DEFAULT
// iATU unroll: outbound region i at ATU + i*0x200
#define ATU_CTRL1    0x00
#define ATU_CTRL2    0x04
#define ATU_LBASE    0x08
#define ATU_UBASE    0x0C
#define ATU_LIMIT    0x10
#define ATU_LTARGET  0x14
#define ATU_UTARGET  0x18
#define ATU_ULIMIT   0x20
#define ATU_ENABLE   BIT31
#define ATU_CFG_SHIFT BIT28
#define ATU_TYPE_MEM  0x0
#define ATU_TYPE_CFG0 0x4

// QMP PCS v4
#define PCS_SW_RESET    0x000
#define PCS_STATUS1     0x014
#define PCS_PWR_DOWN    0x040
#define PCS_START_CTRL  0x044

#define TLMM_NORTH  0x0F900000u

// ---- Qualcomm clock protocol (binary ClockDxe vtable), inlined -----------
#define EFI_CLOCK_PROTOCOL_GUID \
  { 0x241AFAE6, 0x885F, 0x4F6C, { 0xA7, 0xEA, 0xC2, 0x8E, 0xAB, 0x79, 0xC3, 0xE5 } }
typedef struct _EFI_CLOCK_PROTOCOL EFI_CLOCK_PROTOCOL;
typedef EFI_STATUS (EFIAPI *CLK_GET_ID)(EFI_CLOCK_PROTOCOL *, CONST CHAR8 *, UINTN *);
typedef EFI_STATUS (EFIAPI *CLK_ENABLE)(EFI_CLOCK_PROTOCOL *, UINTN);
typedef EFI_STATUS (EFIAPI *CLK_IS_ON)(EFI_CLOCK_PROTOCOL *, UINTN, BOOLEAN *);
typedef EFI_STATUS (EFIAPI *CLK_SET_FREQ)(EFI_CLOCK_PROTOCOL *, UINTN, UINT32, UINT32, UINT32 *);
struct _EFI_CLOCK_PROTOCOL {
  UINT64        Version;
  CLK_GET_ID    GetClockID;
  CLK_ENABLE    EnableClock;
  VOID          *DisableClock;
  VOID          *IsClockEnabled;
  CLK_IS_ON     IsClockOn;
  CLK_SET_FREQ  SetClockFreqHz;
};
STATIC EFI_GUID  mClockGuid = EFI_CLOCK_PROTOCOL_GUID;

// ---- PMIC VREG protocol (edk2-msm EFIPmicVreg.h), inlined ----------------
#define EFI_PMICVREG_PROTOCOL_GUID \
  { 0x22d38d3d, 0xe8b6, 0x4f8f, { 0x9c, 0x26, 0xbc, 0xeb, 0x07, 0xd6, 0xcb, 0x68 } }
typedef struct {
  UINT32   PullDown;
  UINT32   SwMode;
  UINT32   PinCtrled;
  UINT32   SwEnable;     // 1 = on
  BOOLEAN  VregOk;
} VREG_STATUS;
typedef struct {
  UINT64  Revision;
  EFI_STATUS (EFIAPI *VregControl)(UINT32, UINT32, BOOLEAN);
  EFI_STATUS (EFIAPI *VregSetLevel)(UINT32, UINT32, UINT32);
  EFI_STATUS (EFIAPI *VregGetLevel)(UINT32, UINT32, UINT32 *);
  VOID    *VregSetPwrMode;
  VOID    *VregMultiphaseCtrl;
  EFI_STATUS (EFIAPI *VregGetStatus)(UINT32, UINT32, VREG_STATUS *);
} VREG_PROTOCOL;
STATIC EFI_GUID  mVregGuid = EFI_PMICVREG_PROTOCOL_GUID;
#define VREG_LDO(n)   ((UINT32)((n) - 1))
#define VREG_SMPS(n)  ((UINT32)(33 + (n)))

// ---- generated data ------------------------------------------------------
typedef struct { UINT16 Off; UINT8 Val; } QMP_WRITE;
STATIC CONST QMP_WRITE  mQmp[] = {
  #include "QmpPcieTables.inc"
};
STATIC CONST UINT8  mSsdt[] = {
  #include "Pcie0Ssdt.inc"
};

STATIC UINT32  mFail;   // first failing step, 0 = all good

// Values repeated in the final summary (the only screen held long enough to
// photograph; earlier lines scroll away).
STATIC UINT32  mSumLnk, mSumId1, mSumScr0, mSumSmr = 0xFFFFFFFFu, mSumSmrNew = 0xFFFFFFFFu;
STATIC UINT32  mSumBarSz, mSumMhi[4], mSumAtu0, mSumAtu1, mSumCb = 0xFFFFFFFFu, mSumSmrOk;

// ---- helpers ---------------------------------------------------------------
STATIC VOID
StallUs (
  UINT32  Us
  )
{
  UINT64  F, Now, End;

  __asm__ volatile ("mrs %0, cntfrq_el0" : "=r" (F));
  __asm__ volatile ("isb; mrs %0, cntvct_el0" : "=r" (Now));
  End = Now + (F * Us) / 1000000ULL + 1;
  do {
    __asm__ volatile ("isb; mrs %0, cntvct_el0" : "=r" (Now));
  } while (Now < End);
}

#define StallMs(ms)  StallUs ((ms) * 1000u)

STATIC VOID Set32 (UINTN A, UINT32 M) { MmioWrite32 (A, MmioRead32 (A) | M); }
STATIC VOID Clr32 (UINTN A, UINT32 M) { MmioWrite32 (A, MmioRead32 (A) & ~M); }

// TLMM cfg: pull[1:0] func[5:2] drv[8:6] OE bit9; io +4 bit1 = out
STATIC VOID
Gpio (
  UINT32   N,
  UINT32   Func,
  UINT32   Pull,
  BOOLEAN  Out,
  BOOLEAN  High
  )
{
  UINTN  C = TLMM_NORTH + 0x1000u * N;

  MmioWrite32 (C + 4, High ? BIT1 : 0);
  MmioWrite32 (C, Pull | (Func << 2) | (Out ? BIT9 : 0));
}

STATIC BOOLEAN
Poll (
  UINTN   A,
  UINT32  Mask,
  UINT32  Want,
  UINT32  TimeoutUs
  )
{
  UINT32  T;

  for (T = 0; T < TimeoutUs; T += 10) {
    if ((MmioRead32 (A) & Mask) == Want) {
      return TRUE;
    }
    StallUs (10);
  }
  return (MmioRead32 (A) & Mask) == Want;
}

STATIC VOID
Fail (
  UINT32       Step,
  CONST CHAR8  *What
  )
{
  if (mFail == 0) {
    mFail = Step;
  }
  DEBUG ((DEBUG_ERROR, "DaguPcie: step %u FAILED: %a\n", Step, What));
}

// ---- 1. QCA6390 power -------------------------------------------------------
STATIC VOID
RailOn (
  VREG_PROTOCOL  *V,
  UINT32         Dev,
  UINT32         Id,
  CONST CHAR8    *Name,
  UINT32         Mv
  )
{
  VREG_STATUS  St;
  UINT32       Uv = 0;
  EFI_STATUS   S1, S2 = EFI_SUCCESS, S3 = EFI_SUCCESS;

  SetMem (&St, sizeof (St), 0);
  S1 = V->VregGetStatus (Dev, Id, &St);
  V->VregGetLevel (Dev, Id, &Uv);
  if (!EFI_ERROR (S1) && St.SwEnable == 1) {
    DEBUG ((DEBUG_ERROR, "DaguPcie rail %a (pmic%u): already on, %u uV\n", Name, Dev, Uv));
    return;
  }
  if (Mv != 0) {
    S2 = V->VregSetLevel (Dev, Id, Mv);
  }
  S3 = V->VregControl (Dev, Id, TRUE);
  SetMem (&St, sizeof (St), 0);
  V->VregGetStatus (Dev, Id, &St);
  Uv = 0;
  V->VregGetLevel (Dev, Id, &Uv);
  DEBUG ((
    DEBUG_ERROR,
    "DaguPcie rail %a (pmic%u): was off (%r), set %u mV %r, enable %r -> en=%u %u uV\n",
    Name, Dev, S1, Mv, S2, S3, St.SwEnable, Uv
    ));
}

STATIC VOID
PowerQca6390 (
  VOID
  )
{
  VREG_PROTOCOL  *V;

  if (EFI_ERROR (gBS->LocateProtocol (&mVregGuid, NULL, (VOID **)&V))) {
    DEBUG ((DEBUG_ERROR, "DaguPcie: no PMIC VREG protocol, relying on XBL rails\n"));
  } else {
    // dagu dts: vreg_s4a_1p8, vreg_s5a (2.0 V on dagu), vreg_s6a_0p95,
    // vreg_s8c_1p35, vreg_l16a_3p0 (VDD_ASD, 3.024-3.304 V). a = PM8150
    // (pmic 0), c = PM8150L (pmic 2). Only switched on if found off.
    RailOn (V, 0, VREG_SMPS (4), "S4A 1.8", 0);
    RailOn (V, 0, VREG_SMPS (5), "S5A 2.0", 2000);
    RailOn (V, 0, VREG_SMPS (6), "S6A 0.95", 950);
    RailOn (V, 2, VREG_SMPS (8), "S8C 1.35", 1350);
    // L16A (VDD_ASD, BT antenna switch) is NOT touched here: on the first
    // device boot the PMIC VREG call for pmic0 LDO16 never returned and the
    // boot hung right after the S8C line. Wi-Fi/PCIe does not need it; it is
    // left for the Bluetooth bring-up through another path.
  }
  DEBUG ((DEBUG_ERROR, "DaguPcie: rails done, asserting WLAN_EN/BT_EN\n"));
  // pwrseq-qcom-wcn: >= 100 ms between enable-gpio toggles, 60 ms power-up.
  Gpio (20, 0, 0, TRUE, TRUE);                     // WLAN_EN
  StallMs (100);
  Gpio (21, 0, 0, TRUE, TRUE);                     // BT_EN
  StallMs (100);
  DEBUG ((
    DEBUG_ERROR, "DaguPcie: WLAN_EN=%u BT_EN=%u\n",
    MmioRead32 (TLMM_NORTH + 0x14004u) & 1u, MmioRead32 (TLMM_NORTH + 0x15004u) & 1u
    ));
}

// ---- 2. clocks / GDSC / resets ---------------------------------------------
STATIC VOID
Clk (
  EFI_CLOCK_PROTOCOL  *C,
  CONST CHAR8         *Name,
  UINT32              Hz
  )
{
  UINTN       Id;
  UINT32      Got = 0;
  BOOLEAN     On = FALSE;
  EFI_STATUS  S, F = EFI_SUCCESS, E;

  if (C == NULL) {
    return;
  }
  S = C->GetClockID (C, Name, &Id);
  if (EFI_ERROR (S)) {
    DEBUG ((DEBUG_ERROR, "DaguPcie clk %a: id %r\n", Name, S));
    return;
  }
  if (Hz != 0) {
    F = C->SetClockFreqHz (C, Id, Hz, 2 /* closest */, &Got);
  }
  E = C->EnableClock (C, Id);
  C->IsClockOn (C, Id, &On);
  DEBUG ((DEBUG_ERROR, "DaguPcie clk %a: freq %r %u, en %r on=%u\n", Name, F, Got, E, On));
}

STATIC VOID
ClocksOn (
  BOOLEAN  Pipe
  )
{
  EFI_CLOCK_PROTOCOL  *C = NULL;

  gBS->LocateProtocol (&mClockGuid, NULL, (VOID **)&C);
  if (!Pipe) {
    Clk (C, "gcc_pcie_0_aux_clk", 19200000);
    Clk (C, "gcc_pcie_0_cfg_ahb_clk", 0);
    Clk (C, "gcc_pcie_0_mstr_axi_clk", 0);
    Clk (C, "gcc_pcie_0_slv_axi_clk", 0);
    Clk (C, "gcc_pcie_0_slv_q2a_axi_clk", 0);
    Clk (C, "gcc_aggre_noc_pcie_tbu_clk", 0);
    Clk (C, "gcc_ddrss_pcie_sf_tbu_clk", 0);
    Clk (C, "gcc_pcie_phy_aux_clk", 0);
    Clk (C, "gcc_pcie0_phy_refgen_clk", 100000000);
    Clk (C, "gcc_pcie_wifi_clkref_en", 0);
    // Belt and braces: the branch enables by MMIO (gcc-sm8250.c).
    Set32 (GCC_PCIE_VOTE, BIT0 | BIT1 | BIT2 | BIT3 | BIT5);
    Set32 (GCC_PCIE_PHY_AUX_CBCR, BIT0);
    Set32 (GCC_PCIE0_REFGEN_CBCR, BIT0);
    Set32 (GCC_PCIE_WIFI_CLKREF, BIT0);
    Set32 (GCC_AGGRE_NOC_TBU_CBCR, BIT0);
    Set32 (GCC_DDRSS_PCIE_TBU_CBCR, BIT0);
  } else {
    Clk (C, "gcc_pcie_0_pipe_clk", 0);
    Set32 (GCC_PCIE_VOTE, BIT4);
  }
}

STATIC BOOLEAN
GdscOn (
  VOID
  )
{
  Clr32 (GCC_PCIE_0_GDSCR, BIT0);                  // SW_COLLAPSE off
  if (!Poll (GCC_PCIE_0_GDSCR, BIT31, BIT31, 1000)) {
    DEBUG ((DEBUG_ERROR, "DaguPcie: GDSC not on, GDSCR=%08x\n", MmioRead32 (GCC_PCIE_0_GDSCR)));
    return FALSE;
  }
  DEBUG ((DEBUG_ERROR, "DaguPcie: GDSC on, GDSCR=%08x\n", MmioRead32 (GCC_PCIE_0_GDSCR)));
  return TRUE;
}

// ---- DBI helpers -------------------------------------------------------------
STATIC UINT32
PcieCap (
  VOID
  )
{
  UINT32  P = MmioRead8 (DBI + 0x34);
  UINT32  N;

  for (N = 0; P >= 0x40 && P < 0x100 && N < 32; N++) {
    if (MmioRead8 (DBI + P) == 0x10) {
      return P;
    }
    P = MmioRead8 (DBI + P + 1);
  }
  return 0;
}

STATIC VOID
AtuRegion (
  UINT32  Idx,
  UINT32  Type,
  UINT32  Base,
  UINT32  Limit,
  UINT32  Target,
  UINT32  Ctrl2
  )
{
  UINTN  R = ATU + Idx * 0x200u;

  MmioWrite32 (R + ATU_LBASE, Base);
  MmioWrite32 (R + ATU_UBASE, 0);
  MmioWrite32 (R + ATU_LIMIT, Limit);
  MmioWrite32 (R + ATU_ULIMIT, 0);
  MmioWrite32 (R + ATU_LTARGET, Target);
  MmioWrite32 (R + ATU_UTARGET, 0);
  MmioWrite32 (R + ATU_CTRL1, Type);
  MmioWrite32 (R + ATU_CTRL2, ATU_ENABLE | Ctrl2);
  Poll (R + ATU_CTRL2, ATU_ENABLE, ATU_ENABLE, 1000);
}

// ---- 3-5. controller, PHY, link ------------------------------------------------
STATIC BOOLEAN
BringUpPcie0 (
  VOID
  )
{
  UINTN   I;
  UINT32  Cap, Sta, V;

  // Pins: PERST# gpio79 low (asserted), CLKREQ# gpio80 func pci_e0 pull-up,
  // WAKE# gpio81 input.
  Gpio (79, 0, 0, TRUE, FALSE);
  Gpio (80, 1, 3, FALSE, FALSE);
  Gpio (81, 0, 0, FALSE, FALSE);
  StallMs (1);

  DEBUG ((DEBUG_ERROR, "DaguPcie: step 2 GDSC (GDSCR %08x)\n", MmioRead32 (GCC_PCIE_0_GDSCR)));
  if (!GdscOn ()) {
    Fail (2, "pcie_0_gdsc");
    return FALSE;
  }
  ClocksOn (FALSE);

  // init_2_7_0: core block reset, then PARF.
  DEBUG ((DEBUG_ERROR, "DaguPcie: step 2b core reset + PARF\n"));
  MmioWrite32 (GCC_PCIE_0_BCR, 1);
  StallMs (1);
  MmioWrite32 (GCC_PCIE_0_BCR, 0);
  StallMs (1);

  DEBUG ((DEBUG_ERROR, "DaguPcie: PARF SYS_CTRL %08x\n", MmioRead32 (PARF + PARF_SYS_CTRL)));
  MmioWrite32 (PARF + PARF_DEVICE_TYPE, 0x4);                  // RC
  Clr32 (PARF + PARF_PHY_CTRL, BIT0);                          // PHY_TEST_PWR_DOWN
  MmioWrite32 (PARF + PARF_DBI_BASE_ADDR_V2, DBI);
  MmioWrite32 (PARF + PARF_DBI_BASE_ADDR_V2_HI, 0);
  MmioWrite32 (PARF + PARF_ATU_BASE_ADDR, ATU);
  MmioWrite32 (PARF + PARF_ATU_BASE_ADDR_HI, 0);
  MmioWrite32 (PARF + PARF_SLV_ADDR_SPACE_SIZE_V2, 0);
  MmioWrite32 (PARF + PARF_SLV_ADDR_SPACE_SIZE_V2_HI, 0x80000000u);
  Clr32 (PARF + PARF_SYS_CTRL, BIT29);                         // MAC_PHY_POWERDOWN_IN_P2_D_MUX_EN
  Set32 (PARF + PARF_MHI_CLOCK_RESET_CTRL, BIT4);              // BYPASS
  Clr32 (PARF + PARF_PM_CTRL, BIT5);                           // REQ_NOT_ENTR_L1
  Set32 (PARF + PARF_AXI_MSTR_WR_ADDR_HALT_V2, BIT31);
  // Do NOT touch DBI yet: the DWC core runs off the PHY pipe clock, and a
  // DBI read before the PHY is started stalls the bus (third device boot
  // hung exactly here). Linux also only touches DBI after phy_power_on().
  DEBUG ((DEBUG_ERROR, "DaguPcie: PARF written\n"));

  // qmp_pcie_init + qmp_pcie_power_on (sm8250 gen3x1).
  DEBUG ((DEBUG_ERROR, "DaguPcie: step 3 PHY reset + tables\n"));
  MmioWrite32 (GCC_PCIE_0_PHY_BCR, 1);
  StallUs (300);
  MmioWrite32 (GCC_PCIE_0_PHY_BCR, 0);
  StallUs (300);
  Set32 (PHY_PCS + PCS_PWR_DOWN, BIT0 | BIT1);                 // SW_PWRDN | REFCLK_DRV_DSBL
  for (I = 0; I < ARRAY_SIZE (mQmp); I++) {
    MmioWrite32 (PHY + mQmp[I].Off, mQmp[I].Val);
  }
  ClocksOn (TRUE);                                             // pipe
  Clr32 (PHY_PCS + PCS_SW_RESET, BIT0);
  Set32 (PHY_PCS + PCS_START_CTRL, BIT0 | BIT1);               // SERDES_START | PCS_START
  DEBUG ((DEBUG_ERROR, "DaguPcie: PHY started, waiting PHYSTATUS\n"));
  StallMs (2);
  if (!Poll (PHY_PCS + PCS_STATUS1, BIT6, 0, 10000)) {         // PHYSTATUS
    DEBUG ((DEBUG_ERROR, "DaguPcie: PHY status1 %08x\n", MmioRead32 (PHY_PCS + PCS_STATUS1)));
    Fail (3, "QMP PHY did not come up");
    return FALSE;
  }
  DEBUG ((DEBUG_ERROR, "DaguPcie: PHY up (%u writes), reading DBI\n", (UINT32)ARRAY_SIZE (mQmp)));
  DEBUG ((DEBUG_ERROR, "DaguPcie: DBI id %08x\n", MmioRead32 (DBI)));

  // post_init: no hot-plug capable slot.
  DEBUG ((DEBUG_ERROR, "DaguPcie: step 4 root port + iATU\n"));
  Set32 (DBI + DBI_MISC_CONTROL_1, BIT0);                      // DBI RO write enable
  Cap = PcieCap ();
  if (Cap != 0) {
    Clr32 (DBI + Cap + 0x14, BIT6);                            // SLTCAP.HPC
  }

  // dw_pcie_setup_rc
  MmioWrite32 (DBI + 0x10, 0);                                 // BAR0
  MmioWrite32 (DBI + 0x14, 0);                                 // BAR1
  V = MmioRead32 (DBI + 0x3C);
  MmioWrite32 (DBI + 0x3C, (V & 0xFFFF00FFu) | 0x100u);        // INTx pin A
  V = MmioRead32 (DBI + 0x18);
  MmioWrite32 (DBI + 0x18, (V & 0xFF000000u) | 0x00010100u);   // pri 0, sec 1, sub 1
  V = MmioRead32 (DBI + 0x04);
  MmioWrite32 (DBI + 0x04, (V & 0xFFFF0000u) | 0x0146u);       // MEM | MASTER | SERR
  MmioWrite16 (DBI + 0x0A, 0x0604);                            // class: PCI bridge
  // pci.sys scans bus 0 dev 1-31 and fn 1-7: let unclaimed requests
  // complete OK with all-ones data instead of an AXI SLVERR (SError).
  MmioWrite32 (DBI + DBI_AMBA_ERR_RESP, 0);

  // iATU 0: bus 1 config, ECAM shift mode (bus/dev/fn from address bits).
  AtuRegion (0, ATU_TYPE_CFG0, CFG_WIN, CFG_WIN + 0xFFFFFu, 0, ATU_CFG_SHIFT);
  // iATU 1: MEM 1:1 window for BARs.
  AtuRegion (1, ATU_TYPE_MEM, MEM_BASE, MEM_LIMIT, MEM_BASE, 0);
  DEBUG ((
    DEBUG_ERROR, "DaguPcie: iATU0 ctrl1 %08x ctrl2 %08x, iATU1 ctrl2 %08x, amba %08x\n",
    MmioRead32 (ATU + ATU_CTRL1), MmioRead32 (ATU + ATU_CTRL2),
    MmioRead32 (ATU + 0x200 + ATU_CTRL2), MmioRead32 (DBI + DBI_AMBA_ERR_RESP)
    ));
  Set32 (DBI + DBI_LINK_WIDTH_SPEED, BIT17);                   // directed speed change
  Clr32 (DBI + DBI_MISC_CONTROL_1, BIT0);

  // PERST# held >= 100 ms (PCIE_T_PVPERL_MS), then release and train.
  DEBUG ((DEBUG_ERROR, "DaguPcie: step 4b PERST release + LTSSM\n"));
  StallMs (100);
  Gpio (79, 0, 0, TRUE, TRUE);
  StallMs (1);
  Set32 (PARF + PARF_LTSSM, BIT8);

  Sta = 0;
  for (I = 0; I < 200; I++) {                                  // up to 1 s
    StallMs (5);
    Sta = (Cap != 0) ? MmioRead16 (DBI + Cap + 0x12) : 0;
    if (Sta & BIT13) {                                         // LNKSTA.DLLLA
      break;
    }
  }
  DEBUG ((
    DEBUG_ERROR,
    "DaguPcie: link %a after %u ms: LNKSTA %04x debug0 %08x debug1 %08x\n",
    (Sta & BIT13) ? "UP" : "DOWN", (UINT32)(I * 5), Sta,
    MmioRead32 (DBI + DBI_PORT_DEBUG0), MmioRead32 (DBI + DBI_PORT_DEBUG1)
    ));
  mSumLnk = (Sta & BIT13) ? 1 : 0;
  if (!(Sta & BIT13)) {
    Fail (4, "link did not train");
    return FALSE;
  }
  StallMs (100);                                               // device ready after link
  return TRUE;
}

// ---- MMIO mapping ---------------------------------------------------------------
// The dagu UEFI memory map has no PCIe entries: the first PARF write took a
// level-3 translation fault (FAR 0x01C00000) and the boot looped. GCC/TLMM
// work because Qualcomm's HWIO/Clock drivers add them to the GCD at runtime;
// do the same for the PCIe0 blocks: add as MMIO, then make them uncached so
// CpuDxe installs the page-table entries.
STATIC BOOLEAN
MapMmio (
  EFI_PHYSICAL_ADDRESS  Base,
  UINT64                Len,
  CONST CHAR8           *Name
  )
{
  EFI_GCD_MEMORY_SPACE_DESCRIPTOR  D;
  EFI_STATUS                       Sa = EFI_SUCCESS, Ss;

  if (EFI_ERROR (gDS->GetMemorySpaceDescriptor (Base, &D)) ||
      D.GcdMemoryType == EfiGcdMemoryTypeNonExistent)
  {
    Sa = gDS->AddMemorySpace (EfiGcdMemoryTypeMemoryMappedIo, Base, Len,
                              EFI_MEMORY_UC | EFI_MEMORY_RUNTIME);
  }
  Ss = gDS->SetMemorySpaceAttributes (Base, Len, EFI_MEMORY_UC | EFI_MEMORY_RUNTIME);
  if (EFI_ERROR (Ss)) {
    Ss = gDS->SetMemorySpaceAttributes (Base, Len, EFI_MEMORY_UC);
  }
  DEBUG ((DEBUG_ERROR, "DaguPcie: map %a %lx+%lx add %r attr %r\n", Name, Base, Len, Sa, Ss));
  return !EFI_ERROR (Ss);
}

// ---- SMMU: let PCIe0 DMA through -------------------------------------------------
// Windows runs without an SMMU driver, but every DMA/MSI write from the
// QCA6390 still passes the apps SMMU (SMMU-500 at 0x15000000) with stream
// ID 0x1c00 (sm8250.dtsi pcie0 iommu-map: 0x1c00..0x1c01). With sCR0.USFCFG
// set, an unmatched stream faults, so the MHI firmware download and MSIs
// die and qcwlan fails MiniportInitialize (Code 10). If no stream match
// entry covers 0x1c00, add a BYPASS S2CR for it in a free SMR slot; global
// bypass is not changed.
#define SMMU            0x15000000u
#define SMMU_SCR0       0x000
#define SMMU_IDR0       0x020
#define SMMU_SMR(n)     (0x800u + 4u * (n))
#define SMMU_S2CR(n)    (0xC00u + 4u * (n))
#define SMR_VALID       BIT31
#define S2CR_BYPASS     (1u << 16)
#define PCIE0_SID       0x1C00u
#define PCIE0_SID_MASK  0x0001u

STATIC VOID
SmmuBypassPcie0 (
  VOID
  )
{
  UINT32  Scr0, Idr0, N, I, Smr, Id, Mask, FreeSlot = 0xFFFFFFFFu, Hit = 0xFFFFFFFFu;

  Scr0 = MmioRead32 (SMMU + SMMU_SCR0);
  Idr0 = MmioRead32 (SMMU + SMMU_IDR0);
  mSumScr0 = Scr0;
  N = Idr0 & 0xFFu;
  for (I = 0; I < N && I < 128; I++) {
    Smr = MmioRead32 (SMMU + SMMU_SMR (I));
    if (!(Smr & SMR_VALID)) {
      FreeSlot = I;                         // keep the highest free slot
      continue;
    }
    Id = Smr & 0x7FFFu;
    Mask = (Smr >> 16) & 0x7FFFu;
    if (((Id ^ PCIE0_SID) & ~Mask & 0x7FFFu) == 0 && Hit == 0xFFFFFFFFu) {
      Hit = I;
    }
  }
  DEBUG ((
    DEBUG_ERROR,
    "DaguPcie: SMMU sCR0 %08x (CLIENTPD %u USFCFG %u) IDR0 %08x smrs %u, sid %x %a%u\n",
    Scr0, Scr0 & 1u, (Scr0 >> 10) & 1u, Idr0, N, PCIE0_SID,
    (Hit != 0xFFFFFFFFu) ? "matched by SMR " : "unmatched, free SMR ",
    (Hit != 0xFFFFFFFFu) ? Hit : FreeSlot
    ));
  mSumSmr = Hit;
  if (Hit != 0xFFFFFFFFu) {
    DEBUG ((DEBUG_ERROR, "DaguPcie: SMR %u S2CR %08x (left alone)\n",
            Hit, MmioRead32 (SMMU + SMMU_S2CR (Hit))));
    return;
  }
  if ((Scr0 & 1u) || !((Scr0 >> 10) & 1u)) {
    DEBUG ((DEBUG_ERROR, "DaguPcie: SMMU passes unmatched streams, nothing to do\n"));
    return;
  }
  if (FreeSlot == 0xFFFFFFFFu) {
    DEBUG ((DEBUG_ERROR, "DaguPcie: no free SMR, PCIe DMA will fault\n"));
    return;
  }
  // Fifth boot: S2CR type BYPASS is refused by the hypervisor in every slot
  // (reads back 0x20000 = FAULT, SMR stays 0), and all boot-time streams
  // (UFS 0xE0, ...) are TRANS to a context bank whose translation is off.
  // That is the Linux arm-smmu-qcom "bypass_quirk". Do the same: point
  // stream 0x1c00 TRANS at the context bank UFS already uses (the bootloader
  // set it up as pass-through); if no UFS stream is found, build one the
  // Linux way in the last context bank (SCTLR=0, CBAR S1_TRANS_S2_BYPASS).
  {
    UINT32  Want = SMR_VALID | (PCIE0_SID_MASK << 16) | PCIE0_SID;
    UINT32  Cb = 0xFFFFFFFFu, Src = 0xFFFFFFFFu, Id1, PgShift, NumPage, NumCb, S2;

    for (I = 0; I < N && I < 128; I++) {
      Smr = MmioRead32 (SMMU + SMMU_SMR (I));
      S2 = MmioRead32 (SMMU + SMMU_S2CR (I));
      if ((Smr & SMR_VALID) && (Smr & 0x7FFFu) == 0xE0u && ((S2 >> 16) & 3u) == 0) {
        Cb = S2 & 0xFFu;                       // UFS context bank
        Src = I;
        break;
      }
    }
    if (Cb == 0xFFFFFFFFu) {
      Id1 = MmioRead32 (SMMU + 0x24);
      PgShift = (Id1 & BIT31) ? 16 : 12;
      NumPage = 1u << (((Id1 >> 28) & 7u) + 1);
      NumCb = Id1 & 0xFFu;
      Cb = NumCb - 1;
      MmioWrite32 (SMMU + ((NumPage + Cb) << PgShift) + 0x0, 0);          // CB SCTLR: MMU off
      MmioWrite32 (SMMU + (1u << PgShift) + 4u * Cb, 1u << 16);           // GR1 CBAR: S1_TRANS_S2_BYPASS
      DEBUG ((
        DEBUG_ERROR, "DaguPcie: no UFS stream, quirk CB %u (ID1 %08x) CBAR %08x\n",
        Cb, Id1, MmioRead32 (SMMU + (1u << PgShift) + 4u * Cb)
        ));
    } else {
      DEBUG ((DEBUG_ERROR, "DaguPcie: reuse UFS context bank %u (SMR %u)\n", Cb, Src));
    }
    // Sixth boot: S2CR (TRANS, cb 3) stuck, but the masked SMR 0x80011C00
    // read back 0. Do exactly what Linux arm_smmu_write_sme() does for the
    // pcie0 iommu-map (two single SIDs, mask 0): S2CR then SMR per stream,
    // then the arm_smmu_device_reset tail: clear sGFSR, TLBIALLNSNH,
    // TLBGSYNC, rewrite sCR0 (an emulating hypervisor may commit there).
    (VOID)Want;
    mSumSmrNew = 0xFFFFFFFEu;
    {
      STATIC CONST UINT32  Sids[2] = { 0x1C00u, 0x1C01u };
      UINT32               K, Slot[2] = { 0xFFFFFFFFu, 0xFFFFFFFFu }, Ok = 0, T;

      I = 0;
      for (K = 0; K < 2; K++) {
        for (; I < N && I < 128; I++) {
          if (!(MmioRead32 (SMMU + SMMU_SMR (I)) & SMR_VALID)) {
            break;
          }
        }
        if (I >= N || I >= 128) {
          break;
        }
        Slot[K] = I;
        MmioWrite32 (SMMU + SMMU_S2CR (I), Cb);              // TRANS -> cb, PRIVCFG default
        MmioWrite32 (SMMU + SMMU_SMR (I), SMR_VALID | Sids[K]);
        I++;
      }
      MmioWrite32 (SMMU + 0x48, MmioRead32 (SMMU + 0x48));   // sGFSR: write-1-to-clear
      MmioWrite32 (SMMU + 0x6C, 0);                           // TLBIALLNSNH
      MmioWrite32 (SMMU + 0x70, 0);                           // TLBGSYNC
      for (T = 0; T < 1000 && (MmioRead32 (SMMU + 0x74) & 1u); T++) {   // sTLBGSTATUS.GSACTIVE
        StallUs (1);
      }
      MmioWrite32 (SMMU + SMMU_SCR0, Scr0);                   // same value: commit
      for (K = 0; K < 2; K++) {
        if (Slot[K] == 0xFFFFFFFFu) {
          continue;
        }
        Smr = MmioRead32 (SMMU + SMMU_SMR (Slot[K]));
        S2 = MmioRead32 (SMMU + SMMU_S2CR (Slot[K]));
        DEBUG ((
          DEBUG_ERROR, "DaguPcie: SID %x -> SMR %u: SMR %08x S2CR %08x\n",
          Sids[K], Slot[K], Smr, S2
          ));
        if (Smr == (SMR_VALID | Sids[K]) && (S2 & 0x300FFu) == Cb) {
          Ok++;
          if (mSumSmrNew == 0xFFFFFFFEu) {
            mSumSmrNew = Slot[K];
          }
        }
      }
      mSumSmrOk = Ok;
      DEBUG ((DEBUG_ERROR, "DaguPcie: %u/2 PCIe0 stream entries held, sCR0 now %08x\n",
              Ok, MmioRead32 (SMMU + SMMU_SCR0)));
    }
    mSumCb = Cb;
  }
}

// Show how existing streams (UFS works) are passed through: valid SMRs whose
// S2CR is BYPASS. Compact, for the photo.
STATIC VOID
SmmuDumpBypass (
  VOID
  )
{
  UINT32  N = MmioRead32 (SMMU + SMMU_IDR0) & 0xFFu, I, Smr, S2cr, Shown = 0;

  DEBUG ((DEBUG_ERROR, "=== SMMU valid SMRs (idx:smr/s2cr type):"));
  for (I = 0; I < N && I < 128; I++) {
    Smr = MmioRead32 (SMMU + SMMU_SMR (I));
    if (!(Smr & SMR_VALID)) {
      continue;
    }
    S2cr = MmioRead32 (SMMU + SMMU_S2CR (I));
    if (Shown < 16) {
      DEBUG ((DEBUG_ERROR, " %u:%x/%x", I, Smr & 0x7FFFFFFFu, S2cr));
    }
    Shown++;
  }
  DEBUG ((DEBUG_ERROR, "  (%u valid)\n", Shown));
}

// ---- 6. probe config space, publish ACPI -----------------------------------------
STATIC BOOLEAN
ProbeConfig (
  VOID
  )
{
  UINT32  Id0, Id1, Id1f1, Id1d1, Ss, Cls;

  DEBUG ((DEBUG_ERROR, "DaguPcie: step 5 config read bus 1\n"));
  Id0 = MmioRead32 (DBI);
  Id1 = MmioRead32 (CFG_WIN);                       // bus 1 dev 0 fn 0
  Ss = MmioRead32 (CFG_WIN + 0x2C);
  Cls = MmioRead32 (CFG_WIN + 0x08);
  Id1f1 = MmioRead32 (CFG_WIN + 0x1000);            // fn 1: expect all-ones
  Id1d1 = MmioRead32 (CFG_WIN + 0x8000);            // dev 1: expect all-ones
  DEBUG ((
    DEBUG_ERROR,
    "DaguPcie: bus0 %08x | bus1 dev0 %08x subsys %08x class %08x | fn1 %08x dev1 %08x\n",
    Id0, Id1, Ss, Cls, Id1f1, Id1d1
    ));
  mSumId1 = Id1;
  mSumAtu0 = MmioRead32 (ATU + ATU_CTRL2);
  mSumAtu1 = MmioRead32 (ATU + 0x200 + ATU_CTRL2);
  if ((Id1 & 0xFFFF) != 0x17CB) {
    Fail (5, "no Qualcomm device on bus 1");
    return FALSE;
  }
  if (Id1f1 == Id1 || Id1d1 == Id1) {
    DEBUG ((DEBUG_ERROR, "DaguPcie: WARNING config aliasing (ECAM shift mode not effective)\n"));
  }
  return TRUE;
}

// What qcwlan does first: map BAR0 and read the MHI registers (MHIREGLEN
// +0x0, MHIVER +0x8, MHICFG +0x10, BHIOFF +0x28). All-ones means the BAR
// window does not reach the device; that alone would make the driver report
// a bad MHI version. BAR and command register are restored to 0 afterwards
// so Windows assigns resources itself.
STATIC VOID
ProbeBar0 (
  VOID
  )
{
  UINTN   Cfg = CFG_WIN;
  UINT32  Lo, Hi, Sz, Base;

  MmioWrite32 (Cfg + 0x10, 0xFFFFFFFFu);
  Lo = MmioRead32 (Cfg + 0x10);
  Sz = ~(Lo & 0xFFFFFFF0u) + 1;
  mSumBarSz = Sz;
  if (Lo == 0 || Lo == 0xFFFFFFFFu || Sz == 0 || Sz > 0x02000000u) {
    DEBUG ((DEBUG_ERROR, "DaguPcie: BAR0 sizing read %08x, skip\n", Lo));
    MmioWrite32 (Cfg + 0x10, 0);
    return;
  }
  Base = (MEM_BASE + Sz - 1) & ~(Sz - 1);           // first aligned slot
  MmioWrite32 (Cfg + 0x10, Base | (Lo & 0xF));
  if ((Lo & 0x6) == 0x4) {                          // 64-bit BAR
    MmioWrite32 (Cfg + 0x14, 0);
  }
  Hi = MmioRead32 (Cfg + 0x04);
  MmioWrite32 (Cfg + 0x04, (Hi & 0xFFFF0000u) | 0x0006u);   // MEM | MASTER
  // Root port: forward that window downstream.
  MmioWrite32 (DBI + 0x20, ((MEM_LIMIT >> 16) & 0xFFF0u) << 16 | ((MEM_BASE >> 16) & 0xFFF0u));
  MmioWrite32 (DBI + 0x04, (MmioRead32 (DBI + 0x04) & 0xFFFF0000u) | 0x0146u);
  StallMs (1);
  mSumMhi[0] = MmioRead32 (Base + 0x00);
  mSumMhi[1] = MmioRead32 (Base + 0x08);
  mSumMhi[2] = MmioRead32 (Base + 0x10);
  mSumMhi[3] = MmioRead32 (Base + 0x28);
  DEBUG ((
    DEBUG_ERROR, "DaguPcie: BAR0 %08x size %x @%08x: MHIREGLEN %08x MHIVER %08x MHICFG %08x BHIOFF %08x\n",
    Lo, Sz, Base, mSumMhi[0], mSumMhi[1], mSumMhi[2], mSumMhi[3]
    ));
  // Hand the device back unconfigured.
  MmioWrite32 (Cfg + 0x04, Hi & 0xFFFF0000u);
  MmioWrite32 (Cfg + 0x10, 0);
  MmioWrite32 (Cfg + 0x14, 0);
}

#pragma pack(1)
typedef struct {
  EFI_ACPI_MEMORY_MAPPED_CONFIGURATION_BASE_ADDRESS_TABLE_HEADER                         Header;
  EFI_ACPI_MEMORY_MAPPED_ENHANCED_CONFIGURATION_SPACE_BASE_ADDRESS_ALLOCATION_STRUCTURE  Seg0;
} DAGU_MCFG;
#pragma pack()

STATIC VOID
PublishAcpi (
  VOID
  )
{
  EFI_ACPI_TABLE_PROTOCOL  *Acpi;
  DAGU_MCFG                Mcfg;
  UINTN                    Key;
  EFI_STATUS               S1, S2;

  if (EFI_ERROR (gBS->LocateProtocol (&gEfiAcpiTableProtocolGuid, NULL, (VOID **)&Acpi))) {
    Fail (6, "no ACPI table protocol");
    return;
  }
  ZeroMem (&Mcfg, sizeof (Mcfg));
  Mcfg.Header.Header.Signature = EFI_ACPI_6_3_PCI_EXPRESS_MEMORY_MAPPED_CONFIGURATION_SPACE_BASE_ADDRESS_DESCRIPTION_TABLE_SIGNATURE;
  Mcfg.Header.Header.Length = sizeof (Mcfg);
  Mcfg.Header.Header.Revision = 1;
  CopyMem (Mcfg.Header.Header.OemId, "DAGU  ", 6);
  Mcfg.Header.Header.OemTableId = SIGNATURE_64 ('P', 'C', 'I', 'E', '0', ' ', ' ', ' ');
  Mcfg.Header.Header.OemRevision = 1;
  Mcfg.Header.Header.CreatorId = SIGNATURE_32 ('D', 'A', 'G', 'U');
  Mcfg.Header.Header.CreatorRevision = 1;
  Mcfg.Seg0.BaseAddress = DBI;
  Mcfg.Seg0.PciSegmentGroupNumber = 0;
  Mcfg.Seg0.StartBusNumber = 0;
  Mcfg.Seg0.EndBusNumber = 1;

  S1 = Acpi->InstallAcpiTable (Acpi, &Mcfg, sizeof (Mcfg), &Key);
  S2 = Acpi->InstallAcpiTable (Acpi, (VOID *)mSsdt, sizeof (mSsdt), &Key);
  DEBUG ((DEBUG_ERROR, "DaguPcie: MCFG %r, PCI0 SSDT (%u bytes) %r\n", S1, (UINT32)sizeof (mSsdt), S2));
  if (EFI_ERROR (S1) || EFI_ERROR (S2)) {
    Fail (6, "ACPI install");
  }
}

EFI_STATUS
EFIAPI
DaguPcieDxeInitialize (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
  BOOLEAN  Up;

  DEBUG ((DEBUG_ERROR, "\n=== DAGU PCIE0 / QCA6390 ===\n"));
  // PARF 0x01C00000 + QMP PHY 0x01C06000; DBI/ATU/config/MEM 0x60000000-0x63FFFFFF.
  if (!MapMmio (PARF, 0x10000, "PARF+PHY") || !MapMmio (DBI, 0x4000000, "PCIe0 AXI")) {
    Fail (1, "cannot map PCIe0 MMIO, not touching it");
    DEBUG ((DEBUG_ERROR, "=== DAGU PCIE0: FAILED (map) - holding %u s ===\n", DAGU_PCIE_HOLD_S));
    StallMs (DAGU_PCIE_HOLD_S * 1000u);
    return EFI_SUCCESS;
  }
  PowerQca6390 ();
  Up = BringUpPcie0 () && ProbeConfig ();
  if (Up) {
    ProbeBar0 ();
    SmmuBypassPcie0 ();
    PublishAcpi ();
  }
  DEBUG ((
    DEBUG_ERROR,
    "\n=== SUMMARY  link %a  dev %08x  atu0 %08x atu1 %08x\n"
    "=== BAR0 size %x  MHIREGLEN %08x MHIVER %08x MHICFG %08x BHIOFF %08x\n"
    "=== SMMU sCR0 %08x (CLIENTPD %u USFCFG %u)  SMR hit %d new %d  cb %d  held %u/2\n",
    mSumLnk ? "UP" : "DOWN", mSumId1, mSumAtu0, mSumAtu1,
    mSumBarSz, mSumMhi[0], mSumMhi[1], mSumMhi[2], mSumMhi[3],
    mSumScr0, mSumScr0 & 1u, (mSumScr0 >> 10) & 1u, (INT32)mSumSmr, (INT32)mSumSmrNew, (INT32)mSumCb, mSumSmrOk
    ));
  if (Up) {
    SmmuDumpBypass ();
  }
  DEBUG ((
    DEBUG_ERROR,
    "=== DAGU PCIE0: %a (first failing step %u) - holding %u s ===\n",
    (Up && mFail == 0) ? "OK, PCI0 published" : "FAILED, no PCI0 for Windows",
    mFail, DAGU_PCIE_HOLD_S
    ));
  StallMs (DAGU_PCIE_HOLD_S * 1000u);
  return EFI_SUCCESS;
}
