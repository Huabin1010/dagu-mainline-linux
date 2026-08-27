from pathlib import Path
import re
import struct

home = Path(__file__).resolve().parents[1] / "edk2-msm"
sm = home / "Platform/EFI_Binaries/Drivers/sm8250"

for name in [
    "PlatformInfoDxeDriver/PlatformInfoDxeDriver.efi",
    "PmicDxe/PmicDxe.efi",
    "ButtonsDxe/ButtonsDxe.efi",
]:
    p = sm / name
    if not p.exists():
        # try elish buttons
        p = home / "Platform/EFI_Binaries/Drivers/Devices/elish/ButtonsDxe/ButtonsDxe.efi"
    b = p.read_bytes()
    strs = sorted(set(m.decode("ascii", "ignore") for m in re.findall(rb"[\x20-\x7e]{8,}", b)))
    hits = [
        s
        for s in strs
        if any(
            k in s.lower()
            for k in [
                "platform",
                "board",
                "subtype",
                "pmic",
                "gpio",
                "pon",
                "dagu",
                "elish",
                "mtp",
                "sku",
                "key",
                "button",
            ]
        )
    ]
    print("====", name, "size", len(b), "====")
    for s in hits[:60]:
        print(s)

# FV map buttons
for map_name in ["FVMAIN.Fv.map", "FVMAIN_COMPACT.Fv.map"]:
    mp = home / "workspace/Build/dagu/RELEASE_CLANG38/FV" / map_name
    if not mp.exists():
        continue
    text = mp.read_text(errors="ignore")
    print("====", map_name, "lines", text.count("\n"), "====")
    for line in text.splitlines():
        if "5BD181DB" in line.upper() or "Button" in line or "button" in line:
            print(line)
