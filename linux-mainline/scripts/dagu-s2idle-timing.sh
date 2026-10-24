#!/bin/sh
# Time one s2idle cycle: PM phases, slow device callbacks, panel and
# backlight calls, plus the userspace side (logind, gnome-shell).
#   dagu-s2idle-timing.sh on      arm tracepoints and kprobes
#   dagu-s2idle-timing.sh report  print phases and callbacks > 20 ms
#   dagu-s2idle-timing.sh off
set -eu
T=/sys/kernel/tracing
[ -d "$T/events" ] || mount -t tracefs nodev "$T"
case "${1:-report}" in
on)
	echo 0 >"$T/tracing_on"
	for e in "$T"/events/dagu "$T"/events/power; do
		[ -d "$e" ] && echo 0 >"$e/enable"
	done
	echo >"$T/kprobe_events"
	echo 'p:dagu/bl_update l81a_backlight_update' >>"$T/kprobe_events"
	echo 'p:dagu/panel_enable drm_panel_enable' >>"$T/kprobe_events"
	echo 'p:dagu/panel_disable drm_panel_disable' >>"$T/kprobe_events"
	echo 'p:dagu/irq_wakeup pm_system_irq_wakeup irq=%x0:u32' >>"$T/kprobe_events"
	echo 'p:dagu/wow_reason ath11k_wmi_tlv_wow_wakeup_host_parse tag=%x1:u16 reason=+8(%x3):s32' \
		>>"$T/kprobe_events"
	echo 'tag == 49' >"$T/events/dagu/wow_reason/filter"
	echo 0 >"$T/options/stacktrace"
	echo 8192 >"$T/buffer_size_kb"
	echo >"$T/trace"
	echo 1 >"$T/events/power/suspend_resume/enable"
	echo 1 >"$T/events/power/device_pm_callback_start/enable"
	echo 1 >"$T/events/power/device_pm_callback_end/enable"
	echo 1 >"$T/events/dagu/enable"
	echo 1 >"$T/tracing_on"
	;;
report)
	awk '
	/suspend_resume:/ { print; next }
	/dagu\// || /bl_update|panel_|irq_wakeup|wow_reason/ { print; next }
	/device_pm_callback_start:/ {
		match($0, /[0-9]+\.[0-9]+:/); t = substr($0, RSTART, RLENGTH - 1)
		match($0, /callback_start: [^ ]+ [^,]+/); k = substr($0, RSTART + 16, RLENGTH - 16)
		st[k] = t; next
	}
	/device_pm_callback_end:/ {
		match($0, /[0-9]+\.[0-9]+:/); t = substr($0, RSTART, RLENGTH - 1)
		match($0, /callback_end: [^ ]+ [^,]+/); k = substr($0, RSTART + 14, RLENGTH - 14)
		if (k in st) { d = (t - st[k]) * 1000; if (d > 20) printf "  %8.1f ms  %s  (end %s)\n", d, k, t }
	}' "$T/trace"
	;;
off)
	echo 0 >"$T/events/power/enable" 2>/dev/null || true
	echo 0 >"$T/events/dagu/enable" 2>/dev/null || true
	echo >"$T/kprobe_events"
	;;
esac
