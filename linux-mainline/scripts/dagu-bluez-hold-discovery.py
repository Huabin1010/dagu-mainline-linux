#!/usr/bin/env python3
"""Keep discovery suspended until LE GATT browse finishes.

QCA6390 cannot scan and carry ATT at the same time. BlueZ resumed
discovery as soon as the link keys were stored, five seconds before the
HID service was discovered, so Pair never returned.
"""
from __future__ import annotations

import sys
from pathlib import Path

MARKER = "dagu: do not resume discovery while LE GATT"


def patch(path: Path, old: str, new: str, already: str) -> None:
    text = path.read_text(encoding="utf-8")
    if already in text:
        print(f"{path.name}: already has {already[:48]!r}")
        return
    if old not in text:
        raise SystemExit(f"{path}: pattern not found:\n{old[:180]!r}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"{path.name}: hold-discovery applied")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <bluez-src>")
    root = Path(sys.argv[1])
    adapter_c = root / "src/adapter.c"
    if MARKER in adapter_c.read_text(encoding="utf-8"):
        print(f"{adapter_c}: already patched")
        return

    patch(
        adapter_c,
        "\tbool discovery_suspended;\t/* discovery has been suspended */\n",
        "\tbool discovery_suspended;\t/* discovery has been suspended */\n"
        "\tbool dagu_hold_discovery;\t/* dagu: keep scan off until LE GATT finishes */\n",
        "dagu_hold_discovery",
    )
    patch(
        adapter_c,
        "\ttrigger_start_discovery(adapter, IDLE_DISCOV_TIMEOUT);\n"
        "}\n"
        "\n"
        "static void discovering_callback(",
        "\ttrigger_start_discovery(adapter, IDLE_DISCOV_TIMEOUT);\n"
        "}\n"
        "\n"
        "void btd_adapter_release_discovery(struct btd_adapter *adapter)\n"
        "{\n"
        "\tif (!adapter->dagu_hold_discovery)\n"
        "\t\treturn;\n"
        "\n"
        "\tadapter->dagu_hold_discovery = false;\n"
        "\tresume_discovery(adapter);\n"
        "}\n"
        "\n"
        "static void discovering_callback(",
        "btd_adapter_release_discovery",
    )
    patch(
        adapter_c,
        "\tif (device != NULL)\n"
        "\t\tdevice_bonding_complete(device, addr_type, status);\n"
        "\n"
        "\tresume_discovery(adapter);\n"
        "\n"
        "\tcheck_oob_bonding_complete(adapter, bdaddr, status);\n",
        "\tif (device != NULL)\n"
        "\t\tdevice_bonding_complete(device, addr_type, status);\n"
        "\n"
        "\t/* dagu: do not resume discovery while LE GATT browse is still\n"
        "\t * running. This controller drops ATT once scanning restarts,\n"
        "\t * and Pair then waits until the client times out.\n"
        "\t */\n"
        "\tif (status == 0 && device && addr_type != BDADDR_BREDR &&\n"
        "\t\t\t!btd_device_svc_resolved(device, addr_type)) {\n"
        "\t\tadapter->dagu_hold_discovery = true;\n"
        "\t} else {\n"
        "\t\tadapter->dagu_hold_discovery = false;\n"
        "\t\tresume_discovery(adapter);\n"
        "\t}\n"
        "\n"
        "\tcheck_oob_bonding_complete(adapter, bdaddr, status);\n",
        MARKER,
    )
    patch(
        root / "src/adapter.h",
        "int adapter_create_bonding(struct btd_adapter *adapter, const bdaddr_t *bdaddr,\n"
        "\t\t\t\t\tuint8_t addr_type, uint8_t io_cap);\n",
        "void btd_adapter_release_discovery(struct btd_adapter *adapter);\n"
        "\n"
        "int adapter_create_bonding(struct btd_adapter *adapter, const bdaddr_t *bdaddr,\n"
        "\t\t\t\t\tuint8_t addr_type, uint8_t io_cap);\n",
        "btd_adapter_release_discovery",
    )
    patch(
        root / "src/device.h",
        "void device_bonding_complete(struct btd_device *device, uint8_t bdaddr_type,\n"
        "\t\t\t\t\t\t\tuint8_t status);\n",
        "bool btd_device_svc_resolved(struct btd_device *device, uint8_t bdaddr_type);\n"
        "void device_bonding_complete(struct btd_device *device, uint8_t bdaddr_type,\n"
        "\t\t\t\t\t\t\tuint8_t status);\n",
        "btd_device_svc_resolved",
    )
    patch(
        root / "src/device.c",
        "void device_bonding_complete(struct btd_device *device, uint8_t bdaddr_type,\n"
        "\t\t\t\t\t\t\t\tuint8_t status)\n",
        "bool btd_device_svc_resolved(struct btd_device *device, uint8_t bdaddr_type)\n"
        "{\n"
        "\treturn get_state(device, bdaddr_type)->svc_resolved;\n"
        "}\n"
        "\n"
        "void device_bonding_complete(struct btd_device *device, uint8_t bdaddr_type,\n"
        "\t\t\t\t\t\t\t\tuint8_t status)\n",
        "bool btd_device_svc_resolved",
    )
    patch(
        root / "src/device.c",
        "\tbtd_device_update_allowed_services(dev);\n"
        "\tdevice_resolved_drivers(dev->adapter, dev);\n"
        "}\n",
        "\tbtd_device_update_allowed_services(dev);\n"
        "\tdevice_resolved_drivers(dev->adapter, dev);\n"
        "\tbtd_adapter_release_discovery(dev->adapter);\n"
        "}\n",
        "btd_adapter_release_discovery(dev->adapter)",
    )
    patch(
        root / "src/device.c",
        "\tif (err == ETIMEDOUT || err == ECONNRESET || err == ECONNABORTED)\n"
        "\t\tadapter_connect_list_add(device->adapter, device);\n"
        "\n"
        "done:\n"
        "\tattio_cleanup(device);\n"
        "}\n",
        "\tif (err == ETIMEDOUT || err == ECONNRESET || err == ECONNABORTED)\n"
        "\t\tadapter_connect_list_add(device->adapter, device);\n"
        "\n"
        "done:\n"
        "\tbtd_adapter_release_discovery(device->adapter);\n"
        "\tattio_cleanup(device);\n"
        "}\n",
        "btd_adapter_release_discovery(device->adapter)",
    )
    if MARKER not in adapter_c.read_text(encoding="utf-8"):
        raise SystemExit("hold-discovery marker missing after patch")
    print(f"{root}: hold-discovery ok")


if __name__ == "__main__":
    main()
