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
	iproute2 iputils-ping ca-certificates alsa-utils alsa-ucm-conf \
	e2fsprogs dbus-user-session polkitd pkexec \
	ubuntu-desktop-minimal gdm3 gnome-session gnome-terminal \
	gnome-control-center gnome-settings-daemon nautilus \
	resources gnome-text-editor gnome-calculator gnome-clocks \
	gnome-characters gnome-disk-utility file-roller eog evince \
	libgl1-mesa-dri libgbm1 mesa-vulkan-drivers \
	libinput-bin xserver-xorg-input-libinput \
	fonts-noto-core fonts-noto-cjk \
	network-manager onboard \
	ibus ibus-gtk3 ibus-gtk4 ibus-libpinyin \
	bluez systemd-timesyncd pci.ids

apt-get clean
rm -rf /var/lib/apt/lists/*

echo dagu >/etc/hostname
printf '127.0.0.1\tlocalhost\n127.0.1.1\tdagu\n' >/etc/hosts
printf '%s\n' 'LABEL=dagu-linux / ext4 defaults 0 1' >/etc/fstab

echo "root:$PASS" | chpasswd
id dagu >/dev/null 2>&1 || useradd -m -s /bin/bash dagu
echo "dagu:$PASS" | chpasswd
for g in sudo video render input plugdev bluetooth audio; do
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
# Chromium component snow: mutter SEND=0 advertised only LINEAR, ANGLE still
# allocated Adreno TILE/UBWC and tagged the dmabuf LINEAR. Honest KMS
# modifiers + disable-direct-scanout lets GL import the real layout; primary
# KMS fb stays XR24 linear (USE=0). Do not set FD_MESA_DEBUG on mutter —
# noubwc/notile on the compositor breaks UBWC import.
# Onboard on Wayland eats touch (XInput fallback). GNOME OSK is enough.
mkdir -p /etc/systemd/system/gdm.service.d
cat >/etc/systemd/system/gdm.service.d/dagu-kms.conf <<'EOF'
[Service]
Environment=MUTTER_DEBUG_DISABLE_HW_CURSORS=1
Environment=MUTTER_DEBUG_SEND_KMS_MODIFIERS=1
Environment=MUTTER_DEBUG_USE_KMS_MODIFIERS=0
Environment=MUTTER_DEBUG_PAINT=disable-direct-scanout
Environment=GSK_RENDERER=ngl
Environment=MESA_EXTENSION_OVERRIDE=-EGL_KHR_swap_buffers_with_damage;-EGL_EXT_swap_buffers_with_damage;-EGL_KHR_partial_update
UnsetEnvironment=FD_MESA_DEBUG TU_DEBUG LD_PRELOAD MESA_VK_WSI_DEBUG
ExecStartPre=/bin/sh -c "rm -f /tmp/.X*-lock; mkdir -p /tmp/.X11-unix; find /tmp/.X11-unix -mindepth 1 -delete || true"
EOF

# GPU: never force llvmpipe here. GDM's systemd --user reads environment.d,
# and LIBGL_ALWAYS_SOFTWARE=1 + mutter GBM on card0 SIGSEGVs on the first swap.
mkdir -p /etc/environment.d
rm -f /etc/environment.d/dagu-swrend.conf
cat >/etc/environment.d/dagu-mutter.conf <<'EOF'
MUTTER_DEBUG_DISABLE_HW_CURSORS=1
MUTTER_DEBUG_SEND_KMS_MODIFIERS=1
MUTTER_DEBUG_USE_KMS_MODIFIERS=0
MUTTER_DEBUG_PAINT=disable-direct-scanout
GSK_RENDERER=ngl
MESA_EXTENSION_OVERRIDE=-EGL_KHR_swap_buffers_with_damage;-EGL_EXT_swap_buffers_with_damage;-EGL_KHR_partial_update
EOF
mkdir -p /etc/systemd/user.conf.d
cat >/etc/systemd/user.conf.d/dagu-mutter.conf <<'EOF'
[Manager]
DefaultEnvironment=MUTTER_DEBUG_DISABLE_HW_CURSORS=1 MUTTER_DEBUG_SEND_KMS_MODIFIERS=1 MUTTER_DEBUG_USE_KMS_MODIFIERS=0 MUTTER_DEBUG_PAINT=disable-direct-scanout GSK_RENDERER=ngl MESA_EXTENSION_OVERRIDE=-EGL_KHR_swap_buffers_with_damage;-EGL_EXT_swap_buffers_with_damage;-EGL_KHR_partial_update
EOF
# gnome-shell is org.gnome.Shell@.service under the user manager, which can
# outlive GDM restarts. Put the compositor contract on that unit so mutter
# cannot keep a stale SEND=0 / FD_MESA_DEBUG=notile from an old manager.
mkdir -p /etc/systemd/user/org.gnome.Shell@.service.d
cat >/etc/systemd/user/org.gnome.Shell@.service.d/dagu-kms.conf <<'EOF'
[Service]
Environment=MUTTER_DEBUG_DISABLE_HW_CURSORS=1
Environment=MUTTER_DEBUG_SEND_KMS_MODIFIERS=1
Environment=MUTTER_DEBUG_USE_KMS_MODIFIERS=0
Environment=MUTTER_DEBUG_PAINT=disable-direct-scanout
Environment=GSK_RENDERER=ngl
Environment=MESA_EXTENSION_OVERRIDE=-EGL_KHR_swap_buffers_with_damage;-EGL_EXT_swap_buffers_with_damage;-EGL_KHR_partial_update
UnsetEnvironment=FD_MESA_DEBUG TU_DEBUG LD_PRELOAD MESA_VK_WSI_DEBUG
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

# Chrome: native Wayland + GLES. Ozone tags linux-dmabuf LINEAR; force GBM
# pixels LINEAR and load dagu-mesa (unused-depth color sysmem; 3D GMEM).
# GPU raster on. Never preload either into gnome-shell.
CHROME_DISABLE_FEATURES='Vulkan,DefaultANGLEVulkan,VulkanFromANGLE,WaylandOverlayDelegation'
if [ -x /opt/google/chrome/chrome ]; then
	cat >/usr/local/bin/dagu-chrome <<'EOF'
#!/bin/sh
export FONTCONFIG_PATH="${FONTCONFIG_PATH:-/etc/fonts}"
if [ -f /usr/local/lib/dagu-mesa/libgallium-26.0.8-1ubuntu0.3.so ]; then
	export LD_LIBRARY_PATH="/usr/local/lib/dagu-mesa${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
if [ -f /usr/local/lib/libdagu-linear-mod.so ]; then
	export LD_PRELOAD="/usr/local/lib/libdagu-linear-mod.so${LD_PRELOAD:+:$LD_PRELOAD}"
fi
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
	--disable-features=Vulkan,DefaultANGLEVulkan,VulkanFromANGLE,WaylandOverlayDelegation \
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
       or line.startswith("export LD_PRELOAD=") \
            or line.startswith("export FONTCONFIG_PATH=") \
            or line.startswith("# dagu-chrome-gpu"):
        continue
    if 'exec -a "$0" "$HERE/chrome"' in line:
        out.append(
            'export FONTCONFIG_PATH="${FONTCONFIG_PATH:-/etc/fonts}"\n'
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

# Chrome text-input-v3 never sends show_input_panel; open GNOME OSK on IM
# cursor. Install as a system extension so disable-user-extensions cannot
# hide it. Landscape _relayout minHeight can exceed the short side.
install_dagu_osk() {
	local d="$1"
	mkdir -p "$d"
	cat >"$d/metadata.json" <<'EOF'
{
  "uuid": "dagu-osk-focus@dagu",
  "name": "dagu OSK on text focus",
  "description": "Show GNOME OSK for Chrome omnibox; fit landscape height.",
  "shell-version": ["50"],
  "session-modes": ["user"]
}
EOF
	cat >"$d/extension.js" <<'EOF'
import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

export default class DaguOskFocus extends Extension {
    enable() {
        this._im = Main.inputMethod;
        this._openTimeout = 0;
        this._conns = [];
        this._connect(this._im, 'notify::current-focus', () => {
            if (this._im.currentFocus)
                this._openSoon(50);
        });
        this._connect(this._im, 'cursor-location-changed', () => this._openSoon(50));
        this._connect(Main.layoutManager, 'monitors-changed', () => {
            this._patchRelayout();
            if (this._im.currentFocus)
                this._openSoon(120);
        });
        this._connect(global.stage, 'captured-event', (_a, event) => {
            this._maybeChromeOmnibox(event);
            return Clutter.EVENT_PROPAGATE;
        });
        this._patchRelayout();
    }

    _connect(obj, sig, cb) {
        this._conns.push([obj, obj.connect(sig, cb)]);
    }

    _patchRelayout() {
        const kbd = Main.keyboard?.keyboardActor;
        if (!kbd || kbd._daguRelayout)
            return;
        kbd._daguRelayout = true;
        const orig = kbd._relayout.bind(kbd);
        kbd._relayout = () => {
            orig();
            const mon = Main.layoutManager.keyboardMonitor;
            if (!mon)
                return;
            kbd.width = mon.width;
            if (mon.width > mon.height)
                kbd.height = Math.round(Math.min(mon.height * 0.46, 380));
        };
    }

    _eventXY(event) {
        try {
            const c = event.get_coords();
            if (Array.isArray(c))
                return [c[0], c[1]];
            if (c && 'x' in c)
                return [c.x, c.y];
        } catch (e) {
        }
        return [0, 0];
    }

    _maybeChromeOmnibox(event) {
        const type = event.type();
        if (type !== Clutter.EventType.TOUCH_BEGIN &&
            type !== Clutter.EventType.BUTTON_PRESS)
            return;
        const win = global.display.focus_window;
        if (!win)
            return;
        const wm = `${win.get_wm_class() || ''} ${win.get_title() || ''}`;
        if (!/chrome|chromium|google-chrome/i.test(wm))
            return;
        const [x, y] = this._eventXY(event);
        const rect = win.get_frame_rect();
        const band = Math.max(80, Math.round(rect.height * 0.14));
        if (x < rect.x || x > rect.x + rect.width)
            return;
        if (y < rect.y || y > rect.y + band)
            return;
        this._openSoon(80);
    }

    _openSoon(ms) {
        if (this._openTimeout)
            GLib.source_remove(this._openTimeout);
        this._openTimeout = GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => {
            this._openTimeout = 0;
            this._open();
            return GLib.SOURCE_REMOVE;
        });
    }

    _open() {
        this._patchRelayout();
        const idx = Main.layoutManager.focusIndex;
        Main.layoutManager.keyboardIndex = idx;
        Main.keyboard?.open(idx);
        const kbd = Main.keyboard?.keyboardActor;
        kbd?._relayout?.();
        kbd?.open?.(true);
    }

    disable() {
        if (this._openTimeout) {
            GLib.source_remove(this._openTimeout);
            this._openTimeout = 0;
        }
        for (const [obj, id] of this._conns)
            obj.disconnect(id);
        this._conns = [];
    }
}
EOF
}
install_dagu_osk /usr/share/gnome-shell/extensions/dagu-osk-focus@dagu
install_dagu_osk /home/dagu/.local/share/gnome-shell/extensions/dagu-osk-focus@dagu
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
disable-user-extensions=false
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

[org/gnome/desktop/media-handling]
automount=false
automount-open=false
autorun-never=true
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
systemctl unmask systemd-backlight@backlight:l81a-wled.service >/dev/null 2>&1 || true
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

# No working RTC: clock stays at rootfs build date. HTTPS CDN certs
# (Bilibili static.hdslb.com) then fail "not yet valid" and Chrome
# shows HTML without CSS. NTP after Wi-Fi, HTTP Date as fallback.
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
printf 'Asia/Shanghai\n' >/etc/timezone
cat >/usr/local/sbin/dagu-time-sync.py <<'EOF'
#!/usr/bin/env python3
from __future__ import annotations

import os
import socket
import struct
import subprocess
import sys
from email.utils import parsedate_to_datetime
from pathlib import Path
from urllib.request import Request, urlopen

STAMP = Path("/var/lib/dagu/last-good-time")
NTP_HOSTS = (
    "ntp.aliyun.com",
    "ntp.tencent.com",
    "ntp.tuna.tsinghua.edu.cn",
    "pool.ntp.org",
)
HTTP_URLS = (
    "http://mirrors.tuna.tsinghua.edu.cn/",
    "http://detectportal.firefox.com/",
    "https://www.bilibili.com/",
)


def sntp(host: str, timeout: float = 3.0) -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(b"\x1b" + 47 * b"\0", (host, 123))
        data, _ = sock.recvfrom(512)
    finally:
        sock.close()
    if len(data) < 48:
        raise OSError("short ntp")
    t = struct.unpack("!12I", data[:48])[10]
    unix = t - 2208988800
    if unix < 1_700_000_000:
        raise OSError(f"ntp sanity {unix}")
    return unix


def http_date(url: str) -> int:
    req = Request(url, method="HEAD", headers={"User-Agent": "dagu-time-sync"})
    try:
        with urlopen(req, timeout=8) as r:
            raw = r.headers.get("Date")
    except Exception:
        req = Request(url, headers={"User-Agent": "dagu-time-sync"})
        with urlopen(req, timeout=8) as r:
            raw = r.headers.get("Date")
            r.read(64)
    if not raw:
        raise OSError("no Date")
    dt = parsedate_to_datetime(raw)
    unix = int(dt.timestamp())
    if unix < 1_700_000_000:
        raise OSError(f"http sanity {unix}")
    return unix


def apply_unix(unix: int) -> None:
    STAMP.parent.mkdir(parents=True, exist_ok=True)
    iso = subprocess.check_output(
        ["date", "-u", "-d", f"@{unix}", "+%Y-%m-%d %H:%M:%S"],
        text=True,
    ).strip()
    subprocess.check_call(["date", "-u", "-s", iso])
    STAMP.write_text(str(unix) + "\n")
    try:
        subprocess.run(
            ["hwclock", "-w"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except FileNotFoundError:
        pass
    pam = "/usr/local/sbin/dagu-fix-pam.sh"
    if os.access(pam, os.X_OK):
        subprocess.call([pam])


def restore_stamp() -> bool:
    try:
        unix = int(STAMP.read_text().strip())
    except (OSError, ValueError):
        return False
    now = int(__import__("time").time())
    if unix <= now:
        return False
    apply_unix(unix)
    print("restored", unix, file=sys.stderr)
    return True


def main() -> int:
    restore_stamp()
    last_err = None
    for host in NTP_HOSTS:
        try:
            unix = sntp(host)
            apply_unix(unix)
            print(f"ntp {host} -> {unix}")
            return 0
        except Exception as e:
            last_err = e
            print(f"ntp {host}: {e}", file=sys.stderr)
    for url in HTTP_URLS:
        try:
            unix = http_date(url)
            apply_unix(unix)
            print(f"http {url} -> {unix}")
            return 0
        except Exception as e:
            last_err = e
            print(f"http {url}: {e}", file=sys.stderr)
    print(f"dagu-time-sync failed: {last_err}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
EOF
chmod 755 /usr/local/sbin/dagu-time-sync.py
cat >/etc/systemd/system/dagu-time-sync.service <<'EOF'
[Unit]
Description=dagu NTP/HTTP clock for TLS CDN
After=network-online.target NetworkManager-wait-online.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/sbin/dagu-time-sync.py
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/dagu-time-sync.service \
	/etc/systemd/system/multi-user.target.wants/dagu-time-sync.service
cat >/etc/systemd/system/dagu-time-sync.timer <<'EOF'
[Unit]
Description=Refresh dagu wall clock every 6h

[Timer]
OnBootSec=2min
OnUnitActiveSec=6h
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF
ln -sf /etc/systemd/system/dagu-time-sync.timer \
	/etc/systemd/system/timers.target.wants/dagu-time-sync.timer
cat >/etc/NetworkManager/dispatcher.d/50-dagu-time-sync <<'EOF'
#!/bin/sh
[ "$2" = up ] || exit 0
systemctl start dagu-time-sync.service
EOF
chmod 755 /etc/NetworkManager/dispatcher.d/50-dagu-time-sync
systemctl enable systemd-timesyncd.service 2>/dev/null || true

# Hide internal UFS partitions from Files/Nautilus (USB sticks stay visible).
mkdir -p /etc/udev/rules.d
cat >/etc/udev/rules.d/99-dagu-hide-internal-ufs.rules <<'EOF'
ACTION=="add|change", SUBSYSTEM=="block", DEVPATH=="*/1d84000.ufshc/*", ENV{UDISKS_IGNORE}="1"
EOF

# Speakers: ACP has no analog-stereo path for Q6 TDM, so PipeWire stayed
# on Dummy Output. UCM HiFi + mixer oneshot give a 2ch Speaker sink.
mkdir -p /usr/share/alsa/ucm2/Xiaomi-dagu \
	/usr/share/alsa/ucm2/conf.d/sm8250 \
	/usr/share/alsa/ucm2/conf.d/snd-sm8250 \
	/etc/wireplumber/wireplumber.conf.d \
	/etc/udev/rules.d
cat >/usr/share/alsa/ucm2/conf.d/sm8250/Xiaomi-dagu-CS35L41-WCD9385.conf <<'EOF'
Syntax 7

Comment "Xiaomi Pad 5 Pro 12.4 speakers"

SectionUseCase."HiFi" {
	File "/Xiaomi-dagu/HiFi.conf"
	Comment "Play HiFi quality Music"
}
EOF
cp /usr/share/alsa/ucm2/conf.d/sm8250/Xiaomi-dagu-CS35L41-WCD9385.conf \
	/usr/share/alsa/ucm2/conf.d/snd-sm8250/Xiaomi-dagu-CS35L41-WCD9385.conf
cat >/usr/share/alsa/ucm2/Xiaomi-dagu/HiFi.conf <<'EOF'
Syntax 7

SectionVerb {
	EnableSequence [
		cset "name='TERT_TDM_RX_0 Audio Mixer MultiMedia1' on"
		cset "name='TL PCM Source' ASP"
		cset "name='TR PCM Source' ASP"
		cset "name='BL PCM Source' ASP"
		cset "name='BR PCM Source' ASP"
		cset "name='TL Analog PCM Volume' 20"
		cset "name='TR Analog PCM Volume' 20"
		cset "name='BL Analog PCM Volume' 20"
		cset "name='BR Analog PCM Volume' 20"
		cset "name='TL Digital PCM Volume' 850"
		cset "name='TR Digital PCM Volume' 850"
		cset "name='BL Digital PCM Volume' 850"
		cset "name='BR Digital PCM Volume' 850"
	]
	DisableSequence [
		cset "name='TERT_TDM_RX_0 Audio Mixer MultiMedia1' off"
	]
	Value {
		TQ "HiFi"
	}
}

SectionDevice."Speaker" {
	Comment "Speakers"
	Value {
		PlaybackPriority 200
		PlaybackPCM "hw:${CardId},0"
		PlaybackChannels 2
		PlaybackRate 48000
	}
}
EOF
cat >/usr/local/sbin/dagu-speaker-route.sh <<'EOF'
#!/bin/sh
set -eu
CARD="${DAGU_ALSA_CARD:-0}"
cset() {
	amixer -c "$CARD" cset "name=$1" "$2" >/dev/null 2>&1 || true
}
cset "TERT_TDM_RX_0 Audio Mixer MultiMedia1" on
for p in TL TR BL BR; do
	cset "$p PCM Source" ASP
	cset "$p Analog PCM Volume" 20
	cset "$p Digital PCM Volume" 850
done
exit 0
EOF
chmod 755 /usr/local/sbin/dagu-speaker-route.sh
cat >/etc/systemd/system/dagu-speaker-route.service <<'EOF'
[Unit]
Description=dagu CS35L41 TDM mixer route
After=sound.target systemd-udev-settle.service
Wants=sound.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/dagu-speaker-route.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/dagu-speaker-route.service \
	/etc/systemd/system/multi-user.target.wants/dagu-speaker-route.service
cat >/etc/udev/rules.d/99-dagu-speaker.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="sound", KERNEL=="controlC0", RUN+="/usr/local/sbin/dagu-speaker-route.sh"
EOF
cat >/etc/wireplumber/wireplumber.conf.d/50-dagu-speaker.conf <<'EOF'
monitor.alsa.rules = [
  {
    matches = [
      { device.name = "~alsa_card.platform-sound" }
    ]
    actions = {
      update-props = {
        api.alsa.use-ucm = true
        api.acp.auto-profile = true
        api.acp.auto-port = true
        api.alsa.disable-pro-audio = true
        device.profile = "HiFi"
        device.nick = "Speakers"
      }
    }
  }
  {
    matches = [
      { node.name = "~alsa_output.platform-sound.*" }
    ]
    actions = {
      update-props = {
        audio.channels = 2
        audio.rate = 48000
        audio.format = "S24_LE"
        audio.position = [ FL FR ]
        node.nick = "Speakers"
        priority.session = 2000
      }
    }
  }
]
EOF

rm -f /usr/sbin/policy-rc.d
echo "==> desktop setup done"
