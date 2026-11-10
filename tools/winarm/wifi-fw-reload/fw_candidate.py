"""Accept or reject a firmware file before the Windows adapter is reopened.

The QCA6390 hw2.0 miniport reads FWFileName, strips ".mbn", and appends
"20.mbn". The file it opens is wlanfw20.mbn. wlanfw.mbn is written with
the same bytes so the two names cannot drift. Board-data names are not
a destination: BDFileName stays where the driver already has it.

Linux ath11k amss.bin (3628672 bytes, sha256 prefix 8ab2a06422e39890)
and Linux m3.bin (sha256 prefix 1921d25edb52f90a) were measured on
2026-11-09. Those files must not be copied onto the Windows names.
"""

from __future__ import annotations

ELF_MAGIC = b"\x7fELF"

FW_DEST = ("wlanfw20.mbn", "wlanfw.mbn")
M3_DEST = ("m3.bin",)

# Measured Linux ath11k images. A renamed copy still matches the prefix.
LINUX_SHA256_PREFIXES = (
    "8ab2a06422e39890",
    "1921d25edb52f90a",
)

FORBIDDEN_BASENAMES = frozenset(
    {
        "amss.bin",
        "amss20.bin",
        "board.bin",
        "board-2.bin",
        "bdwlan.elf",
        "bdwlan.e11",
        "bdwlan.eff",
        "bd_l81a.elf",
    }
)

FW_SIZE = (1_000_000, 8_000_000)
M3_SIZE = (64_000, 1_000_000)


class Reject(Exception):
    """The candidate must not be written or loaded."""


def _parts(path: str) -> list[str]:
    return [p for p in path.replace("\\", "/").split("/") if p and p != "."]


def decide(role: str, path: str, size: int, magic: bytes, sha256: str) -> tuple[str, ...]:
    """Return the driver-directory filenames to replace.

    role is "fw" or "m3". sha256 is hex, any case. magic is the leading
    bytes of the file (four bytes are enough).
    """
    if role not in ("fw", "m3"):
        raise Reject(f"unknown role {role!r}")
    parts = _parts(path)
    if not parts:
        raise Reject("empty path")
    lowered = [p.lower() for p in parts]
    if "ath11k" in lowered:
        raise Reject("path is the Linux ath11k firmware directory")
    base = lowered[-1]
    if base in FORBIDDEN_BASENAMES:
        raise Reject(f"refusing Linux or board file name {base}")
    if role == "fw" and base == "m3.bin":
        raise Reject("m3.bin is not the WLAN firmware")
    if role == "m3" and base in ("wlanfw.mbn", "wlanfw20.mbn"):
        raise Reject("WLAN firmware is not the M3 image")
    if not magic.startswith(ELF_MAGIC):
        raise Reject("file does not start with ELF magic")
    low, high = FW_SIZE if role == "fw" else M3_SIZE
    if not low <= size <= high:
        raise Reject(f"{role} size {size} is outside {low}..{high}")
    digest = sha256.strip().lower()
    if len(digest) < 16 or any(c not in "0123456789abcdef" for c in digest):
        raise Reject("sha256 is missing")
    for prefix in LINUX_SHA256_PREFIXES:
        if digest.startswith(prefix):
            raise Reject("sha256 matches the Linux ath11k image measured 2026-11-09")
    return FW_DEST if role == "fw" else M3_DEST
