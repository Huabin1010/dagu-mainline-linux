#!/bin/bash
# Runs inside an arm64 Ubuntu chroot/container. Configures dagu desktop.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
PASS="${ROOT_PASSWORD:-dagu}"
MIRROR="${MIRROR:-http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports}"
SUITE="${SUITE:-resolute}"

printf '# see sources.list.d/ubuntu.sources\n' >/etc/apt/sources.list
mkdir -p /etc/apt/sources.list.d
cat >/etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: $MIRROR
Suites: $SUITE $SUITE-updates $SUITE-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

# Do not start services while qemu-building.
printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d

apt-get update
apt-get install -y --no-install-recommends \
	systemd systemd-sysv openssh-server sudo kmod udev \
	iproute2 iputils-ping ca-certificates alsa-utils \
	e2fsprogs dbus-user-session polkitd pkexec \
	ubuntu-desktop-minimal gdm3 gnome-session gnome-terminal \
	gnome-control-center gnome-settings-daemon nautilus \
	libgl1-mesa-dri libgbm1 mesa-vulkan-drivers \
	libinput-bin xserver-xorg-input-libinput \
	fonts-noto-core fonts-noto-cjk \
	network-manager onboard \
	ibus ibus-gtk3 ibus-gtk4 ibus-libpinyin \
	bluez

