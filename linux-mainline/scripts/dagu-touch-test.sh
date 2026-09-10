#!/usr/bin/env bash
# 把触控测试推到 dagu 并运行。对照 ginkgo 的 ginkgo-touch-test.sh。
#   ./scripts/dagu-touch-test.sh --probe   # 只列 /dev/input
#   ./scripts/dagu-touch-test.sh           # 画屏；resin/音量- 或串口回车退出
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/scripts/dagu-touch-test.py"
REMOTE=/usr/local/sbin/dagu-touch-test.py
PHONE_IP="${PHONE_IP:-192.168.7.2}"
SSH_USER="${SSH_USER:-root}"
PASS_FILE="$ROOT/out/root-password"

if [[ ! -f "$SRC" ]]; then
	echo "missing $SRC" >&2
	exit 1
fi

ssh_ready() {
	ping -c 1 -W 1 "$PHONE_IP" >/dev/null 2>&1
}

ssh_cmd() {
	local extra=()
	if [[ -f "$ROOT/out/id_dagu" ]]; then
		extra+=(-i "$ROOT/out/id_dagu")
	fi
	if [[ -f "$PASS_FILE" ]] && command -v sshpass >/dev/null; then
		SSHPASS="$(tr -d '\n' <"$PASS_FILE")" sshpass -e \
			ssh "${extra[@]}" -o StrictHostKeyChecking=accept-new \
			-o ConnectTimeout=8 "${SSH_USER}@${PHONE_IP}" "$@"
	else
		ssh "${extra[@]}" -o StrictHostKeyChecking=accept-new \
			-o ConnectTimeout=8 "${SSH_USER}@${PHONE_IP}" "$@"
	fi
}

push_via_ssh() {
	"$ROOT/scripts/usb-connect.sh"
	if [[ -f "$PASS_FILE" ]] && command -v sshpass >/dev/null; then
		SSHPASS="$(tr -d '\n' <"$PASS_FILE")" sshpass -e \
			scp -o StrictHostKeyChecking=accept-new "$SRC" "${SSH_USER}@${PHONE_IP}:${REMOTE}"
	else
		scp -o StrictHostKeyChecking=accept-new "$SRC" "${SSH_USER}@${PHONE_IP}:${REMOTE}"
	fi
	ssh_cmd "chmod +x ${REMOTE}"
}

push_via_serial() {
	if ! lsusb | grep -qi '0525:a4a7'; then
		echo "no g_serial 0525:a4a7 and no RNDIS ${PHONE_IP}" >&2
		lsusb | grep -iE '0525|1d6b|18d1' || true
		exit 1
	fi
	python3 "$ROOT/scripts/dagu-console.py" put "$SRC" "$REMOTE"
}

if ssh_ready; then
	echo "==> RNDIS ${PHONE_IP}"
	push_via_ssh
	if [[ "${1:-}" == "--probe" ]]; then
		ssh_cmd "python3 ${REMOTE} --probe"
	else
		echo "平板屏幕会变成测试图。点屏幕看点；resin/音量- 退出。"
		echo "Ctrl-C 也会停，退出后会把 GDM 拉起来。"
		ssh_cmd "python3 -u ${REMOTE}"
	fi
else
	echo "==> g_serial /dev/ttyACM0（无 RNDIS）"
	push_via_serial
	if [[ "${1:-}" == "--probe" ]]; then
		python3 "$ROOT/scripts/dagu-console.py" run "python3 ${REMOTE} --probe"
	else
		echo "平板屏幕会变成测试图（会短暂停 GDM 才能画 fb0）。"
		echo "resin/音量- 或这边回车退出；Ctrl-C 也会停。"
		python3 "$ROOT/scripts/dagu-console.py" stream "python3 -u ${REMOTE}"
	fi
fi
