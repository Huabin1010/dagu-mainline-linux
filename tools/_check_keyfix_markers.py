from pathlib import Path

root = Path(__file__).resolve().parents[1]
efi = (
    root
    / "edk2-msm/workspace/Build/dagu/RELEASE_CLANG38/AARCH64/MdeModulePkg/Application/BootManagerMenuApp/BootManagerMenuApp/DEBUG/BootManagerMenuApp.efi"
)
img = root / "artifacts/boot-dagu-latest.img"

for label, path in (("efi", efi), ("img", img)):
    b = path.read_bytes()
    print(
        label,
        path.name,
        "size",
        len(b),
        "KEYFIX-4 utf16",
        "KEYFIX-4".encode("utf-16le") in b,
        "key sc= utf16",
        "key sc=".encode("utf-16le") in b,
        "KEYFIX-4 ascii",
        b"KEYFIX-4" in b,
    )
