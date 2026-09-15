#!/usr/bin/env bash
# Watch Mineradio (Electron) for FD leak / RSS blow-up / GPU hang.
# Mainline msm has no /sys/kernel/debug/kgsl — use /proc fd + smaps + hangcheck.
#
# On the tablet (root):
#   ./scripts/dagu-mineradio-watch.sh
#   ./scripts/dagu-mineradio-watch.sh --once
# From the host:
#   ./scripts/dagu-mineradio-watch.sh --host
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${DAGU_SSH_HOST:-192.168.7.2}"
KEY="${DAGU_SSH_KEY:-$ROOT/out/id_dagu}"
OUT_DEV="${DAGU_RADIO_LOG:-/var/log/dagu-mineradio}"
INTERVAL="${DAGU_RADIO_INTERVAL:-5}"

pick_pid() {
	pgrep -n -f /opt/Mineradio/mineradio || pgrep -n -f mineradio || true
}

sample() {
	mkdir -p "$OUT_DEV"
	log="$OUT_DEV/watch.tsv"
	if [ ! -f "$log" ]; then
		printf 'ts\tpid\tfd\trss_kb\tvms_kb\thangcheck\tvram\n' >"$log"
	fi
	pid=$(pick_pid)
	if [ -z "$pid" ]; then
		printf '%s\t-\t-\t-\t-\t%s\t-\n' "$(date +%s)" \
			"$(dmesg | grep -c 'hangcheck recover' || true)" >>"$log"
		echo "mineradio: not running"
		return 0
	fi
	fd=$(ls "/proc/$pid/fd" 2>/dev/null | wc -l)
	rss=$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)
	vms=$(awk '/^VmSize:/{print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)
	hang=$(dmesg | grep -c "hangcheck recover" || true)
	vram="-"
	if [ -r /sys/class/drm/card0/device/mem_info_vram_used ]; then
		vram=$(cat /sys/class/drm/card0/device/mem_info_vram_used)
	fi
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$pid" "$fd" "$rss" "$vms" "$hang" "$vram" >>"$log"
	echo "pid=$pid fd=$fd rss_kb=$rss hangcheck=$hang vram=$vram"
	if [ "$fd" -gt 900 ]; then
		echo "WARN: fd=$fd approaching 1024" >&2
	fi
	if dmesg | tail -n 40 | grep -q "00800005"; then
		echo "WARN: recent 00800005 hangcheck in dmesg" >&2
	fi
}

case "${1:-}" in
--host)
	scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		"$ROOT/scripts/dagu-mineradio-watch.sh" \
		"root@$HOST:/usr/local/sbin/dagu-mineradio-watch.sh"
	ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		"root@$HOST" "chmod +x /usr/local/sbin/dagu-mineradio-watch.sh
		mkdir -p $OUT_DEV
		if [ -f /run/dagu-mineradio-watch.pid ]; then
			kill \$(cat /run/dagu-mineradio-watch.pid) 2>/dev/null || true
		fi
		nohup /usr/local/sbin/dagu-mineradio-watch.sh >$OUT_DEV/watch.out 2>&1 &
		echo \$! > /run/dagu-mineradio-watch.pid
		echo watch_pid=\$(cat /run/dagu-mineradio-watch.pid)"
	;;
--stop)
	ssh -i "$KEY" -o StrictHostKeyChecking=no "root@$HOST" \
		'if [ -f /run/dagu-mineradio-watch.pid ]; then kill $(cat /run/dagu-mineradio-watch.pid) 2>/dev/null || true; rm -f /run/dagu-mineradio-watch.pid; fi; echo stopped'
	;;
--pull)
	mkdir -p "$ROOT/out/display-stress"
	scp -i "$KEY" -o StrictHostKeyChecking=no -r \
		"root@$HOST:$OUT_DEV/." "$ROOT/out/display-stress/mineradio-watch/" || true
	;;
--once)
	sample
	;;
"" )
	if [ ! -e /proc/self ]; then
		echo "not on the tablet; use: $0 --host" >&2
		exit 1
	fi
	echo "watching every ${INTERVAL}s -> $OUT_DEV/watch.tsv"
	while true; do
		sample || true
		sleep "$INTERVAL"
	done
	;;
*)
	echo "usage: $0 [--host|--stop|--pull|--once]" >&2
	exit 2
	;;
esac
