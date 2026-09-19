#!/usr/bin/env python3
"""Patch BlueZ profiles/input/device.c: device-initiated HID waits.

K380 and other classic HID keyboards advertise Reconnect Initiate and not
Normally Connectable. GNOME Device1.Connect still called bt_io_connect,
which pages, drops PSCAN, and misses the keypress page. Wait for incoming
L2CAP HID instead; host/any modes still page.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

FIELD = "\tunsigned int\t\tincoming_timer;\n"

CANCEL_FUNCS = """\
static void input_device_cancel_incoming(struct input_device *idev)
{
	if (idev->incoming_timer > 0) {
		timeout_remove(idev->incoming_timer);
		idev->incoming_timer = 0;
	}
}

static bool input_device_wait_incoming_timeout(gpointer user_data)
{
	struct input_device *idev = user_data;

	idev->incoming_timer = 0;
	if (is_connected(idev) || idev->ctrl_io)
		return FALSE;

	/* Keep PSCAN; do not page. GNOME Connect waited for a keypress. */
	btd_service_connecting_complete(idev->service, -ETIMEDOUT);
	return FALSE;
}

"""

CONNECT_INSERT = """\
	/* SDP HIDReconnectInitiate + !HIDNormallyConnectable (K380).
	 * Outgoing page disables PSCAN on QCA6390 and misses the keypress.
	 */
	if (idev->reconnect_mode == RECONNECT_DEVICE ||
	    idev->reconnect_mode == RECONNECT_NONE) {
		input_device_cancel_incoming(idev);
		idev->incoming_timer = timeout_add_seconds(25,
				input_device_wait_incoming_timeout,
				idev, NULL);
		DBG("path=%s wait incoming reconnect_mode=%d",
		    idev->path, idev->reconnect_mode);
		return 0;
	}

"""


def patch_text(text: str) -> str:
    if "input_device_wait_incoming_timeout" in text:
        return text

    field_re = re.compile(r"^(\tunsigned int\t+reconnect_timer;)$", re.M)
    if not field_re.search(text):
        raise SystemExit("reconnect_timer field not found")
    text = field_re.sub(r"\1\n" + FIELD.rstrip("\n"), text, count=1)

    free_re = re.compile(
        r"(if \(idev->reconnect_timer > 0\)\n\t\ttimeout_remove\(idev->reconnect_timer\);)"
    )
    if not free_re.search(text):
        raise SystemExit("reconnect_timer free not found")
    text = free_re.sub(
        r"\1\n\n\tif (idev->incoming_timer > 0)\n"
        r"\t\ttimeout_remove(idev->incoming_timer);",
        text,
        count=1,
    )

    conn_re = re.compile(
        r"static int input_device_connected\(struct input_device \*idev\)\n\{\n\tint err;\n"
    )
    if not conn_re.search(text):
        raise SystemExit("input_device_connected not found")
    text = conn_re.sub(
        CANCEL_FUNCS
        + "static int input_device_connected(struct input_device *idev)\n"
        + "{\n\tint err;\n\n\tinput_device_cancel_incoming(idev);\n",
        text,
        count=1,
    )

    connect_re = re.compile(
        r"(int input_device_connect\(struct btd_service \*service\)\n"
        r"\{\n"
        r"\tstruct input_device \*idev;\n"
        r"\n"
        r"\tDBG\(\"\"\);\n"
        r"\n"
        r"\tidev = btd_service_get_user_data\(service\);\n"
        r"\n"
        r"\tif \(idev->ctrl_io\)\n"
        r"\t\treturn -EBUSY;\n"
        r"\n"
        r"\tif \(is_connected\(idev\)\)\n"
        r"\t\treturn -EALREADY;\n"
        r"\n)"
        r"(\treturn dev_connect\(idev\);\n)"
    )
    if not connect_re.search(text):
        raise SystemExit("input_device_connect not found")
    text = connect_re.sub(r"\1" + CONNECT_INSERT + r"\2", text, count=1)

    disc_re = re.compile(
        r"(int input_device_disconnect\(struct btd_service \*service\)\n"
        r"\{\n"
        r"\tstruct input_device \*idev;\n"
        r"\tint err, flags;\n"
        r"\n"
        r"\tDBG\(\"\"\);\n"
        r"\n"
        r"\tidev = btd_service_get_user_data\(service\);\n)"
    )
    if disc_re.search(text):
        text = disc_re.sub(
            r"\1\n\tinput_device_cancel_incoming(idev);\n", text, count=1
        )
    return text


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} profiles/input/device.c")
    path = Path(sys.argv[1])
    original = path.read_text(encoding="utf-8")
    patched = patch_text(original)
    if patched == original:
        print(f"{path}: already patched")
        return
    path.write_text(patched, encoding="utf-8")
    print(f"{path}: hid wait-incoming applied")


if __name__ == "__main__":
    main()
