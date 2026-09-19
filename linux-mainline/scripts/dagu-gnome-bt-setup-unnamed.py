#!/usr/bin/env python3
"""Patch gnome-bluetooth 47 for GNOME Settings 未设置.

Stock start_pairing waits for notify::name on unnamed LE rows, so the
spinner never reaches Device1.Pair. Pair with the address.

StopDiscovery is async. Pair/Connect immediately races Inquiry on
QCA6390 (TDD) and aborts LE Create Connection
(le-connection-abort-by-local). Drain Discovering first.

Device1.Pair on a bonded device returns org.bluez.Error.AlreadyExists.
Stock setup_device treats that as failure, never sets Trusted, never
Connects — Settings stays 未设置 after a bluetoothctl pair. Treat
AlreadyExists as Pair success.

Connect after Pair retries for 25s (BlueZ GDBus Pair window), not 3s.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

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

DRAIN = """	/* dagu: StopDiscovery is async. Pairing/Connect immediately races
	 * the still-running Inquiry on QCA6390 (TDD) and aborts LE Create
	 * Connection (le-connection-abort-by-local). Drain Discovering
	 * before Device1.Pair / Device1.Connect.
	 */
	{
		g_autoptr(GDBusProxy) adapter = NULL;
		gint64 deadline;

		adapter = _bluetooth_client_get_default_adapter (self->client);
		deadline = g_get_monotonic_time () + 5 * G_TIME_SPAN_SECOND;
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
"""

SETUP_RACE_RE = re.compile(
    r"\tg_object_set \(G_OBJECT \(self->client\), \"default-adapter-setup-mode\", FALSE, NULL\);\n"
    r"\tbluetooth_client_setup_device \(self->client,\n"
)

SETUP_WAIT = (
    "	g_object_set (G_OBJECT (self->client), \"default-adapter-setup-mode\", FALSE, NULL);\n"
    + DRAIN
    + "	bluetooth_client_setup_device (self->client,\n"
)

CONNECT_RACE_RE = re.compile(
    r"(\tif \(gtk_switch_get_active \(button\)\)\n"
    r"\t+g_object_set \(G_OBJECT \(self->client\),\n"
    r"[ \t]+\"default-adapter-setup-mode\", FALSE,\n"
    r"[ \t]+NULL\);\n)"
    r"(\tbluetooth_client_connect_service \(self->client,\n)"
)

CONNECT_WAIT = r"\1" + DRAIN + r"\2"

ALREADY_RE = re.compile(
    r"if \(device1_call_pair_finish \(DEVICE1\(proxy\), res, &error\) == FALSE\) \{\n"
    r"[ \t]+g_debug \(\"Pair\(\) failed for %s: %s\",\n"
    r"[ \t]+g_dbus_proxy_get_object_path \(proxy\),[\n \t]+error->message\);\n"
    r"[ \t]+g_task_return_error \(task, error\);\n"
    r"[ \t]+\} else \{\n"
)

ALREADY_OK = """if (device1_call_pair_finish (DEVICE1(proxy), res, &error) == FALSE) {
		/* dagu: GNOME 未设置 after bluetoothctl pair. Bonded
		 * Device1.Pair returns AlreadyExists; stock setup_device
		 * failed, never Trusted, never Connect, row kept spinning.
		 */
		g_autofree char *remote = g_dbus_error_get_remote_error (error);
		if (g_strcmp0 (remote, "org.bluez.Error.AlreadyExists") == 0) {
			g_clear_error (&error);
			g_debug ("Pair() AlreadyExists for %s; continue setup",
				 g_dbus_proxy_get_object_path (proxy));
			g_task_return_boolean (task, TRUE);
		} else {
			g_debug ("Pair() failed for %s: %s",
				 g_dbus_proxy_get_object_path (proxy),
				 error->message);
			g_task_return_error (task, error);
		}
	} else {
"""


def patch_widget(text: str) -> str:
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
    if text.count("dagu: StopDiscovery is async") < 2:
        new, n = CONNECT_RACE_RE.subn(CONNECT_WAIT, text, count=1)
        if n != 1:
            raise SystemExit("switch_connected setup-mode FALSE block not found")
        text = new
    return text


def patch_client(text: str) -> str:
    if "dagu: GNOME 未设置 after bluetoothctl pair" in text:
        return text
    new, n = ALREADY_RE.subn(ALREADY_OK, text, count=1)
    if n != 1:
        raise SystemExit("device_pair_callback AlreadyExists site not found")
    return new


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(
            f"usage: {sys.argv[0]} bluetooth-settings-widget.c|bluetooth-client.c"
        )
    path = Path(sys.argv[1])
    text = path.read_text()
    name = path.name
    if name == "bluetooth-settings-widget.c":
        new = patch_widget(text)
    elif name == "bluetooth-client.c":
        new = patch_client(text)
    else:
        raise SystemExit(f"unsupported file {name}")
    if new == text:
        print(f"already patched {path}")
        return
    path.write_text(new)
    print(f"patched {path}")


if __name__ == "__main__":
    main()
