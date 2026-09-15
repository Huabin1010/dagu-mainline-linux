#!/usr/bin/env python3
"""Unmount userdata, e2fsck, resize2fs to the full 106G partition, reboot.

The 128G UFS userdata is already sda34 ~106G. The ext4 was left at 8G:
init mounts noload (bad journal), so the kernel refuses online resize.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys

RESCUE = "/run/dagu-grow"
DEV = "/dev/sda34"


def klog(msg: str) -> None:
    line = f"dagu-grow: {msg}"
    print(line, flush=True)
    try:
        with open("/dev/kmsg", "w") as f:
            f.write(line + "\n")
    except OSError:
        pass


def copy_bin(name: str) -> None:
    src = shutil.which(name)
    if not src:
        raise SystemExit(f"missing {name}")
    dst = os.path.join(RESCUE, "bin", os.path.basename(src))
    shutil.copy2(src, dst)
    os.chmod(dst, 0o755)
    out = subprocess.check_output(["ldd", src], text=True, errors="ignore")
    for raw in out.splitlines():
        so = None
        if "=>" in raw:
            parts = raw.strip().split()
            if len(parts) >= 3 and parts[2].startswith("/"):
                so = parts[2]
        elif raw.strip().startswith("/"):
            so = raw.strip().split()[0]
        if not so or not os.path.isfile(so):
            continue
        libdst = os.path.join(RESCUE, "lib", os.path.basename(so))
        if not os.path.exists(libdst):
            shutil.copy2(so, libdst)


def write_grow_sh() -> None:
    path = os.path.join(RESCUE, "grow.sh")
    with open(path, "w") as f:
        f.write(
            r"""#!/bin/sh
echo "dagu-grow: inside rescue" >/dev/kmsg
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev 2>/dev/null || true
echo 1 >/proc/sys/kernel/sysrq
# Keep KPSS WDT fed; nobody else is pinging after switch-root.
( while :; do
	printf '\0' >/dev/watchdog 2>/dev/null
	printf '\0' >/dev/watchdog0 2>/dev/null
	sleep 2
done ) &
sync
echo "dagu-grow: e2fsck" >/dev/kmsg
/bin/e2fsck -fy /dev/sda34
rc=$?
echo "dagu-grow: e2fsck rc=$rc" >/dev/kmsg
if [ "$rc" -gt 2 ]; then
	echo "dagu-grow: e2fsck failed" >/dev/kmsg
	echo b >/proc/sysrq-trigger
	sleep 60
fi
echo "dagu-grow: resize2fs" >/dev/kmsg
/bin/resize2fs /dev/sda34
echo "dagu-grow: resize rc=$?" >/dev/kmsg
sync
if mount -t ext4 /dev/sda34 /mnt; then
	date >/mnt/var/log/dagu-grow.log 2>/dev/null
	echo "e2fsck=$rc resize done" >>/mnt/var/log/dagu-grow.log
	umount /mnt
fi
echo "dagu-grow: reboot" >/dev/kmsg
echo b >/proc/sysrq-trigger
sleep 60
"""
        )
    os.chmod(path, 0o755)


def main() -> int:
    if os.geteuid() != 0:
        raise SystemExit("root only")
    if not os.path.exists(DEV):
        raise SystemExit("no " + DEV)

    klog("stop session")
    subprocess.run(["pkill", "-u", "dagu", "-f", "chrome|chromium|gnome-shell"], check=False)
    subprocess.run(["systemctl", "stop", "gdm.service"], check=False)
    os.sync()

    subprocess.run(["umount", RESCUE], check=False)
    shutil.rmtree(RESCUE, ignore_errors=True)
    os.makedirs(RESCUE, exist_ok=True)
    subprocess.check_call(["mount", "-t", "tmpfs", "-o", "size=64M", "grow", RESCUE])
    for d in ("bin", "lib", "lib64", "proc", "sys", "dev", "oldroot", "usr/sbin", "mnt"):
        os.makedirs(os.path.join(RESCUE, d), exist_ok=True)

    copy_bin("e2fsck")
    copy_bin("resize2fs")
    copy_bin("mount")
    copy_bin("umount")
    copy_bin("sync")
    copy_bin("sleep")
    copy_bin("sh")
    copy_bin("mkdir")
    ld = "/lib/ld-linux-aarch64.so.1"
    if os.path.isfile(ld):
        shutil.copy2(ld, os.path.join(RESCUE, "lib", os.path.basename(ld)))
        os.symlink("../lib/ld-linux-aarch64.so.1", os.path.join(RESCUE, "lib64", "ld-linux-aarch64.so.1"))
    gnu = os.path.join(RESCUE, "usr/lib/aarch64-linux-gnu")
    os.makedirs(gnu, exist_ok=True)
    os.makedirs(os.path.join(RESCUE, "lib/aarch64-linux-gnu"), exist_ok=True)
    for name in os.listdir(os.path.join(RESCUE, "lib")):
        for dest in (
            os.path.join(gnu, name),
            os.path.join(RESCUE, "lib/aarch64-linux-gnu", name),
        ):
            if not os.path.exists(dest):
                os.symlink(f"/lib/{name}", dest)
    write_grow_sh()
    for name in os.listdir(os.path.join(RESCUE, "bin")):
        klog(f"have {name}")

    klog("switch-root")
    # systemd switch-root unmounts the old root and execs grow.sh as PID 1.
    # Do not mount --make-rprivate / — that tears down systemd and the KPSS
    # watchdog reboots before e2fsck can finish.
    os.execv(
        "/usr/bin/systemctl",
        ["systemctl", "--force", "switch-root", RESCUE, "/grow.sh"],
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
