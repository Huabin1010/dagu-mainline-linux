#!/usr/bin/env bash
# Arm DPU ftrace and dump it on the next vblank timeout: 400000 (DSC_IDX).
#
# There is no msm.dpu_disable_dsc_clock_gating. Video-mode idle_pc only
# drops IRQs (IDLE_TIMEOUT=58 ms), it does not gate DSC clocks.
#
# On the tablet (root):
#   /usr/local/sbin/dagu-dpu-timeout-watch.sh
# From the host:
#   linux-mainline/scripts/dagu-dpu-timeout-watch.sh --host
#   linux-mainline/scripts/dagu-dpu-timeout-watch.sh --pull
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${DAGU_SSH_HOST:-192.168.7.2}"
KEY="${DAGU_SSH_KEY:-$ROOT/out/id_dagu}"
OUT_HOST="${DAGU_DPU_OUT:-$ROOT/out/display-stress}"
OUT_DEV="${DAGU_DPU_DEV:-/var/log/dagu-dpu}"
REMOTE=/usr/local/sbin/dagu-dpu-timeout-watch.sh
TR="/sys/kernel/debug/tracing"

SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o ConnectTimeout=12 "root@$HOST")
SCP=(scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

arm_trace() {
	# Event tracer only (CONFIG_FTRACE + SCHED_TRACER). Do not turn on
	# FUNCTION_TRACER or hw_log_mask (ignore_loglevel + DPU_REG printk
	# stalls 120 Hz).
	if [ -d "$TR/events/dpu" ]; then
		echo 0 >"$TR/tracing_on"
		echo >"$TR/trace"
		echo 16384 >"$TR/buffer_size_kb"
		echo 1 >"$TR/events/dpu/enable"
		for ev in dpu_enc_trigger_flush dpu_enc_rc dpu_enc_kickoff \
			dpu_enc_prepare_kickoff dpu_enc_wait_event_timeout \
			dpu_enc_frame_done_timeout dpu_enc_underrun_cb; do
			[ -d "$TR/events/dpu/$ev" ] && echo 1 >"$TR/events/dpu/$ev/enable"
		done
		echo 1 >"$TR/tracing_on"
		echo "dpu-watch: ftrace dpu on, $(cat $TR/buffer_size_kb) kB"
		return
	fi
	echo "dpu-watch: no ftrace (CONFIG_FTRACE=n). dmesg + drm state only."
}

on_device() {
	mkdir -p "$OUT_DEV"
	echo $$ >/run/dagu-dpu-watch.pid
	arm_trace
	prev=$(dmesg | grep -c "vblank timeout:" || true)
	while true; do
		cur=$(dmesg | grep -c "vblank timeout:" || true)
		if [ "$cur" -gt "$prev" ]; then
			ts=$(date +%Y%m%d-%H%M%S)
			out="$OUT_DEV/dpu-timeout-$ts"
			mkdir -p "$out"
			dmesg -T | grep -E "vblank timeout|commit done|underrun|underflow|dsc|DSC" \
				>"$out/dmesg.txt" || true
			if [ -f "$TR/trace" ]; then
				cat "$TR/trace" >"$out/trace.txt"
			else
				echo "CONFIG_FTRACE=n" >"$out/trace.txt"
			fi
			cat /sys/kernel/debug/dri/0/state >"$out/drm-state.txt" || true
			cat /sys/kernel/debug/dri/0/crtc-0/status >"$out/crtc.txt" || true
			echo "$cur" >"$out/timeout_count"
			echo "dpu-watch: dumped $out (timeouts $prev → $cur)"
			prev=$cur
		fi
		sleep 0.4
	done
}

case "${1:-}" in
--host)
	"${SSH[@]}" "mkdir -p /usr/local/sbin $OUT_DEV; cat >$REMOTE && chmod 755 $REMOTE" <"$0"
	# Do not pkill -f the script name here: it matches this SSH argv.
	"${SSH[@]}" "kill \$(cat /run/dagu-dpu-watch.pid 2>/dev/null) 2>/dev/null || true; \
		setsid -f $REMOTE >/var/log/dagu-dpu/watch.log 2>&1"
	echo "armed on $HOST; pull later with --pull"
	;;
--pull)
	mkdir -p "$OUT_HOST"
	"${SCP[@]}" -r "root@$HOST:$OUT_DEV/." "$OUT_HOST/" || true
	echo "pulled $OUT_HOST"
	;;
--stop)
	"${SSH[@]}" "echo 0 >$TR/tracing_on; echo 0 >$TR/events/dpu/enable; \
		kill \$(cat /run/dagu-dpu-watch.pid 2>/dev/null) 2>/dev/null || true"
	;;
*)
	on_device
	;;
esac
