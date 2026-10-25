#!/bin/sh
# kprobes on the MGMT discovery state machine, with call stacks on every
# state change and every LE scan disable. Needs CONFIG_KPROBE_EVENTS (no
# FUNCTION_TRACER, so bpftrace cannot attach here).
#
# Field offsets are for the #654 build. Re-read them after a struct
# hci_dev change:
#   pahole -C hci_dev out/kernel/vmlinux | grep -E ' flags;|discovery |dev_flags'
#   (discovery.state is discovery + 4)
# Read with: grep dagu_ /sys/kernel/tracing/trace
# discovery.state: 0 STOPPED 1 STARTING 2 FINDING 3 RESOLVING 4 STOPPING
T=/sys/kernel/tracing
mountpoint -q $T || mount -t tracefs none $T
echo 0 > $T/tracing_on
for e in $T/events/kprobes/dagu_*; do [ -d "$e" ] && echo 0 > "$e/enable"; done
echo > $T/kprobe_events
cat >> $T/kprobe_events <<'EOF'
p:dagu_dss hci_discovery_set_state old=+2340($arg1):s32 new=$arg2:s32 flags=+104($arg1):x64 dflags=+4176($arg1):x64
p:dagu_scan_off hci_scan_disable_sync state=+2340($arg1):s32 dflags=+4176($arg1):x64
p:dagu_scan_cc le_set_scan_enable_complete enable=$arg2:u8 state=+2340($arg1):s32 dflags=+4176($arg1):x64
p:dagu_lsd le_scan_disable
p:dagu_inq_done hci_inquiry_complete_evt state=+2340($arg1):s32 flags=+104($arg1):x64
p:dagu_inq_cancel hci_cc_inquiry_cancel state=+2340($arg1):s32
EOF
echo 16384 > $T/buffer_size_kb
echo > $T/trace
for e in dagu_dss dagu_scan_off dagu_scan_cc dagu_lsd dagu_inq_done dagu_inq_cancel; do
	echo 1 > $T/events/kprobes/$e/enable
done
echo stacktrace > $T/events/kprobes/dagu_dss/trigger
echo stacktrace > $T/events/kprobes/dagu_scan_off/trigger
echo 1 > $T/tracing_on
echo armed
