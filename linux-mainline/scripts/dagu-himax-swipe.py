#!/usr/bin/env python3
"""Inject Himax MT-B swipes. Physical: X 0-1599, Y 0-2559."""
import argparse
import os
import struct
import time

EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
SYN_REPORT = 0
ABS_MT_SLOT = 0x2F
ABS_MT_POSITION_X = 0x35
ABS_MT_POSITION_Y = 0x36
ABS_MT_TRACKING_ID = 0x39
BTN_TOUCH = 0x14A


def pack(typ, code, value, tv=None):
    if tv is None:
        tv = time.time()
    sec = int(tv)
    usec = int((tv - sec) * 1e6)
    return struct.pack("llHHi", sec, usec, typ, code, value)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dev", default="/dev/input/event3")
    ap.add_argument("--axis", choices=("x", "y"), default="x")
    ap.add_argument("--rounds", type=int, default=6)
    ap.add_argument("--steps", type=int, default=36)
    ap.add_argument("--hz", type=float, default=120)
    ap.add_argument("--hold", type=float, default=0,
                    help="seconds to hold-and-scrub without lifting")
    ap.add_argument("--oneway", action="store_true",
                    help="one direction only (user: 按住向上滑)")
    ap.add_argument("--log", default="",
                    help="jsonl of injected samples")
    ap.add_argument("--no-tap", action="store_true",
                    help="do not tap to focus (lab cards / old Bilibili cards)")
    ap.add_argument("--profile", choices=("hold", "slow", "fast", "homepage"),
                    default="hold",
                    help="homepage: slow then fast one-way feed scrolls, never tap")
    ap.add_argument("--native-portrait", action="store_true",
                    help="Mutter transform=normal: feed scroll is physical Y")
    ap.add_argument("--tap", nargs=2, type=int, metavar=("X", "Y"),
                    help="single physical tap then exit")
    args = ap.parse_args()

    fd = os.open(args.dev, os.O_WRONLY)
    dt = 1.0 / args.hz
    tid = 40
    logf = open(args.log, "w") if args.log else None

    def log_pt(kind, x, y):
        if logf:
            logf.write("%.6f %s %d %d\n" % (time.time(), kind, x, y))

    def syn():
        os.write(fd, pack(EV_SYN, SYN_REPORT, 0))

    def down(x, y):
        nonlocal tid
        tid += 1
        os.write(fd, pack(EV_ABS, ABS_MT_SLOT, 0))
        os.write(fd, pack(EV_ABS, ABS_MT_TRACKING_ID, tid))
        os.write(fd, pack(EV_ABS, ABS_MT_POSITION_X, x))
        os.write(fd, pack(EV_ABS, ABS_MT_POSITION_Y, y))
        os.write(fd, pack(EV_KEY, BTN_TOUCH, 1))
        syn()

    def move(x, y):
        os.write(fd, pack(EV_ABS, ABS_MT_POSITION_X, x))
        os.write(fd, pack(EV_ABS, ABS_MT_POSITION_Y, y))
        syn()

    def up():
        os.write(fd, pack(EV_ABS, ABS_MT_TRACKING_ID, -1))
        os.write(fd, pack(EV_KEY, BTN_TOUCH, 0))
        syn()

    if args.tap:
        x, y = args.tap
        down(x, y)
        time.sleep(0.04)
        up()
        os.close(fd)
        if logf:
            logf.close()
        return

    def swipe(x0, y0, x1, y1):
        down(x0, y0)
        time.sleep(dt)
        for i in range(1, args.steps + 1):
            t = i / args.steps
            x = int(x0 + (x1 - x0) * t)
            y = int(y0 + (y1 - y0) * t)
            move(x, y)
            time.sleep(dt)
        time.sleep(0.02)
        up()
        time.sleep(0.04)

    def stroke(x0, y0, x1, y1, steps, hz):
        """One-way drag. Move immediately so Chrome never sees a tap."""
        dt_s = 1.0 / hz
        dx = 48 if x1 >= x0 else -48
        dy = 48 if y1 >= y0 else -48
        if abs(x1 - x0) < abs(y1 - y0):
            dx = 0
        else:
            dy = 0
        down(x0, y0)
        move(x0 + dx, y0 + dy)
        time.sleep(dt_s)
        for i in range(1, steps + 1):
            t = i / steps
            x = int((x0 + dx) + (x1 - x0 - dx) * t)
            y = int((y0 + dy) + (y1 - y0 - dy) * t)
            move(x, y)
            time.sleep(dt_s)
        up()
        time.sleep(0.06)

    def feed_strokes(n, steps, hz, down_bias=2):
        # 270° landscape: logical vertical feed is physical X.
        # Mutter normal (portrait): logical vertical feed is physical Y.
        # Offset 420 avoids the old center tap that opened a card.
        for i in range(n):
            go_back = i % (down_bias + 1) == down_bias
            if args.native_portrait:
                x = 420
                if go_back:
                    stroke(x, 600, x, 2000, steps, hz)
                else:
                    stroke(x, 2000, x, 600, steps, hz)
            else:
                y = 420
                if go_back:
                    stroke(360, y, 1280, y, steps, hz)
                else:
                    stroke(1280, y, 360, y, steps, hz)

    if args.profile == "homepage":
        feed_strokes(4, 48, 40, down_bias=3)
        time.sleep(0.12)
        feed_strokes(12, 12, 120, down_bias=3)
        os.close(fd)
        if logf:
            logf.close()
        return
    if args.profile == "slow":
        feed_strokes(4, 48, 40, down_bias=3)
        os.close(fd)
        if logf:
            logf.close()
        return
    if args.profile == "fast":
        feed_strokes(12, 12, 120, down_bias=3)
        os.close(fd)
        if logf:
            logf.close()
        return

    # tap to focus page (below Chrome toolbar). Skipped on homepage
    # tests: that coordinate lands on a Bilibili card and opens a video.
    if not args.no_tap:
        down(820, 1480)
        time.sleep(0.04)
        up()
        time.sleep(0.12)

    if args.hold:
        if args.axis == "x":
            a, b, y = 1200, 380, 1500
            down(a, y)
            log_pt("down", a, y)
            t0 = time.time()
            if args.oneway:
                while True:
                    elapsed = time.time() - t0
                    if elapsed >= args.hold:
                        break
                    t = min(1.0, elapsed / args.hold)
                    x = int(a + (b - a) * t)
                    move(x, y)
                    log_pt("move", x, y)
                    time.sleep(dt)
            else:
                phase = 0.0
                while time.time() - t0 < args.hold:
                    phase += dt * args.hz / 24.0
                    t = abs((phase % 2.0) - 1.0)
                    x = int(a + (b - a) * t)
                    move(x, y)
                    log_pt("move", x, y)
                    time.sleep(dt)
            up()
            log_pt("up", b if args.oneway else x, y)
        else:
            x, a, b = 800, 2200, 500
            down(x, a)
            log_pt("down", x, a)
            t0 = time.time()
            if args.oneway:
                while True:
                    elapsed = time.time() - t0
                    if elapsed >= args.hold:
                        break
                    t = min(1.0, elapsed / args.hold)
                    y = int(a + (b - a) * t)
                    move(x, y)
                    log_pt("move", x, y)
                    time.sleep(dt)
            else:
                phase = 0.0
                while time.time() - t0 < args.hold:
                    phase += dt * args.hz / 24.0
                    t = abs((phase % 2.0) - 1.0)
                    y = int(a + (b - a) * t)
                    move(x, y)
                    log_pt("move", x, y)
                    time.sleep(dt)
            up()
            log_pt("up", x, b if args.oneway else y)
    else:
        for _ in range(args.rounds):
            if args.axis == "x":
                swipe(1200, 1500, 380, 1500)
                swipe(380, 1500, 1200, 1500)
            else:
                swipe(800, 2200, 800, 500)
                swipe(800, 500, 800, 2200)

    os.close(fd)
    if logf:
        logf.close()


if __name__ == "__main__":
    main()
