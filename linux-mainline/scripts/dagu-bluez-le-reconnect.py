#!/usr/bin/env python3
"""Finish Pair and re-arm LE auto-connect when the link drops mid-browse.

A bonded mouse that disconnects while GATT discovery is still running never
got a Pair reply, and it was left off the kernel connect list. Settings then
timed out and every later use needed another manual connect.
"""
from __future__ import annotations

import sys
from pathlib import Path

OLD = """\
static void att_disconnected_cb(int err, void *user_data)
{
	struct btd_device *device = user_data;

	DBG("");

	if (device->browse)
		goto done;

	DBG("%s (%d)", strerror(err), err);

	g_slist_foreach(device->services, disconnect_gatt_service, NULL);

	btd_gatt_client_disconnected(device->client_dbus);

	if (!device_get_auto_connect(device)) {
		DBG("Automatic connection disabled");
		goto done;
	}

	/*
	 * Keep scanning/re-connection active if disconnection reason
	 * is connection timeout, remote user terminated connection or local
	 * initiated disconnection.
	 */
	if (err == ETIMEDOUT || err == ECONNRESET || err == ECONNABORTED)
		adapter_connect_list_add(device->adapter, device);

done:
	attio_cleanup(device);
}
"""

NEW = """\
static void att_disconnected_cb(int err, void *user_data)
{
	struct btd_device *device = user_data;

	DBG("%s (%d)", strerror(err), err);

	/* dagu: a drop during GATT browse must still answer Pair and put a
	 * bonded mouse back on the connect list. Otherwise Settings times
	 * out and the next advertisement does not reconnect.
	 */
	if (device->browse)
		browse_request_complete(device->browse, BROWSE_GATT,
					device->bdaddr_type, -ECONNABORTED);
	else {
		g_slist_foreach(device->services, disconnect_gatt_service,
									NULL);
		btd_gatt_client_disconnected(device->client_dbus);
	}

	if (!device_get_auto_connect(device)) {
		DBG("Automatic connection disabled");
		goto done;
	}

	/*
	 * Keep scanning/re-connection active if disconnection reason
	 * is connection timeout, remote user terminated connection or local
	 * initiated disconnection.
	 */
	if (err == ETIMEDOUT || err == ECONNRESET || err == ECONNABORTED)
		adapter_connect_list_add(device->adapter, device);

done:
	attio_cleanup(device);
}
"""

MARKER = "dagu: a drop during GATT browse must still answer Pair"


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} src/device.c")
    path = Path(sys.argv[1])
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        print(f"{path}: already patched")
        return
    if OLD not in text:
        raise SystemExit(f"{path}: att_disconnected_cb not found")
    path.write_text(text.replace(OLD, NEW, 1), encoding="utf-8")
    print(f"{path}: le reconnect applied")


if __name__ == "__main__":
    main()
