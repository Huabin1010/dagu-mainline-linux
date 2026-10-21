#!/usr/bin/env python3
"""Keep Keyboard K380 in the list when the page fails.

Page Timeout made bluetoothd send MGMT Remove Device for the temporary
device. GNOME dropped the row. The next inquiry added it back, and the
following click paged again and missed.
"""
from __future__ import annotations

import sys
from pathlib import Path

MARKER = "dagu: keep the row after a failed page"

OLD = """\
\t/* In the case the bonding was canceled or did exists, remove the device
\t * when it is temporary. */
\tif (device && !device_is_bonding(device, NULL)
\t\t\t\t\t\t&& device_is_temporary(device))
\t\tbtd_adapter_remove_device(adapter, device);
}
"""

NEW = """\
\t/* dagu: keep the row after a failed page. Removing a temporary
\t * device here is why Keyboard K380 disappears and the next
\t * inquiry puts it back. Discovery still drops a temporary
\t * device that stops being seen.
\t */
}
"""


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <bluez-src-or-adapter.c>")
    path = Path(sys.argv[1])
    if path.is_dir():
        path = path / "src/adapter.c"
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        print(f"{path}: already patched")
        return
    if OLD not in text:
        raise SystemExit(f"{path}: connect-failed removal not found")
    path.write_text(text.replace(OLD, NEW, 1), encoding="utf-8")
    print(f"{path.name}: keep classic row applied")


if __name__ == "__main__":
    main()
