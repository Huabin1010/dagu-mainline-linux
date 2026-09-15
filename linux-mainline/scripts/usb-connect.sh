#!/usr/bin/env bash
# Host RNDIS -> 192.168.7.2 (run after fastboot boot).
set -euo pipefail

HOST_IP="${HOST_IP:-192.168.7.1/24}"
PHONE_IP="${PHONE_IP:-192.168.7.2}"
WAIT_PING="${WAIT_PING:-60}"

sudo_cmd() {
	if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
		"$@"
	else
		sudo "$@"
	fi
}

find_rndis_iface() {
	local name driver
	for name in /sys/class/net/*; do
		name=$(basename "$name")
		[[ "$name" == lo ]] && continue
		driver=$(readlink -f "/sys/class/net/$name/device/driver" 2>/dev/null || true)
		if [[ "$driver" == *rndis* ]] || [[ "$driver" == *cdc_ether* ]] || [[ "$name" == enx* ]]; then
			echo "$name"
			return 0
		fi
	done
	return 1
}

iface=""
for _ in $(seq 1 45); do
	iface=$(find_rndis_iface || true)
	[[ -n "$iface" ]] && break
	sleep 1
done
[[ -n "$iface" ]] || { echo "error: no RNDIS iface" >&2; ip -br link; exit 1; }

if command -v nmcli &>/dev/null; then
	sudo_cmd nmcli device set "$iface" managed no || true
fi
sudo_cmd ip link set "$iface" up
sudo_cmd ip addr flush dev "$iface" || true
sudo_cmd ip addr add "$HOST_IP" dev "$iface"
echo "==> $iface  ${HOST_IP%%/*} -> $PHONE_IP"

host_addr="${HOST_IP%%/*}"
for ((i = 1; i <= WAIT_PING; i++)); do
	if ping -c1 -W1 -I "$host_addr" "$PHONE_IP" &>/dev/null; then
		echo "==> ping OK (${i}s)"
		echo "SSH: ssh -o StrictHostKeyChecking=no root@$PHONE_IP"
		exit 0
	fi
	sleep 1
done
echo "error: $PHONE_IP not responding" >&2
exit 1
