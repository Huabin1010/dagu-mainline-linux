#!/usr/bin/env bash
# Install the off-mode charger on a live tablet. Does not flash the kernel.
# Serial gadget (0525:a4a7). Does not reboot.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DAGU_TTY="${DAGU_TTY:-/dev/ttyACM1}"
CONSOLE=(python3 "$ROOT/scripts/dagu-console.py")

put() {
	echo "==> $2"
	"${CONSOLE[@]}" put "$1" "$2"
}

put "$ROOT/scripts/dagu_offmode_charger.py" /usr/local/sbin/dagu-offmode-charger
put "$ROOT/systemd/dagu-offmode-gate.service" /etc/systemd/system/dagu-offmode-gate.service
put "$ROOT/systemd/dagu-offmode-charger.service" /etc/systemd/system/dagu-offmode-charger.service
put "$ROOT/systemd/dagu-offmode-pending.service" /etc/systemd/system/dagu-offmode-pending.service
put "$ROOT/systemd/gdm-dagu-charger.conf" /etc/systemd/system/gdm.service.d/dagu-charger.conf
put "$ROOT/systemd/logind-dagu-power.conf" /etc/systemd/logind.conf.d/dagu-power.conf

echo "==> enable"
"${CONSOLE[@]}" run 'mkdir -p /var/lib/dagu /etc/systemd/system/gdm.service.d /etc/systemd/system/poweroff.target.wants /etc/systemd/system/multi-user.target.wants && chmod 755 /usr/local/sbin/dagu-offmode-charger && ln -sfn /etc/systemd/system/dagu-offmode-gate.service /etc/systemd/system/multi-user.target.wants/dagu-offmode-gate.service && rm -f /etc/systemd/system/multi-user.target.wants/dagu-offmode-charger.service && chmod 644 /etc/systemd/system/dagu-offmode-*.service /etc/systemd/system/gdm.service.d/dagu-charger.conf && rm -f /etc/systemd/system/dagu-offmode-daemon.service /etc/systemd/system/multi-user.target.wants/dagu-offmode-daemon.service && ln -sfn /etc/systemd/system/dagu-offmode-pending.service /etc/systemd/system/poweroff.target.wants/dagu-offmode-pending.service && echo LINKS_OK'
"${CONSOLE[@]}" run 'systemctl stop dagu-offmode-daemon.service 2>/dev/null; systemctl daemon-reload && systemctl enable dagu-offmode-gate.service dagu-offmode-pending.service && echo ENABLE_OK'
"${CONSOLE[@]}" run '/usr/local/sbin/dagu-offmode-charger gate; echo GATE_RC:$?; /usr/local/sbin/dagu-offmode-charger status; if test -f /run/dagu-charger-mode; then echo FLAG:yes; else echo FLAG:no; fi; systemctl is-active gdm'
