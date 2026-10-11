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

# Do not pump the GTK main loop here. A nested iteration re-enters the
# switch handler, and set_connecting_state(LOADING) then runs after Connect
# has already finished, so the row spinner never clears. QCA6390 Inquiry
# is cancelled in the kernel before LE Create Connection.
DRAIN = """	/* dagu: ask the adapter to stop discovery, but do not nest the main
	 * loop. The kernel cancels Inquiry before LE Create Connection.
	 */
	{
		g_autoptr(GDBusProxy) adapter = NULL;

		adapter = _bluetooth_client_get_default_adapter (self->client);
		if (adapter)
			g_dbus_proxy_call (adapter, "StopDiscovery", NULL,
					   G_DBUS_CALL_FLAGS_NONE, -1,
					   NULL, NULL, NULL);
	}
"""

ABORT = """typedef struct {
	BluetoothSettingsWidget *self;
	char *path;
	char *bdaddr;
} DaguAbort;

static void
dagu_abort_widget_gone (gpointer data, GObject *where_the_object_was)
{
	DaguAbort *abort = data;

	(void) where_the_object_was;
	abort->self = NULL;
}

static gboolean
dagu_connect_abort_cb (gpointer user_data)
{
	DaguAbort *abort = user_data;

	/* Device1.Connect that never returns leaves the controller
	 * initiating. The next click is then InProgress. Disconnect
	 * aborts that procedure once the peer has had time to answer.
	 */
	if (abort->self != NULL) {
		BluetoothSettingsWidget *self = abort->self;

		g_object_weak_unref (G_OBJECT (self), dagu_abort_widget_gone, abort);
		abort->self = NULL;
		if (is_connecting (self, abort->bdaddr))
			bluetooth_client_connect_service (self->client, abort->path,
							   FALSE, NULL, NULL, NULL);
	}

	g_free (abort->path);
	g_free (abort->bdaddr);
	g_free (abort);
	return G_SOURCE_REMOVE;
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


OLD_DRAIN_RE = re.compile(
    r"[ \t]*/\* dagu: StopDiscovery is async\. Pairing(?:/Connect)? immediately races[^\n]*\n"
    r"(?:.*\n)*?"
    r"[ \t]*g_main_context_iteration \(NULL, TRUE\);\n"
    r"[ \t]*\}\n"
    r"[ \t]*\}\n",
)

SPINNER_RE = re.compile(
    r"(\t\tset_connecting_state \(self, CONNECTING_STATE_IDLE\);\n"
    r"\t\}\n\n"
    r"\tremove_connecting \(self, data->bdaddr\);)"
)

SPINNER_OK = """	}

	remove_connecting (self, data->bdaddr);
	/* dagu: reconcile the connecting spinner with whoever is still in
	 * flight. Clearing only when the selected address matched left
	 * CONNECTING_STATE_LOADING set after the user moved to another row.
	 */
	if (self->selected_bdaddr && is_connecting (self, self->selected_bdaddr))
		set_connecting_state (self, CONNECTING_STATE_LOADING);
	else
		set_connecting_state (self, CONNECTING_STATE_IDLE);"""


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
    if (
        "ask the adapter to stop discovery" not in text
        and "dagu: StopDiscovery is async" not in text
    ):
        new, n = SETUP_RACE_RE.subn(SETUP_WAIT, text, count=1)
        if n != 1:
            raise SystemExit("setup-mode FALSE + setup_device block not found")
        text = new
    text, _n = OLD_DRAIN_RE.subn(DRAIN, text)
    if "reconcile the connecting spinner" not in text:
        new, n = SPINNER_RE.subn(SPINNER_OK, text, count=1)
        if n != 1:
            raise SystemExit("connecting spinner clear site not found")
        text = new
    if "dagu_connect_abort_cb" not in text:
        anchor = "static gboolean\nswitch_connected_state_set ("
        if anchor not in text:
            raise SystemExit("switch_connected_state_set not found")
        text = text.replace(anchor, ABORT + anchor, 1)
        old_arm = (
            "\tadd_connecting (self, data->bdaddr);\n"
            "\tset_connecting_state (self, CONNECTING_STATE_LOADING);\n"
        )
        new_arm = old_arm + (
            "\tif (gtk_switch_get_active (button)) {\n"
            "\t\tDaguAbort *abort = g_new0 (DaguAbort, 1);\n"
            "\t\tabort->self = self;\n"
            "\t\tabort->path = g_strdup (self->selected_object_path);\n"
            "\t\tabort->bdaddr = g_strdup (data->bdaddr);\n"
            "\t\tg_object_weak_ref (G_OBJECT (self), dagu_abort_widget_gone, abort);\n"
            "\t\tg_timeout_add_seconds (20, dagu_connect_abort_cb, abort);\n"
            "\t}\n"
        )
        if old_arm not in text:
            raise SystemExit("switch connecting arm not found")
        text = text.replace(old_arm, new_arm, 1)
    cancelled = (
        "\tif (!success && g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))\n"
        "\t\tgoto out;\n"
    )
    if cancelled in text:
        text = text.replace(
            cancelled,
            "\tif (!success && g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {\n"
            "\t\tself = data->self;\n"
            "\t\tremove_connecting (self, data->bdaddr);\n"
            "\t\tif (self->selected_bdaddr && is_connecting (self, self->selected_bdaddr))\n"
            "\t\t\tset_connecting_state (self, CONNECTING_STATE_LOADING);\n"
            "\t\telse\n"
            "\t\t\tset_connecting_state (self, CONNECTING_STATE_IDLE);\n"
            "\t\tgoto out;\n"
            "\t}\n",
            1,
        )
    if text.count("ask the adapter to stop discovery") < 2:
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
