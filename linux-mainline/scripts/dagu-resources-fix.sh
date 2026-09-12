#!/bin/sh
# Make GNOME Resources show dagu sensors instead of PC-only sysfs names.
set -eu

RUN=/run/dagu
mkdir -p "$RUN" /usr/share/hwdata /usr/local/lib /usr/local/lib/dagu-resources-bin \
	/usr/local/share/applications /etc/systemd/system

# Resources' pci.ids parser splits on a *single* space. A "\t\tVID PID  Name"
# subdevice line with two spaces produces an empty token and aborts the whole
# file, so Manufacturer stays N/A even when 17cb/1101 is present.
if [ -f /usr/share/misc/pci.ids ]; then
	python3 - <<'PY'
from pathlib import Path
import re

src = Path("/usr/share/misc/pci.ids")
dst = Path("/usr/share/hwdata/pci.ids")
out = []
for line in src.read_text(errors="replace").splitlines(True):
	nl = line.endswith("\n")
	body = line[:-1] if nl else line
	if body.startswith("#") or body.startswith("C ") or body == "":
		out.append(line)
		continue
	if body.startswith("\t\t"):
		m = re.match(r"^(\t\t)([0-9a-fA-F]{4})\s+([0-9a-fA-F]{4})\s+(.*)$", body)
		if m:
			body = f"{m.group(1)}{m.group(2)} {m.group(3)} {m.group(4)}"
	elif body.startswith("\t"):
		m = re.match(r"^(\t)([0-9a-fA-F]{4})\s+(.*)$", body)
		if m:
			body = f"{m.group(1)}{m.group(2)} {m.group(3)}"
	else:
		m = re.match(r"^([0-9a-fA-F]{4})\s+(.*)$", body)
		if m:
			body = f"{m.group(1)} {m.group(2)}"
	out.append(body + ("\n" if nl else ""))
text = "".join(out)
needle = "\t1101 QCA6390 Wireless Network Adapter\n"
if needle not in text:
	text = text.replace(
		"17cb Qualcomm Technologies, Inc\n",
		"17cb Qualcomm Technologies, Inc\n" + needle,
		1,
	)
dst.write_text(text)
PY
fi

# CPU temp: Resources only knows coretemp/k10temp/cpu-thermal.
for h in /sys/class/hwmon/hwmon*; do
	[ -f "$h/name" ] || continue
	n=$(cat "$h/name" 2>/dev/null || true)
	if [ "$n" = "cluster0_thermal" ]; then
		printf 'coretemp\n' >"$RUN/hwmon-cpu-name"
		mountpoint -q "$h/name" || mount --bind "$RUN/hwmon-cpu-name" "$h/name"
		break
	fi
done
for z in /sys/class/thermal/thermal_zone*; do
	[ -f "$z/type" ] || continue
	t=$(cat "$z/type" 2>/dev/null || true)
	if [ "$t" = "cluster0-thermal" ]; then
		printf 'cpu-thermal\n' >"$RUN/cpu-thermal-type"
		mountpoint -q "$z/type" || mount --bind "$RUN/cpu-thermal-type" "$z/type"
		break
	fi
done

# One pack in Resources: hide the two BQ27Z561 cells (bms stays).
for p in /sys/class/power_supply/bq27z561-0 /sys/class/power_supply/bq27z561-1; do
	t=$(readlink -f "$p" 2>/dev/null || true)
	[ -n "$t" ] && [ -d "$t" ] && chmod 700 "$t" || true
done

# Resources lists every /sys/block disk. UFS LUNs sdb–sdf are Android
# boot/modem slices, not user storage. size=0 makes them "virtual" and the
# default UI hides them. Keep sda (userdata / dagu-linux) and any USB disk.
printf '0\n' >"$RUN/block-size-zero"
root_pk=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null || true)
root_pk=${root_pk:-sda}
for d in /sys/block/sd*; do
	[ -d "$d" ] || continue
	name=$(basename "$d")
	[ "$name" = "$root_pk" ] && continue
	link=$(readlink -f "$d" 2>/dev/null || true)
	case "$link" in
	*1d84000.ufshc*)
		mountpoint -q "$d/size" || mount --bind "$RUN/block-size-zero" "$d/size"
		;;
	esac
done

# Swap: no zram in this kernel; a small file is enough for the Swap row.
if [ ! -f /swapfile ]; then
	avail=$(df -k / | awk 'NR==2{print $4}')
	if [ "${avail:-0}" -gt 800000 ]; then
		fallocate -l 512M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=512
		chmod 600 /swapfile
		mkswap /swapfile
	fi
fi
if [ -f /swapfile ]; then
	grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
	swapon /swapfile 2>/dev/null || true
fi

# Memory speed: no SMBIOS on this SoC. Resources runs udevadm -p dmi/id.
cat >/usr/local/lib/dagu-resources-bin/udevadm <<'EOF'
#!/bin/sh
if [ "${1:-}" = info ] && [ "${2:-}" = -p ] && [ "${3:-}" = /sys/devices/virtual/dmi/id ]; then
	cat <<'DMI'
E: MEMORY_ARRAY_NUM_DEVICES=1
E: MEMORY_DEVICE_0_PRESENT=1
E: MEMORY_DEVICE_0_SIZE=8589934592
E: MEMORY_DEVICE_0_FORM_FACTOR=Row Of Chips
E: MEMORY_DEVICE_0_TYPE=LPDDR5
E: MEMORY_DEVICE_0_TYPE_DETAIL=Synchronous
E: MEMORY_DEVICE_0_SPEED_MTS=3200
E: MEMORY_DEVICE_0_CONFIGURED_SPEED_MTS=3200
DMI
	exit 0
