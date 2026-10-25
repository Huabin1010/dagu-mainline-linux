#!/bin/sh
# RF check against a known peer (the build PC's Bluetooth, made
# discoverable). Inquiry, then page the peer, N times; report page time
# and status, inquiry RSSI of the peer, and echo RTTs.
# VDD_ASD off: 0/10 pages, peer never heard. On: 9/10, median 0.9 s.
# Usage: dagu-bt-page-loop.sh <peer BD_ADDR> <tag> [N]
PEER=$1
TAG=$2
N=${3:-10}
OUT=/root/bt-peer
mkdir -p "$OUT"
timeout 600 btmon -w "$OUT/$TAG-page.snoop" >/dev/null 2>&1 &
BTMON=$!
sleep 1
i=0
while [ $i -lt "$N" ]; do
	timeout 9 hcitool -i hci0 inq --length=3 >/dev/null 2>&1
	timeout 12 l2ping -c 3 -i 0.2 -s 40 "$PEER" >>"$OUT/$TAG-page.l2ping" 2>&1
	sleep 1
	i=$((i + 1))
done
kill $BTMON 2>/dev/null
wait
btmon -r "$OUT/$TAG-page.snoop" 2>/dev/null >"$OUT/$TAG-page.txt"
python3 - "$OUT/$TAG-page.txt" "$OUT/$TAG-page.l2ping" "$PEER" <<'EOF' | tee "$OUT/$TAG-page.result"
import re, sys, statistics
txt, ping, peer = sys.argv[1:]
t0 = None
pages = []
rssi = []
last = None
for line in open(txt, errors="replace"):
    m = re.search(r"\[hci0\] (\d+\.\d+)", line)
    ts = float(m.group(1)) if m else None
    if "Create Connection (0x01|0x0005) plen" in line:
        t0 = ts
    elif "Connect Complete (0x03)" in line:
        last = ("cc", ts)
    elif "Inquiry Result" in line:
        last = ("inq", ts)
    elif last and last[0] == "cc" and "Status:" in line and t0 is not None:
        pages.append((line.split("Status:")[1].strip(), last[1] - t0))
        t0 = None
        last = None
    elif last and last[0] == "inq" and re.search(r"^\s+RSSI: (-?\d+)", line):
        rssi.append(int(re.search(r"RSSI: (-?\d+)", line).group(1)))
ok = [d for s, d in pages if s.startswith("Success")]
print(f"pages={len(pages)} ok={len(ok)} fail={len(pages)-len(ok)}")
if ok:
    print(f"page ok ms: med={statistics.median(ok)*1000:.0f} max={max(ok)*1000:.0f}")
for s, d in pages:
    if not s.startswith("Success"):
        print(f"  fail {s} after {d*1000:.0f} ms")
if rssi:
    print(f"tablet sees PC (inquiry) n={len(rssi)} med={statistics.median(rssi)} min={min(rssi)} max={max(rssi)}")
rtt = [float(x) for x in re.findall(r"time ([\d.]+)ms", open(ping).read())]
if rtt:
    rtt.sort()
    print(f"echo n={len(rtt)} med={statistics.median(rtt):.1f} p90={rtt[int(len(rtt)*0.9)-1]:.1f} max={rtt[-1]:.1f} ms")
EOF
