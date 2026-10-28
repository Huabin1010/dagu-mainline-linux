#!/usr/bin/env bash
# Build the dagu (Xiaomi Pad 5 Pro 12.4, SM8250) UEFI firmware as an Android
# boot image, by porting the already-working xiaomi-pipa (Xiaomi Pad 6, same
# SM8250 SoC) target in Project-Aloha/mu_aloha_platforms (KonaPkg).
#
# dagu and pipa share the exact XBL (BOOT.XF.3.2-00304-SM8250-2), so the port
# is: pipa device dir + dagu's own extracted stock UEFI binaries (board EFIs,
# L81A panel XMLs, charger cfg) + dagu memory map with a PStore serial-log
# carveout + the generic-kona DTB (msm-id 0x164/0x20001, board-id 0,0) that
# dagu's ABL accepts (same id our Linux vendor_boot uses).
#
#   ./build-dagu-uefi.sh            # DEBUG build (screen + memory serial)
#   BUILD_TYPE=RELEASE ./build-dagu-uefi.sh
#
# Output: out/xiaomi-dagu-uefi-<type>.img
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
BUILD_TYPE="${BUILD_TYPE:-DEBUG}"
MU=mu_aloha_platforms
FW=UEFIFirmwareBackup
DAGU_FW="$FW/xiaomi-dagu/BOOT.XF.3.2-00304-SM8250-2"
PIPA_FW="$FW/xiaomi-pipa/BOOT.XF.3.2-00304-SM8250-2"

# 1. Upstream sources ---------------------------------------------------------
[ -d "$MU/.git" ] || git clone --depth 1 https://github.com/Project-Aloha/mu_aloha_platforms.git "$MU"
if [ ! -d "$FW/.git" ]; then
	git clone --depth 1 --filter=blob:none --sparse \
		https://github.com/Project-Aloha/UEFIFirmwareBackup.git "$FW"
	git -C "$FW" sparse-checkout set xiaomi-dagu xiaomi-pipa
fi
[ -d "$DAGU_FW" ] || { echo "missing $DAGU_FW" >&2; exit 1; }

# 2. Build container ----------------------------------------------------------
if ! docker image inspect mu-aloha:v1 >/dev/null 2>&1; then
	cp "$MU/pip-requirements.txt" docker/
	docker build -t mu-aloha:v1 -f docker/Dockerfile.mu docker
fi

