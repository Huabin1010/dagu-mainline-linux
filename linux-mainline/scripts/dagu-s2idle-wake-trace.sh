#!/bin/sh
# kprobes on the s2idle wake/abort paths (no bpftrace: FUNCTION_TRACER is
# off, so bpftrace cannot list traceable functions).
#   dagu-s2idle-wake-trace.sh on    arm, clear buffer
#   dagu-s2idle-wake-trace.sh show  print buffer
#   dagu-s2idle-wake-trace.sh off   remove probes
set -eu
T=/sys/kernel/tracing
[ -d "$T/events" ] || mount -t tracefs nodev "$T"
case "${1:-show}" in
on)
	echo 0 >"$T/tracing_on"
	[ -d "$T/events/dagu" ] && echo 0 >"$T/events/dagu/enable"
	echo >"$T/kprobe_events"
	# struct wakeup_source starts with const char *name.
	echo 'p:dagu/irq_wakeup pm_system_irq_wakeup irq=%x0:u32' >>"$T/kprobe_events"
	echo 'p:dagu/ws_event pm_wakeup_ws_event name=+0(+0(%x0)):string hard=%x2:u32' >>"$T/kprobe_events"
	echo 'p:dagu/sys_wakeup pm_system_wakeup' >>"$T/kprobe_events"
	echo 'p:dagu/s2idle_wake s2idle_wake' >>"$T/kprobe_events"
	echo 'r:dagu/suspend_start dpm_suspend_start ret=$retval:s32' >>"$T/kprobe_events"
	echo 'r:dagu/suspend_end dpm_suspend_end ret=$retval:s32' >>"$T/kprobe_events"
	echo 'r:dagu/wakeup_pending pm_wakeup_pending ret=$retval:u8' >>"$T/kprobe_events"
	# ath11k WoW host wakeup TLV: vdev_id, flag, wake_reason (wmi.h).
	echo 'p:dagu/wow_reason ath11k_wmi_tlv_wow_wakeup_host_parse tag=%x1:u16 vdev=+0(%x3):u32 flag=+4(%x3):u32 reason=+8(%x3):s32' \
		>>"$T/kprobe_events" 2>/dev/null || true
	echo 'ret == 1' >"$T/events/dagu/wakeup_pending/filter"
	echo 4096 >"$T/buffer_size_kb"
	echo "${STACK:-0}" >"$T/options/stacktrace"
	echo >"$T/trace"
	echo 1 >"$T/events/dagu/enable"
	echo 1 >"$T/tracing_on"
	;;
show)
	cat "$T/trace"
	;;
off)
	echo 0 >"$T/events/dagu/enable" 2>/dev/null || true
	echo 0 >"$T/options/stacktrace"
	echo >"$T/kprobe_events"
	;;
esac
