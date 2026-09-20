#!/bin/sh
set -e
if [ -f /tmp/dagu-offmode-charger ]; then
	install -m755 /tmp/dagu-offmode-charger /usr/local/sbin/dagu-offmode-charger
fi
chmod 755 /usr/local/sbin/dagu-offmode-charger
mkdir -p /var/lib/dagu \
	/etc/systemd/system/gdm.service.d \
	/etc/systemd/system/multi-user.target.wants \
	/etc/systemd/system/poweroff.target.wants \
	/etc/systemd/system/dagu-charger.target.wants \
	/etc/systemd/logind.conf.d
if [ -f /tmp/dagu-charger.target ]; then
	install -m644 /tmp/dagu-charger.target \
		/tmp/dagu-offmode-gate.service \
		/tmp/dagu-offmode-charger.service \
		/tmp/dagu-offmode-daemon.service \
		/tmp/dagu-offmode-pending.service \
		/etc/systemd/system/
fi
if [ -f /tmp/gdm-dagu-charger.conf ]; then
	install -m644 /tmp/gdm-dagu-charger.conf \
		/etc/systemd/system/gdm.service.d/dagu-charger.conf
fi
if [ -f /tmp/dagu-power.conf ]; then
	install -m644 /tmp/dagu-power.conf \
		/etc/systemd/logind.conf.d/dagu-power.conf
fi
ln -sfn /etc/systemd/system/dagu-offmode-gate.service \
	/etc/systemd/system/multi-user.target.wants/dagu-offmode-gate.service
ln -sfn /etc/systemd/system/dagu-offmode-charger.service \
	/etc/systemd/system/multi-user.target.wants/dagu-offmode-charger.service
ln -sfn /etc/systemd/system/dagu-offmode-daemon.service \
	/etc/systemd/system/multi-user.target.wants/dagu-offmode-daemon.service
ln -sfn /etc/systemd/system/dagu-offmode-pending.service \
	/etc/systemd/system/poweroff.target.wants/dagu-offmode-pending.service
ln -sfn /etc/systemd/system/dagu-offmode-charger.service \
	/etc/systemd/system/dagu-charger.target.wants/dagu-offmode-charger.service
systemctl daemon-reload
systemctl enable dagu-offmode-gate.service dagu-offmode-charger.service \
	dagu-offmode-daemon.service dagu-offmode-pending.service
systemctl restart dagu-offmode-daemon.service || true
echo DAGU_OFFMODE_DEPLOY_OK
