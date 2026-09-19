#!/usr/bin/env python3
"""Compare Linux reserved-memory / iomem facts with the dagu UEFI port.

Read-only vs linux-mainline/dts and dumps/. Writes nothing except stdout.
Exit 1 if any required alignment is missing.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DTS_RM = ROOT / "linux-mainline/dts/dagu-reserved-memory-stock.dtsi"
DTS_BOARD = ROOT / "linux-mainline/dts/sm8250-xiaomi-dagu.dts"
DTS_HIMAX = ROOT / "linux-mainline/dts/dagu-geni-spi-experiment.on.dtsi"
DTS_I2C = ROOT / "linux-mainline/dts/dagu-geni-i2c-experiment.on.dtsi"
MEMMAP = (
    ROOT
    / "port/dagu/Platform/Xiaomi/sm8250/Library/dagu/PlatformMemoryMapLib"
    / "PlatformMemoryMapLib.c"
)
ACPI_DIR = ROOT / "port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu"
DTB = ROOT / "port/dagu/Platform/Xiaomi/sm8250/FdtBlob_compat/dagu.dtb"
IOMEM = ROOT / "dumps/dagu-20260826-210700-root/memory/iomem.txt"

# Linux reserved-memory → UEFI name, address, size
REQUIRED_RAM = (
    ("Hypervisor", 0x80000000, 0x00600000, "dagu-reserved-memory-stock.dtsi hyp_region@80000000"),
    ("XBL AOP", 0x80600000, 0x00260000, "dagu-reserved-memory-stock.dtsi xbl_aop_region@80600000"),
    ("AOP CMD DB", 0x80860000, 0x00020000, "dagu-reserved-memory-stock.dtsi reserved-memory@80860000"),
    ("Removed Mem", 0x80B00000, 0x05300000, "dagu-reserved-memory-stock.dtsi removed_region@80b00000"),
    ("PIL Reserved", 0x86200000, 0x0C500000, "PIL camera@86200000 .. cdsp_secure end 0x92700000"),
    ("Display Reserved", 0x9C000000, 0x02300000, "dagu-reserved-memory-stock.dtsi cont_splash_region@9c000000"),
    ("PSTORE", 0xB0000000, 0x00400000, "sm8250-xiaomi-dagu.dts ramoops@b0000000"),
    ("Disp rdump", 0xB0400000, 0x01000000, "dagu-reserved-memory-stock.dtsi disp_rdump_region@b0400000"),
    ("RAM Partition", 0xD0000000, 0x1B0000000, "sm8250-xiaomi-dagu.dts memory bank1 remainder"),
    ("UFS HC", 0x01D84000, 0x0001C000, "sm8250.dtsi ufshc@1d84000 / iomem ufs_mem"),
    ("GPU KGSL", 0x03D00000, 0x00040000, "sm8250.dtsi gpu@3d00000 / iomem kgsl-3d0"),
    ("PCIE0 PARF", 0x01C00000, 0x00004000, "sm8250.dtsi pcie@1c00000 parf"),
    ("PCIE0 MEM", 0x60000000, 0x04000000, "sm8250.dtsi pcie0 ranges / iomem qcom,pcie"),
    ("VENUS", 0x0AA00000, 0x00100000, "sm8250.dtsi video-codec@aa00000"),
    ("MDSS", 0x0AE00000, 0x000C0000, "sm8250.dtsi display-subsystem@ae00000"),
    ("CDSP PAS", 0x08300000, 0x00010000, "sm8250.dtsi remoteproc@8300000"),
    ("SLPI PAS", 0x05C00000, 0x00004000, "sm8250.dtsi remoteproc@5c00000"),
    ("ADRENO SMMU", 0x03DA0000, 0x00010000, "sm8250.dtsi iommu@3da0000"),
    ("LPASS RX", 0x03200000, 0x00052000, "sm8250.dtsi rxmacro@3200000"),
)

ACPI_NEEDLES = (
    (ACPI_DIR / "Dsdt.asl", ("SM8250",)),
    (ACPI_DIR / "dsdt_common.asl", ("SOID, 356", "STOR, 0x1", "Include(\"ufs.asl\")",
                                    "Include(\"Pep_lpi.asl\")", "Include(\"graphics.asl\")",
                                    "Include(\"himax.asl\")", "Include(\"pcie.asl\")",
                                    "Include(\"bluetooth.asl\")", "Include(\"usb.asl\")",
                                    "Include(\"dbg-uart.asl\")",
                                    "Include(\"audio.asl\")", "Include(\"keyboard.asl\")",
                                    "Include(\"battery.asl\")", "Include(\"buttons.asl\")",
                                    "Include(\"backlight.asl\")", "Include(\"sensors.asl\")",
                                    "Include(\"thermal.asl\")", "Include(\"venus.asl\")",
                                    "Include(\"pen.asl\")", "Include(\"typec.asl\")",
                                    "Include(\"haptics.asl\")", "Include(\"i2c.asl\")",
                                    "Include(\"display.asl\")", "Include(\"cdsp.asl\")",
                                    "Include(\"pmic.asl\")", "Include(\"lpass.asl\")",
                                    "Include(\"smmu.asl\")", "Include(\"ipcc.asl\")",
                                    "Include(\"smem.asl\")", "Include(\"qmp.asl\")",
                                    "Include(\"led.asl\")",
                                    "Include(\"npu.asl\")",
                                    "Include(\"ipa.asl\")")),
    (ACPI_DIR / "ufs.asl", ("0x1D84000", "QCOM24A5")),
    (ACPI_DIR / "graphics.asl", ("0x03D00000", "QCOM24B4", "{332}")),
    (ACPI_DIR / "i2c.asl", ("QCOM0C10", "QCOM0C11", "0x00990000", "0x00988000", "0x0088C000")),
    (ACPI_DIR / "himax.asl", ("HIMA8312", "{39}", "1600", "2560", "\\\\_SB.SP04")),
    (ACPI_DIR / "pcie.asl", ("0x01C00000", "0x60000000", "QCA6390", "{172}")),
    (ACPI_DIR / "bluetooth.asl", ("0x00998000", "QCOM2464", "{639}")),
    (ACPI_DIR / "usb.asl", ("0x0A600000", "QCOM24A6", "{165}", "PRS5169", "152",
                            "QCOM24CC", "0xA4A7", "ACM0")),
    (ACPI_DIR / "dbg-uart.asl", ("0x00A90000", "{389}", "34", "35")),
    (ACPI_DIR / "audio.asl", ("QCOM24A8", "WCD9385", "CIRR0041", "0x00984000")),
    (ACPI_DIR / "keyboard.asl", ("NANO0803", "{83}", "\\\\_SB.IC02")),
    (ACPI_DIR / "battery.asl", ("BQ270561", "0x00980000", "0x00A94000", "BQ270970", "0x00884000", "DIS0")),
    (ACPI_DIR / "buttons.asl", ("{110}", "{121}", "PNP0C0C")),
    (ACPI_DIR / "backlight.asl", ("KTZ8866", "0x00A8C000", "0x00A84000")),
    (ACPI_DIR / "sensors.asl", ("QCOM24C0", "0x05C00000")),
    (ACPI_DIR / "thermal.asl", ("QCOM24E0", "0x0C263000")),
    (ACPI_DIR / "venus.asl", ("0x0AA00000", "QCOM24B8", "{206}")),
    (ACPI_DIR / "pen.asl", ("IDTP9418", "0x3B", "{113}")),
    (ACPI_DIR / "typec.asl", ("QCOM24C8",)),
    (ACPI_DIR / "haptics.asl", ("QCOM24C4", "0xC000")),
    (ACPI_DIR / "display.asl", ("0x0AE00000", "QCOM24B5", "1600", "2560", "120")),
    (ACPI_DIR / "cdsp.asl", ("0x08300000", "QCOM24C1")),
    (ACPI_DIR / "pmic.asl", ("QCOM0C09", "0x0C440000", "QCOM24E2")),
    (ACPI_DIR / "lpass.asl", ("0x03200000", "QCOM24A9")),
    (ACPI_DIR / "smmu.asl", ("0x03DA0000", "QCOM24C3")),
    (ACPI_DIR / "ipcc.asl", ("0x00408000", "QCOM24E4")),
    (ACPI_DIR / "smem.asl", ("0x80900000", "QCOM00A5")),
    (ACPI_DIR / "qmp.asl", ("QCOM24A7", "Return (0x0)")),
    (ACPI_DIR / "led.asl", ("0xD300", "QCOM24E8")),
    (ACPI_DIR / "npu.asl", ("0x86900000", "QCOM24CA")),
    (ACPI_DIR / "ipa.asl", ("0x86800000", "QCOM24CB")),
    (ACPI_DIR / "graphics.asl", ("0x03D00000", "QCOM24B4", "{332}", "QCOM24B9")),
)


def parse_memmap(text: str) -> dict[str, tuple[int, int]]:
    out: dict[str, tuple[int, int]] = {}
    for m in re.finditer(
        r'\{\s*"([^"]+)"\s*,\s*(0x[0-9A-Fa-f]+)\s*,\s*(0x[0-9A-Fa-f]+)',
        text,
    ):
        out[m.group(1)] = (int(m.group(2), 16), int(m.group(3), 16))
    return out


def parse_reserved_regs(text: str) -> list[tuple[int, int, str]]:
    regs: list[tuple[int, int, str]] = []
    for m in re.finditer(
        r"([A-Za-z0-9_,@ \t-]+)\s*\{\s*[^}]*?reg = <0x0 (0x[0-9a-fA-F]+) 0x0 (0x[0-9a-fA-F]+)>",
        text,
        re.S,
    ):
        label = " ".join(m.group(1).split())
        regs.append((int(m.group(2), 16), int(m.group(3), 16), label))
    return regs


def check_dtb(path: Path) -> list[str]:
    errs: list[str] = []
    if not path.is_file():
        return [f"missing DTB {path}"]
    blob = path.read_bytes()
    if b"dagu" not in blob.lower() and b"xiaomi dagu" not in blob.lower():
        errs.append(f"{path}: no 'dagu' string (refusing elish/nabu)")
    if b"l81a" not in blob.lower() and b"L81A" not in blob:
        errs.append(f"{path}: no 'l81a' panel string")
    if b"elish" in blob and b"dagu" not in blob.lower():
        errs.append(f"{path}: looks like leftover elish FDT")
    return errs


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()
    errs: list[str] = []

    if not MEMMAP.is_file():
        print(f"missing {MEMMAP}", file=sys.stderr)
        return 2
    mmap = parse_memmap(MEMMAP.read_text(encoding="utf-8", errors="replace"))

    print("== UEFI memory map vs Linux reserved-memory ==")
    for name, addr, size, src in REQUIRED_RAM:
        got = mmap.get(name)
        ok = got == (addr, size)
        mark = "OK" if ok else "FAIL"
        print(f"  [{mark}] {name:18s} 0x{addr:X}+0x{size:X}  <- {src}")
        if not ok:
            errs.append(f"{name}: want 0x{addr:X}+0x{size:X} got {got}")

    if DTS_RM.is_file():
        regs = parse_reserved_regs(DTS_RM.read_text(encoding="utf-8", errors="replace"))
        print(f"\n== {DTS_RM.relative_to(ROOT)} parsed {len(regs)} reg= nodes ==")
        if not args.quiet:
            for a, s, lab in regs[:20]:
                print(f"  0x{a:X}+0x{s:X}  {lab}")

    print("\n== ACPI needles ==")
    for path, needles in ACPI_NEEDLES:
        text = path.read_text(encoding="utf-8", errors="replace") if path.is_file() else ""
        if not path.is_file():
            errs.append(f"missing {path}")
            print(f"  [FAIL] missing {path}")
            continue
        missing = [n for n in needles if n not in text]
        mark = "OK" if not missing else "FAIL"
        print(f"  [{mark}] {path.relative_to(ROOT)}")
        for n in missing:
            errs.append(f"{path.name}: missing {n!r}")
            print(f"         missing {n!r}")

    print("\n== hardware facts (Linux DT) ==")
    board = DTS_BOARD.read_text(encoding="utf-8", errors="replace") if DTS_BOARD.is_file() else ""
    himax = DTS_HIMAX.read_text(encoding="utf-8", errors="replace") if DTS_HIMAX.is_file() else ""
    i2c = DTS_I2C.read_text(encoding="utf-8", errors="replace") if DTS_I2C.is_file() else ""
    facts = (
        (DTS_BOARD, "&gpu", "&gpu {" in board),
        (DTS_BOARD, "&ufs_mem_hc", "&ufs_mem_hc" in board),
        (DTS_BOARD, "&pcie0", "&pcie0 { status = \"okay\"" in board),
        (DTS_BOARD, "&uart6 qca6390-bt", "qcom,qca6390-bt" in board),
        (DTS_BOARD, "&usb_1_dwc3", "&usb_1_dwc3" in board),
        (DTS_BOARD, "hall GPIO110/121", "tlmm 110" in board and "tlmm 121" in board),
        (DTS_BOARD, "&slpi", "&slpi" in board and "slpi.mbn" in board),
        (DTS_BOARD, "&venus", "&venus" in board and "venus.mdt" in board),
        (DTS_BOARD, "p9418 @3b", "idt,p9418" in board),
        (DTS_BOARD, "&mdss", "&mdss" in board),
        (DTS_BOARD, "&cdsp", "&cdsp" in board and "cdsp.mbn" in board),
        (DTS_BOARD, "&adreno_smmu", "&adreno_smmu" in board),
        (DTS_HIMAX, "&spi4 product", "&spi4" in himax and "himax,hx83121-dagu" in himax),
        (DTS_HIMAX, "IRQ 39", "interrupts = <39" in himax),
        (DTS_HIMAX, "himax_spi disabled", "&himax_spi { status = \"disabled\"" in himax),
        (DTS_I2C, "keyboard@4c", "keyboard@4c" in i2c and "nanosic,803" in i2c),
        (DTS_I2C, "bq27z561 @55", "ti,bq27z561" in i2c),
        (DTS_I2C, "ktz8866 @11", "kinetic,ktz8866" in i2c),
        (DTS_I2C, "cs35l41", "cirrus,cs35l41" in i2c),
        (DTS_I2C, "bq25970 @66", "ti,bq25970" in i2c),
    )
    for path, label, ok in facts:
        print(f"  [{'OK' if ok else 'FAIL'}] {path.name} {label}")
        if not ok:
            errs.append(f"{path}: {label}")

    if IOMEM.is_file():
        iomem = IOMEM.read_text(encoding="utf-8", errors="replace")
        print("\n== live iomem ==")
        for needle in ("01d84000-01d86fff", "03d00000-03d3ffff",
                       "03da0000-03daffff", "17c10000-17c10fff",
                       "0c440000-0c4410ff", "00408000-00408fff"):
            ok = needle in iomem
            print(f"  [{'OK' if ok else 'FAIL'}] {needle}")
            if not ok:
                errs.append(f"iomem missing {needle}")
    else:
        print("\n== live iomem SKIP (dumps not present) ==")

    print("\n== UEFI FDT ==")
    dtb_errs = check_dtb(DTB)
    if dtb_errs:
        errs.extend(dtb_errs)
        for e in dtb_errs:
            print(f"  [FAIL] {e}")
    else:
        print(f"  [OK] {DTB.relative_to(ROOT)} has dagu + l81a")

    if errs:
        print("\nUNALIGNED:")
        for e in errs:
            print(f"  - {e}")
        return 1
    print("\nALL REQUIRED ALIGNMENTS OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
