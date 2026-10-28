/** @file
  dagu platform settings Windows cannot make itself, plus a boot census.

  1. CPU performance level. dagu boots Windows without the Qualcomm PEP and
     the DSDT has no _CPC/_PSS, so Windows never touches the EPSS frequency
     domains and the cores stay at whatever level is current when UEFI exits.
     Pick a level per domain from the hardware LUT and write its index to
     PERF_STATE, the same register write Linux qcom-cpufreq-hw does
     (epss_soc_data: LUT at +0x100, PERF_STATE at +0x320, DOMAIN_STATE at
     +0x20). Hardware LMh still throttles on temperature.

  2. Census. Records, in \dagu-uefi-diag.txt on the ESP (readable from Linux
     with the ESP mounted), the EPSS state before/after, and the QCA6390
     (Wi-Fi/BT) power rails as seen through the PMIC VREG protocol, so the
     Wi-Fi/BT power-on sequence can be written against real indices. The
     PStore ring does not survive a cold power cycle; a file does. Read-only
     with respect to the rails.

  SPDX-License-Identifier: BSD-2-Clause-Patent
**/
#include <Uefi.h>
#include <Guid/EventGroup.h>
#include <Protocol/SimpleFileSystem.h>
#include <Library/BaseLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/DebugLib.h>
#include <Library/IoLib.h>
#include <Library/PrintLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiRuntimeServicesTableLib.h>
#include <Library/UefiDriverEntryPoint.h>
#include <Library/ArmSmcLib.h>

// Target MHz per EPSS domain: 0 = A55 x4 (LUT max 1805), 1 = A77 x3 (2419),
// 2 = A77 prime (3187). The highest LUT entry <= target is used. Below the
// top bins: the tablet has no OS thermal policy, only hardware LMh.
#define DAGU_CPU_MHZ_D0  1805u
#define DAGU_CPU_MHZ_D1  2151u           // LUT 2150.4 MHz (19.2 x 112)
#define DAGU_CPU_MHZ_D2  2362u

// 1 = write \dagu-uefi-diag.txt to the ESP at ReadyToBoot.
#define DAGU_PLAT_DIAG   1

#define EPSS_ENABLE        0x000
#define EPSS_DOMAIN_STATE  0x020
#define EPSS_DCVS_CTRL     0x0B0
#define EPSS_FREQ_LUT      0x100
#define EPSS_VOLT_LUT      0x200
#define EPSS_PERF_STATE    0x320
#define EPSS_LUT_MAX       40u
#define XO_KHZ             19200u
#define GPLL0_DIV2_KHZ     300000u

typedef struct {
  UINTN   Base;
  UINT32  TargetMhz;
  UINT32  Cores;
  INT32   Index;      // chosen LUT index, -1 = leave alone
} EPSS_DOMAIN;

STATIC EPSS_DOMAIN  mDom[] = {
  { 0x18591000u, DAGU_CPU_MHZ_D0, 4, -1 },
  { 0x18592000u, DAGU_CPU_MHZ_D1, 3, -1 },
  { 0x18593000u, DAGU_CPU_MHZ_D2, 1, -1 },
};

// ---- PMIC VREG protocol (edk2-msm EFIPmicVreg.h), inlined -----------------
#define EFI_PMICVREG_PROTOCOL_GUID \
  { 0x22d38d3d, 0xe8b6, 0x4f8f, { 0x9c, 0x26, 0xbc, 0xeb, 0x07, 0xd6, 0xcb, 0x68 } }

typedef enum { EFI_PM_OFF, EFI_PM_ON, EFI_PM_INVALID } EFI_PM_ON_OFF_TYPE;

typedef struct {
  EFI_PM_ON_OFF_TYPE  PullDown;
  UINT32              SwMode;
  EFI_PM_ON_OFF_TYPE  PinCtrled;
  EFI_PM_ON_OFF_TYPE  SwEnable;
  BOOLEAN             VregOk;
} EFI_PM_VREG_STATUS_TYPE;

