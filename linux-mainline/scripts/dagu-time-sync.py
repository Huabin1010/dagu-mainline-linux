#!/usr/bin/env python3
"""Set wall clock when PMIC RTC is missing/stuck (build date 2026-07).

CDN certs (static.hdslb.com) then fail with "not yet valid" and Chrome
loads Bilibili HTML without CSS/JS.
"""
from __future__ import annotations

import os
import socket
import struct
import subprocess
import sys
from email.utils import parsedate_to_datetime
from pathlib import Path
from urllib.request import Request, urlopen

STAMP = Path("/var/lib/dagu/last-good-time")
NTP_HOSTS = (
    "ntp.aliyun.com",
    "ntp.tencent.com",
    "ntp.tuna.tsinghua.edu.cn",
    "pool.ntp.org",
)
HTTP_URLS = (
    "http://mirrors.tuna.tsinghua.edu.cn/",
    "http://detectportal.firefox.com/",
    "https://www.bilibili.com/",
)


def sntp(host: str, timeout: float = 3.0) -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(b"\x1b" + 47 * b"\0", (host, 123))
        data, _ = sock.recvfrom(512)
    finally:
        sock.close()
    if len(data) < 48:
        raise OSError("short ntp")
    t = struct.unpack("!12I", data[:48])[10]
    unix = t - 2208988800
    if unix < 1_700_000_000:
        raise OSError(f"ntp sanity {unix}")
    return unix


def http_date(url: str) -> int:
    req = Request(url, method="HEAD", headers={"User-Agent": "dagu-time-sync"})
    try:
        with urlopen(req, timeout=8) as r:
            raw = r.headers.get("Date")
    except Exception:
        req = Request(url, headers={"User-Agent": "dagu-time-sync"})
        with urlopen(req, timeout=8) as r:
            raw = r.headers.get("Date")
            r.read(64)
    if not raw:
        raise OSError("no Date")
    dt = parsedate_to_datetime(raw)
    unix = int(dt.timestamp())
    if unix < 1_700_000_000:
        raise OSError(f"http sanity {unix}")
    return unix


def apply_unix(unix: int) -> None:
    STAMP.parent.mkdir(parents=True, exist_ok=True)
    iso = subprocess.check_output(
        ["date", "-u", "-d", f"@{unix}", "+%Y-%m-%d %H:%M:%S"],
        text=True,
    ).strip()
    subprocess.check_call(["date", "-u", "-s", iso])
    STAMP.write_text(str(unix) + "\n")
    try:
        subprocess.run(
            ["hwclock", "-w"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except FileNotFoundError:
        pass
    pam = "/usr/local/sbin/dagu-fix-pam.sh"
    if os.access(pam, os.X_OK):
        subprocess.call([pam])


def restore_stamp() -> bool:
    try:
        unix = int(STAMP.read_text().strip())
    except (OSError, ValueError):
        return False
    now = int(__import__("time").time())
    if unix <= now:
        return False
    apply_unix(unix)
    print("restored", unix, file=sys.stderr)
    return True


def main() -> int:
    restore_stamp()
    last_err = None
    for host in NTP_HOSTS:
        try:
            unix = sntp(host)
            apply_unix(unix)
            print(f"ntp {host} -> {unix}")
            return 0
        except Exception as e:
            last_err = e
            print(f"ntp {host}: {e}", file=sys.stderr)
    for url in HTTP_URLS:
        try:
            unix = http_date(url)
            apply_unix(unix)
            print(f"http {url} -> {unix}")
            return 0
        except Exception as e:
            last_err = e
            print(f"http {url}: {e}", file=sys.stderr)
    print(f"dagu-time-sync failed: {last_err}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
