from pathlib import Path

root = Path(__file__).resolve().parents[1]
paths = {
    "port_c": root / "port/dagu/Common/edk2/MdeModulePkg/Application/BootManagerMenuApp/BootManagerMenu.c",
    "edk2_c": root / "edk2-msm/Common/edk2/MdeModulePkg/Application/BootManagerMenuApp/BootManagerMenu.c",
    "edk2_uni": root
    / "edk2-msm/Common/edk2/MdeModulePkg/Application/BootManagerMenuApp/BootManagerMenuStrings.uni",
    "efi": root
    / "edk2-msm/workspace/Build/dagu/RELEASE_CLANG38/AARCH64/MdeModulePkg/Application/BootManagerMenuApp/BootManagerMenuApp/DEBUG/BootManagerMenuApp.efi",
    "apriori": root / "edk2-msm/Platform/Qualcomm/sm8250/Apriori.fdf.inc",
}
for k, p in paths.items():
    print(k, "exists" if p.exists() else "MISSING", p)
    if not p.exists():
        continue
    if p.suffix in {".c", ".uni", ".inc"}:
        t = p.read_text(errors="ignore")
        for needle in [
            "DaguReadAnyKey",
            "KEYFIX-5",
            "CheckEvent",
            "Please select boot device",
            "ButtonsDxe.dagu.efi",
        ]:
            if needle in t:
                print(f"  contains: {needle}")
    if p.suffix == ".efi":
        b = p.read_bytes()
        for s in ["KEYFIX-5", "KEYFIX-4", "key sc=", "DaguRead", "Please select"]:
            print(f"  efi utf16 {s}:", s.encode("utf-16le") in b)
            print(f"  efi ascii {s}:", s.encode() in b)
