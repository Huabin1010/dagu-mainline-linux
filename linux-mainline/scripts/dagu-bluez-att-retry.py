#!/usr/bin/env python3
"""Resend a missed ATT PDU before Settings gives up on Pair.

BlueZ waits 30 s for one Attribute Protocol response and then shuts the
socket. The kernel's 2 s idle timer sends HCI Disconnect after that, so
the row shows disconnected even though the bond was stored. Three tries
at 2 s stay inside the 25 s Settings call.
"""
from __future__ import annotations

import sys
from pathlib import Path

MARKER = "dagu: resend a missed ATT PDU"

OLD_TIMEOUT = "#define ATT_TIMEOUT_INTERVAL\t\t30000  /* 30000 ms */"

NEW_TIMEOUT = """\
/* dagu: resend a missed ATT PDU. 30 s is past the 25 s Settings call,
 * and the first miss is what a connection-update drops. See
 * DAGU_ATT_TIMEOUT_MS in dagu_le_conn_policy.h.
 */
#define ATT_TIMEOUT_INTERVAL		2000   /* 2000 ms */
#define DAGU_ATT_TIMEOUT_TRIES		3
"""

OLD_OP = """\
	bool retry;
	bt_att_response_func_t callback;
"""

NEW_OP = """\
	bool retry;
	uint8_t dagu_tries;
	bt_att_response_func_t callback;
"""

OLD_CB = """\
	DBG(att, "(chan %p) Operation timed out: 0x%02x", chan,
						op->opcode);

	if (att->timeout_callback)
		att->timeout_callback(op->id, op->opcode, att->timeout_data);

	op->timeout_id = 0;
	disc_att_send_op(op);
"""

NEW_CB = """\
	DBG(att, "(chan %p) Operation timed out: 0x%02x", chan,
						op->opcode);

	op->timeout_id = 0;
	op->dagu_tries++;
	/* dagu: resend a missed ATT PDU. Shutting the socket on the
	 * first miss is what turns a dropped Exchange MTU into
	 * "disconnected" after Settings has already timed out.
	 */
	if (op->dagu_tries < DAGU_ATT_TIMEOUT_TRIES) {
		DBG(att, "(chan %p) dagu: resend ATT 0x%02x try %u",
					chan, op->opcode, op->dagu_tries);
		if (!queue_push_head(chan->queue, op)) {
			disc_att_send_op(op);
			io_shutdown(chan->io);
			return false;
		}
		wakeup_chan_writer(chan, NULL);
		return false;
	}

	if (att->timeout_callback)
		att->timeout_callback(op->id, op->opcode, att->timeout_data);

	disc_att_send_op(op);
"""


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} src/shared/att.c")
    path = Path(sys.argv[1])
    text = path.read_text(encoding="utf-8")
    proto = "static void wakeup_chan_writer(void *data, void *user_data);\n"
    if MARKER in text and "dagu_tries" in text and "2000   /* 2000 ms */" in text:
        if proto not in text:
            needle = "static bool timeout_cb(void *user_data)\n"
            if needle not in text:
                raise SystemExit(f"{path}: timeout_cb missing for prototype")
            text = text.replace(needle, proto + "\n" + needle, 1)
            path.write_text(text, encoding="utf-8")
            print(f"{path}: att retry prototype added")
            return
        print(f"{path}: already patched")
        return
    for old, new, label in (
        (OLD_TIMEOUT, NEW_TIMEOUT, "timeout"),
        (OLD_OP, NEW_OP, "send op"),
        (OLD_CB, NEW_CB, "timeout callback"),
    ):
        if old not in text:
            raise SystemExit(f"{path}: {label} pattern not found")
        text = text.replace(old, new, 1)
    needle = "static bool timeout_cb(void *user_data)\n"
    if proto not in text:
        if needle not in text:
            raise SystemExit(f"{path}: timeout_cb missing for prototype")
        text = text.replace(needle, proto + "\n" + needle, 1)
    path.write_text(text, encoding="utf-8")
    print(f"{path}: att retry applied")


if __name__ == "__main__":
    main()
