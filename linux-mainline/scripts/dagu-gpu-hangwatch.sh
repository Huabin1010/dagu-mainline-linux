#!/usr/bin/env bash
# Watch Adreno hangcheck on dagu and dump the hanging cmdstream.
#
# On the tablet (root):
#   ./scripts/dagu-gpu-hangwatch.sh
# From the host:
#   ./scripts/dagu-gpu-hangwatch.sh --host          # start watcher
#   ./scripts/dagu-gpu-hangwatch.sh --pull          # copy dumps back
#
# msm debugfs:
#   /sys/kernel/debug/dri/0/hangrd  — blocks until the next GPU hang, then
#                                     emits a freedreno .rd of the last IB
#   /sys/kernel/debug/dri/0/rd      — every submit (huge; leave closed)
#   /sys/module/msm/parameters/rd_full — Y dumps the full cmdstream into hangrd
#
# 00800005 is a CCU/CP fault (logic / cmdstream), not a thermal timeout.
# GPU thermals in the 50s °C with simple_ondemand @ 670 MHz are not a wall.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${DAGU_SSH_HOST:-192.168.7.2}"
KEY="${DAGU_SSH_KEY:-$ROOT/out/id_dagu}"
OUT_HOST="${DAGU_HANG_OUT:-$ROOT/out/gpu-hang}"
OUT_DEV="${DAGU_HANG_DEV:-/var/log/dagu-gpu}"
REMOTE_BIN=/usr/local/sbin/dagu-gpu-hangwatch.sh
PIDFILE=/run/dagu-hangwatch.pid

SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o ConnectTimeout=12 "root@$HOST")
SCP=(scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

on_device() {
	mkdir -p "$OUT_DEV"
	# hangrd is EBUSY unless the GPU just hung. Do not cat it in a loop.
	echo 1 > /sys/module/msm/parameters/rd_full
	echo "hangwatch: rd_full=Y hangcheck_period=$(cat /sys/kernel/debug/dri/0/hangcheck_period_ms)ms"
	echo "hangwatch: writing $OUT_DEV on new hangcheck recover (Ctrl-C to stop)"
	prev=$(dmesg | grep -c "hangcheck recover" || true)
	n=0
	while true; do
		cur=$(dmesg | grep -c "hangcheck recover" || true)
		if [ "$cur" -gt "$prev" ]; then
			n=$((n + 1))
			stamp=$(date +%Y%m%d-%H%M%S)
			rd="$OUT_DEV/hang-$stamp-$n.rd"
			meta="$OUT_DEV/hang-$stamp-$n.txt"
			{
				echo "==== hung $stamp recover $prev -> $cur ===="
				echo -n "cur_freq="; cat /sys/class/devfreq/3d00000.gpu/cur_freq
				echo -n "governor="; cat /sys/class/devfreq/3d00000.gpu/governor
				echo -n "gpu_temp_tz15="; cat /sys/class/thermal/thermal_zone15/temp 2>/dev/null
				echo -n "gpu_temp_tz24="; cat /sys/class/thermal/thermal_zone24/temp 2>/dev/null
				dmesg | grep -E "gpu fault|hangcheck|00800005" | tail -n 40
			} > "$meta"
			# May be EBUSY if recover already released the dump.
			cat /sys/kernel/debug/dri/0/hangrd > "$rd" 2>>"$meta" || true
			echo "rd_bytes=$(wc -c < "$rd" 2>/dev/null || echo 0)" >> "$meta"
			echo "hangwatch: recover $cur dumped $rd"
			prev=$cur
		fi
		sleep 1
	done
}

case "${1:-}" in
--host)
	"${SCP[@]}" "$ROOT/scripts/dagu-gpu-hangwatch.sh" "root@$HOST:$REMOTE_BIN"
	"${SSH[@]}" "chmod +x $REMOTE_BIN
		if [ -f $PIDFILE ]; then kill \$(cat $PIDFILE) 2>/dev/null || true; rm -f $PIDFILE; fi
		mkdir -p $OUT_DEV
		nohup $REMOTE_BIN >/tmp/dagu-hangwatch.log 2>&1 & echo \$! > $PIDFILE
		echo hangwatch_pid=\$(cat $PIDFILE)"
	;;
--pull)
	mkdir -p "$OUT_HOST"
	"${SCP[@]}" -r "root@$HOST:$OUT_DEV/." "$OUT_HOST/" || true
	echo "pulled into $OUT_HOST"
	;;
--stop)
	"${SSH[@]}" "if [ -f $PIDFILE ]; then kill \$(cat $PIDFILE) 2>/dev/null || true; rm -f $PIDFILE; fi; echo stopped"
	;;
"" )
	if [[ -e /sys/kernel/debug/dri/0/hangrd ]]; then
		on_device
	else
		echo "not on the tablet; use: $0 --host" >&2
		exit 1
	fi
	;;
*)
	echo "usage: $0 [--host|--pull|--stop]" >&2
	exit 2
	;;
esac
