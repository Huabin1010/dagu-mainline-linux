"""dagu TestLab UART expectations — shared by tests and serial_log preflight."""
from __future__ import annotations

# DTB alias: serial0 = "/soc/qcom,qup_uart@988000"
DTB_SERIAL0_NODE = "qcom,qup_uart@988000"
DTB_SERIAL0_MMIO = 0x988000

SERIAL_BAUD = 115200
SERIAL_DATA_BITS = 8
SERIAL_PARITY = "N"
SERIAL_STOP_BITS = 1

# dagu outputs debug on SoC UART pins (GENI @ 0x988000).
# PC "COMx" only appears when a USB-TTL adapter is wired to those pins.
UART_IS_USB_CDC = False
UART_REQUIRES_USB_TTL = True

FIRMWARE_UART_PCD = "PcdDebugUartPortBase"
BUILD_UART_FLAG = "-u"

# Human-readable explanation for operators (also asserted in unit tests).
NO_COM_IS_NORMAL_WITHOUT_TTL = (
    "No COM port on PC is expected when only Type-C adb/fastboot is connected. "
    "That does NOT by itself indicate broken UEFI; connect USB-TTL to board UART."
)