apt-get clean
rm -rf /var/lib/apt/lists/*

echo dagu >/etc/hostname
printf '127.0.0.1\tlocalhost\n127.0.1.1\tdagu\n' >/etc/hosts
printf '%s\n' 'LABEL=dagu-linux / ext4 defaults 0 1' >/etc/fstab

echo "root:$PASS" | chpasswd
id dagu >/dev/null 2>&1 || useradd -m -s /bin/bash dagu
echo "dagu:$PASS" | chpasswd
for g in sudo video render input plugdev bluetooth; do
	getent group "$g" >/dev/null && usermod -aG "$g" dagu || true
done
echo 'dagu ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/dagu
chmod 440 /etc/sudoers.d/dagu

mkdir -p /etc/gdm3
cat >/etc/gdm3/custom.conf <<'EOF'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=dagu
DefaultSession=ubuntu.desktop
WaylandEnable=true
EOF

# Stale /tmp/.X*-lock makes XWayland fail 50 times and GDM give up the display.
# fb0 Himax test is smooth; GNOME snow+断触 is compositor:
#   XR30 10bpc (panel is 8bpc DSC) plus full-stage CLUTTER_PAINT at 120Hz
#   starves input. Keep linear modifiers; do not disable clipped redraws.
# Onboard on Wayland eats touch (XInput fallback). GNOME OSK is enough.
mkdir -p /etc/systemd/system/gdm.service.d
cat >/etc/systemd/system/gdm.service.d/dagu-kms.conf <<'EOF'
[Service]
Environment=MUTTER_DEBUG_DISABLE_HW_CURSORS=1
Environment=MUTTER_DEBUG_SEND_KMS_MODIFIERS=0
Environment=MUTTER_DEBUG_USE_KMS_MODIFIERS=0
Environment=GSK_RENDERER=ngl
Environment=TU_DEBUG=noubwc
Environment=FD_MESA_DEBUG=noubwc,notile
Environment=MESA_VK_WSI_DEBUG=linear
Environment=MESA_EXTENSION_OVERRIDE=-EGL_KHR_swap_buffers_with_damage;-EGL_EXT_swap_buffers_with_damage;-EGL_KHR_partial_update
ExecStartPre=/bin/sh -c "rm -f /tmp/.X*-lock; mkdir -p /tmp/.X11-unix; find /tmp/.X11-unix -mindepth 1 -delete || true"
EOF

# GPU: never force llvmpipe here. GDM's systemd --user reads environment.d,
# and LIBGL_ALWAYS_SOFTWARE=1 + mutter GBM on card0 SIGSEGVs on the first swap.
mkdir -p /etc/environment.d
rm -f /etc/environment.d/dagu-swrend.conf
cat >/etc/environment.d/dagu-mutter.conf <<'EOF'
MUTTER_DEBUG_DISABLE_HW_CURSORS=1
MUTTER_DEBUG_SEND_KMS_MODIFIERS=0
MUTTER_DEBUG_USE_KMS_MODIFIERS=0
GSK_RENDERER=ngl
TU_DEBUG=noubwc
FD_MESA_DEBUG=noubwc,notile
MESA_VK_WSI_DEBUG=linear
MESA_EXTENSION_OVERRIDE=-EGL_KHR_swap_buffers_with_damage;-EGL_EXT_swap_buffers_with_damage;-EGL_KHR_partial_update
EOF
mkdir -p /etc/systemd/user.conf.d
cat >/etc/systemd/user.conf.d/dagu-mutter.conf <<'EOF'
[Manager]
DefaultEnvironment=MUTTER_DEBUG_DISABLE_HW_CURSORS=1 MUTTER_DEBUG_SEND_KMS_MODIFIERS=0 MUTTER_DEBUG_USE_KMS_MODIFIERS=0 GSK_RENDERER=ngl TU_DEBUG=noubwc FD_MESA_DEBUG=noubwc,notile MESA_VK_WSI_DEBUG=linear MESA_EXTENSION_OVERRIDE=-EGL_KHR_swap_buffers_with_damage;-EGL_EXT_swap_buffers_with_damage;-EGL_KHR_partial_update
EOF
mkdir -p /usr/share/drirc.d
cat >/usr/share/drirc.d/00-dagu-no-rgb10.conf <<'EOF'
<driconf>
    <device>
        <application name="Default">
            <option name="allow_rgb10_configs" value="false" />
        </application>
    </device>
</driconf>
EOF

# Chrome: native Wayland + GLES. Buffer layout is session Mesa (noubwc,notile);
# do not disable GPU raster here.
CHROME_DISABLE_FEATURES='Vulkan,DefaultANGLEVulkan,VulkanFromANGLE'
if [ -x /opt/google/chrome/chrome ]; then
	cat >/usr/local/bin/dagu-chrome <<'EOF'
#!/bin/sh
export FONTCONFIG_PATH="${FONTCONFIG_PATH:-/etc/fonts}"
export TU_DEBUG="${TU_DEBUG:-noubwc}"
export FD_MESA_DEBUG="${FD_MESA_DEBUG:-noubwc,notile}"
export MESA_VK_WSI_DEBUG="${MESA_VK_WSI_DEBUG:-linear}"
exec /opt/google/chrome/chrome \
	--ozone-platform=wayland \
	--ozone-platform-hint=wayland \
	--in-process-gpu \
	--use-gl=angle \
	--use-angle=gles \
	--start-maximized \
	--enable-wayland-ime \
	--disable-gtk-ime \
	--wayland-text-input-version=3 \
	--enable-features=WaylandTextInputV3 \
	--disable-features=Vulkan,DefaultANGLEVulkan,VulkanFromANGLE \
	"$@"
EOF
	chmod 755 /usr/local/bin/dagu-chrome
	mkdir -p /usr/local/share/applications /home/dagu/.local/share/applications
	if [ -f /usr/share/applications/google-chrome.desktop ]; then
		sed 's|^Exec=/usr/bin/google-chrome-stable|Exec=/usr/local/bin/dagu-chrome|' \
			/usr/share/applications/google-chrome.desktop \
			>/usr/local/share/applications/google-chrome.desktop
		cp /usr/local/share/applications/google-chrome.desktop \
			/home/dagu/.local/share/applications/google-chrome.desktop
		chown dagu:dagu /home/dagu/.local/share/applications/google-chrome.desktop
	fi
	if [ -f /opt/google/chrome/google-chrome ]; then
		python3 - "$CHROME_DISABLE_FEATURES" <<'PY'
from pathlib import Path
import sys
feat = sys.argv[1]
p = Path("/opt/google/chrome/google-chrome")
text = p.read_text()
out = []
for line in text.splitlines(True):
    if line.startswith("export TU_DEBUG=") or line.startswith("export FD_MESA_DEBUG=") \
       or line.startswith("export MESA_VK_WSI_DEBUG=") \
       or line.startswith("export MESA_EXTENSION_OVERRIDE=") \
            or line.startswith("export FONTCONFIG_PATH=") \
            or line.startswith("# dagu-chrome-gpu"):
        continue
    if 'exec -a "$0" "$HERE/chrome"' in line:
        out.append(
            'export FONTCONFIG_PATH="${FONTCONFIG_PATH:-/etc/fonts}"\n'
            'export TU_DEBUG="${TU_DEBUG:-noubwc}"\n'
            'export FD_MESA_DEBUG="${FD_MESA_DEBUG:-noubwc,notile}"\n'
            'export MESA_VK_WSI_DEBUG="${MESA_VK_WSI_DEBUG:-linear}"\n'
            '# dagu-chrome-gpu\n'
            'exec -a "$0" "$HERE/chrome" --ozone-platform=wayland --ozone-platform-hint=wayland --in-process-gpu'
            ' --use-gl=angle --use-angle=gles --start-maximized --enable-wayland-ime --disable-gtk-ime'
            f' --wayland-text-input-version=3 --enable-features=WaylandTextInputV3 --disable-features={feat} "$@"\n'
        )
        continue
    out.append(line)
p.write_text("".join(out))
PY
	fi
fi

# 12.4" 1600x2560 is ~243 PPI. Scale 1 makes Chrome glyphs tiny/soft; integer
# 2x matches wl_output and avoids fractional-scale upsampling.
mkdir -p /home/dagu/.config
cat >/home/dagu/.config/monitors.xml <<'EOF'
<monitors version="2">
  <configuration>
    <layoutmode>logical</layoutmode>
    <logicalmonitor>
      <x>0</x>
      <y>0</y>
      <scale>2</scale>
      <primary>yes</primary>
      <monitor>
        <monitorspec>
          <connector>DSI-1</connector>
          <vendor>unknown</vendor>
          <product>unknown</product>
          <serial>unknown</serial>
        </monitorspec>
        <mode>
          <width>1600</width>
          <height>2560</height>
          <rate>120.000</rate>
        </mode>
        <maxbpc>8</maxbpc>
      </monitor>
    </logicalmonitor>
  </configuration>
</monitors>
EOF
chown dagu:dagu /home/dagu/.config/monitors.xml 2>/dev/null || true

mkdir -p /home/dagu/.config/autostart
# Onboard on Wayland has no XInput and steals GTK touch; GNOME OSK is enough.
rm -f /home/dagu/.config/autostart/onboard.desktop
cat >/home/dagu/.config/autostart/onboard-autostart.desktop <<'EOF'
[Desktop Entry]
Hidden=true
X-GNOME-Autostart-enabled=false
EOF
# Linger keeps user systemd across GDM restarts, so old CLUTTER_PAINT sticks.
rm -f /var/lib/systemd/linger/dagu
chown -R dagu:dagu /home/dagu

# Chrome text-input-v3 never sends show_input_panel; open GNOME OSK on IM cursor.
EXTDIR=/home/dagu/.local/share/gnome-shell/extensions/dagu-osk-focus@dagu
mkdir -p "$EXTDIR"
cat >"$EXTDIR/metadata.json" <<'EOF'
{
  "uuid": "dagu-osk-focus@dagu",
  "name": "dagu OSK on text focus",
  "description": "Show GNOME OSK when a Wayland client enables text-input without show_input_panel (Chrome).",
  "shell-version": ["50"]
}
EOF
cat >"$EXTDIR/extension.js" <<'EOF'
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

export default class DaguOskFocus extends Extension {
    enable() {
        this._im = Main.inputMethod;
        this._ids = [
            this._im.connect('notify::current-focus', () => {
                if (this._im.currentFocus)
                    this._open();
            }),
            this._im.connect('cursor-location-changed', () => this._open()),
        ];
    }

    _open() {
        Main.keyboard?.open(Main.layoutManager.focusIndex);
    }

    disable() {
        for (const id of this._ids)
            this._im.disconnect(id);
        this._ids = [];
    }
}
EOF
chown -R dagu:dagu /home/dagu/.local/share/gnome-shell

mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
cat >/etc/dconf/profile/user <<'EOF'
user-db:user
system-db:local
EOF
cat >/etc/dconf/db/local.d/00-dagu-tablet <<'EOF'
[org/gnome/desktop/a11y/applications]
screen-keyboard-enabled=true

[org/gnome/desktop/a11y]
always-show-universal-access-status=true

[org/gnome/shell]
enabled-extensions=['ding@rastersoft.com', 'ubuntu-dock@ubuntu.com', 'tiling-assistant@ubuntu.com', 'dagu-osk-focus@dagu']

[org/gnome/desktop/input-sources]
sources=[('xkb', 'us'), ('ibus', 'libpinyin')]

[org/gnome/desktop/interface]
toolkit-accessibility=true
scaling-factor=uint32 2
color-scheme='default'

[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/warty-final-ubuntu.png'
picture-uri-dark='file:///usr/share/backgrounds/ubuntu-wallpaper-d.png'
primary-color='#2c001e'
picture-options='zoom'

[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/desktop/screensaver]
lock-enabled=false
ubuntu-lock-on-suspend=false

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
power-button-action='nothing'
idle-dim=false
EOF
dconf update 2>/dev/null || true

# Short power key: logind lock is a no-op when already locked, so the
# tablet cannot unblank. Ignore the key here; dagu-power-button.py toggles.
mkdir -p /etc/systemd/logind.conf.d /etc/xdg/autostart /usr/local/bin /usr/local/sbin
cat >/etc/systemd/logind.conf.d/dagu-power.conf <<'EOF'
[Login]
HandlePowerKey=ignore
HandlePowerKeyLongPress=poweroff
HandleSuspendKey=ignore
HandleHibernateKey=ignore
IdleAction=ignore
EOF
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1 || true
# Saved brightness 0 would restore DCS 0x51=0 on the next boot.
systemctl mask systemd-backlight@backlight:l81a-wled.service >/dev/null 2>&1 || true
# Keep in sync with linux-mainline/scripts/dagu-power-button.py
cat >/usr/local/sbin/dagu-power-button.py <<'EOF'
#!/usr/bin/env python3
"""dagu: short power key toggles Mutter DPMS only.

DCS 0x51 times out on this video-mode panel (~200 ms × 2 links) and
does not restore. lock-sessions makes mutter set PowerSaveMode=3 AND
the lock shield, then a second press races blank-on-lock. Just flip
PowerSaveMode 0/3; kernel unprepare is a no-op so clocks can return.
Long press stays logind HandlePowerKeyLongPress=poweroff.
"""
import glob
import os
import struct
import subprocess
import time

KEY_POWER = 116
EV_KEY = 1
FMT = "llHHI"
SIZE = struct.calcsize(FMT)
LONG_PRESS = 1.2


def find_pwrkey():
    for name_path in glob.glob("/sys/class/input/event*/device/name"):
        try:
            with open(name_path, encoding="utf-8") as f:
                name = f.read().strip()
        except OSError:
            continue
        if name == "pm8941_pwrkey":
            event = name_path.split("/")[4]
            return f"/dev/input/{event}"
    return "/dev/input/event1"


