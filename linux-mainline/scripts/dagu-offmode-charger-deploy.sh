#!/usr/bin/env bash
# Push off-mode charger (Android charger-mode) to a live dagu. No kernel flash.
# Prefers Wi-Fi SSH; falls back to g_serial /dev/ttyACM0.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${DAGU_HOST:-${DAGU_SSH_HOST:-192.168.7.2}}"
KEY="${DAGU_SSH_KEY:-$ROOT/out/id_dagu}"
SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "root@$HOST")
SCP=(scp -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null)
CONSOLE=(python3 "$ROOT/scripts/dagu-console.py")

have_ssh() {
	timeout 12 "${SSH[@]}" true >/dev/null 2>&1
}

enable_units() {
	cat <<'EOF'
set -e
sudo chmod 755 /usr/local/sbin/dagu-offmode-charger
sudo mkdir -p /var/lib/dagu \
	/etc/systemd/system/gdm.service.d \
	/etc/systemd/system/multi-user.target.wants \
	/etc/systemd/system/poweroff.target.wants \
	/etc/systemd/system/dagu-charger.target.wants \
	/etc/systemd/logind.conf.d
sudo ln -sfn /etc/systemd/system/dagu-offmode-gate.service \
	/etc/systemd/system/multi-user.target.wants/dagu-offmode-gate.service
sudo ln -sfn /etc/systemd/system/dagu-offmode-charger.service \
	/etc/systemd/system/multi-user.target.wants/dagu-offmode-charger.service
sudo ln -sfn /etc/systemd/system/dagu-offmode-daemon.service \
	/etc/systemd/system/multi-user.target.wants/dagu-offmode-daemon.service
sudo ln -sfn /etc/systemd/system/dagu-offmode-pending.service \
	/etc/systemd/system/poweroff.target.wants/dagu-offmode-pending.service
sudo ln -sfn /etc/systemd/system/dagu-offmode-charger.service \
	/etc/systemd/system/dagu-charger.target.wants/dagu-offmode-charger.service
sudo systemctl daemon-reload
sudo systemctl enable dagu-offmode-gate.service dagu-offmode-charger.service \
	dagu-offmode-daemon.service dagu-offmode-pending.service
sudo systemctl restart dagu-offmode-daemon.service || true
sudo /usr/local/sbin/dagu-offmode-charger status || true
echo DAGU_OFFMODE_DEPLOY_OK
EOF
}

copy_ssh() {
	"${SSH[@]}" 'mkdir -p /usr/local/sbin /etc/systemd/system/gdm.service.d /etc/systemd/logind.conf.d /var/lib/dagu'
	"${SCP[@]}" \
		"$ROOT/scripts/dagu_offmode_charger.py" \
		"root@$HOST:/usr/local/sbin/dagu-offmode-charger"
	"${SCP[@]}" \
		"$ROOT/systemd/dagu-charger.target" \
		"$ROOT/systemd/dagu-offmode-gate.service" \
		"$ROOT/systemd/dagu-offmode-charger.service" \
		"$ROOT/systemd/dagu-offmode-daemon.service" \
		"$ROOT/systemd/dagu-offmode-pending.service" \
		"root@$HOST:/etc/systemd/system/"
	"${SCP[@]}" \
		"$ROOT/systemd/gdm-dagu-charger.conf" \
		"root@$HOST:/etc/systemd/system/gdm.service.d/dagu-charger.conf"
	"${SCP[@]}" \
		"$ROOT/systemd/logind-dagu-power.conf" \
		"root@$HOST:/etc/systemd/logind.conf.d/dagu-power.conf"
	"${SSH[@]}" 'bash -s' <"$ROOT/scripts/dagu-offmode-charger-enable.sh"
}

copy_serial() {
	"${CONSOLE[@]}" put "$ROOT/scripts/dagu_offmode_charger.py" \
		/tmp/dagu-offmode-charger
	"${CONSOLE[@]}" put "$ROOT/systemd/dagu-charger.target" \
		/tmp/dagu-charger.target
	"${CONSOLE[@]}" put "$ROOT/systemd/dagu-offmode-gate.service" \
		/tmp/dagu-offmode-gate.service
	"${CONSOLE[@]}" put "$ROOT/systemd/dagu-offmode-charger.service" \
		/tmp/dagu-offmode-charger.service
	"${CONSOLE[@]}" put "$ROOT/systemd/dagu-offmode-daemon.service" \
		/tmp/dagu-offmode-daemon.service
	"${CONSOLE[@]}" put "$ROOT/systemd/dagu-offmode-pending.service" \
		/tmp/dagu-offmode-pending.service
	"${CONSOLE[@]}" put "$ROOT/systemd/gdm-dagu-charger.conf" \
		/tmp/gdm-dagu-charger.conf
	"${CONSOLE[@]}" put "$ROOT/systemd/logind-dagu-power.conf" \
		/tmp/dagu-power.conf
	"${CONSOLE[@]}" put "$ROOT/scripts/dagu-offmode-charger-enable.sh" \
		/tmp/dagu-offmode-charger-enable.sh
	"${CONSOLE[@]}" run 'sudo bash /tmp/dagu-offmode-charger-enable.sh'
}

if have_ssh; then
	echo "==> Wi-Fi SSH $HOST"
	copy_ssh
elif [[ -e /dev/ttyACM0 ]]; then
	echo "==> g_serial /dev/ttyACM0"
	copy_serial
else
	echo "no SSH to $HOST and no /dev/ttyACM0" >&2
	exit 1
fi
