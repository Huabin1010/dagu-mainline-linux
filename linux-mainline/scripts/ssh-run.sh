#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT/scripts"
REMOTE_CMD="${*:-dmesg}"
KEY=()
if [[ -f "$ROOT/out/id_dagu" ]]; then
	KEY=(-i "$ROOT/out/id_dagu")
fi
"$SCRIPT_DIR/usb-connect.sh" >/dev/null
ssh "${KEY[@]}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o ConnectTimeout=10 root@192.168.7.2 "$REMOTE_CMD"
