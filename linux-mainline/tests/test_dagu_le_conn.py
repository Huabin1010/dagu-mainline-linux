#!/usr/bin/env python3
"""Unit tests for the mouse connection-update decision.

The captured click applied interval 7 before any Attribute Protocol
response. Settings then hit its 25 s call and the link was disconnected
locally. These tests lock the numbers that keep that sequence from
repeating.

Run:

  python3 linux-mainline/tests/test_dagu_le_conn.py
"""
from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "linux/net/bluetooth/dagu_le_conn_policy.h"
KERNEL = ROOT / "linux/net/bluetooth"
PATCHER = ROOT / "scripts/dagu-bluez-att-retry.py"
ROW_PATCHER = ROOT / "scripts/dagu-bluez-keep-classic-row.py"

C_MAIN = r"""
#include "dagu_le_conn_policy.h"
#include <stdio.h>

static int fails;

static void expect(int cond, const char *what)
{
	if (cond)
		return;
	fprintf(stderr, "fail: %s\n", what);
	fails++;
}

int main(void)
{
	/* Captured request 7-7, no ATT response yet: hold the HCI update. */
	expect(dagu_le_should_defer(0, 7) == 1, "interval 7 without ATT defers");
	expect(dagu_le_should_defer(0, 6) == 1, "interval 6 without ATT defers");
	expect(dagu_le_should_defer(0, 9) == 1, "interval 9 without ATT defers");
	/* One ATT PDU means the create interval already carried it. */
	expect(dagu_le_should_defer(1, 7) == 0, "interval 7 after ATT is sent");
	expect(dagu_le_should_defer(1, 6) == 0, "interval 6 after ATT is sent");
	/* Create window is not deferred. 24 is 30 ms, 23 is just under. */
	expect(dagu_le_should_defer(0, 24) == 0, "create floor is not deferred");
	expect(dagu_le_should_defer(0, 23) == 1, "just under the floor defers");
	expect(dagu_le_should_defer(0, 40) == 0, "50 ms create max is not deferred");
	expect(DAGU_LE_CREATE_FLOOR == 24, "floor is 24 units");

	expect(DAGU_LE_UPDATE_WAIT_MS >= 45, "wait covers one 45 ms event");
	expect(DAGU_LE_UPDATE_WAIT_MS < 2000, "wait is shorter than one ATT try");
	expect(DAGU_LE_UPDATE_WAIT_MS < DAGU_SETTINGS_CALL_MS,
	       "wait is inside Settings");

	/* Original send plus two resends, then give up. */
	expect(dagu_att_give_up(0) == 0, "no timeout yet");
	expect(dagu_att_give_up(1) == 0, "first miss is resent");
	expect(dagu_att_give_up(2) == 0, "second miss is resent");
	expect(dagu_att_give_up(3) == 1, "third miss closes the socket");
	expect(DAGU_ATT_TIMEOUT_MS == 2000, "ATT try is 2 s");
	expect(DAGU_ATT_TIMEOUT_TRIES == 3, "three ATT tries");
	expect(DAGU_ATT_TIMEOUT_MS * DAGU_ATT_TIMEOUT_TRIES < DAGU_SETTINGS_CALL_MS,
	       "all ATT tries finish before Settings gives up");
	/* Kernel idle disconnect is another 2 s after the socket closes. */
	expect(DAGU_ATT_TIMEOUT_MS * DAGU_ATT_TIMEOUT_TRIES + 2000
	       < DAGU_SETTINGS_CALL_MS,
	       "tries plus idle disconnect still beat the Settings call");

	/* Classic page while LE scan is up is the K380 Page Timeout. */
	expect(dagu_discovery_must_wait(0, 0) == 0, "idle radio can discover");
	expect(dagu_discovery_must_wait(1, 0) == 1, "LE create owns the radio");
	expect(dagu_discovery_must_wait(0, 1) == 1, "classic page owns the radio");
	expect(dagu_discovery_must_wait(1, 1) == 1, "both connects own the radio");
	expect(dagu_pause_le_scan_for_page(0) == 0, "scan already off");
	expect(dagu_pause_le_scan_for_page(1) == 1, "scan pauses for the page");

	/* Inquiry restart must keep the clock offset the click will page with. */
	expect(dagu_keep_page_params(0, 900) == 1, "fresh inquiry is kept");
	expect(dagu_keep_page_params(900, 900) == 1, "age at the limit is kept");
	expect(dagu_keep_page_params(901, 900) == 0, "stale inquiry is dropped");
	expect(dagu_keep_page_params(-1, 900) == 0, "negative age is dropped");
	expect(dagu_program_page_timeout(16384) == 1, "configured page timeout is written");
	expect(dagu_program_page_timeout(0) == 0, "unset page timeout stays at the controller default");

	if (fails) {
		fprintf(stderr, "%d failed\n", fails);
		return 1;
	}
	return 0;
}
"""