typedef EFI_STATUS (EFIAPI *EFI_PM_VREG_CONTROL)(UINT32, UINT32, BOOLEAN);
typedef EFI_STATUS (EFIAPI *EFI_PM_VREG_SET_LEVEL)(UINT32, UINT32, UINT32);
typedef EFI_STATUS (EFIAPI *EFI_PM_VREG_GET_LEVEL)(UINT32, UINT32, UINT32 *);
typedef EFI_STATUS (EFIAPI *EFI_PM_VREG_SET_PWR_MODE)(UINT32, UINT32, UINT32);
typedef EFI_STATUS (EFIAPI *EFI_PM_VREG_MULTIPHASE_CTRL)(UINT32, UINT32, UINT32);
typedef EFI_STATUS (EFIAPI *EFI_PM_VREG_GET_STATUS)(UINT32, UINT32, EFI_PM_VREG_STATUS_TYPE *);

typedef struct {
  UINT64                       Revision;
  EFI_PM_VREG_CONTROL          VregControl;
  EFI_PM_VREG_SET_LEVEL        VregSetLevel;
  EFI_PM_VREG_GET_LEVEL        VregGetLevel;
  EFI_PM_VREG_SET_PWR_MODE     VregSetPwrMode;
  EFI_PM_VREG_MULTIPHASE_CTRL  VregMultiphaseCtrl;
  EFI_PM_VREG_GET_STATUS       VregGetStatus;
} EFI_QCOM_PMIC_VREG_PROTOCOL;

STATIC EFI_GUID  mVregGuid = EFI_PMICVREG_PROTOCOL_GUID;

// EFI_PM_VREG_ID_TYPE: LDO_1..LDO_33 = 0..32, LDO_INVALID = 33, SMPS_1 = 34.
#define VREG_LDO(n)   ((UINT32)((n) - 1))
#define VREG_SMPS(n)  ((UINT32)(33 + (n)))

#define TLMM_NORTH  0x0F900000u

// ---- log buffer -----------------------------------------------------------
STATIC CHAR8    mLog[12288];
STATIC UINTN    mLogLen;
STATIC BOOLEAN  mDone;

STATIC VOID
EFIAPI
Log (
  IN CONST CHAR8  *Fmt,
  ...
  )
{
  VA_LIST  Args;
  UINTN    N;

  if (mLogLen + 2 >= sizeof (mLog)) {
    return;
  }
  VA_START (Args, Fmt);
  N = AsciiVSPrint (mLog + mLogLen, sizeof (mLog) - mLogLen, Fmt, Args);
  VA_END (Args);
  DEBUG ((DEBUG_ERROR, "DaguPlat %a", mLog + mLogLen));
  mLogLen += N;
}

// ---- EPSS -----------------------------------------------------------------
STATIC UINT32
LutKhz (
  UINTN   Base,
  UINT32  I,
  UINT32  *CoreCount
  )
{
  UINT32  V = MmioRead32 (Base + EPSS_FREQ_LUT + I * 4u);

  *CoreCount = (V >> 16) & 7u;
  return ((V >> 30) & 3u) ? XO_KHZ * (V & 0xFFu) : GPLL0_DIV2_KHZ;
}

STATIC VOID
EpssChoose (
  EPSS_DOMAIN  *D
  )
{
  UINT32  I, Khz, Prev = 0, Cc, Best = 0;
  INT32   BestI = -1;

  for (I = 0; I < EPSS_LUT_MAX; I++) {
    Khz = LutKhz (D->Base, I, &Cc);
    if (I > 0 && Khz == Prev) {
      break;                         // repeated entry ends the table
    }
    Prev = Khz;
    if (Cc == 1) {
      continue;                      // LUT_TURBO_IND: boost row, skip
    }
    if (Khz <= D->TargetMhz * 1000u && Khz >= Best) {
      Best = Khz;
      BestI = (INT32)I;
    }
  }
  D->Index = BestI;
}

