#!/bin/sh
# Print the lab HTML dump over SSH. No screenshots.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
KEY="${DAGU_SSH_KEY:-$ROOT/out/id_dagu}"
HOST="${DAGU_SSH_HOST:-192.168.7.2}"
ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o ConnectTimeout=10 -o ControlMaster=no \
	"root@$HOST" 'python3 - <<"PY"
import json, urllib.request
raw = urllib.request.urlopen("http://127.0.0.1:8770/api/dump", timeout=4).read()
d = json.loads(raw.decode())
hw = d.get("hw") or d.get("host") or {}
v = d.get("verdict") or {}
print("fps", d.get("fps"), "p50", d.get("p50"), "p99", d.get("p99"), "n", d.get("n"))
print("videos", d.get("videos"), "holes", d.get("holes"))
print("venus", hw.get("venus_irq"), "v14_open", hw.get("video14_open"), "mem", hw.get("mem_avail_mb"), "M", hw.get("pressure"))
print("chrome_rss", hw.get("chrome_rss_mb"), "M  shmem", hw.get("shmem_mb"), "M")
print("verdict", json.dumps(v, ensure_ascii=False))
print("---json---")
print(json.dumps(d, indent=2, ensure_ascii=False)[:4000])
PY'
