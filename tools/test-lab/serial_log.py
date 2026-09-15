#!/usr/bin/env python3
"""Capture dagu UEFI boot logs over UART (115200 8N1)."""
from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import dataclass, asdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "test"))

from uart_expectations import (  # noqa: E402
    BUILD_UART_FLAG,
    DTB_SERIAL0_MMIO,
    DTB_SERIAL0_NODE,
    FIRMWARE_UART_PCD,
    NO_COM_IS_NORMAL_WITHOUT_TTL,
    SERIAL_BAUD,
    UART_IS_USB_CDC,
    UART_REQUIRES_USB_TTL,
)

DEFAULT_BAUD = SERIAL_BAUD


@dataclass(frozen=True)
class SerialConfig:
    port: str
    baud: int = DEFAULT_BAUD
    timeout: float = 0.25


@dataclass
class PreflightReport:
    configured_port: str
    baud: int
    detected_ports: list[str]
    firmware_pcd_hex: str
    dtb_serial0_node: str
    uart_requires_usb_ttl: bool
    uart_is_usb_cdc: bool
    ready: bool
    message: str


def load_lab_config() -> dict:
    path = ROOT / "test-lab.json"
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def default_port() -> str:
    cfg = load_lab_config()
    return str(cfg.get("serial_port", "")).strip()


def default_baud() -> int:
    cfg = load_lab_config()
    return int(cfg.get("serial_baud", DEFAULT_BAUD))


def list_serial_ports() -> list[str]:
    try:
        from serial.tools import list_ports
    except ImportError as exc:
        raise RuntimeError("pyserial is required: pip install pyserial") from exc

    return sorted({p.device for p in list_ports.comports()})


def pick_port(explicit: str | None) -> str:
    if explicit:
        return explicit
    configured = default_port()
    if configured:
        return configured
    ports = list_serial_ports()
    if len(ports) == 1:
        return ports[0]
    if not ports:
        raise RuntimeError("no serial ports found; pass --port COMx")
    raise RuntimeError(
        "multiple serial ports found; pass --port explicitly: "
        + ", ".join(ports)
    )


def build_preflight_report() -> PreflightReport:
    configured = default_port()
    ports = list_serial_ports()
    if configured:
        ready = configured in ports if ports else True
        msg = (
            f"Using configured port {configured}."
            if ready
            else f"Configured {configured} not in detected ports {ports}."
        )
    elif len(ports) == 1:
        ready = True
        msg = f"Auto-select single port {ports[0]}."
    elif len(ports) > 1:
        ready = False
        msg = f"Multiple ports {ports}; set test-lab.json serial_port."
    else:
        ready = False
        msg = NO_COM_IS_NORMAL_WITHOUT_TTL

    return PreflightReport(
        configured_port=configured,
        baud=default_baud(),
        detected_ports=ports,
        firmware_pcd_hex=f"0x{DTB_SERIAL0_MMIO:08x}",
        dtb_serial0_node=DTB_SERIAL0_NODE,
        uart_requires_usb_ttl=UART_REQUIRES_USB_TTL,
        uart_is_usb_cdc=UART_IS_USB_CDC,
        ready=ready,
        message=msg,
    )


def open_serial(config: SerialConfig):
    try:
        import serial
    except ImportError as exc:
        raise RuntimeError("pyserial is required: pip install pyserial") from exc

    return serial.Serial(
        port=config.port,
        baudrate=config.baud,
        bytesize=serial.EIGHTBITS,
        parity=serial.PARITY_NONE,
        stopbits=serial.STOPBITS_ONE,
        timeout=config.timeout,
    )


def cmd_list() -> int:
    ports = list_serial_ports()
    if not ports:
        print("(no serial ports detected)")
        print(NO_COM_IS_NORMAL_WITHOUT_TTL)
        return 1
    for port in ports:
        print(port)
    return 0