STATIC VOID
EpssApply (
  BOOLEAN  Verbose
  )
{
  UINTN   N, C;
  UINT32  En, Dcvs, Before, After, Cc;

  for (N = 0; N < ARRAY_SIZE (mDom); N++) {
    EPSS_DOMAIN  *D = &mDom[N];

    En = MmioRead32 (D->Base + EPSS_ENABLE);
    if ((En & 1u) == 0) {
      if (Verbose) {
        Log ("epss d%u: hw not enabled (0x%x), skip\n", N, En);
      }
      continue;
    }
    if (D->Index < 0) {
      EpssChoose (D);
    }
    if (D->Index < 0) {
      if (Verbose) {
        Log ("epss d%u: no LUT entry <= %u MHz\n", N, D->TargetMhz);
      }
      continue;
    }
    Dcvs = MmioRead32 (D->Base + EPSS_DCVS_CTRL);
    Before = MmioRead32 (D->Base + EPSS_DOMAIN_STATE) & 0xFFu;
    MmioWrite32 (D->Base + EPSS_PERF_STATE, (UINT32)D->Index);
    if (Dcvs & 1u) {                 // per-core DCVS: one vote per core
      for (C = 1; C < D->Cores; C++) {
        MmioWrite32 (D->Base + EPSS_PERF_STATE + C * 4u, (UINT32)D->Index);
      }
    }
    if (Verbose) {
      gBS->Stall (2000);
      After = MmioRead32 (D->Base + EPSS_DOMAIN_STATE) & 0xFFu;
      Log (
        "epss d%u: dcvs=0x%x %u MHz -> idx %d (%u MHz), now %u MHz\n",
        N, Dcvs, Before * XO_KHZ / 1000u, D->Index,
        LutKhz (D->Base, (UINT32)D->Index, &Cc) / 1000u,
        After * XO_KHZ / 1000u
        );
    }
  }
}

// ---- QCA6390 rail census --------------------------------------------------
STATIC VOID
WcnCensus (
  VOID
  )
{
  EFI_QCOM_PMIC_VREG_PROTOCOL  *Vreg;
  EFI_STATUS                   Status;
  UINT32                       Dev, Id, Uv;
  EFI_PM_VREG_STATUS_TYPE      St;
  STATIC CONST struct { CONST CHAR8 *Name; UINT32 Id; } Want[] = {
    { "S4", VREG_SMPS (4) }, { "S5", VREG_SMPS (5) }, { "S6", VREG_SMPS (6) },
    { "S8", VREG_SMPS (8) }, { "L9", VREG_LDO (9) },  { "L16", VREG_LDO (16) },
  };
  UINTN                        R;

  Status = gBS->LocateProtocol (&mVregGuid, NULL, (VOID **)&Vreg);
  if (EFI_ERROR (Status)) {
    Log ("wcn: no PMIC VREG protocol (%r)\n", Status);
    return;
  }
  Log ("wcn: PMIC VREG rev 0x%lx\n", Vreg->Revision);
  for (Dev = 0; Dev < 4; Dev++) {
    for (R = 0; R < ARRAY_SIZE (Want); R++) {
      EFI_STATUS  Ss, Ls;

      Uv = 0;
      SetMem (&St, sizeof (St), 0);
      Ss = Vreg->VregGetStatus (Dev, Want[R].Id, &St);
      Ls = Vreg->VregGetLevel (Dev, Want[R].Id, &Uv);
      if (EFI_ERROR (Ss) && EFI_ERROR (Ls)) {
        continue;
      }
      Log (
        "  pmic%u %a: en=%u ok=%u mode=%u lvl=%u (%r/%r)\n",
        Dev, Want[R].Name, St.SwEnable, St.VregOk, St.SwMode, Uv, Ss, Ls
        );
    }
    // Every enabled rail on this PMIC, compact, for the full picture.
    Log ("  pmic%u on:", Dev);
    for (Id = 0; Id < VREG_SMPS (13); Id++) {
      if (Id == 33) {
        continue;
      }
      SetMem (&St, sizeof (St), 0);
      if (!EFI_ERROR (Vreg->VregGetStatus (Dev, Id, &St)) && St.SwEnable == EFI_PM_ON) {
        Uv = 0;
        Vreg->VregGetLevel (Dev, Id, &Uv);
        Log (" %a%u=%u", Id < 33 ? "L" : "S", Id < 33 ? Id + 1 : Id - 33, Uv);
      }
    }
    Log ("\n");
  }
  Log (
    "wcn: gpio20(WLAN_EN)=%u gpio21(BT_EN)=%u cfg20=0x%x cfg21=0x%x\n",
    (MmioRead32 (TLMM_NORTH + 0x1000u * 20u + 4u) >> 1) & 1u,
    (MmioRead32 (TLMM_NORTH + 0x1000u * 21u + 4u) >> 1) & 1u,
    MmioRead32 (TLMM_NORTH + 0x1000u * 20u),
    MmioRead32 (TLMM_NORTH + 0x1000u * 21u)
    );
}

