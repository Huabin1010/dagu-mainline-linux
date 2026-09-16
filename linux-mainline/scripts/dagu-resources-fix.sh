#!/bin/sh
# Make GNOME Resources show dagu sensors instead of PC-only sysfs names.
set -eu

RUN=/run/dagu
mkdir -p "$RUN" /usr/share/hwdata /usr/local/lib /usr/local/lib/dagu-resources-bin \
	/usr/local/share/applications /etc/systemd/system

# Resources parses pci.ids with split("  "): ID and name need TWO spaces.
# Ubuntu's canonical file is /usr/share/misc/pci.ids; Resources opens hwdata.
# A one-space "minimal" file makes parse_pci_ids() fail → Manufacturer N/A.
mkdir -p /usr/share/hwdata
if [ -f /usr/share/misc/pci.ids ]; then
	cp -a /usr/share/misc/pci.ids /usr/share/hwdata/pci.ids
else
	cat >/usr/share/hwdata/pci.ids <<'EOF'
# Fallback pci.ids for dagu Resources (double spaces required).
17cb  Qualcomm Technologies, Inc
	010b  SM8250 PCIe Root Complex
	1101  QCA6390 Wireless Network Adapter
	a650  Adreno (TM) 650
EOF
fi
# pci.ids has no Adreno 650 id; Resources needs Device::from_vid_pid(17cb,a650).
if ! grep -q $'^\ta650  ' /usr/share/hwdata/pci.ids; then
	python3 - <<'PY'
from pathlib import Path
p = Path("/usr/share/hwdata/pci.ids")
lines = p.read_text(errors="replace").splitlines(True)
out, i = [], 0
while i < len(lines):
    out.append(lines[i])
    if lines[i].startswith("17cb  "):
        i += 1
        while i < len(lines) and (lines[i].startswith("\t") or lines[i].startswith("#") or lines[i].strip() == ""):
            out.append(lines[i]); i += 1
        out.append("\ta650  Adreno (TM) 650\n")
        continue
    i += 1
p.write_text("".join(out))
PY
fi

# Never bind-mount card0/device/uevent. A fake PCI_ID makes libdrm/Chrome
# drmGetDeviceFromDevId fail and --in-process-gpu aborts the whole browser.
if mountpoint -q /sys/class/drm/card0/device/uevent; then
	umount /sys/class/drm/card0/device/uevent || true
fi

# UFS is not PCI/SATA/USB. Do not invent device/address. Resources Link = N/A
# is the honest value. Tear down any previous fake sda overlay.
_dagu_teardown_sda_overlay() {
	real=/sys/devices/platform/soc@0/1d84000.ufshc/host0/target0:0:0/0:0:0:0/block/sda
	systemctl disable --now dagu-resources-sda-poll.service 2>/dev/null || true
	pkill -f dagu-resources-sda-poll.sh 2>/dev/null || true
	if [ -e "$real" ] && mountpoint -q "$real"; then
		umount -l "$real" 2>/dev/null || true
	fi
	for t in $(findmnt -n -o TARGET 2>/dev/null | grep '/run/dagu/block-sda' | sort -r); do
		umount -l "$t" 2>/dev/null || true
	done
}
_dagu_teardown_sda_overlay

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
# UPower runs as root; chmod does not hide the cells. Ignore them in udev.
# UPower 1.91 still lists TYPE_BATTERY cells; kernel pack-cell → TYPE_UNKNOWN.
cat >/etc/udev/rules.d/90-dagu-bms.rules <<'EOF'
SUBSYSTEM=="power_supply", KERNEL=="bq27z561-*", ENV{UPOWER_IGNORE}="1", ENV{UPOWER_BATTERY_TYPE}=""
EOF
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --subsystem-match=power_supply 2>/dev/null || true

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
printf '40000\n' >"$RUN/gpu-hwmon/hwmon0/temp1_input"
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