def gnome_env():
    env = os.environ.copy()
    uid = "1001"
    try:
        out = subprocess.check_output(
            ["loginctl", "list-sessions", "--no-legend"], text=True
        )
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[2] == "dagu" and "seat" in line:
                uid = parts[1]
                break
    except (OSError, subprocess.SubprocessError):
        pass
    env["XDG_RUNTIME_DIR"] = f"/run/user/{uid}"
    env["DBUS_SESSION_BUS_ADDRESS"] = f"unix:path=/run/user/{uid}/bus"
    return env


def dpms_sysfs():
    try:
        with open("/sys/class/drm/card0-DSI-1/dpms", encoding="ascii") as f:
            return f.read().strip().lower()
    except OSError:
        return "on"


def mutter_mode():
    try:
        out = subprocess.check_output(
            [
                "busctl",
                "--user",
                "get-property",
                "org.gnome.Mutter.DisplayConfig",
                "/org/gnome/Mutter/DisplayConfig",
                "org.gnome.Mutter.DisplayConfig",
                "PowerSaveMode",
            ],
            env=gnome_env(),
            text=True,
        )
        # "i 0" / "i 3"
        parts = out.split()
        return int(parts[-1]) if parts else 0
    except (OSError, subprocess.SubprocessError, ValueError):
        return 0 if dpms_sysfs() == "on" else 3