// ---- ESP file -------------------------------------------------------------
STATIC VOID
WriteEspFile (
  VOID
  )
{
  EFI_STATUS                       Status;
  EFI_HANDLE                       *Handles;
  UINTN                            Count, I, Len;
  EFI_SIMPLE_FILE_SYSTEM_PROTOCOL  *Fs;
  EFI_FILE_PROTOCOL                *Root, *Probe, *File;

  Status = gBS->LocateHandleBuffer (
                  ByProtocol, &gEfiSimpleFileSystemProtocolGuid, NULL, &Count, &Handles
                  );
  if (EFI_ERROR (Status)) {
    DEBUG ((DEBUG_ERROR, "DaguPlat: no file systems (%r)\n", Status));
    return;
  }
  for (I = 0; I < Count; I++) {
    if (EFI_ERROR (gBS->HandleProtocol (Handles[I], &gEfiSimpleFileSystemProtocolGuid, (VOID **)&Fs)) ||
        EFI_ERROR (Fs->OpenVolume (Fs, &Root)))
    {
      continue;
    }
    // The Windows ESP is the volume holding the boot manager.
    if (EFI_ERROR (Root->Open (Root, &Probe, L"\\EFI\\Microsoft\\Boot\\bootmgfw.efi",
                               EFI_FILE_MODE_READ, 0)))
    {
      Root->Close (Root);
      continue;
    }
    Probe->Close (Probe);
    if (!EFI_ERROR (Root->Open (Root, &File, L"\\dagu-uefi-diag.txt",
                                EFI_FILE_MODE_READ | EFI_FILE_MODE_WRITE, 0)))
    {
      File->Delete (File);           // replace, do not append to a longer file
    }
    Status = Root->Open (
                     Root, &File, L"\\dagu-uefi-diag.txt",
                     EFI_FILE_MODE_CREATE | EFI_FILE_MODE_READ | EFI_FILE_MODE_WRITE, 0
                     );
    if (!EFI_ERROR (Status)) {
      Len = mLogLen;
      Status = File->Write (File, &Len, mLog);
      File->Close (File);
    }
    DEBUG ((DEBUG_ERROR, "DaguPlat: diag -> ESP %r (%u bytes)\n", Status, mLogLen));
    Root->Close (Root);
    break;
  }
  gBS->FreePool (Handles);
}

// ---- Windows -> fastboot bridge -------------------------------------------
// Windows cannot write the Qualcomm reboot-reason cookie itself (no SPMI
// driver in the WoA stack). Instead it drops an empty file \dagu-fastboot on
// its ESP (over SSH: `break > S:\dagu-fastboot`) and does a normal restart.
// Before Windows is launched we notice the flag, delete it (so we never loop),
// and reboot into fastboot the way Linux qcom-pon does: write the PMIC
// PON_SOFT_RB_SPARE cookie (bootloader magic 0x2 << GEN2 shift 1 = 0x04, mask
// bits[7:1]=0xFE) via the PmicDxe PON protocol, then PSCI SYSTEM_RESET over
// SMC. XBL reads that cookie and comes up in fastboot. The earlier
// EfiResetCold+RESET_PARAM path (QcomModulePkg RebootDevice) did not work on
// dagu -- its XBL reads the PON cookie, not the ResetRuntimeDxe reason.
//
// Detection and the reset are split: the filesystem notify (TPL_CALLBACK) may
// catch the flag first, but the PMIC protocol is only known to work at the
// TPL_APPLICATION of ReadyToBoot (WcnCensus uses it there). So detection just
// sets mFastbootPending; TryFastbootReset() performs the PMIC write + reset
// and simply returns if the PMIC write is not possible yet, to retry later.
#define EFI_PMICPON_PROTOCOL_GUID \
  { 0x97044b58, 0xfea4, 0x4ad0, { 0x9d, 0x0b, 0xe4, 0x17, 0xd6, 0x0f, 0x11, 0xa1 } }

