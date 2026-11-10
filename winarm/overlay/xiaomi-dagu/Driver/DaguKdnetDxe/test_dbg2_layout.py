#!/usr/bin/env python3
"""Check the generated DBG2 blob against the 8250 URS0 entry."""
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_dbg2 import OEM, build  # noqa: E402


def test_table_matches_reference_layout():
    blob = build()
    assert blob[:4] == b"DBG2"
    assert struct.unpack_from("<I", blob, 4)[0] == len(blob) == 0x116
    assert blob[8] == 0x01
    assert (sum(blob) & 0xFF) == 0
    info_off, info_count = struct.unpack_from("<II", blob, 0x24)
    assert (info_off, info_count) == (0x2C, 1)

    dev = blob[info_off:]
    revision, length, count = struct.unpack_from("<BHB", dev, 0)
    assert (revision, length, count) == (0x01, 0xEA, 2)
    (
        name_len, name_off, oem_len, oem_off,
        port_type, subtype, reserved, base_off, size_off,
    ) = struct.unpack_from("<HHHHHHHHH", dev, 4)
    assert name_len == 0x0A and name_off == 0x36
    assert oem_len == 0x94 and oem_off == 0x56
    assert port_type == 0x8003 and subtype == 0x5143
    assert reserved == 0 and base_off == 0x16 and size_off == 0x2E
    assert dev[name_off:name_off + name_len] == b"\\_SB.URS0\x00"
    assert dev[oem_off:oem_off + oem_len] == OEM
    assert struct.unpack_from("<Q", dev, 0x1A)[0] == 0x0A600000
    assert struct.unpack_from("<Q", dev, 0x26)[0] == 0x0A600000
    assert struct.unpack_from("<II", dev, 0x2E) == (0x000FFFFF, 0x00001000)


if __name__ == "__main__":
    test_table_matches_reference_layout()
    print("ok")