def cmd_preflight(as_json: bool) -> int:
    report = build_preflight_report()
    if as_json:
        print(json.dumps(asdict(report), indent=2, ensure_ascii=False))
    else:
        print("=== dagu UART preflight ===")
        print(f"firmware {FIRMWARE_UART_PCD}: {report.firmware_pcd_hex} ({report.dtb_serial0_node})")
        print(f"build flag: {BUILD_UART_FLAG} (USE_UART=1)")
        print(f"baud: {report.baud} 8N1")
        print(f"configured serial_port: {report.configured_port or '(not set)'}")
        print(f"detected COM ports: {report.detected_ports or '(none)'}")
        print(f"capture ready: {report.ready}")
        print(f"note: {report.message}")
        if not report.uart_is_usb_cdc:
            print("Type-C adb/fastboot does NOT expose UEFI UART as a COM port.")
    return 0 if report.ready else 1


def cmd_watch(
    config: SerialConfig,
    out_log: Path | None,
    follow: bool,
    duration_sec: float | None,
    quiet: bool,
) -> int:
    ser = open_serial(config)
    deadline = None if duration_sec is None else time.time() + duration_sec
    log_fp = out_log.open("ab") if out_log else None

    if not quiet:
        banner = (
            f"# serial-log port={config.port} baud={config.baud} "
            f"started={time.strftime('%Y-%m-%d %H:%M:%S')}\n"
        )
        sys.stdout.buffer.write(banner.encode("ascii"))
        sys.stdout.buffer.flush()
        if log_fp:
            log_fp.write(banner.encode("ascii"))
            log_fp.flush()

    try:
        while True:
            chunk = ser.read(4096)
            if chunk:
                if not quiet:
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                if log_fp:
                    log_fp.write(chunk)
                    log_fp.flush()
            elif deadline is not None and time.time() >= deadline:
                return 0
            elif not follow:
                return 0
            elif ser.in_waiting:
                continue
            else:
                time.sleep(0.05)
    except KeyboardInterrupt:
        return 0
    finally:
        if log_fp:
            log_fp.close()
        ser.close()


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description="Capture dagu UEFI UART boot log (115200 8N1)"
    )
    ap.add_argument("--port", help="Serial port (COM3, /dev/ttyUSB0, ...)")
    ap.add_argument("--baud", type=int, default=default_baud())
    ap.add_argument("--timeout", type=float, default=0.25)
    sub = ap.add_subparsers(dest="action", required=True)

    p_list = sub.add_parser("list", help="List detected serial ports")
    p_list.set_defaults(func="list")

    p_pre = sub.add_parser("preflight", help="Check host UART wiring / config")
    p_pre.add_argument("--json", action="store_true")
    p_pre.set_defaults(func="preflight")

    p_watch = sub.add_parser("watch", help="Stream UART output")
    p_watch.add_argument("--log", type=Path, help="Append raw bytes to this file")
    p_watch.add_argument("--once", action="store_true", help="Read one chunk then exit")
    p_watch.add_argument(
        "--duration",
        type=float,
        help="Stop after N seconds (implies follow unless --once)",
    )
    p_watch.add_argument(
        "--quiet",
        action="store_true",
        help="Write only to --log, not stdout",
    )
    p_watch.set_defaults(func="watch")

    return ap


def main() -> int:
    ap = build_parser()
    args = ap.parse_args()

    if args.action == "list":
        try:
            return cmd_list()
        except RuntimeError as exc:
            print(str(exc), file=sys.stderr)
            return 1

    if args.action == "preflight":
        try:
            return cmd_preflight(as_json=args.json)
        except RuntimeError as exc:
            print(str(exc), file=sys.stderr)
            return 1

    try:
        port = pick_port(args.port)
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        print(NO_COM_IS_NORMAL_WITHOUT_TTL, file=sys.stderr)
        return 1

    config = SerialConfig(port=port, baud=args.baud, timeout=args.timeout)
    if args.action == "watch":
        follow = not args.once
        if args.duration is not None:
            follow = True
        return cmd_watch(
            config,
            out_log=args.log,
            follow=follow,
            duration_sec=args.duration,
            quiet=args.quiet,
        )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