typedef enum {
  DAGU_PON_PERPH_SPARE, DAGU_PON_DVDD_SPARE, DAGU_PON_XVDD_SPARE, DAGU_PON_SOFT_SPARE
} DAGU_PON_SPARE_REG;

typedef EFI_STATUS (EFIAPI *DAGU_PON_GET_SPARE)(UINT32, UINT32, UINT8 *);
typedef EFI_STATUS (EFIAPI *DAGU_PON_SET_SPARE)(UINT32, UINT32, UINT8, UINT8);

typedef struct {
  UINT64              Revision;
  DAGU_PON_GET_SPARE  GetSpareReg;
  DAGU_PON_SET_SPARE  SetSpareReg;
} DAGU_PON_PROTOCOL;

STATIC EFI_GUID  mPonGuid = EFI_PMICPON_PROTOCOL_GUID;
STATIC BOOLEAN   mFastbootPending;

#define PSCI_SYSTEM_RESET  0x84000009u

STATIC VOID
CheckFastbootFlag (
  VOID
  )
{
  EFI_STATUS                       Status;
  EFI_HANDLE                       *Handles;
  UINTN                            Count, I;
  EFI_SIMPLE_FILE_SYSTEM_PROTOCOL  *Fs;
  EFI_FILE_PROTOCOL                *Root, *Probe, *Flag;

  if (EFI_ERROR (gBS->LocateHandleBuffer (
                        ByProtocol, &gEfiSimpleFileSystemProtocolGuid, NULL, &Count, &Handles)))
  {
    return;
  }
  for (I = 0; I < Count; I++) {
    if (EFI_ERROR (gBS->HandleProtocol (Handles[I], &gEfiSimpleFileSystemProtocolGuid, (VOID **)&Fs)) ||
        EFI_ERROR (Fs->OpenVolume (Fs, &Root)))
    {
      continue;
    }
    // Only act on the Windows ESP (the volume with the boot manager).
    if (EFI_ERROR (Root->Open (Root, &Probe, L"\\EFI\\Microsoft\\Boot\\bootmgfw.efi",
                               EFI_FILE_MODE_READ, 0)))
    {
      Root->Close (Root);
      continue;
    }
    Probe->Close (Probe);
    Status = Root->Open (Root, &Flag, L"\\dagu-fastboot",
                         EFI_FILE_MODE_READ | EFI_FILE_MODE_WRITE, 0);
    DEBUG ((DEBUG_ERROR, "DaguPlat: ESP found (%u fs), flag open %r\n", (UINT32)Count, Status));
    if (EFI_ERROR (Status)) {
      Root->Close (Root);
      break;                           // found the ESP, no flag: boot normally
    }
    Status = Flag->Delete (Flag);      // clears the handle; persists on FAT
    Root->Close (Root);
    if (!EFI_ERROR (Status)) {
      mFastbootPending = TRUE;         // actual reset is done by TryFastbootReset
      DEBUG ((DEBUG_ERROR, "DaguPlat: fastboot flag seen, pending reset\n"));
    } else {
      DEBUG ((DEBUG_ERROR, "DaguPlat: fastboot flag delete %r\n", Status));
    }
    break;
  }
  gBS->FreePool (Handles);
}

