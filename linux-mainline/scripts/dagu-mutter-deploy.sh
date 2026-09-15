#!/usr/bin/env bash
# Swap libmutter-18.so.0.0.0 on the tablet. Lab-only. SIGQUIT gnome-shell.
# Does not flash the kernel. Does not stop gdm.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEY="$ROOT/linux-mainline/out/id_dagu"
HOST="${DAGU_HOST:-192.168.7.2}"
SO="${1:-$ROOT/linux-mainline/out/libmutter-18.so.0.0.0-dagu}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST")
SCP=(scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

if [[ ! -f "$SO" ]]; then
  echo "missing $SO" >&2
  exit 1
fi

# SONAME is libmutter-18.so.0 — do not treat that as an existing RPATH.
if ! aarch64-linux-gnu-readelf -d "$SO" | grep -E 'RPATH|RUNPATH' | grep -q 'mutter-18'; then
  patchelf --set-rpath '$ORIGIN/mutter-18' "$SO"
fi
file "$SO"
aarch64-linux-gnu-readelf -d "$SO" | grep -E 'SONAME|RPATH|RUNPATH'
echo "BuildID $(aarch64-linux-gnu-readelf -n "$SO" | awk '/Build ID/{print $NF}')"

"${SSH[@]}" 'set -e
  test -f /usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0
  mkdir -p /var/backups/dagu-mutter
  if [[ ! -f /var/backups/dagu-mutter/libmutter-18.so.0.0.0.stock-50.1-0ubuntu2.2 ]]; then
    cp -a /usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0 \
          /var/backups/dagu-mutter/libmutter-18.so.0.0.0.stock-50.1-0ubuntu2.2
  fi
  # A second SONAME in this dir makes ldconfig prefer the backup.
  rm -f /usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0.stock-* \
        /usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0.dagu
'
"${SCP[@]}" "$SO" "root@$HOST:/usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0.dagu.new"
"${SSH[@]}" 'set -e
  install -m 0644 /usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0.dagu.new \
                  /usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0
  rm -f /usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0.dagu.new \
        /usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0.dagu
  ln -sfn libmutter-18.so.0.0.0 /usr/lib/aarch64-linux-gnu/libmutter-18.so.0
  ldconfig
  # GDM respawns the session. Do not systemctl stop gdm.
  pkill -QUIT -u dagu -x gnome-shell || true
'
echo "swapped $SO onto $HOST; gnome-shell SIGQUIT"
echo "restore: ${SSH[*]} 'install -m 0644 /var/backups/dagu-mutter/libmutter-18.so.0.0.0.stock-50.1-0ubuntu2.2 /usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0 && ln -sfn libmutter-18.so.0.0.0 /usr/lib/aarch64-linux-gnu/libmutter-18.so.0 && ldconfig && pkill -QUIT -u dagu -x gnome-shell'"
