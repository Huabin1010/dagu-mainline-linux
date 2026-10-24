#!/bin/sh
# Run one s2idle cycle through logind and record which IRQs and wakeup
# sources fired across it. Results in /tmp/dagu-wake/. Run it detached
# (systemd-run --no-block) so the serial shell is not part of the cycle.
# If the tablet really sleeps, a power-key press finishes the run.
set -u
D=/tmp/dagu-wake
rm -rf "$D"; mkdir -p "$D"
snap_wake() {
	for w in /sys/class/wakeup/*; do
		printf '%s ev=%s act=%s wk=%s\n' "$(cat "$w/name")" \
			"$(cat "$w/event_count")" "$(cat "$w/active_count")" \
			"$(cat "$w/wakeup_count")"
	done
}
irqsum() {
	awk 'NR>1 { s=0; for (i=2;i<=NF;i++) { if ($i !~ /^[0-9]+$/) break; s+=$i }
	            n=$1; $1=""; print n, s, $0 }' /proc/interrupts
}
irqsum >"$D/irq.before"
snap_wake >"$D/wake.before"
cat /proc/uptime >"$D/log"
systemctl suspend
# Returns once the job is queued. A spurious wake finishes in ~1 s.
sleep 4
while systemctl is-active -q systemd-suspend.service || \
	[ "$(systemctl show -p ActiveState --value sleep.target)" = active ]; do
	sleep 0.5
done
cat /proc/uptime >>"$D/log"
irqsum >"$D/irq.after"
snap_wake >"$D/wake.after"
awk 'NR==FNR { b[$1]=$2; next }
     { d=$2-b[$1]; if (d>0) { n=$1; $1=""; $2=""; print d, n, $0 } }' \
	"$D/irq.before" "$D/irq.after" | sort -rn | cut -c1-160 >"$D/irq.diff"
diff "$D/wake.before" "$D/wake.after" >"$D/wake.diff"
journalctl -b -o short-monotonic -t kernel -n 120 --no-pager >"$D/kern"
echo done >>"$D/log"
