#!/bin/sh
# Interactive GPU floor for Adreno 650. Max OPP is already 670 MHz.
# Do not set governor=performance — the die sits ~75C composing 120Hz LINEAR.
set -eu
D=/sys/class/devfreq/3d00000.gpu
[ -d "$D" ] || exit 0
# 490 MHz during a hold-drag still hitch (Himax inject: 28% of
# samples at 490 while busy_max=100). 587 is the idle OPP.
# Finger-down boost to 670 is linux-mainline/scripts/dagu-touch-boost.py
# — do not set governor=performance.
printf '587000000\n' >"$D/min_freq"
printf '10\n' >"$D/polling_interval"
exit 0