def set_mutter(mode):
    subprocess.run(
        [
            "busctl",
            "--user",
            "set-property",
            "org.gnome.Mutter.DisplayConfig",
            "/org/gnome/Mutter/DisplayConfig",
            "org.gnome.Mutter.DisplayConfig",
            "PowerSaveMode",
            "i",
            str(mode),
        ],
        env=gnome_env(),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def blank():
    set_mutter(3)


def unblank():
    set_mutter(0)


def open_event():
    path = find_pwrkey()
    last_err = None
    for _ in range(60):
        path = find_pwrkey()
        try:
            return os.open(path, os.O_RDONLY)
        except OSError as err:
            last_err = err
            time.sleep(1)
    raise SystemExit(f"cannot open {path}: {last_err}")


def main():
    fd = open_event()
    down_at = None
    last = 0.0
    while True:
        data = os.read(fd, SIZE)
        if len(data) < SIZE:
            continue
        _s, _us, etype, code, value = struct.unpack(FMT, data)
        if etype != EV_KEY or code != KEY_POWER:
            continue
        now = time.monotonic()
        if value == 1:
            down_at = now
            continue
        if value != 0 or down_at is None:
            continue
        held = now - down_at
        down_at = None
        if held >= LONG_PRESS:
            continue
        if now - last < 0.35:
            continue
        last = now
        if mutter_mode() != 0 or dpms_sysfs() != "on":
            unblank()
        else:
            blank()


if __name__ == "__main__":
    main()
EOF
chmod 755 /usr/local/sbin/dagu-power-button.py
# After=multi-user.target + WantedBy=multi-user.target deadlocks the job
# until someone starts it by hand (power key then does nothing at boot).
cat >/etc/systemd/system/dagu-power-button.service <<'EOF'
[Unit]
Description=dagu power key toggles mutter DPMS
After=systemd-logind.service
Wants=systemd-logind.service

[Service]
Type=simple
User=dagu
Group=dagu
SupplementaryGroups=input
Environment=XDG_RUNTIME_DIR=/run/user/1001
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus
ExecStart=/usr/bin/python3 /usr/local/sbin/dagu-power-button.py
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/dagu-power-button.service \
	/etc/systemd/system/multi-user.target.wants/dagu-power-button.service
# gpio-keys hall idles as laptop (SW_TABLET_MODE=0); mutter then hides OSK.
cat >/usr/local/sbin/dagu-tablet-mode.py <<'EOF'
#!/usr/bin/env python3
import glob
import os
import struct
import time

EV_SYN = 0
EV_SW = 5
SYN_REPORT = 0
SW_TABLET_MODE = 1
FMT = "llHHI"


def find_gpio_keys():
    for name_path in glob.glob("/sys/class/input/event*/device/name"):
        try:
            with open(name_path, encoding="utf-8") as f:
                name = f.read().strip()
        except OSError:
            continue
        if name == "gpio-keys":
            return f"/dev/input/{name_path.split('/')[4]}"
    return "/dev/input/event4"


def emit(fd, etype, code, value):
    os.write(fd, struct.pack(FMT, 0, 0, etype, code, value))


def main():
    path = find_gpio_keys()
    fd = os.open(path, os.O_WRONLY)
    try:
        while True:
            emit(fd, EV_SW, SW_TABLET_MODE, 1)
            emit(fd, EV_SYN, SYN_REPORT, 0)
            time.sleep(15)
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
EOF
chmod 755 /usr/local/sbin/dagu-tablet-mode.py
cat >/etc/systemd/system/dagu-tablet-mode.service <<'EOF'
[Unit]
Description=dagu force SW_TABLET_MODE for GNOME OSK
After=systemd-udevd.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/sbin/dagu-tablet-mode.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/dagu-tablet-mode.service \
	/etc/systemd/system/multi-user.target.wants/dagu-tablet-mode.service
cat >/usr/local/bin/dagu-blank-on-lock <<'EOF'
#!/bin/sh
# Intentionally empty: writing l81a-wled (DCS 0x51) ETIMEDOUTs and racing
# lock-sessions made power-key blank flash then stay black.
exit 0
EOF
chmod 755 /usr/local/bin/dagu-blank-on-lock
cat >/etc/xdg/autostart/dagu-blank-on-lock.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=dagu blank panel on lock
Exec=/usr/local/bin/dagu-blank-on-lock
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
if [ -d /home/dagu ]; then
	mkdir -p /home/dagu/.config/autostart
	cp /etc/xdg/autostart/dagu-blank-on-lock.desktop \
		/home/dagu/.config/autostart/dagu-blank-on-lock.desktop
	chown -R dagu:dagu /home/dagu/.config/autostart 2>/dev/null || true
fi

sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config || true
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config || true

# glycin+bwrap --seccomp exits 1 on this kernel, so GNOME never loads
# wallpapers/icons and the panel stays solid blue.
if [ -x /usr/bin/bwrap ] && [ ! -x /usr/bin/bwrap.real ]; then
	dpkg-divert --local --rename --divert /usr/bin/bwrap.real --add /usr/bin/bwrap || true
fi
if [ -x /usr/bin/bwrap.real ]; then
	cat >/usr/bin/bwrap <<'EOF'
#!/bin/bash
i=1
for a in "$@"; do
	case "$a" in
	/usr/libexec/glycin-loaders/*)
		exec "${@:i}"
		;;
	esac
	i=$((i + 1))
done
args=()
skip=0
for a in "$@"; do
	if [ "$skip" = 1 ]; then skip=0; continue; fi
	if [ "$a" = "--seccomp" ]; then skip=1; continue; fi
	args+=("$a")
done
exec /usr/bin/bwrap.real "${args[@]}"
EOF
	chmod 755 /usr/bin/bwrap
fi

systemctl set-default graphical.target || true
systemctl enable gdm3.service || true
systemctl enable serial-getty@ttyGS0.service || true
systemctl enable serial-getty@tty0.service || true
systemctl enable ssh.service || true
systemctl enable NetworkManager.service || true

mkdir -p /usr/local/sbin /etc/systemd/system /etc/systemd/system/multi-user.target.wants
cat >/usr/local/sbin/dagu-resize-root.sh <<'EOF'
#!/bin/sh
dev=$(awk '$2 == "/" { print $1; exit }' /proc/mounts)
[ -n "$dev" ] && resize2fs "$dev"
EOF
chmod 755 /usr/local/sbin/dagu-resize-root.sh
cat >/etc/systemd/system/dagu-resize-root.service <<'EOF'
[Unit]
Description=Grow Ubuntu ext4 on userdata
After=local-fs.target
ConditionPathExists=/sbin/resize2fs

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/dagu-resize-root.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/dagu-resize-root.service \
	/etc/systemd/system/multi-user.target.wants/dagu-resize-root.service

# RTC often stays in 2026-07 while shadow lastchg is the host date. pam_unix
# then treats the password as "changed in the future" and the lock screen
# rejects dagu/dagu. Missing pam_gnome_keyring.so makes GNOME say the
# authentication service is broken.
cat >/usr/local/sbin/dagu-fix-pam.sh <<'EOF'
#!/bin/sh
today=$(date -u +%F 2>/dev/null) || exit 0
for u in dagu root; do
	id "$u" >/dev/null 2>&1 || continue
	chage -d "$today" "$u" 2>/dev/null || true
done
for f in /etc/pam.d/gdm-password /etc/pam.d/gdm-autologin; do
	[ -f "$f" ] || continue
	if [ ! -e /usr/lib/security/pam_gnome_keyring.so ] &&
	   [ ! -e /usr/lib/aarch64-linux-gnu/security/pam_gnome_keyring.so ]; then
		sed -i 's/^\(auth[[:space:]]\+optional[[:space:]]\+pam_gnome_keyring.so\)/# \1/' "$f"
		sed -i 's/^\(session[[:space:]]\+optional[[:space:]]\+pam_gnome_keyring.so\)/# \1/' "$f"
	fi
done
EOF
chmod 755 /usr/local/sbin/dagu-fix-pam.sh
cat >/etc/systemd/system/dagu-fix-pam.service <<'EOF'
[Unit]
Description=Fix dagu shadow dates vs stuck RTC for GNOME lock
After=local-fs.target
Before=gdm.service gdm3.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/dagu-fix-pam.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/dagu-fix-pam.service \
	/etc/systemd/system/multi-user.target.wants/dagu-fix-pam.service
/usr/local/sbin/dagu-fix-pam.sh || true

rm -f /usr/sbin/policy-rc.d
echo "==> desktop setup done"
