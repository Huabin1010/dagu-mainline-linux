from pathlib import Path
import struct
import subprocess

efi = (
    Path(__file__).resolve().parents[1]
    / "edk2-msm/Platform/EFI_Binaries/Drivers/Devices/elish/ButtonsDxe/ButtonsDxe.efi"
)
# disassemble original for analysis
subprocess.run(
    [
        "llvm-objdump",
        "-d",
        "--section=.text",
        f"--start-address=0x3900",
        f"--stop-address=0x3c00",
        str(efi),
    ],
    check=False,
)
