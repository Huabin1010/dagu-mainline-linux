from pathlib import Path
import struct

b = (
    Path(__file__).resolve().parents[1]
    / "edk2-msm/Platform/EFI_Binaries/Drivers/Devices/elish/ButtonsDxe/ButtonsDxe.efi"
).read_bytes()

# Find ASCII anchors and dump nearby 16-byte aligned GUIDs
anchors = [
    b"PmicGpioProtocol",
    b"PmicPONProtocol",
    b"PlatformInfo",
    b"InitializeKeyMap",
    b"ConfigureButtonGPIOs",
    b"VOL+",
    b"HOME",
]


def fmt_guid(g: bytes) -> str:
    d1, d2, d3 = struct.unpack_from("<IHH", g, 0)
    return f"{d1:08x}-{d2:04x}-{d3:04x}-{g[8:10].hex()}-{g[10:].hex()}"


for a in anchors:
    idx = 0
    while True:
        i = b.find(a, idx)
        if i < 0:
            break
        print(f"\n=== {a.decode()} @ {i} ===")
        start = max(0, i - 64)
        end = min(len(b), i + 64)
        # scan for guid-like (version nibble 0x4xxx in time_hi)
        for off in range(start, end - 15):
            g = b[off : off + 16]
            ver = (g[7] >> 4) & 0xF
            if ver in (1, 2, 3, 4, 5) and g[8] & 0x80:
                # weak filter; print unique
                pass
        # just hex dump
        print(b[start:end].hex())
        idx = i + 1
        break

# Also collect all GUIDs that appear in DEPEX + in PE that match known Qualcomm style
print("\n=== Scanning PE for PUSH-style GUID constants near protocol names ===")
# Search for known DEPEX guids occurrence in PE
depex_guids = [
    bytes.fromhex("c1777438c769d2118e3900a0c969723b"),
    bytes.fromhex("455c7a15b221c543ba7c822fee5fe599"),
    bytes.fromhex("d7c6c54ba44c3588d1bcd29cc2025d4a"),
    bytes.fromhex("665ba49befa4441ca3e4ed2224786be2"),
]
for g in depex_guids:
    print(fmt_guid(g), "count", b.count(g))

# Heuristic: find uint16 constants that look like PMIC gpio numbers near VOL
# Look for pattern of structure: gpio=6 for vol+
for needle in [struct.pack("<I", 6), struct.pack("<H", 6)]:
    pass

# Dump 256 bytes around first 'EnableInput failed for VOL'
i = b.find(b"EnableInput failed for VOL")
print("\ncontext VOL fail @", i)
if i > 0:
    # look backwards in code for immediate 6
    region = b[max(0, i - 2000) : i]
    # find .ascii refs - find ADRP targets hard; print offsets of byte 0x06 in dword immediates in AArch64
    # simpler: find all occurrences of little-endian dword 6 in file and print nearby if near key strings
print("\nDword 6 offsets near button strings:")
for off in range(0, len(b) - 4, 4):
    if struct.unpack_from("<I", b, off)[0] == 6:
        # check if within 0x200 of a button-related string offset reference - skip
        if abs(off - b.find(b"VOL+")) < 0x800 or abs(off - b.find(b"HOME")) < 0x800:
            print(hex(off), "near VOL/HOME")
