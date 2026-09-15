#!/usr/bin/env bash
# Unbound workqueue affinity: cache → system.
# B-kick-kernel: drmModeAtomicCommit queues on system_unbound_wq;
# cache-scope left the work on a sleeping LLC for ~90 ms while
# gnome-shell and KMS were already in ppoll. system lets any awake
# CPU run commit_work. Does not chrt kworkers. Does not flash.
# apply/restore are live sysfs; persist via dagu-wq-affinity.service.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEY="$ROOT/linux-mainline/out/id_dagu"
HOST="${DAGU_HOST:-192.168.7.2}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST")
PARAM=/sys/module/workqueue/parameters/default_affinity_scope

cmd="${1:-status}"

case "$cmd" in
  status|apply|restore)
    "${SSH[@]}" bash -s "$cmd" <<'EOF'
set -euo pipefail
cmd=$1
p=/sys/module/workqueue/parameters/default_affinity_scope
cur=$(cat "$p")
case "$cmd" in
  status) echo "default_affinity_scope=$cur" ;;
  apply)
    echo system > "$p"
    echo "default_affinity_scope=$(cat "$p") (was $cur)"
    ;;
  restore)
    echo cache > "$p"
    echo "default_affinity_scope=$(cat "$p") (was $cur)"
    ;;
esac
EOF
    ;;
  *)
    echo "usage: $0 {status|apply|restore}" >&2
    exit 2
    ;;
esac
