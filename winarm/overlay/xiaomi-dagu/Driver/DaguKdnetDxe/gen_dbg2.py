#!/usr/bin/env python3
"""Build the one-device DBG2 blob DaguKdnetDxe installs.

The layout matches the first USB entry of Qualcomm's 8250 DBG2
(port type 0x8003, subtype 0x5143, controller 0x0A600000, name
\\_SB.URS0), including that entry's 0x94-byte OEM blob. Address
sizes are 0x000FFFFF and 0x00001000, the same pair the reference
table publishes for this controller.
"""
import struct
import sys

# OEM blob copied from the URS0 device in DBG2_8250. It is itself a
# DBG2 prefix (UART at 0x00A90000, then the start of the USB device).
# Subtype 0x5143 is the Microsoft KDNET USB subtype; the reference
# table carries this blob with that subtype.
OEM = bytes.fromhex(
    "444247321A040000010051434F4D2020"
    "51434F4D45444B328081000051434F4D"
    "010000002C0000000500000001460001"
    "0A002600000000000080110000001600"
    "2200002000200000A900000000000010"
    "00005C5F53422E554152440000000000"
    "00000000000000000000000000000000"
    "000001EA00020A003600940056000380"
    "4351000016002E00002000200000600A"
    "00000000"
)

NAMEPATH = b"\\_SB.URS0\x00"
PAD = 0x16  # namepath ends at 0x40; OEM data starts at 0x56


def gas(address: int) -> bytes:
    # Space 0, bit width 0x20, bit offset 0, access width 0x20.
    # The access width matches the 8250 reference, not the ACPI encoding.
    return struct.pack("<BBBBQ", 0x00, 0x20, 0x00, 0x20, address)


def build() -> bytes:
    assert len(NAMEPATH) == 0x0A
    assert len(OEM) == 0x94
    base0 = gas(0x0A600000)
    base1 = gas(0x0A600000)
    sizes = struct.pack("<II", 0x000FFFFF, 0x00001000)
    # Device-relative offsets. The fixed header is 0x16 bytes.
    body_wo_oem = base0 + base1 + sizes + NAMEPATH + (b"\x00" * PAD)
    assert len(body_wo_oem) == 0x56 - 0x16
    # Revision, Length, RegisterCount, then the ten UINT16 fields
    # through AddressSizeOffset. Packed size is 0x16.
    device_fixed = struct.pack(
        "<BHBHHHHHHHHH",
        0x01,          # revision (reference uses 1)
        0xEA,          # length
        0x02,          # register count
        0x0A,          # namepath length
        0x36,          # namepath offset
        0x94,          # OEM data length
        0x56,          # OEM data offset
        0x8003,        # port type: net
        0x5143,        # port subtype: KDNET USB
        0x0000,        # reserved
        0x16,          # base address offset
        0x2E,          # address size offset
    )
    assert len(device_fixed) == 0x16
    device = device_fixed + body_wo_oem + OEM
    assert len(device) == 0xEA
    assert device[0x36:0x36 + 10] == NAMEPATH
    assert device[0x56:0x56 + 0x94] == OEM
    # Two GAS structures, both at 0x0A600000.
    assert struct.unpack_from("<Q", device, 0x16 + 4)[0] == 0x0A600000
    assert struct.unpack_from("<Q", device, 0x22 + 4)[0] == 0x0A600000
    assert struct.unpack_from("<II", device, 0x2E) == (0x000FFFFF, 0x00001000)

    header = struct.pack(
        "<4s I BB 6s 8s I 4s I",
        b"DBG2",
        0x2C + 0xEA,   # length, filled before checksum
        0x01,          # revision
        0x00,          # checksum placeholder
        b"DAGU  ",
        b"KDNET   ",
        1,
        b"DAGU",
        1,
    )
    assert len(header) == 36
    table = header + struct.pack("<II", 0x2C, 1) + device
    assert len(table) == 0x116
    checksum = (-sum(table)) & 0xFF
    table = table[:9] + bytes([checksum]) + table[10:]
    assert (sum(table) & 0xFF) == 0
    return table


def as_inc(blob: bytes) -> str:
    lines = []
    for i in range(0, len(blob), 16):
        chunk = blob[i:i + 16]
        lines.append("  " + ", ".join("0x%02x" % b for b in chunk) + ",")
    return "\n".join(lines) + "\n"


def main() -> None:
    blob = build()
    if len(sys.argv) == 2:
        with open(sys.argv[1], "w", encoding="ascii") as out:
            out.write(as_inc(blob))
    else:
        sys.stdout.buffer.write(blob)


if __name__ == "__main__":
    main()
