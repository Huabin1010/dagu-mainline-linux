#!/usr/bin/env python3
"""Minimal: EVENTFD WAIT_AVAILABLE on empty point, then Transfer a SIGNALED fence.

Does not touch Chrome/Mutter. Opens /dev/dri/renderD128.
Also times TIMELINE_WAIT timeout=0 on an already-signaled point.
"""
from __future__ import annotations

import ctypes
import errno
import json
import os
import time

WAIT_AVAILABLE = 1 << 2
CREATE_SIGNALED = 1 << 0


def _iowr(nr, size):
    return (3 << 30) | (ord("d") << 8) | nr | (size << 16)


class Create(ctypes.Structure):
    _fields_ = [("handle", ctypes.c_uint32), ("flags", ctypes.c_uint32)]


class Destroy(ctypes.Structure):
    _fields_ = [("handle", ctypes.c_uint32), ("pad", ctypes.c_uint32)]


class Eventfd(ctypes.Structure):
    _fields_ = [
        ("handle", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("point", ctypes.c_uint64),
        ("fd", ctypes.c_int32),
        ("pad", ctypes.c_uint32),
    ]


class Transfer(ctypes.Structure):
    _fields_ = [
        ("src_handle", ctypes.c_uint32),
        ("dst_handle", ctypes.c_uint32),
        ("src_point", ctypes.c_uint64),
        ("dst_point", ctypes.c_uint64),
        ("flags", ctypes.c_uint32),
        ("pad", ctypes.c_uint32),
    ]


class TimelineWait(ctypes.Structure):
    _fields_ = [
        ("handles", ctypes.c_uint64),
        ("points", ctypes.c_uint64),
        ("timeout_nsec", ctypes.c_int64),
        ("count_handles", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("first_signaled", ctypes.c_uint32),
        ("pad", ctypes.c_uint32),
        ("deadline_nsec", ctypes.c_uint64),
    ]


IOCTL_CREATE = _iowr(0xBF, ctypes.sizeof(Create))
IOCTL_DESTROY = _iowr(0xC0, ctypes.sizeof(Destroy))
IOCTL_TRANSFER = _iowr(0xCC, ctypes.sizeof(Transfer))
IOCTL_EVENTFD = _iowr(0xCF, ctypes.sizeof(Eventfd))
IOCTL_TL_WAIT = _iowr(0xCA, ctypes.sizeof(TimelineWait))

libc = ctypes.CDLL(None, use_errno=True)
libc.ioctl.restype = ctypes.c_int
libc.ioctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_void_p]


def ioc(fd, nr, obj):
    ctypes.set_errno(0)
    rc = libc.ioctl(fd, nr, ctypes.byref(obj))
    err = 0 if rc == 0 else (ctypes.get_errno() or errno.EIO)
    return rc, err


def efd_count(efd):
    text = open(f"/proc/self/fdinfo/{efd}").read()
    for line in text.splitlines():
        if line.startswith("eventfd-count:"):
            return int(line.split(":", 1)[1].strip(), 16)
    return None


def tl_wait(fd, handle, point, flags, tmo):
    h = ctypes.c_uint32(handle)
    p = ctypes.c_uint64(point)
    req = TimelineWait(
        handles=ctypes.addressof(h),
        points=ctypes.addressof(p),
        timeout_nsec=tmo,
        count_handles=1,
        flags=flags,
        first_signaled=0,
        pad=0,
        deadline_nsec=0,
    )
    t0 = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
    rc, err = ioc(fd, IOCTL_TL_WAIT, req)
    ms = (time.clock_gettime_ns(time.CLOCK_MONOTONIC) - t0) / 1e6
    return rc, err, ms


def main():
    fd = os.open("/dev/dri/renderD128", os.O_RDWR | os.O_CLOEXEC)
    out = {"fd": fd}

    cr = Create(0, 0)
    rc, err = ioc(fd, IOCTL_CREATE, cr)
    out["timeline"] = {"handle": cr.handle, "rc": rc, "err": err}
    tl = cr.handle

    tmp = Create(0, CREATE_SIGNALED)
    rc, err = ioc(fd, IOCTL_CREATE, tmp)
    out["signaled"] = {"handle": tmp.handle, "rc": rc, "err": err}

    rc, err, ms = tl_wait(fd, tmp.handle, 0, 0, 0)
    out["wait0_already_signaled"] = {"rc": rc, "err": err, "ms": round(ms, 3)}

    efd = os.eventfd(0, os.EFD_CLOEXEC | os.EFD_NONBLOCK)
    ev = Eventfd(handle=tl, flags=WAIT_AVAILABLE, point=1, fd=efd, pad=0)
    rc, err = ioc(fd, IOCTL_EVENTFD, ev)
    out["eventfd_arm"] = {"rc": rc, "err": err, "count_before": efd_count(efd)}

    tr = Transfer(
        src_handle=tmp.handle,
        dst_handle=tl,
        src_point=0,
        dst_point=1,
        flags=0,
        pad=0,
    )
    t0 = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
    rc, err = ioc(fd, IOCTL_TRANSFER, tr)
    ms = (time.clock_gettime_ns(time.CLOCK_MONOTONIC) - t0) / 1e6
    out["transfer"] = {"rc": rc, "err": err, "ms": round(ms, 3), "count_after": efd_count(efd)}

    rc, err, ms = tl_wait(fd, tl, 1, 0, 0)
    out["wait0_after_xfer"] = {"rc": rc, "err": err, "ms": round(ms, 3)}
    rc, err, ms = tl_wait(fd, tl, 1, WAIT_AVAILABLE, 0)
    out["wait4_after_xfer"] = {"rc": rc, "err": err, "ms": round(ms, 3)}
    out["count_final"] = efd_count(efd)

    # already-available then EVENTFD (retroactive)
    efd2 = os.eventfd(0, os.EFD_CLOEXEC | os.EFD_NONBLOCK)
    ev2 = Eventfd(handle=tl, flags=WAIT_AVAILABLE, point=1, fd=efd2, pad=0)
    rc, err = ioc(fd, IOCTL_EVENTFD, ev2)
    out["eventfd_after_signal"] = {"rc": rc, "err": err, "count": efd_count(efd2)}

    ioc(fd, IOCTL_DESTROY, Destroy(tl, 0))
    ioc(fd, IOCTL_DESTROY, Destroy(tmp.handle, 0))
    os.close(efd)
    os.close(efd2)
    os.close(fd)
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