fi
exec /usr/bin/udevadm "$@"
EOF
chmod 755 /usr/local/lib/dagu-resources-bin/udevadm

# lscpu: first "Model name" on this SoC is Cortex-A77, not the product name.
# Virtualization: has no line, so Resources shows N/A.
cat >/usr/local/lib/dagu-resources-bin/lscpu <<'EOF'
#!/bin/sh
real=/usr/bin/lscpu
out=$("$real" "$@") || exit $?
case " $* " in
*" -J "*|*" --json "*|*" -p"*|*" --parse"*|*" -e"*|*" --extended"*)
	printf '%s\n' "$out"
	exit 0
	;;
esac
printf '%s\n' "$out" | awk '
BEGIN {
	print "Model name:          Qualcomm Kryo 585 (Snapdragon 870)"
	print "Virtualization:      none"
}
/^Model name:/ { next }
/^Virtualization:/ { next }
{ print }
'
EOF
chmod 755 /usr/local/lib/dagu-resources-bin/lscpu
ln -sfn /usr/local/lib/dagu-resources-bin/lscpu /usr/local/bin/lscpu

# Resources globs device/hwmon/hwmon? (one digit). Adreno is hwmon31.
# Overlay with regular files; a poller fills them from devfreq/thermal (not from
# the overlaid directory).
if [ -d /sys/class/drm/card0/device/hwmon ] && mountpoint -q /sys/class/drm/card0/device/hwmon; then
	umount /sys/class/drm/card0/device/hwmon || true
fi
if [ -d "$RUN/gpu-hwmon/hwmon0" ]; then
	for f in "$RUN/gpu-hwmon/hwmon0"/*; do
		[ -e "$f" ] || continue
		mountpoint -q "$f" && umount "$f" || true
	done
fi
rm -rf "$RUN/gpu-hwmon"
mkdir -p "$RUN/gpu-hwmon/hwmon0"
printf 'adreno\n' >"$RUN/gpu-hwmon/hwmon0/name"
printf '305000000\n' >"$RUN/gpu-hwmon/hwmon0/freq1_input"
printf '1600000000\n' >"$RUN/gpu-hwmon/hwmon0/freq2_input"
printf '40000\n' >"$RUN/gpu-hwmon/hwmon0/temp1_input"
printf '0\n' >"$RUN/gpu-hwmon/hwmon0/power1_average"
chmod 644 "$RUN/gpu-hwmon/hwmon0"/*
if [ -d /sys/class/drm/card0/device/hwmon ]; then
	mount --bind "$RUN/gpu-hwmon" /sys/class/drm/card0/device/hwmon
fi

cat >/usr/local/sbin/dagu-resources-gpu-poll.sh <<'EOF'
#!/bin/sh
H=/run/dagu/gpu-hwmon/hwmon0
[ -d "$H" ] || exit 0
while true; do
	freq=305000000
	for d in /sys/class/devfreq/*gpu*; do
		[ -f "$d/cur_freq" ] || continue
		freq=$(cat "$d/cur_freq")
		break
	done
	printf '%s\n' "$freq" >"$H/freq1_input"
	printf '1600000000\n' >"$H/freq2_input"
	temp=40000
	for z in /sys/class/thermal/thermal_zone*; do
		[ -f "$z/type" ] || continue
		t=$(cat "$z/type")
		case "$t" in
		gpu-top-thermal|gpuss-0-thermal|gpu)
			temp=$(cat "$z/temp")
			break
			;;
		esac
	done
	printf '%s\n' "$temp" >"$H/temp1_input"
	busy=0
	[ -f /sys/class/drm/card0/device/gpu_busy_percent ] && \
		busy=$(cat /sys/class/drm/card0/device/gpu_busy_percent)
	# µW ≈ busy% × 7 W × freq / 670 MHz
	uw=$(awk -v b="$busy" -v f="$freq" 'BEGIN{printf "%.0f", b*70000*f/670000000}')
	printf '%s\n' "$uw" >"$H/power1_average"
	sleep 1
done
EOF
chmod 755 /usr/local/sbin/dagu-resources-gpu-poll.sh

if [ ! -e /etc/systemd/system/multi-user.target.wants/dagu-resources-gpu-poll.service ]; then
	cat >/etc/systemd/system/dagu-resources-gpu-poll.service <<'EOF'
[Unit]
Description=dagu: refresh Resources GPU hwmon0 files
After=dagu-resources-fix.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/dagu-resources-gpu-poll.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
	systemctl enable dagu-resources-gpu-poll.service >/dev/null 2>&1 || true
fi


cat >/usr/local/bin/dagu-resources <<'EOF'
#!/bin/sh
# GPU stats come from kernel sysfs on card0/device (msm_gpu_resources_sysfs).
# Do not LD_PRELOAD: Resources issues raw syscalls and the hook never fires.
export PATH="/usr/local/lib/dagu-resources-bin:${PATH}"
exec /usr/bin/resources "$@"
EOF
chmod 755 /usr/local/bin/dagu-resources

cat >/usr/local/share/applications/net.nokyan.Resources.desktop <<'EOF'
[Desktop Entry]
Name=Resources
Comment=Monitor your system resources and processes
Exec=/usr/local/bin/dagu-resources
Icon=net.nokyan.Resources
Terminal=false
Type=Application
Categories=GTK;System;Monitor;
StartupNotify=true
EOF
update-desktop-database /usr/local/share/applications 2>/dev/null || true
exit 0
