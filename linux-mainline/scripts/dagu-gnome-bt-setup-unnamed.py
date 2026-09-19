#!/usr/bin/env python3
"""Patch gnome-bluetooth settings widget for GNOME 未设置.

Clicking an unnamed LE row set pairing=TRUE and waited for notify::name.
Devices that only have an address never fire that, so the spinner never
reaches Device1.Pair. Pair with the address. After Pair, Connect retries
for 25s (BlueZ GDBus Pair window), not 3s.
"""
from __future__ import annotations

import sys
from pathlib import Path

import re

WAIT_NAME_RE = re.compile(
    r"[ \t]+if \(name == NULL\) \{\n"
    r"[ \t]+g_debug \(\"No name yet, will start pairing later\"\);\n"
    r"[ \t]+g_signal_connect \(G_OBJECT \(row\), \"notify::name\",\n"
    r"[ \t]+G_CALLBACK \(device_name_appeared\),[ \t\n]*self\);\n"
    r"[ \t]+return;\n"
    r"[ \t]+\}\n",
)

PAIR_ADDR = """	/* dagu: GNOME 未设置. Waiting for Name leaves the row spinning
	 * when the device only has an address (LE random, no GAP name).
	 * Pair with the address; setup_device does not need a friendly name.
	 */
	if (name == NULL)
		name = g_strdup (bdaddr);
"""

SETUP_RACE_RE = re.compile(
    r"\tg_object_set \(G_OBJECT \(self->client\), \"default-adapter-setup-mode\", FALSE, NULL\);\n"
    r"\tbluetooth_client_setup_device \(self->client,\n"
)

SETUP_WAIT = """	g_object_set (G_OBJECT (self->client), "default-adapter-setup-mode", FALSE, NULL);
	/* dagu: StopDiscovery is async. Pairing immediately races the
	 * still-running Inquiry on QCA6390 (TDD) and aborts LE Create
	 * Connection (le-connection-abort-by-local). Drain Discovering
	 * before Device1.Pair.
	 */
	{
		g_autoptr(GDBusProxy) adapter = NULL;
		gint64 deadline;

		adapter = _bluetooth_client_get_default_adapter (self->client);
		deadline = g_get_monotonic_time () + 2 * G_TIME_SPAN_SECOND;
		while (adapter && g_get_monotonic_time () < deadline) {
			g_autoptr(GVariant) v = NULL;
			gboolean discovering = FALSE;

			v = g_dbus_proxy_get_cached_property (adapter, "Discovering");
			if (v)
				discovering = g_variant_get_boolean (v);
			if (!discovering)
				break;
			g_main_context_iteration (NULL, TRUE);
		}
	}
	bluetooth_client_setup_device (self->client,
"""


def patch_text(text: str) -> str:
    if "dagu: GNOME 未设置" not in text:
        new, n = WAIT_NAME_RE.subn(PAIR_ADDR, text, count=1)
        if n != 1:
            raise SystemExit("start_pairing name==NULL wait block not found")
        text = new
    if "#define CONNECT_TIMEOUT 3.0" in text:
        text = text.replace(
            "#define CONNECT_TIMEOUT 3.0",
            "#define CONNECT_TIMEOUT 25.0",
            1,
        )
    elif "#define CONNECT_TIMEOUT 25.0" not in text:
        raise SystemExit("CONNECT_TIMEOUT 3.0/25.0 not found")
    if "dagu: StopDiscovery is async" not in text:
        new, n = SETUP_RACE_RE.subn(SETUP_WAIT, text, count=1)
        if n != 1:
            raise SystemExit("setup-mode FALSE + setup_device block not found")
        text = new
    return text


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} bluetooth-settings-widget.c")
    path = Path(sys.argv[1])
    text = path.read_text()
    new = patch_text(text)
    if new == text:
        print(f"already patched {path}")
        return
    path.write_text(new)
    print(f"patched {path}")


if __name__ == "__main__":
    main()