STATIC VOID
TryFastbootReset (
  VOID
  )
{
  EFI_STATUS         Status;
  DAGU_PON_PROTOCOL  *Pon;
  ARM_SMC_ARGS       Smc;

  if (!mFastbootPending) {
    return;
  }
  Status = gBS->LocateProtocol (&mPonGuid, NULL, (VOID **)&Pon);
  if (EFI_ERROR (Status) || (Pon->SetSpareReg == NULL)) {
    DEBUG ((DEBUG_ERROR, "DaguPlat: PON protocol %r, defer fastboot reset\n", Status));
    return;                            // retry from a later (safe-TPL) caller
  }
  // Linux qcom-pon: PON_SOFT_RB_SPARE = bootloader(0x2) << GEN2 shift(1) = 0x04.
  Status = Pon->SetSpareReg (0, DAGU_PON_SOFT_SPARE, 0x04u, 0xFEu);
  DEBUG ((DEBUG_ERROR, "DaguPlat: PON SetSpareReg SOFT=0x04 %r -> PSCI reset\n", Status));
  if (EFI_ERROR (Status)) {
    return;                            // leave pending; try again later
  }
  mFastbootPending = FALSE;
  ZeroMem (&Smc, sizeof (Smc));
  Smc.Arg0 = PSCI_SYSTEM_RESET;
  ArmCallSmc (&Smc);                   // full SoC reset; PMIC cookie survives
  gRT->ResetSystem (EfiResetCold, EFI_SUCCESS, 0, NULL);   // just in case
  CpuDeadLoop ();
}

// The ESP's filesystem is connected during BDS, after this driver's DXE
// entry, so a single scan at entry misses it. Re-run the flag check whenever
// any SimpleFileSystem is installed; the ESP shows up before bootmgfw starts.
STATIC VOID   *mFsReg;

STATIC VOID
EFIAPI
OnFsNotify (
  IN EFI_EVENT  Event,
  IN VOID       *Context
  )
{
  CheckFastbootFlag ();
  TryFastbootReset ();                  // may succeed here; else ReadyToBoot retries
}

STATIC VOID
EFIAPI
OnReadyToBoot (
  IN EFI_EVENT  Event,
  IN VOID       *Context
  )
{
  CheckFastbootFlag ();                 // backstop: also catch it here
  TryFastbootReset ();                  // TPL_APPLICATION: PMIC write works here
  if (mDone) {
    EpssApply (FALSE);
    return;
  }
  mDone = TRUE;
  Log ("dagu-uefi-diag v1\n");
  EpssApply (TRUE);
  WcnCensus ();
  if (DAGU_PLAT_DIAG) {
    WriteEspFile ();
  }
}

STATIC VOID
EFIAPI
OnExitBootServices (
  IN EFI_EVENT  Event,
  IN VOID       *Context
  )
{
  EpssApply (FALSE);                 // last word before the OS: MMIO only
}

EFI_STATUS
EFIAPI
DaguPlatDxeInitialize (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
  EFI_EVENT   Ev, FsEv;
  EFI_STATUS  Status;

  // Windows -> fastboot: fire the flag check as each filesystem mounts.
  Status = gBS->CreateEvent (EVT_NOTIFY_SIGNAL, TPL_CALLBACK, OnFsNotify, NULL, &FsEv);
  if (!EFI_ERROR (Status)) {
    gBS->RegisterProtocolNotify (&gEfiSimpleFileSystemProtocolGuid, FsEv, &mFsReg);
  }
  CheckFastbootFlag ();                 // in case a filesystem is already up

  Status = gBS->CreateEventEx (EVT_NOTIFY_SIGNAL, TPL_CALLBACK, OnReadyToBoot,
                               NULL, &gEfiEventReadyToBootGuid, &Ev);
  if (EFI_ERROR (Status)) {
    DEBUG ((DEBUG_ERROR, "DaguPlat: ready-to-boot event %r\n", Status));
  }
  Status = gBS->CreateEventEx (EVT_NOTIFY_SIGNAL, TPL_CALLBACK, OnExitBootServices,
                               NULL, &gEfiEventExitBootServicesGuid, &Ev);
  if (EFI_ERROR (Status)) {
    DEBUG ((DEBUG_ERROR, "DaguPlat: exit-boot event %r\n", Status));
  }
  return EFI_SUCCESS;
}
