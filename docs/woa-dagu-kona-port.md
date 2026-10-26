# Windows on ARM for dagu (Xiaomi Pad 5 Pro 12.4, SM8250) — Kona/Mu port

Status as of 2026-10-26. This supersedes the earlier edk2-msm attempt in
[`port/dagu/`](../port/dagu) for the firmware path. Honest summary up front so
nobody is misled:

- **Built and reproducible:** a dagu-specific UEFI firmware (Android boot
  image) from the mature, *already-working* SM8250 target `xiaomi-pipa`
  (Xiaomi Pad 6) in [Project-Aloha/mu_aloha_platforms]
  (https://github.com/Project-Aloha/mu_aloha_platforms) KonaPkg.
- **Not yet done:** booting it on the tablet, running Windows Setup, and
  bringing up drivers. The first on-device UEFI boot is the next gate and it
  needs physical availability (see *Why this can't be finished purely
  remotely*). **Do not assume Windows runs on dagu yet — it does not.**

## Why this is tractable now (and what it still isn't)

dagu is a Snapdragon 870 (SM8250 "Kona"). The Pad 6 (`pipa`) is the same SoC
and is a fully supported WoA target upstream, and dagu ships the **identical
XBL** (`BOOT.XF.3.2-00304-SM8250-2`) — verified against both `xbl_a`/`xbl_b`
on the device. So this is a *device port of a working stack*, not a
from-scratch bring-up:

- UEFI firmware: reuse pipa's KonaPkg target; swap in dagu's own extracted
  stock UEFI binaries (board `DisplayDxe`/`PmicDxeLa`/`TLMMDxe`/`DALSYSDxe`,
  L81A panel XMLs, charger cfg) + dagu panel geometry + dagu memory map.
- SoC Windows drivers: the Kona BSP
  [`WOA-Project/windows_silicon_qcom_kona`](https://github.com/WOA-Project/windows_silicon_qcom_kona)
  (UFS, USB, GPU, Wi-Fi, etc.).
- Windows image: a Win11 25H2 ARM64 ISO is already staged under
  `tools/downloads/win11-arm64/` (built from UUP on Linux).

What is **not** solved by reuse, and is the real ceiling on "all functions
like Linux": dagu's *OEM peripherals* need their own Windows drivers, and most
do not exist — L81A panel (display path beyond UEFI framebuffer), Himax
HX83121 touch, Nanosic 803 folio keyboard, CS35L41 speaker amps, the dual
BQ27Z561 fuel gauge, cameras, SLPI sensors. The hand-written KMDF stubs in
[`port/dagu/windows-drivers/`](../port/dagu/windows-drivers) are skeletons, not
working drivers, and cannot be finished by log-iteration from here because once
Windows HLOS starts there is no remote console — bring-up needs eyes on the
panel. Realistic reachable milestone from this machine: **UEFI boots →
framebuffer → WinPE/Setup runs**. Beyond that (desktop + every peripheral)
needs on-device, in-person driver work.

## Build

```bash
cd winarm
./build-dagu-uefi.sh            # DEBUG: screen + memory serial
# -> winarm/out/xiaomi-dagu-uefi-debug.img  (ANDROID! v2, ~3.7 MB)
```

The reproducible recipe lives in `build-dagu-uefi.sh`; our dagu-specific files
are tracked under `winarm/overlay/xiaomi-dagu/` (the 3 GB upstream clone and
the extracted-firmware checkout are git-ignored and re-fetched by the script).
Device-specific edits vs pipa:

- `PcdsFixedAtBuild.dsc.inc` — panel 1600×2560, SMBIOS/ABL product strings.
- `Library/PlatformMemoryMapLib/PlatformMemoryMapLib.c` — a `PStore` carveout
  at `0xB0400000` (2 MB) for the in-memory serial log, gated on
  `USE_MEMORY_FOR_SERIAL_OUTPUT`. It sits inside the stock
  `disp_rdump_region` (`0xB0400000`, 16 MB), which the dagu Linux DT keeps
  `no-map`, so Linux never writes it and can read it back (see below).
- `APRIORI.inc` — RngDxe dispatched before VariableRuntimeDxe (the latter's
  `DxeRngLib` constructor asserts without `EFI_RNG_PROTOCOL`; upstream only
  builds RELEASE, where that ASSERT is compiled out).
- DEBUG-only build tweaks applied by `build-dagu-uefi.sh`:
  `PcdDebugPropertyMask` 0x2f → 0x0f (ASSERTs print but don't dead-loop) and
  console `SCALE_FACTOR` 1 → 2 (readable in photos).
- `DeviceTreeBlob/Android/android-dagu.dtb` — generic-kona DTB
  (`msm-id 0x164/0x20001, board-id 0,0`), the id dagu's ABL accepts (same one
  `linux-mainline/scripts/build-bootimg.sh` stamps for Linux).
- `KonaNoSb.dsc` — `USE_SCREEN_FOR_SERIAL_OUTPUT=1` and
  `USE_MEMORY_FOR_SERIAL_OUTPUT=1` so early UEFI prints on the panel *and* into
  the PStore ring.

## Safe slot model + logging loop (the "reboot to get logs" system)

```
boot_b = mainline Linux   home base, SSH over Wi-Fi — our remote shell
boot_a = UEFI experiment  the dagu KonaPkg image
```

Driver: [`tools/winarm/dagu-uefi-loop.sh`](../tools/winarm/dagu-uefi-loop.sh).

- `flash`   — SSH-reboot Linux → fastboot, flash the UEFI image to **boot_a**
  only, `set_active a`, reboot into UEFI. boot_b/Linux is never touched.
- `watch`   — poll USB + SSH and timestamp every transition into
  `logs/winarm/<ts>/` (fastboot / linux-gadget / linux-ssh / none).
- `recover` — if the device is in fastboot, `set_active b` + reboot → Linux.
  **This is fully remote** via the USB cable on the build PC.
- `readlog` — from Linux-b, dump and decode the UEFI PStore serial ring at
  `0xB0400000`, if DDR was retained across the reset chain back to Linux.

Recovery matrix:

| UEFI outcome | Signal | Recovery |
|---|---|---|
| crashes back to ABL | USB `18d1:d00d` | `recover` sets active b, reboots to Linux — remote |
| reaches framebuffer/BDS and idles | USB quiet / Windows USB | needs a reboot; not remote unless it proceeds to boot Windows |
| hard hang (no watchdog reboot) | USB dark | **physical** power-cycle (user); ABL retry eventually falls back to b |

### Reading the UEFI log from Linux

The PStore ring lives inside `disp_rdump_region`, which the boot_b DT marks
`no-map`. On arm64, no-map regions are registered as "reserved", not
"System RAM", so `/dev/mem` reads are allowed even with
`CONFIG_STRICT_DEVMEM=y`; no diag kernel is needed. Whether the content
survives depends on the reset type keeping DDR alive through XBL/ABL;
`readlog` reports a bad ring offset if it did not. `read()` on the region
returns EFAULT (no linear mapping for no-map memory on arm64), so `readlog`
`mmap()`s `/dev/mem` instead.

Measured 2026-10-26: after a UEFI crash, **Vol-Down+Power does not retain
DDR**. The 2 MB region came back as sparse single-bit noise (DRAM decay), no
text, so that reset removes DDR power. The ring is only useful across warm
resets. Photos of the panel (2x font in DEBUG builds) are the channel for
crashes that need a button reset.

The on-panel serial text (screen serial) remains the first-boot channel.

## Windows deployment (from Linux, once UEFI boots)

All data on `userdata` is to be wiped (confirmed). Plan, runnable from the
mainline Linux on boot_b:

1. Repartition: shrink/replace `userdata` with an EFI System Partition (FAT32,
   ~300 MB) + a Windows NTFS partition. (Qualcomm WoA also wants the ESP laid
   where the firmware's BDS looks; pipa/nabu use the deployer's layout — mirror
   that.)
2. Apply the image: `wimlib-imagex apply` the ARM64 `install.wim`/`esd` from
   `tools/downloads/win11-arm64/` onto the NTFS partition.
3. Lay the ESP: `bcdboot`-equivalent (`wimlib` + manual BCD, or the
   `Port-Windows-11-Xiaomi-Pad-5` deployer layout) — EFI/Microsoft boot files.
4. Inject drivers offline: the Kona BSP + dagu ACPI (from
   [`port/dagu/.../AcpiTables/dagu`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu))
   via `dism`-style offline servicing (`drvstore`/registry hive edits with
   `hivexsh`), plus the dagu OEM driver stubs as they mature.
5. Keep mainline Linux on boot_b as the recovery path throughout.

The `erdilS/Port-Windows-11-Xiaomi-Pad-5` guide is the closest reference
(nabu/elish, same family); its deployer automates steps 1–4 on Windows, but the
steps are reproducible from Linux with `sgdisk`, `mkfs.ntfs`/`mkfs.vfat`,
`wimlib-imagex`, and `hivex` — all present on the build host.

## Why this can't be finished purely remotely

Once the device leaves Linux-on-boot_b there is no remote console: UEFI only
prints to the panel (and the PStore RAM ring we read back *after* returning to
Linux), and Windows HLOS has no remote shell at all until networking + an
RDP/SSH story exists (which itself needs working drivers). A first UEFI boot
that hangs needs a physical power-cycle. Driver bring-up for the OEM
peripherals needs someone watching the screen. So the autonomous, remote part
ends at "produce a correct UEFI image + a safe flash/log loop + a Windows
deployment that is laid down from Linux"; the actual *boot-and-verify* and
*driver* work is in-person.
