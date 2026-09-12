#!/bin/sh
# Interactive GPU floor for Adreno 650. Max OPP is already 670 MHz.
# Do not set governor=performance — the die sits ~75C composing 120Hz LINEAR.
set -eu
D=/sys/class/devfreq/3d00000.gpu
[ -d "$D" ] || exit 0
printf '490000000\n' >"$D/min_freq"
printf '10\n' >"$D/polling_interval"
exit 0
