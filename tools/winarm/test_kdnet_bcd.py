#!/usr/bin/env python3
"""Byte layout of the KDNET fields written into {dbgsettings}.

bcdedit stores hostip as the four address bytes followed by four zeros,
and port as an 8-byte little-endian integer. debugtype 3 is NET.
"""


def hostip_bytes(text: str) -> bytes:
    parts = [int(p) for p in text.split(".")]
    if len(parts) != 4 or any(p < 0 or p > 255 for p in parts):
        raise ValueError(text)
    return bytes(parts) + b"\x00" * 4


def port_bytes(port: int) -> bytes:
    if not 1 <= port <= 65535:
        raise ValueError(port)
    return port.to_bytes(8, "little")


def test_aloha_kdnet_bytes():
    assert hostip_bytes("169.254.255.255") == bytes.fromhex("a9feffff00000000")
    assert port_bytes(50000) == bytes.fromhex("50c3000000000000")
    assert port_bytes(1) == b"\x01" + b"\x00" * 7


def test_rejects_bad_values():
    try:
        hostip_bytes("169.254.255")
    except ValueError:
        pass
    else:
        raise AssertionError("short address accepted")
    try:
        port_bytes(0)
    except ValueError:
        pass
    else:
        raise AssertionError("port 0 accepted")


if __name__ == "__main__":
    test_aloha_kdnet_bytes()
    test_rejects_bad_values()
    print("ok")
