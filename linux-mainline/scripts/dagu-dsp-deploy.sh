#!/usr/bin/env bash
# Push CDSP/SLPI firmware + FastRPC/SEE clients to a live Linux dagu.
# Does not flash. Kernel DT must already okay &cdsp / &slpi.
# hexagonrpcd must attach SNS PD *before* dagu-ssc; otherwise sensor_pd dogs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${DAGU_HOST:-192.168.7.2}"
KEY="${DAGU_SSH_KEY:-$ROOT/out/id_dagu}"
SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "root@$HOST")
SCP=(scp -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null)
CONSOLE=(python3 "$ROOT/scripts/dagu-console.py")
CROSS="${CROSS_COMPILE:-aarch64-linux-gnu-}"
DSP="$ROOT/firmware/dagu/lib/firmware/qcom/sm8250/xiaomi/dagu"
SNS_DUMP="$ROOT/../dumps/dagu-android-live/sensors"
HFS_REL="usr/share/qcom/sm8250/Xiaomi/dagu"

have_ssh() {
	timeout 12 "${SSH[@]}" true >/dev/null 2>&1
}

is_elf() {
	[[ -x "$1" ]] && [[ "$(head -c 4 "$1")" == $'\x7fELF' ]]
}

[[ -f "$DSP/cdsp.mbn" && -f "$DSP/slpi.mbn" ]] || {
	echo "missing $DSP/{cdsp,slpi}.mbn — stage firmware first" >&2
	exit 1
}

make -C "$ROOT/userspace" CC="${CROSS}gcc" dagu-ssc dagu-cdsp-rpc
is_elf "$ROOT/userspace/dagu-ssc" || { echo "missing dagu-ssc" >&2; exit 1; }
is_elf "$ROOT/userspace/dagu-cdsp-rpc" || { echo "missing dagu-cdsp-rpc" >&2; exit 1; }

bash "$ROOT/scripts/build-hexagonrpcd.sh"
is_elf "$ROOT/out/hexagonrpc/hexagonrpcd" || { echo "missing hexagonrpcd" >&2; exit 1; }

# Mainline has no Qualcomm socinfo sysfs. sns_reg_config fopen()s these
# through HexagonFS /sys/devices/soc0 → $tree/socinfo/.
# soc_id 356 = SM8250 (DT qcom,msm-id 0x164). revision 2.1 = 0x20001.
# hw_platform DAGU is the Xiaomi board token in sns JSON filters.
stage_socinfo() {
	local dir="$1"
	mkdir -p "$dir"
	printf 'DAGU\n' >"$dir/hw_platform"
	printf 'UNKNOWN\n' >"$dir/platform_subtype"
	printf '0\n' >"$dir/platform_subtype_id"
	printf '65536\n' >"$dir/platform_version"
	printf '356\n' >"$dir/soc_id"
	printf '2.1\n' >"$dir/revision"
}

stage_hexagonfs_tree() {
	local tree="$1"
	mkdir -p "$tree/sensors/config" "$tree/sensors/registry" \
		"$tree/sensors/persist-registry/registry" "$tree/socinfo" "$tree/dsp/sdsp" "$tree/acdb"
	stage_socinfo "$tree/socinfo"
	if [[ -d "$SNS_DUMP/sns/sensors/config" ]]; then
		cp -a "$SNS_DUMP/sns/sensors/config/." "$tree/sensors/config/"
	fi
	if [[ -f "$SNS_DUMP/sns/sensors/sns_reg_config" ]]; then
		cp -a "$SNS_DUMP/sns/sensors/sns_reg_config" "$tree/sensors/sns_reg.conf"
	fi
	# HexagonFS maps /mnt/vendor/persist/sensors/registry to persist-registry/.
	# Android keeps sns_reg_version and temp.json as siblings of registry/.
	if [[ -d "$SNS_DUMP/persist/registry" ]]; then
		cp -a "$SNS_DUMP/persist/registry/." "$tree/sensors/persist-registry/"
	fi
	if [[ -d "$tree/sensors/persist-registry/registry" ]]; then
		cp -a "$tree/sensors/persist-registry/registry/." "$tree/sensors/registry/" 2>/dev/null || true
	fi
	if [[ ! -s "$tree/sensors/persist-registry/sns_reg_version" ]]; then
		printf 'version=4\0' >"$tree/sensors/persist-registry/sns_reg_version"
	fi
}