def load_patcher():
    spec = importlib.util.spec_from_file_location(
        "dagu_bluez_att_retry", PATCHER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class LeConnPolicyTest(unittest.TestCase):
    def test_policy_binary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "check.c"
            exe = Path(tmp) / "check"
            src.write_text(C_MAIN, encoding="utf-8")
            subprocess.run(
                ["gcc", "-Wall", "-Werror", "-I", str(POLICY.parent),
                 "-o", str(exe), str(src)],
                check=True,
            )
            subprocess.run([str(exe)], check=True)

    def test_kernel_wires_the_decision(self) -> None:
        conn = (KERNEL / "hci_conn.c").read_text(encoding="utf-8")
        event = (KERNEL / "hci_event.c").read_text(encoding="utf-8")
        sync = (KERNEL / "hci_sync.c").read_text(encoding="utf-8")
        l2cap = (KERNEL / "l2cap_core.c").read_text(encoding="utf-8")
        self.assertIn("dagu_le_should_defer", conn)
        self.assertIn("hci_le_note_att_rx", conn)
        self.assertIn("dagu: defer LE update", conn)
        self.assertIn("hci_le_arm_deferred_update(hcon, true)", event)
        self.assertIn("hci_le_arm_deferred_update(conn, false)", sync)
        self.assertIn("hci_le_note_att_rx(hcon)", l2cap)
        self.assertIn("L2CAP_CID_ATT", l2cap)
        self.assertIn("hci_lookup_acl_connect", sync)
        self.assertIn("dagu_discovery_must_wait", sync)
        self.assertIn("dagu: pause LE scan for classic page", sync)
        self.assertIn("dagu_pause_le_scan_for_page", sync)
        self.assertIn("dagu: keep the inquiry clock offset", sync)
        self.assertIn("hci_inquiry_cache_drop_expired", sync)
        self.assertIn("dagu_keep_page_params", sync)
        self.assertIn("dagu: classic page rep", sync)
        self.assertIn("dagu_program_page_timeout", sync)
        self.assertIn("HCI_OP_WRITE_PG_TIMEOUT", sync)
        self.assertIn("dagu: page timeout %u", sync)
        self.assertIn("dagu: limited inquiry before LE scan", sync)
        self.assertIn("dagu: LE scan after inquiry", sync)
        self.assertIn("dagu: limited inquiry before page", sync)
        self.assertIn("dagu_fill_page_params", sync)
        self.assertIn("dagu_queue_le_after_inquiry", event)
        self.assertNotIn("dagu: refresh inquiry before page", sync)
        core = (KERNEL / "hci_core.c").read_text(encoding="utf-8")
        self.assertIn("hci_inquiry_cache_drop_expired", core)
        self.assertIn("dagu_keep_page_params", core)
        header = (KERNEL.parent.parent / "include/net/bluetooth/hci_core.h")
        header_text = header.read_text(encoding="utf-8")
        self.assertIn("hci_lookup_acl_connect", header_text)
        self.assertIn("hci_inquiry_cache_drop_expired", header_text)
        overlay = (ROOT / "scripts/apply-overlays.sh").read_text(encoding="utf-8")
        self.assertIn("dagu: keep the inquiry clock offset", overlay)
        self.assertIn("hci_inquiry_cache_drop_expired", overlay)

    def test_att_retry_patch_applies(self) -> None:
        patcher = load_patcher()
        fixture = (
            patcher.OLD_TIMEOUT + "\n"
            "struct att_send_op {\n"
            + patcher.OLD_OP
            + "};\n"
            "static bool timeout_cb(void *user_data)\n{\n"
            + patcher.OLD_CB
            + "\tio_shutdown(chan->io);\n\treturn false;\n}\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "att.c"
            path.write_text(fixture, encoding="utf-8")
            saved = sys.argv
            try:
                sys.argv = ["dagu-bluez-att-retry.py", str(path)]
                patcher.main()
                text = path.read_text(encoding="utf-8")
                self.assertIn("dagu: resend a missed ATT PDU", text)
                self.assertIn("uint8_t dagu_tries", text)
                self.assertIn("op->dagu_tries < DAGU_ATT_TIMEOUT_TRIES", text)
                self.assertIn("2000   /* 2000 ms */", text)
                self.assertIn("DAGU_ATT_TIMEOUT_TRIES\t\t3", text)
                self.assertNotIn("30000  /* 30000 ms */", text)
                patcher.main()
            finally:
                sys.argv = saved
            again = path.read_text(encoding="utf-8")
        self.assertEqual(text, again)

    def test_failed_page_keeps_the_row(self) -> None:
        spec = importlib.util.spec_from_file_location(
            "dagu_bluez_keep_classic_row", ROW_PATCHER)
        patcher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(patcher)
        fixture = (
            "static void connect_failed_callback(void)\n{\n"
            + patcher.OLD
            + "\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "adapter.c"
            path.write_text(fixture, encoding="utf-8")
            saved = sys.argv
            try:
                sys.argv = ["dagu-bluez-keep-classic-row.py", str(path)]
                patcher.main()
                text = path.read_text(encoding="utf-8")
                self.assertIn(patcher.MARKER, text)
                self.assertNotIn("btd_adapter_remove_device", text)
                patcher.main()
            finally:
                sys.argv = saved
            again = path.read_text(encoding="utf-8")
        self.assertEqual(text, again)


if __name__ == "__main__":
    unittest.main()