# Hide AdwActionRow whose subtitle is N/A (no fake values). Do not hide
# ResGraphBox: logical CPU tiles title "N/A" until the first cpufreq
# sample, and walking that label to hide the box blanks the Processor
# logical-CPU page across reboot (this service recompiles the .so).
cat >/usr/local/src/dagu-resources-hide-na.c <<'EOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>

/*
 * Hide AdwActionRow rows whose subtitle is a real N/A (UFS has no PCIe
 * Link, Adreno has no Slot / Max Power Cap). Values stay truthful.
 *
 * Never hide ResGraphBox. Logical CPU tiles set title_label to "N/A"
 * until the first cpufreq sample. Walking from that label to ResGraphBox
 * and calling gtk_widget_set_visible(false) made Processor → Show usages
 * of logical CPUs a blank page. /proc/stat usage is real; a missing
 * frequency string is not a missing graph.
 *
 * ident: dagu-hide-na:rows-only
 */
static const char dagu_hide_na_ident[] __attribute__((used)) =
	"dagu-hide-na:rows-only";

static int is_na(const char *s)
{
	if (!s)
		return 0;
	while (*s == ' ' || *s == '\t')
		s++;
	if (!*s)
		return 0;
	if (strcmp(s, "N/A") == 0 || strcmp(s, "n/a") == 0)
		return 1;
	if (strcmp(s, "不适用") == 0 || strcmp(s, "不可用") == 0)
		return 1;
	if (strcmp(s, "—") == 0)
		return 1;
	return 0;
}

void adw_action_row_set_subtitle(void *self, const char *subtitle)
{
	static void (*real)(void *, const char *);
	static void (*set_visible)(void *, int);

	if (!real)
		real = dlsym(RTLD_NEXT, "adw_action_row_set_subtitle");
	if (real)
		real(self, subtitle);
	if (!set_visible)
		set_visible = dlsym(RTLD_DEFAULT, "gtk_widget_set_visible");
	if (set_visible && self)
		set_visible(self, !is_na(subtitle));
}
EOF
mkdir -p /usr/local/src /usr/local/lib
if command -v cc >/dev/null 2>&1; then
	cc -shared -fPIC -O2 -o /usr/local/lib/libdagu-resources-hide-na.so.new \
		/usr/local/src/dagu-resources-hide-na.c -ldl
	if grep -a -q 'dagu-hide-na:rows-only' /usr/local/lib/libdagu-resources-hide-na.so.new; then
		mv -f /usr/local/lib/libdagu-resources-hide-na.so.new \
			/usr/local/lib/libdagu-resources-hide-na.so
	else
		rm -f /usr/local/lib/libdagu-resources-hide-na.so.new
		echo "dagu-resources-hide-na.so missing ident" >&2
		exit 1
	fi
elif [ ! -f /usr/local/lib/libdagu-resources-hide-na.so ]; then
	echo "dagu-resources-hide-na.so missing and no C compiler" >&2
	exit 1
elif ! grep -a -q 'dagu-hide-na:rows-only' /usr/local/lib/libdagu-resources-hide-na.so; then
	echo "dagu-resources-hide-na.so is stale (need rows-only ident)" >&2
	exit 1
fi

cat >/usr/local/bin/dagu-resources <<'EOF'
#!/bin/sh
export PATH="/usr/local/lib/dagu-resources-bin:${PATH}"
export LD_PRELOAD="/usr/local/lib/libdagu-resources-hide-na.so${LD_PRELOAD:+:$LD_PRELOAD}"
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

# Adreno 650 max is 670 MHz. simple_ondemand still drops 670→490
# mid hold-drag (Himax inject: ~28% of samples at 490, busy_max=100).
# Idle floor 587 MHz. Finger-down 670 is dagu-touch-boost.py.
# Do not use governor=performance.
if [ -d /sys/class/devfreq/3d00000.gpu ]; then
	printf '587000000\n' >/sys/class/devfreq/3d00000.gpu/min_freq || true
	printf '10\n' >/sys/class/devfreq/3d00000.gpu/polling_interval || true
fi
exit 0