# 3. Assemble the xiaomi-dagu device dir from pipa + dagu binaries + overlay ---
DEV="$MU/Platforms/KonaPkg/Device"
rm -rf "$DEV/xiaomi-dagu"
cp -a "$DEV/xiaomi-pipa" "$DEV/xiaomi-dagu"
rm -rf "$DEV/xiaomi-dagu/Binaries"
cp -a "$DAGU_FW" "$DEV/xiaomi-dagu/Binaries"
# Cosmetic charger bitmaps: use pipa's (pass Mu's BGRT validator; dagu's and
# pipa's both emit a benign "battery_symbol_Soc10.bmp failed" note — harmless).
cp -f "$PIPA_FW"/RawFiles/*.bmp "$DEV/xiaomi-dagu/Binaries/RawFiles/"
# Our authored, dagu-specific files (panel geometry, memory map, DTB).
cp -f overlay/xiaomi-dagu/PcdsFixedAtBuild.dsc.inc "$DEV/xiaomi-dagu/"
cp -f overlay/xiaomi-dagu/Library/PlatformMemoryMapLib/PlatformMemoryMapLib.c \
	"$DEV/xiaomi-dagu/Library/PlatformMemoryMapLib/"
rm -f "$DEV/xiaomi-dagu/DeviceTreeBlob/Android/android-pipa.dtb"
cp -f overlay/xiaomi-dagu/DeviceTreeBlob/Android/android-dagu.dtb \
	"$DEV/xiaomi-dagu/DeviceTreeBlob/Android/"
# DXE dispatch order: RngDxe before VariableRuntimeDxe. VariableRuntimeDxe's
# DxeRngLib constructor needs EFI_RNG_PROTOCOL; upstream only builds RELEASE,
# where the resulting ASSERT_EFI_ERROR is compiled out.
cp -f overlay/xiaomi-dagu/APRIORI.inc "$DEV/xiaomi-dagu/"
# Backlight: XBL/ABL leave the dual KTZ8866 at the dim splash level and
# nothing later raises it. DaguBacklightDxe programs it (dispatched from
# APRIORI right after SimpleFbDxe); also list it in the FV and the DSC.
cp -a overlay/xiaomi-dagu/Driver "$DEV/xiaomi-dagu/"
BL_INF='$(PACKAGE_NAME)/Device/$(TARGET_DEVICE)/Driver/DaguBacklightDxe/DaguBacklightDxe.inf'
grep -q DaguBacklightDxe "$DEV/xiaomi-dagu/DXE.inc" || \
	sed -i "s|^\(\s*\)INF AndromedaPkg/Driver/SimpleFbDxe/SimpleFbDxe.inf|&\n\1INF $BL_INF|" "$DEV/xiaomi-dagu/DXE.inc"
grep -q DaguBacklightDxe "$DEV/xiaomi-dagu/DXE.dsc.inc" || \
	sed -i "s|^\(\s*\)AndromedaPkg/Driver/SimpleFbDxe/SimpleFbDxe.inf|&\n\1$BL_INF|" "$DEV/xiaomi-dagu/DXE.dsc.inc"
# QUP: per-SE firmware for the keyboard (SE2 I2C) and touch (SE4 SPI).
# The blob is generated here because qupv3fw.elf is not in git.
QUP_INF='$(PACKAGE_NAME)/Device/$(TARGET_DEVICE)/Driver/DaguQupDxe/DaguQupDxe.inf'
QUP_ELF="$HERE/../linux-mainline/firmware/dagu/lib/firmware/qcom/sm8250/xiaomi/dagu/qupv3fw.elf"
[ -s "$QUP_ELF" ] || { echo "no QUP firmware: $QUP_ELF" >&2; exit 1; }
python3 - "$QUP_ELF" "$DEV/xiaomi-dagu/Driver/DaguQupDxe/DaguQupFw.inc" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
if data[:4] != b"\x7fELF" or len(data) < 64:
    sys.exit("qupv3fw.elf is not an ELF")
out = open(sys.argv[2], "w")
for i in range(0, len(data), 16):
    chunk = data[i:i + 16]
    out.write("  " + ", ".join("0x%02x" % b for b in chunk) + ",\n")
out.close()
PY
grep -q DaguQupDxe "$DEV/xiaomi-dagu/DXE.inc" || \
	sed -i "s|^\(\s*\)INF .*DaguBacklightDxe.inf|&\n\1INF $QUP_INF|" "$DEV/xiaomi-dagu/DXE.inc"
grep -q DaguQupDxe "$DEV/xiaomi-dagu/DXE.dsc.inc" || \
	sed -i "s|^\(\s*\).*DaguBacklightDxe.inf|&\n\1$QUP_INF|" "$DEV/xiaomi-dagu/DXE.dsc.inc"
# Watchdog probe: read-only log of the APSS watchdog around ExitBootServices.
WDT_INF='$(PACKAGE_NAME)/Device/$(TARGET_DEVICE)/Driver/DaguWdtProbeDxe/DaguWdtProbeDxe.inf'
grep -q DaguWdtProbeDxe "$DEV/xiaomi-dagu/DXE.inc" || \
	sed -i "s|^\(\s*\)INF .*DaguQupDxe.inf|&\n\1INF $WDT_INF|" "$DEV/xiaomi-dagu/DXE.inc"
grep -q DaguWdtProbeDxe "$DEV/xiaomi-dagu/DXE.dsc.inc" || \
	sed -i "s|^\(\s*\).*DaguQupDxe.inf|&\n\1$WDT_INF|" "$DEV/xiaomi-dagu/DXE.dsc.inc"
# CPU EPSS performance level for Windows (no PEP, no _CPC) + boot census
# (EPSS, QCA6390 rails) written to \dagu-uefi-diag.txt on the ESP.
PLAT_INF='$(PACKAGE_NAME)/Device/$(TARGET_DEVICE)/Driver/DaguPlatDxe/DaguPlatDxe.inf'
grep -q DaguPlatDxe "$DEV/xiaomi-dagu/DXE.inc" || \
	sed -i "s|^\(\s*\)INF .*DaguWdtProbeDxe.inf|&\n\1INF $PLAT_INF|" "$DEV/xiaomi-dagu/DXE.inc"
grep -q DaguPlatDxe "$DEV/xiaomi-dagu/DXE.dsc.inc" || \
	sed -i "s|^\(\s*\).*DaguWdtProbeDxe.inf|&\n\1$PLAT_INF|" "$DEV/xiaomi-dagu/DXE.dsc.inc"
grep -q DaguPlatDxe "$DEV/xiaomi-dagu/DXE.inc" && grep -q DaguPlatDxe "$DEV/xiaomi-dagu/DXE.dsc.inc" || \
	{ echo "DaguPlatDxe not registered" >&2; exit 1; }
# QCA6390 power + PCIe0 (Wi-Fi) bring-up. Publishes its own PCI0 SSDT and an
# MCFG only when the link trains, so the PCI0 ASL is compiled into the driver.
PCIE_INF='$(PACKAGE_NAME)/Device/$(TARGET_DEVICE)/Driver/DaguPcieDxe/DaguPcieDxe.inf'
PCIE_DIR="$DEV/xiaomi-dagu/Driver/DaguPcieDxe"
IASL_P="$(command -v iasl || find "$HERE/$MU/MU_BASECORE/BaseTools/Bin" -path '*Linux-x86/iasl' -type f 2>/dev/null | head -1)"
[ -x "$IASL_P" ] || { echo "no iasl for Pcie0Ssdt.asl" >&2; exit 1; }
(cd "$PCIE_DIR" && "$IASL_P" -p Pcie0Ssdt Pcie0Ssdt.asl >/dev/null) || { echo "Pcie0Ssdt.asl failed" >&2; exit 1; }
python3 - "$PCIE_DIR/Pcie0Ssdt.aml" "$PCIE_DIR/Pcie0Ssdt.inc" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
if d[:4] != b"SSDT":
    sys.exit("Pcie0Ssdt.aml is not an SSDT")
open(sys.argv[2], "w").write("".join("  " + ", ".join("0x%02x" % b for b in d[i:i + 16]) + ",\n"
                                     for i in range(0, len(d), 16)))
PY
grep -q DaguPcieDxe "$DEV/xiaomi-dagu/DXE.inc" || \
	sed -i "s|^\(\s*\)INF .*DaguPlatDxe.inf|&\n\1INF $PCIE_INF|" "$DEV/xiaomi-dagu/DXE.inc"
grep -q DaguPcieDxe "$DEV/xiaomi-dagu/DXE.dsc.inc" || \
	sed -i "s|^\(\s*\).*DaguPlatDxe.inf|&\n\1$PCIE_INF|" "$DEV/xiaomi-dagu/DXE.dsc.inc"
grep -q DaguPcieDxe "$DEV/xiaomi-dagu/DXE.inc" && grep -q DaguPcieDxe "$DEV/xiaomi-dagu/DXE.dsc.inc" || \
	{ echo "DaguPcieDxe not registered" >&2; exit 1; }
# DSDT: pipa ships a 0-byte DSDT.aml. AcpiPlatformDxe then reads the table
# Length from an empty RAW section (garbage), asserts Size >= TableSize, and
# AcpiPlatformChecksum walks off the end of mapped DDR (data abort at
# 0xBB800000). Build dagu's own DSDT from edk2-msm/.../AcpiTables/dagu.
#
# Not the SM8250 MTP reference DSDT: it makes UFS0 (the boot disk) and 31 other
# devices _DEP on PEP0 = ACPI\QCOM2519, which only qcpep8250.sys can start. With
# qcpep Windows hangs in PnP start (bugcheck 0x1D5, DRIVER_PNP_WATCHDOG, param1
# "qcpe"); without it acpi.sys never releases UFS0 and the boot dies with 0x7B
# (INACCESSIBLE_BOOT_DEVICE, 0xC0000034). dagu's tree has no _DEP, PEP0 is a
# placeholder (QCOM2430) and UFS0 keeps _CCA 0 as the stock DT (no dma-coherent).
ASL_SRC="$HERE/../edk2-msm/Platform/Xiaomi/sm8250/AcpiTables/dagu"
IASL="$(command -v iasl || true)"
[ -n "$IASL" ] || IASL="$(find "$HERE/$MU/MU_BASECORE/BaseTools/Bin" -path '*Linux-x86/iasl' -type f 2>/dev/null | head -1)"
[ -x "$IASL" ] || { echo "no iasl (install acpica-tools)" >&2; exit 1; }
ASL_TMP="$(mktemp -d)"
cp "$ASL_SRC"/*.asl "$ASL_TMP/"
# DSDT_ONLY keeps only those Include()s in dsdt_common.asl. The default is the
# set Windows actually boots with on dagu. The full table (DSDT_ONLY=all)
# bugchecks Windows with ACPI_BIOS_ERROR (0xA5): it carries PEP0 and ~60 other
# nodes (MDSS, ADSP, PMIC, SPMI, ...) whose dependencies dagu cannot satisfy.
# A plain rebuild once silently produced that full table and bricked boot, so
# never fall back to "all" implicitly. Add a node here only after it is tested.
DSDT_ONLY="${DSDT_ONLY:-ufs Pep_lpi gpio himax keyboard bluetooth}"
[ "$DSDT_ONLY" = all ] && DSDT_ONLY=""
if [ -n "${DSDT_ONLY:-}" ]; then
	keep="$(printf '%s\n' $DSDT_ONLY | sed 's/$/.asl/' | paste -sd'|')"
	sed -Ei "/Include\(\"($keep)\"\)/! s|^(\s*)Include\(|\1// Include(|" "$ASL_TMP/dsdt_common.asl"
	echo "==> DSDT_ONLY: $(grep -oE '^\s*Include\("[^"]+"\)' "$ASL_TMP/dsdt_common.asl" | tr -d ' ' | paste -sd' ')"
fi
(cd "$ASL_TMP" && "$IASL" -vi Dsdt.asl >/dev/null)
cp -f "$ASL_TMP/DSDT.aml" "$DEV/xiaomi-dagu/ACPI/DSDT.aml"
rm -rf "$ASL_TMP"
[ -s "$DEV/xiaomi-dagu/ACPI/DSDT.aml" ] || { echo "empty DSDT.aml" >&2; exit 1; }
# AcpiPlatformUpdateLib overwrites Name() values in place with a fixed-width
# CopyMem and no size check; a shorter AML encoding corrupts the namespace.
python3 - "$DEV/xiaomi-dagu/ACPI/DSDT.aml" \
	"$MU/Silicon/QC/Sm8250/QcomPkg/Library/AcpiPlatformUpdateLib/AcpiPlatformUpdateLib.c" \
	"$MU/Platforms/QcomModulePkg/Include/Protocol/EFIChipInfo.h" <<'PY'
import re, sys
aml, src, hdr = (open(p, "rb").read() for p in sys.argv[1:])
consts = {k.encode(): v.encode() for k, v in
          re.findall(r"#define\s+(\w+)\s+(\d+)", hdr.decode())}
width = {0x0A: 1, 0x0B: 2, 0x0C: 4, 0x0E: 8}
calls = re.findall(
    rb"UpdateNameAslCode\(SIGNATURE_32\('(.)', '(.)', '(.)', '(.)'\),\s*&?\w+,\s*(\w+)\)", src)
if len(calls) < 20:
    sys.exit(f"parsed only {len(calls)} UpdateNameAslCode calls; check the regex")
bad = []
for *chars, length in calls:
    sig = b"".join(chars)
    n = int(consts.get(length, length))
    i = aml.find(b"\x08" + sig)
    if i < 0:
        continue
    op = aml[i + 5]
    have = aml.index(b"\x00", i + 6) - i - 5 if op == 0x0D else width.get(op, 0)
    if have < n:
        bad.append(f"{sig.decode()}: {have} byte(s) in AML, firmware writes {n}")
if bad:
    sys.exit("DSDT placeholders too narrow for AcpiPlatformUpdateLib:\n  " + "\n  ".join(bad))
PY

# MemoryTypeInformation: BDS writes the variable with the size of the PEI HOB.
# The only HOB producer in this tree (MU_BASECORE PrePiHobLib Hob.c) builds 6
# entries (5 runtime types + terminator, 0x30 bytes), and so does MU_BASECORE's
# own var-check lib. AndromedaPkg's copy of the check lib demands 10 entries
# (0x50), so every SetVariable is rejected with SECURITY_VIOLATION ("DataSize =
# 0x30 Expected = 0x50", "settings cannot be saved", status code V03058002 and
# the MsWhea "Unrecognized data" line it triggers). Make the check match the
# producer, as in MU_BASECORE.
sed -i 's/^\(#define\s\+EFI_MEMORY_TYPE_INFORMATION_VARIABLE_INFO_COUNT\s\+\)10$/\16/' \
	"$MU/Platforms/AndromedaPkg/Library/MemoryTypeInfoSecVarCheckLib/MemoryTypeInfoSecVarCheckLib.c"
grep -Eq 'VARIABLE_INFO_COUNT\s+6$' \
	"$MU/Platforms/AndromedaPkg/Library/MemoryTypeInfoSecVarCheckLib/MemoryTypeInfoSecVarCheckLib.c" || \
	{ echo "MemoryTypeInfoSecVarCheckLib count patch failed" >&2; exit 1; }

# FACS: KonaPkg's ACPI.inc ships FACP but no FACS. AcpiTableDxe rewrites
# FADT.FIRMWARE_CTRL from the installed FACS, so it ends up 0 and
# UpdateFacsHardwareSignatureLib logs "Unable to locate FacsPtr". Every other
# platform in the tree installs one; the 64-byte rev-2 table is SoC-neutral.
ACPI_INC="$MU/Platforms/KonaPkg/Include/ACPI.inc"
grep -q 'FACS.aml' "$ACPI_INC" || \
	sed -i 's|^\(\s*\)SECTION RAW = SurfaceDuoACPI/QcomACPI/8250/builtin/FACP.aml|&\n\1SECTION RAW = SurfaceDuoACPI/QcomACPI/8350/builtin/FACS.aml|' "$ACPI_INC"
grep -q 'FACS.aml' "$ACPI_INC" || { echo "FACS patch failed" >&2; exit 1; }

# IORT: the MTP table maps \_SB.UFS0 (and PCIe, USB, ...) behind the apps SMMU
# at 0x15000000. Windows then puts UFS DMA behind that SMMU and needs qcsmmu +
# PEP running before the boot disk shows up; without them the boot dies with
# 0x7B / 0xC0000034. The SM8250 phones that boot Windows from UFS (alioth, lmi,
# elish in edk2-msm) ship no IORT at all. Drop it; bring it back together with a
# dagu IORT once SMMU is owned by a working driver stack.
sed -i '/QcomACPI\/8250\/builtin\/IORT\.aml/d' "$ACPI_INC"
! grep -q 'IORT\.aml' "$ACPI_INC" || { echo "IORT removal failed" >&2; exit 1; }
# MCFG: the MTP table also lists PCIe1 (segment 1 at 0x40000000), which dagu
# never powers. DaguPcieDxe installs a segment-0-only MCFG after link-up.
sed -i '/QcomACPI\/8250\/builtin\/MCFG\.aml/d' "$ACPI_INC"
! grep -q 'MCFG\.aml' "$ACPI_INC" || { echo "MCFG removal failed" >&2; exit 1; }

# 4. Debug serial: screen (panel) + memory (PStore ring at 0xB0400000) --------
sed -i 's/USE_SCREEN_FOR_SERIAL_OUTPUT    = 0/USE_SCREEN_FOR_SERIAL_OUTPUT    = 1/;
        s/USE_MEMORY_FOR_SERIAL_OUTPUT    = 0/USE_MEMORY_FOR_SERIAL_OUTPUT    = 1/' \
	"$MU/Platforms/KonaPkg/KonaNoSb.dsc"
if [ "$BUILD_TYPE" = DEBUG ]; then
	# Diagnostic only: ASSERTs print but do not dead-loop (0x2f -> 0x0f), so
	# one boot shows every failure in the chain instead of only the first.
	sed -i '/^!if \$(TARGET) == DEBUG/,/^!else/ s/PcdDebugPropertyMask|0x2f/PcdDebugPropertyMask|0x0f/' \
		"$MU/Platforms/AndromedaPkg/Andromeda.dsc.inc"
	# 2x console font: the 5x12 glyph is ~1.2 mm tall on the 12.4" panel and
	# unreadable in photos of crash dumps.
	sed -i 's/^#define SCALE_FACTOR 1$/#define SCALE_FACTOR 2/' \
		"$MU/Platforms/AndromedaPkg/Include/Resources/font5x12.h"
fi

# 5. Build --------------------------------------------------------------------
./mu-run.sh python3 build_uefi.py -d xiaomi-dagu -t "$BUILD_TYPE"

mkdir -p out
cp -f "$MU/Build/KonaPkg/xiaomi-dagu.img" "out/xiaomi-dagu-uefi-${BUILD_TYPE,,}.img"

# 6. Package for dagu's ABL ----------------------------------------------------
# ABL rejects from-scratch v2/v3 images (incl. Mu's xiaomi-dagu.img). Reuse the
# Linux pipeline, which magiskboot-repacks the stock v3 boot + vendor_boot, with
# the raw Mu payload (shim + FD) as the "kernel".
OUT="$HERE/out"
gzip -dc "$MU/Build/KonaPkg/bootpayload.bin" > "$OUT/dagu-uefi-payload.raw"
(cd ../linux-mainline && KERNEL_IMG="$OUT/dagu-uefi-payload.raw" \
	BOOTIMG="$OUT/boot-dagu-uefi-v3.img" VBOOT="$OUT/vendor_boot-dagu-uefi.img" \
	./scripts/build-bootimg.sh)
echo "==> $OUT/boot-dagu-uefi-v3.img (+ vendor_boot-dagu-uefi.img) for slot A"
