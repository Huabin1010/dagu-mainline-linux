#!/usr/bin/env python3
"""Host client for dagu TestLab USB v2 (TESTLAB volume over Type-C MSC)."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "test"))

from usb_protocol_constants import (  # noqa: E402
    DEFAULT_USB_POLL_SEC,
    DEFAULT_USB_TIMEOUT_SEC,
    FILES,
    LEGACY_FILES,
    PROTOCOL_VERSION,
    TESTLAB_DIR,
)


@dataclass
class UsbLogPaths:
    root: Path

    def file(self, key: str) -> Path:
        return self.root / FILES[key]


def load_lab_config() -> dict:
    path = ROOT / "test-lab.json"
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def default_timeout() -> float:
    cfg = load_lab_config()
    return float(cfg.get("usb_log_timeout_sec", DEFAULT_USB_TIMEOUT_SEC))


def discover_testlab_root(search_roots: list[Path]) -> Path | None:
    for root in search_roots:
        if not root.exists():
            continue
        for dirpath, dirnames, _ in os.walk(root):
            base = Path(dirpath)
            testlab = base / TESTLAB_DIR
            if testlab.is_dir() and _is_v2_volume(testlab):
                return testlab
            if _is_v2_volume(base):
                return base
    return None


def _is_v2_volume(base: Path) -> bool:
    return (
        (base / FILES["boot_seq"]).exists()
        and (base / FILES["status_json"]).exists()
        and not (base / LEGACY_FILES[2]).exists()
    )


def wait_for_volume(timeout_sec: float, poll_sec: float = DEFAULT_USB_POLL_SEC) -> UsbLogPaths:
    deadline = time.time() + timeout_sec
    search = [Path(f"{letter}:/") for letter in "DEFGHIJKLMNOPQRSTUVWXYZ"]
    search.append(ROOT / "mock-testlab" / TESTLAB_DIR)
    search.append(ROOT / "mock-testlab")

    while time.time() < deadline:
        found = discover_testlab_root(search)
        if found:
            return UsbLogPaths(found)
        time.sleep(poll_sec)
    raise TimeoutError(
        "TESTLAB volume not found; ensure UEFI booted with TestLabBridge v2 and USB MSC started"
    )


def read_text(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")


def cmd_discover() -> int:
    found = discover_testlab_root([Path(f"{l}:/") for l in "DEFGHIJKLMNOPQRSTUVWXYZ"])
    if not found:
        print("(TESTLAB v2 volume not found)", file=sys.stderr)
        return 1
    print(found)
    return 0


def cmd_preflight(as_json: bool) -> int:
    cfg = load_lab_config()
    found = discover_testlab_root([Path(f"{l}:/") for l in "DEFGHIJKLMNOPQRSTUVWXYZ"])
    data = {
        "protocol": PROTOCOL_VERSION,
        "volume_found": found is not None,
        "volume_path": str(found) if found else "",
        "timeout_sec": default_timeout(),
        "poll_sec": cfg.get("usb_log_poll_sec", DEFAULT_USB_POLL_SEC),
    }
    if as_json:
        print(json.dumps(data, indent=2, ensure_ascii=False))
    else:
        print("=== TestLab USB v2 preflight ===")
        print(f"protocol: {PROTOCOL_VERSION}")
        print(f"volume: {data['volume_path'] or '(not mounted — boot UEFI first)'}")
        print(f"timeout: {data['timeout_sec']}s")
    return 0 if found else 1


def cmd_watch(
    paths: UsbLogPaths,
    out_log: Path | None,
    follow: bool,
    poll_sec: float,
) -> int:
    last_seq = ""
    pos = 0
    while True:
        seq = read_text(paths.file("boot_seq")).strip()
        text = read_text(paths.file("boot_log"))
        if seq != last_seq or len(text) > pos:
            chunk = text[pos:]
            if chunk:
                sys.stdout.write(chunk)
                sys.stdout.flush()
                if out_log:
                    with out_log.open("a", encoding="utf-8") as fh:
                        fh.write(chunk)
            pos = len(text)
            last_seq = seq
        if not follow:
            return 0
        time.sleep(poll_sec)


def cmd_dump(paths: UsbLogPaths, dest: Path) -> int:
    src = paths.file("boot_log")
    if not src.exists():
        print(f"missing {src}", file=sys.stderr)
        return 1
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)
    print(dest)
    return 0


def cmd_status(paths: UsbLogPaths) -> int:
    raw = read_text(paths.file("status_json")).strip()
    if not raw:
        print("{}")
        return 1
    try:
        print(json.dumps(json.loads(raw), indent=2, ensure_ascii=False))
    except json.JSONDecodeError:
        print(raw)
    return 0


def cmd_send(paths: UsbLogPaths, command: str, timeout_sec: float) -> int:
    ack_path = paths.file("command_ack")
    before = read_text(ack_path)
    paths.file("command_in").write_text(command.rstrip() + "\n", encoding="ascii")
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        ack = read_text(ack_path)
        if ack and ack != before:
            print(ack.strip())
            return 0 if ack.startswith("OK") else 2
        time.sleep(0.25)
    print("timeout waiting for COMMAND.ACK", file=sys.stderr)
    return 1


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description="dagu TestLab USB v2 log client")
    ap.add_argument("--root", type=Path, help="TESTLAB folder (skip auto discover)")
    ap.add_argument("--timeout", type=float, default=default_timeout())
    sub = ap.add_subparsers(dest="action", required=True)

    sub.add_parser("discover", help="Find TESTLAB v2 volume").set_defaults(func="discover")
    p_pre = sub.add_parser("preflight", help="Check if TESTLAB is mounted")
    p_pre.add_argument("--json", action="store_true")
    p_pre.set_defaults(func="preflight")

    p_watch = sub.add_parser("watch", help="Stream BOOT.LOG")
    p_watch.add_argument("--log", type=Path)
    p_watch.add_argument("--once", action="store_true")
    p_watch.add_argument("--poll", type=float, default=DEFAULT_USB_POLL_SEC)
    p_watch.set_defaults(func="watch")

    p_dump = sub.add_parser("dump", help="Copy BOOT.LOG to file")
    p_dump.add_argument("dest", type=Path)
    p_dump.set_defaults(func="dump")

    sub.add_parser("status", help="Print STATUS.JSON").set_defaults(func="status")

    p_send = sub.add_parser("send", help="Write COMMAND.IN and wait for ACK")
    p_send.add_argument("command")
    p_send.set_defaults(func="send")

    return ap


def resolve_paths(args: argparse.Namespace) -> UsbLogPaths:
    if args.root:
        root = args.root
        if (root / TESTLAB_DIR).is_dir():
            root = root / TESTLAB_DIR
        return UsbLogPaths(root)
    return wait_for_volume(args.timeout)


def main() -> int:
    ap = build_parser()
    args = ap.parse_args()

    if args.action == "discover":
        return cmd_discover()
    if args.action == "preflight":
        return cmd_preflight(as_json=args.json)

    try:
        paths = resolve_paths(args)
    except TimeoutError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    if args.action == "watch":
        return cmd_watch(paths, args.log, follow=not args.once, poll_sec=args.poll)
    if args.action == "dump":
        return cmd_dump(paths, args.dest)
    if args.action == "status":
        return cmd_status(paths)
    if args.action == "send":
        return cmd_send(paths, args.command, args.timeout)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
