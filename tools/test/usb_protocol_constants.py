"""TestLab USB v2 file protocol constants (host + unit tests)."""
from __future__ import annotations

VOLUME_LABEL = "TESTLAB"
TESTLAB_DIR = "TESTLAB"

FILES = {
    "boot_log": "BOOT.LOG",
    "boot_seq": "BOOT.SEQ",
    "status_json": "STATUS.JSON",
    "command_in": "COMMAND.IN",
    "command_ack": "COMMAND.ACK",
}

# Legacy v1 names — must NOT appear in v2 firmware/templates.
LEGACY_FILES = ("CONSOLE.OUT", "CONSOLE.SEQ", "SCREEN.BMP")

PROTOCOL_VERSION = "v2"
DEFAULT_USB_POLL_SEC = 1.0
DEFAULT_USB_TIMEOUT_SEC = 120.0
USB_MSC_DELAY_SEC = 30