remote_install() {
	local run scp_cmd
	if have_ssh; then
		run() { "${SSH[@]}" "$@"; }
		scp_cmd() { "${SCP[@]}" "$@"; }
		DEST="root@$HOST"
	else
		run() { "${CONSOLE[@]}" run "$@"; }
		scp_cmd() { "${CONSOLE[@]}" put "$1" "$2"; DEST=""; }
		DEST=""
	fi

	local hfs_stage="$ROOT/out/hexagonfs-dagu"
	rm -rf "$hfs_stage"
	stage_hexagonfs_tree "$hfs_stage"

	run "mkdir -p /lib/firmware/qcom/sm8250/xiaomi/dagu /usr/local/sbin /usr/local/bin /usr/local/lib /etc/systemd/system /etc/udev/rules.d /$HFS_REL/sensors/config /$HFS_REL/sensors/registry /$HFS_REL/sensors/persist-registry/registry /$HFS_REL/socinfo /$HFS_REL/dsp/sdsp /etc/sensors/config /mnt/vendor/persist/sensors"
	# Running ELF cannot be overwritten (ETXTBSY). CDSP FastRPC stays attached.
	run "systemctl stop dagu-ssc.service hexagonrpcd-sdsp.service 2>/dev/null || true"
	if have_ssh; then
		"${SCP[@]}" "$DSP"/cdsp.* "$DSP"/slpi.* "$DSP"/*.jsn \
			"root@$HOST:/lib/firmware/qcom/sm8250/xiaomi/dagu/"
		"${SCP[@]}" "$ROOT/userspace/dagu-ssc" \
			"root@$HOST:/usr/local/sbin/dagu-ssc"
		"${SCP[@]}" "$ROOT/out/hexagonrpc/hexagonrpcd" \
			"root@$HOST:/usr/local/bin/hexagonrpcd"
		"${SCP[@]}" -p "$ROOT/out/hexagonrpc/"libhexagonrpc.so* \
			"root@$HOST:/usr/local/lib/"
		"${SCP[@]}" "$ROOT/systemd/dagu-ssc.service" \
			"$ROOT/systemd/dagu-cdsp-rpc.service" \
			"$ROOT/systemd/hexagonrpcd-sdsp.service" \
			"root@$HOST:/etc/systemd/system/"
		"${SCP[@]}" "$ROOT/udev/90-dagu-dsp.rules" \
			"root@$HOST:/etc/udev/rules.d/90-dagu-dsp.rules"
		if [[ -d "$hfs_stage/sensors" ]]; then
			tar -C "$hfs_stage" -cf - . | "${SSH[@]}" "tar -C /$HFS_REL -xf -"
		fi
		if [[ -d "$SNS_DUMP/sns/sensors/config" ]]; then
			tar -C "$SNS_DUMP/sns/sensors" -cf - config sns_reg_config 2>/dev/null \
				| "${SSH[@]}" "tar -C /etc/sensors -xf -" || true
		fi
		if [[ -d "$SNS_DUMP/persist" ]]; then
			tar -C "$SNS_DUMP/persist" -cf - . \
				| "${SSH[@]}" "tar -C /mnt/vendor/persist/sensors -xf -" || true
		fi
	else
		for f in "$DSP"/cdsp.* "$DSP"/slpi.* "$DSP"/*.jsn; do
			"${CONSOLE[@]}" put "$f" "/lib/firmware/qcom/sm8250/xiaomi/dagu/$(basename "$f")"
		done
		"${CONSOLE[@]}" put "$ROOT/userspace/dagu-ssc" /usr/local/sbin/dagu-ssc
		"${CONSOLE[@]}" put "$ROOT/userspace/dagu-cdsp-rpc" /usr/local/sbin/dagu-cdsp-rpc
		"${CONSOLE[@]}" put "$ROOT/out/hexagonrpc/hexagonrpcd" /usr/local/bin/hexagonrpcd
		"${CONSOLE[@]}" put "$ROOT/systemd/dagu-ssc.service" /etc/systemd/system/dagu-ssc.service
		"${CONSOLE[@]}" put "$ROOT/systemd/dagu-cdsp-rpc.service" /etc/systemd/system/dagu-cdsp-rpc.service
		"${CONSOLE[@]}" put "$ROOT/systemd/hexagonrpcd-sdsp.service" /etc/systemd/system/hexagonrpcd-sdsp.service
		"${CONSOLE[@]}" put "$ROOT/udev/90-dagu-dsp.rules" /etc/udev/rules.d/90-dagu-dsp.rules
	fi
	run 'chmod 755 /usr/local/sbin/dagu-ssc /usr/local/sbin/dagu-cdsp-rpc /usr/local/bin/hexagonrpcd
		ldconfig /usr/local/lib >/dev/null 2>&1 || true
		# Live SoC identity for HexagonFS /sys/devices/soc0
		for f in /sys/devices/soc0/*; do
			[ -f "$f" ] || continue
			cp -a "$f" /usr/share/qcom/sm8250/Xiaomi/dagu/socinfo/ 2>/dev/null || true
		done
		# Prefer already-copied Android tree if host dump was empty
		if [ ! -s /usr/share/qcom/sm8250/Xiaomi/dagu/sensors/sns_reg.conf ]; then
			if [ -f /etc/sensors/sns_reg_config ]; then
				cp -a /etc/sensors/sns_reg_config /usr/share/qcom/sm8250/Xiaomi/dagu/sensors/sns_reg.conf
			fi
			if [ -d /etc/sensors/config ]; then
				cp -a /etc/sensors/config/. /usr/share/qcom/sm8250/Xiaomi/dagu/sensors/config/ 2>/dev/null || true
			fi
			if [ -d /mnt/vendor/persist/sensors/registry/registry ]; then
				cp -a /mnt/vendor/persist/sensors/registry/registry/. /usr/share/qcom/sm8250/Xiaomi/dagu/sensors/registry/ 2>/dev/null || true
			elif [ -d /mnt/vendor/persist/sensors/registry ]; then
				cp -a /mnt/vendor/persist/sensors/registry/. /usr/share/qcom/sm8250/Xiaomi/dagu/sensors/registry/ 2>/dev/null || true
			fi
		fi
		udevadm control --reload
		systemctl daemon-reload
		systemctl stop dagu-ssc.service hexagonrpcd-sdsp.service 2>/dev/null || true
		# Fresh sensor_pd so fopen listener is registered before the 40s dog
		for d in /sys/class/remoteproc/remoteproc*; do
			[ "$(cat "$d/name" 2>/dev/null)" = slpi ] || continue
			echo stop >"$d/state" 2>/dev/null || true
			sleep 1
			echo start >"$d/state"
			echo "restarted $d"
		done
		for i in $(seq 1 20); do
			[ -e /dev/fastrpc-sdsp ] && break
			sleep 1
		done
		systemctl enable --now hexagonrpcd-sdsp.service dagu-cdsp-rpc.service
		sleep 2
		systemctl enable --now dagu-ssc.service
		systemctl enable --now iio-sensor-proxy.service || true
		echo ===remoteproc===
		for d in /sys/class/remoteproc/remoteproc*; do
			printf "%s name=%s state=%s\n" "$(basename "$d")" \
				"$(cat $d/name 2>/dev/null)" "$(cat $d/state 2>/dev/null)"
		done
		ls -l /dev/fastrpc-* 2>/dev/null || true
		echo ===hexagonfs===
		ls /usr/share/qcom/sm8250/Xiaomi/dagu/sensors/config 2>/dev/null | wc -l
		ls /usr/share/qcom/sm8250/Xiaomi/dagu/sensors/sns_reg.conf 2>/dev/null || true
		systemctl is-active hexagonrpcd-sdsp.service dagu-ssc.service dagu-cdsp-rpc.service
		journalctl -u hexagonrpcd-sdsp -n 40 --no-pager
		journalctl -u dagu-ssc -n 20 --no-pager
		dmesg | grep -iE "cdsp|slpi|fastrpc|pas|DOG|sensor_pd" | tail -30
	'
}

remote_install
echo "dagu-dsp-deploy: done"
