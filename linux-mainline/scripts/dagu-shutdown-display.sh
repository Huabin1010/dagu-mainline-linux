#!/bin/sh
# Stop the framebuffer console from taking the panel when GNOME/Mutter
# drops DRM master. ignore_loglevel + console=tty0 would otherwise keep
# reprinting the same kernel log block until the PMIC finally cuts power.
set -eu

echo 1 >/proc/sys/kernel/printk 2>/dev/null || true
for bind in /sys/class/vtconsole/vtcon*/bind; do
	[ -w "$bind" ] || continue
	echo 0 >"$bind" 2>/dev/null || true
done
# Hide the hardware cursor; leftover fbcon glyphs stay until the panel
# loses scanout, but they are no longer rewritten every printk.
for tty in /dev/tty1 /dev/tty0; do
	[ -c "$tty" ] || continue
	setterm --cursor off --blank force --term linux <"$tty" >"$tty" 2>/dev/null || true
done
exit 0
