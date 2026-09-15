#!/usr/bin/env bash
# Dump Chrome/Ozone dma-buf fences on dagu. Mainline msm has no KGSL.
#
# On the tablet (root):  ./scripts/dagu-chrome-fence-probe.sh
# From the host:         ./scripts/dagu-chrome-fence-probe.sh --host
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${DAGU_SSH_HOST:-192.168.7.2}"
KEY="${DAGU_SSH_KEY:-$ROOT/out/id_dagu}"
OUT_HOST="${DAGU_FENCE_OUT:-$ROOT/out/display-stress}"

SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o ConnectTimeout=12 "root@$HOST")

device_body() {
	mkdir -p /tmp/dagu-reclaim
	stamp=$(date +%Y%m%d-%H%M%S)
	out=/tmp/dagu-reclaim/chrome-fence-$stamp.txt
	{
		echo "stamp=$stamp"
		grep -oE "androidboot.serialno=[^ ]+|androidboot.slot_suffix=[^ ]+" /proc/cmdline || true
		echo -n "hangcheck="; dmesg | grep -c "hangcheck recover" || true
		echo "==== chrome / electron pids ===="
		ps -eo pid,user,rss,cmd | grep -E "[c]hrome|[m]ineradio|[e]lectron" || true
		echo "==== wrapper flags ===="
		grep -n "partial-swap\|PartialSwap\|WaylandLinuxDrmSyncobj" \
			/usr/local/bin/dagu-chrome /usr/local/bin/mineradio 2>/dev/null || true
		echo "==== live chrome cmdline ===="
		for p in $(pgrep -f "/opt/google/chrome/chrome" || true); do
			echo "-- pid $p --"
			tr '\0' ' ' < "/proc/$p/cmdline"; echo
			echo -n "fd="; ls "/proc/$p/fd" 2>/dev/null | wc -l
		done
		echo "==== dma_buf bufinfo ===="
		cat /sys/kernel/debug/dma_buf/bufinfo 2>/dev/null || echo missing
		echo "==== fence summary ===="
		python3 - <<'PY'
from pathlib import Path
p = Path("/sys/kernel/debug/dma_buf/bufinfo")
if not p.exists():
    raise SystemExit(0)
text = p.read_text(errors="replace")
ex = sh = unset = write_sig = write_live = 0
for line in text.splitlines():
    l = line.lower()
    if "write fence" in l:
        if "signalled" in l or "signaled" in l:
            write_sig += 1
        else:
            write_live += 1
    if "exclusive fence" in l or "excl fence" in l:
        if "(unset)" in l or "(none)" in l or "null" in l or l.strip().endswith(":"):
            unset += 1
        else:
            ex += 1
    if "shared fence" in l:
        sh += 1
print(f"write_signalled={write_sig} write_live={write_live} exclusive_set={ex} exclusive_unset={unset} shared={sh} bytes={len(text)}")
PY
	} >"$out"
	echo "$out"
}

case "${1:-}" in
--host)
	mkdir -p "$OUT_HOST"
	scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		"$ROOT/scripts/dagu-chrome-fence-probe.sh" \
		"root@$HOST:/usr/local/sbin/dagu-chrome-fence-probe.sh"
	rpath=$("${SSH[@]}" "chmod +x /usr/local/sbin/dagu-chrome-fence-probe.sh; /usr/local/sbin/dagu-chrome-fence-probe.sh")
	scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		"root@$HOST:$rpath" "$OUT_HOST/$(basename "$rpath")"
	echo "pulled $OUT_HOST/$(basename "$rpath")"
	;;
"" )
	if [ -e /sys/kernel/debug/dma_buf/bufinfo ]; then
		device_body
	else
		echo "not on the tablet; use: $0 --host" >&2
		exit 1
	fi
	;;
*)
	echo "usage: $0 [--host]" >&2
	exit 2
	;;
esac
