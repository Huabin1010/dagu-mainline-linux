#!/bin/bash
# Runs inside an arm64 Ubuntu chroot/container. Configures dagu desktop.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
PASS="${ROOT_PASSWORD:-}"
if [ -z "$PASS" ]; then
	echo "rootfs-desktop-setup: set ROOT_PASSWORD (do not hardcode a password in git)" >&2
	exit 1
fi
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
	gnome-snapshot gstreamer1.0-libcamera libcamera-ipa libspa-0.2-libcamera \
	gir1.2-gst-plugins-base-1.0 \
	libgl1-mesa-dri libgbm1 mesa-vulkan-drivers \
	libinput-bin xserver-xorg-input-libinput python3-evdev \
	fonts-noto-core fonts-noto-cjk \
	network-manager onboard keyd \
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

# Classic HID keyboards (K380): BlueZ 5.64+ rejects unbonded HIDP by default,
# so GNOME can show Connected while hidp_add_connection fails and no evdev
# node appears. Pairing PIN is typed on the keyboard, so HID must be allowed
# before bonding. See linux-mainline/bluetooth/input.conf.
mkdir -p /etc/bluetooth
cat >/etc/bluetooth/input.conf <<'EOF'
[General]
ClassicBondedOnly=false
UserspaceHID=persist
EOF
# HID host (classic keyboard + BLE mouse): keep sniff / UART RPM / QCA IBS.
# Sniff 6–18 slots = 3.75–11.25 ms (not the ACL 80–800). FastConnectable is
# interlaced page scan at 160 ms so a waking K380 can page us. PageTimeout
# 10.24 s because QCA6390 shares the radio with LE HID.
# ReconnectUUIDs stays audio-only. Classic HID keyboards page the host on
# keypress; if bluetoothd outgoing-pages them for PageTimeout the radio is
# not in page scan and both sides miss. Do not add HID 00001124.
# Do not clear HCI_LP_SNIFF or pin UART on.
bt_main_set() {
	local key=$1 val=$2 file=/etc/bluetooth/main.conf
	[ -f "$file" ] || return 0
	if grep -qE "^#?${key}" "$file"; then
		sed -i -E "s|^#?${key}.*|${key}=${val}|" "$file"
	else
		printf '\n%s=%s\n' "$key" "$val" >>"$file"
	fi
}
bt_main_set MinSniffInterval 6
bt_main_set MaxSniffInterval 18
bt_main_set PageTimeout 16384
bt_main_set FastConnectable true
bt_main_set PageScanInterval 0x0100
bt_main_set PageScanWindow 0x0012
bt_main_set ReconnectUUIDs '00001112-0000-1000-8000-00805f9b34fb,0000111f-0000-1000-8000-00805f9b34fb,0000110a-0000-1000-8000-00805f9b34fb,0000110b-0000-1000-8000-00805f9b34fb'
# Computer/Tablet CoD so classic HID inquiry sees a tablet, not 0x000000.
# TemporaryTimeout 180s: unpaired Inquiry results stay in BlueZ (Android
# pairing UI keeps them; default 30s is why bluetoothctl "Device not available").
# JustWorksRepairing: K380 channel re-pair after the keyboard was bonded to
# Android. Privacy=off: classic PIN HID. LE interval 24–40 (30–50 ms) is the
# HID+BR coexistence floor so Inquiry can hear FHS while the mouse is up.
# Do not set ControllerMode=bredr (that kills HOG). Do not add HID ReconnectUUIDs.
bt_main_set Class 0x00011c
bt_main_set TemporaryTimeout 180
bt_main_set JustWorksRepairing always
bt_main_set Privacy off
bt_main_set PairableTimeout 0
bt_main_set MinConnectionInterval 24
bt_main_set MaxConnectionInterval 40
# Keep HCI_CONNECTABLE / bondable after GNOME closes the bluetooth panel.
# Forget of the last classic HID device otherwise drops SCAN_PAGE and the
# next K380 pair attempt is Create Connection with Pairable=no → device gone.
cat >/usr/local/sbin/dagu-bt-hid-host.sh <<'EOF'
#!/bin/sh
set -eu
bt() { timeout 2 btmgmt --index 0 "$@" >/dev/null 2>&1 || true; }
i=0
while [ "$i" -lt 10 ]; do
	timeout 1 btmgmt info >/dev/null 2>&1 && break
	i=$((i + 1))
	sleep 0.3
done
bt connectable on
bt bondable on
bt fast-conn on
timeout 2 bluetoothctl pairable on >/dev/null 2>&1 || true
EOF
chmod 755 /usr/local/sbin/dagu-bt-hid-host.sh
mkdir -p /etc/systemd/system/bluetooth.service.d
cat >/etc/systemd/system/bluetooth.service.d/dagu-hid-host.conf <<'EOF'
[Service]
ExecStartPost=/usr/local/sbin/dagu-bt-hid-host.sh
EOF
cat >/etc/udev/rules.d/90-dagu-bt-hid-host.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="bluetooth", KERNEL=="hci0", RUN+="/usr/local/sbin/dagu-bt-hid-host.sh"
EOF


mkdir -p /etc/gdm3
cat >/etc/gdm3/custom.conf <<'EOF'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=dagu
DefaultSession=ubuntu.desktop
WaylandEnable=true
EOF

# Stale /tmp/.X*-lock makes XWayland fail 50 times and GDM give up the display.
# Honest KMS modifiers: SEND=1 advertises QCOM_*, USE=1 lets the primary fb
# be QCOM_COMPRESSED (UBWC). Chrome windows are native UBWC now, so do not
# set disable-direct-scanout (that was the LINEAR flower contract).
# Do not set FD_MESA_DEBUG on mutter — noubwc/notile breaks UBWC import.
# Onboard on Wayland eats touch (XInput fallback). GNOME OSK is enough.
mkdir -p /etc/systemd/system/gdm.service.d
cat >/etc/systemd/system/gdm.service.d/dagu-kms.conf <<'EOF'
[Service]
Environment=MUTTER_DEBUG_DISABLE_HW_CURSORS=1
Environment=MUTTER_DEBUG_SEND_KMS_MODIFIERS=1
Environment=MUTTER_DEBUG_USE_KMS_MODIFIERS=1
Environment=GSK_RENDERER=ngl
Environment=MESA_EXTENSION_OVERRIDE=-EGL_KHR_swap_buffers_with_damage;-EGL_EXT_swap_buffers_with_damage;-EGL_KHR_partial_update
UnsetEnvironment=FD_MESA_DEBUG TU_DEBUG LD_PRELOAD MESA_VK_WSI_DEBUG DAGU_LINEAR_DESTILE MUTTER_DEBUG_PAINT
ExecStartPre=/bin/sh -c "rm -f /tmp/.X*-lock; mkdir -p /tmp/.X11-unix; find /tmp/.X11-unix -mindepth 1 -delete || true"
EOF

# GPU: never force llvmpipe here. GDM's systemd --user reads environment.d,
# and LIBGL_ALWAYS_SOFTWARE=1 + mutter GBM on card0 SIGSEGVs on the first swap.
mkdir -p /etc/environment.d
rm -f /etc/environment.d/dagu-swrend.conf
cat >/etc/environment.d/dagu-mutter.conf <<'EOF'
MUTTER_DEBUG_DISABLE_HW_CURSORS=1
MUTTER_DEBUG_SEND_KMS_MODIFIERS=1
MUTTER_DEBUG_USE_KMS_MODIFIERS=1
GSK_RENDERER=ngl
MESA_EXTENSION_OVERRIDE=-EGL_KHR_swap_buffers_with_damage;-EGL_EXT_swap_buffers_with_damage;-EGL_KHR_partial_update
EOF
mkdir -p /etc/systemd/user.conf.d
cat >/etc/systemd/user.conf.d/dagu-mutter.conf <<'EOF'
[Manager]
DefaultEnvironment=MUTTER_DEBUG_DISABLE_HW_CURSORS=1 MUTTER_DEBUG_SEND_KMS_MODIFIERS=1 MUTTER_DEBUG_USE_KMS_MODIFIERS=1 GSK_RENDERER=ngl MESA_EXTENSION_OVERRIDE=-EGL_KHR_swap_buffers_with_damage;-EGL_EXT_swap_buffers_with_damage;-EGL_KHR_partial_update
EOF
# gnome-shell is org.gnome.Shell@.service under the user manager, which can
# outlive GDM restarts. Put the compositor contract on that unit so mutter
# cannot keep a stale SEND=0 / FD_MESA_DEBUG=notile from an old manager.
mkdir -p /etc/systemd/user/org.gnome.Shell@.service.d
cat >/etc/systemd/user/org.gnome.Shell@.service.d/dagu-kms.conf <<'EOF'
[Service]
Environment=MUTTER_DEBUG_DISABLE_HW_CURSORS=1
Environment=MUTTER_DEBUG_SEND_KMS_MODIFIERS=1
Environment=MUTTER_DEBUG_USE_KMS_MODIFIERS=1
Environment=GSK_RENDERER=ngl
Environment=MESA_EXTENSION_OVERRIDE=-EGL_KHR_swap_buffers_with_damage;-EGL_EXT_swap_buffers_with_damage;-EGL_KHR_partial_update
UnsetEnvironment=FD_MESA_DEBUG TU_DEBUG LD_PRELOAD MESA_VK_WSI_DEBUG DAGU_LINEAR_DESTILE MUTTER_DEBUG_PAINT
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
# pixels LINEAR and load dagu-mesa (LINEAR GMEM store/fetch). Destile stays
# off. linear-mod is Chrome/Mineradio only — not gnome-shell.
CHROME_DISABLE_FEATURES='Vulkan,DefaultANGLEVulkan,VulkanFromANGLE,WaylandOverlayDelegation'
if [ -x /opt/google/chrome/chrome ]; then
	cat >/usr/local/bin/dagu-chrome <<'EOF'
#!/bin/sh
# Fonts at any Mutter scale: fractional DPR + no LCD (270° panel).
profile="${HOME}/.config/google-chrome"
lock="$profile/SingletonLock"
if [ -L "$lock" ]; then
	hostpid=$(readlink "$lock")
	pid=${hostpid##*-}
	if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
		rm -f "$profile/SingletonLock" "$profile/SingletonSocket" "$profile/SingletonCookie"
		rm -rf /tmp/com.google.Chrome.* /tmp/.com.google.Chrome.*
	fi
fi
export FONTCONFIG_PATH="${FONTCONFIG_PATH:-/etc/fonts}"
export FREETYPE_PROPERTIES="${FREETYPE_PROPERTIES:-truetype:interpreter-version=40}"
if [ -f /usr/local/lib/dagu-mesa/libgallium-26.0.8-1ubuntu0.3.so ]; then
	export LD_LIBRARY_PATH="/usr/local/lib/dagu-mesa${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
# Native UBWC: do not LD_PRELOAD libdagu-linear-mod.so.
if [ ! -e "$lock" ] && [ -f "$profile/Local State" ]; then
	python3 - "$profile/Local State" <<'PY' 2>/dev/null || true
import json, sys
p = sys.argv[1]
with open(p, "r", encoding="utf-8") as f:
    d = json.load(f)
labs = d.setdefault("browser", {}).setdefault("enabled_labs_experiments", [])
if not isinstance(labs, list):
    labs = []
    d["browser"]["enabled_labs_experiments"] = labs
changed = False
for drop in ("lcd-text-aa@1", "lcd-text-aa@0"):
    if drop in labs:
        labs.remove(drop)
        changed = True
if "lcd-text-aa@2" not in labs:
    labs.append("lcd-text-aa@2")
    changed = True
if changed:
    with open(p, "w", encoding="utf-8") as f:
        json.dump(d, f, separators=(",", ":"))
PY
fi
ENABLE_FEAT="WaylandTextInputV3,WaylandFractionalScaleV1,WaylandLinuxDrmSyncobj,AcceleratedVideoDecoder,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL"
DISABLE_FEAT="Vulkan,DefaultANGLEVulkan,VulkanFromANGLE,WaylandOverlayDelegation"
ANGLE="gles"
if [ "${DAGU_CHROME_VIDEO_OVERLAY:-0}" = "1" ]; then
	ENABLE_FEAT="${ENABLE_FEAT},WaylandOverlayDelegation"
	DISABLE_FEAT="Vulkan,DefaultANGLEVulkan,VulkanFromANGLE"
fi
if [ "${DAGU_CHROME_VULKAN:-0}" = "1" ]; then
	ENABLE_FEAT="${ENABLE_FEAT},Vulkan,DefaultANGLEVulkan,VulkanFromANGLE"
	DISABLE_FEAT="WaylandOverlayDelegation"
	ANGLE="vulkan"
	set -- --enable-gpu-rasterization --enable-zero-copy "$@"
fi
unset GTK_IM_MODULE
exec /opt/google/chrome/chrome \
	--ozone-platform=wayland \
	--ozone-platform-hint=wayland \
	--use-gl=angle \
	--use-angle="$ANGLE" \
	--start-maximized \
	--enable-wayland-ime \
	--disable-gtk-ime \
	--wayland-text-input-version=3 \
	--enable-features="$ENABLE_FEAT" \
	--disable-lcd-text \
	--font-render-hinting=none \
	--disable-features="$DISABLE_FEAT" \
	--ignore-gpu-blocklist \
	"$@"
EOF
	chmod 755 /usr/local/bin/dagu-chrome
	install -m755 /dev/stdin /usr/local/bin/dagu-chromium-native <<'EOF'
#!/bin/sh
# Copied from linux-mainline/scripts/dagu-chromium-native.sh at image build.
# Native UBWC; DAGU_TEAR_CONTRACT=1 enables Turnip + overlay flags.
profile="${HOME}/.config/chromium"
lock="$profile/SingletonLock"
if [ -L "$lock" ]; then
	hostpid=$(readlink "$lock")
	pid=${hostpid##*-}
	if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
		rm -f "$profile/SingletonLock" "$profile/SingletonSocket" "$profile/SingletonCookie"
	fi
fi
export FONTCONFIG_PATH="${FONTCONFIG_PATH:-/etc/fonts}"
export FREETYPE_PROPERTIES="${FREETYPE_PROPERTIES:-truetype:interpreter-version=40}"
STOCK="${DAGU_STOCK_MESA:-0}"
VULKAN="${DAGU_CHROME_VULKAN:-0}"
OVERLAY="${DAGU_CHROME_OVERLAY:-0}"
if [ "${DAGU_TEAR_CONTRACT:-0}" = "1" ]; then
	STOCK=1
	VULKAN=1
	OVERLAY=1
fi
unset LD_PRELOAD
if [ "$STOCK" != "1" ] && [ -f /usr/local/lib/dagu-mesa/libgallium-26.0.8-1ubuntu0.3.so ]; then
	export LD_LIBRARY_PATH="/usr/local/lib/dagu-mesa${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
CHROME_BIN=/usr/bin/chromium
[ -x "$CHROME_BIN" ] || CHROME_BIN=/usr/lib/chromium/chromium
export CHROME_DESKTOP="${CHROME_DESKTOP:-org.chromium.Chromium.desktop}"
ENABLE_FEAT="WaylandTextInputV3,WaylandFractionalScaleV1,WaylandLinuxDrmSyncobj,AcceleratedVideoDecoder,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL,AcceleratedVideoEncoder,AcceleratedVideoEncodeLinux,MediaRecorderHEVCSupport"
DISABLE_FEAT="Vulkan,DefaultANGLEVulkan,VulkanFromANGLE,WaylandOverlayDelegation"
ANGLE="gles"
if [ "$OVERLAY" = "1" ]; then
	ENABLE_FEAT="${ENABLE_FEAT},WaylandOverlayDelegation,HardwareOverlays"
	DISABLE_FEAT="Vulkan,DefaultANGLEVulkan,VulkanFromANGLE"
fi
if [ "$VULKAN" = "1" ]; then
	ENABLE_FEAT="${ENABLE_FEAT},Vulkan,DefaultANGLEVulkan,VulkanFromANGLE"
	if [ "$OVERLAY" = "1" ]; then
		DISABLE_FEAT=""
	else
		DISABLE_FEAT="WaylandOverlayDelegation"
	fi
	ANGLE="vulkan"
	set -- --enable-gpu-rasterization --enable-zero-copy "$@"
fi
if [ "${DAGU_CHROME_WAYLAND_BFS:-0}" = "1" ]; then
	ENABLE_FEAT="${ENABLE_FEAT},WaylandExternalBeginFrameSource"
fi
set -- --enable-features="$ENABLE_FEAT" "$@"
if [ -n "$DISABLE_FEAT" ]; then
	set -- --disable-features="$DISABLE_FEAT" "$@"
fi
unset GTK_IM_MODULE
exec "$CHROME_BIN" \
	--ozone-platform=wayland \
	--ozone-platform-hint=wayland \
	--use-gl=angle \
	--use-angle="$ANGLE" \
	--start-maximized \
	--enable-wayland-ime \
	--disable-gtk-ime \
	--wayland-text-input-version=3 \
	--disable-lcd-text \
	--font-render-hinting=none \
	--ignore-gpu-blocklist \
	"$@"
EOF
	cat >/usr/local/bin/dagu-chromium <<'EOF'
#!/bin/sh
exec /usr/local/bin/dagu-chromium-native "$@"
EOF
	chmod 755 /usr/local/bin/dagu-chromium /usr/local/bin/dagu-chromium-native
	mkdir -p /usr/local/share/applications /home/dagu/.local/share/applications
	if [ -f /usr/share/applications/google-chrome.desktop ]; then
		sed 's|^Exec=/usr/bin/google-chrome-stable|Exec=/usr/local/bin/dagu-chrome|' \
			/usr/share/applications/google-chrome.desktop \
			>/usr/local/share/applications/google-chrome.desktop
		cp /usr/local/share/applications/google-chrome.desktop \
			/home/dagu/.local/share/applications/google-chrome.desktop
		chown dagu:dagu /home/dagu/.local/share/applications/google-chrome.desktop
	fi
	if [ -f /usr/share/applications/chromium.desktop ]; then
		sed -e 's|^Exec=.*chromium|Exec=/usr/local/bin/dagu-chromium|' \
			-e 's|^Name=.*|Name=Chromium (Venus)|' \
			-e 's|^StartupWMClass=.*|StartupWMClass=org.chromium.Chromium|' \
			/usr/share/applications/chromium.desktop \
			>/usr/local/share/applications/chromium.desktop
		cp /usr/local/share/applications/chromium.desktop \
			/usr/local/share/applications/org.chromium.Chromium.desktop
		cp /usr/local/share/applications/chromium.desktop \
			/home/dagu/.local/share/applications/chromium.desktop
		cp /usr/local/share/applications/org.chromium.Chromium.desktop \
			/home/dagu/.local/share/applications/org.chromium.Chromium.desktop
		chown dagu:dagu /home/dagu/.local/share/applications/chromium.desktop \
			/home/dagu/.local/share/applications/org.chromium.Chromium.desktop
		# GNOME 50 looks up Icon= by app_id when the window maps.
		for dir in /usr/share/icons/hicolor/*/apps; do
			[ -e "$dir/chromium.png" ] || [ -e "$dir/chromium.svg" ] || continue
			src=$(ls "$dir"/chromium.png "$dir"/chromium.svg 2>/dev/null | head -1)
			[ -n "$src" ] && ln -sfn "$(basename "$src")" "$dir/org.chromium.Chromium.${src##*.}"
		done
	fi
	# Official google-chrome is USE_V4L2=0 (FFmpeg). HTML5 must open
	# Chromium (Venus /dev/video14). Keep Chrome installed for GLES
	# LINEAR tests, but do not make it the default handler.
	if [ -f /usr/local/share/applications/chromium.desktop ]; then
		mkdir -p /home/dagu/.config /etc/xdg
		python3 - <<'PY'
from pathlib import Path
mime = """[Default Applications]
text/html=chromium.desktop
x-scheme-handler/http=chromium.desktop
x-scheme-handler/https=chromium.desktop
x-scheme-handler/about=chromium.desktop
x-scheme-handler/unknown=chromium.desktop
"""
for p in (Path("/home/dagu/.config/mimeapps.list"), Path("/etc/xdg/mimeapps.list")):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(mime)
PY
		chown dagu:dagu /home/dagu/.config/mimeapps.list
		sudo -u dagu env XDG_RUNTIME_DIR=/run/user/1001 HOME=/home/dagu \
			xdg-settings set default-web-browser chromium.desktop 2>/dev/null || true
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
            'exec -a "$0" "$HERE/chrome" --ozone-platform=wayland --ozone-platform-hint=wayland'
            ' --use-gl=angle --use-angle=gles --start-maximized --enable-wayland-ime --disable-gtk-ime'
            ' --wayland-text-input-version=3 --enable-features=WaylandTextInputV3,WaylandFractionalScaleV1,WaylandLinuxDrmSyncobj,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL'
            ' --disable-lcd-text --font-render-hinting=none --ignore-gpu-blocklist'
            f' --disable-features={feat} "$@"\n'
        )
        continue
    out.append(line)
p.write_text("".join(out))
PY
	fi
fi

# Folio keyboard: tap Shift → fcitx5 toggle. keyd needs /dev/uinput
# (CONFIG_INPUT_UINPUT); this kernel ships without it, so use the evdev watcher.
mkdir -p /etc/keyd
cat >/etc/keyd/dagu.conf <<'EOF'
[ids]
15d9:00a3

[main]
leftshift = overloadt(shift, hangul, 400)
rightshift = overloadt(shift, hangul, 400)
EOF
if [ -f /usr/lib/systemd/system/keyd.service ]; then
	systemctl disable --now keyd.service >/dev/null 2>&1 || true
fi
install -m755 /dev/stdin /usr/local/bin/dagu-fcitx5-shift-tap.py <<'EOF'
#!/usr/bin/env python3
from __future__ import annotations
import os, select, subprocess, time
from evdev import InputDevice, ecodes, list_devices
USER="dagu"; UID=1001; RUNTIME=f"/run/user/{UID}"
DEVICE_NAME="Xiaomi Keyboard"; TAP_SEC=0.50
SHIFTS={ecodes.KEY_LEFTSHIFT, ecodes.KEY_RIGHTSHIFT}
def toggle():
    env=os.environ.copy()
    env.update({"HOME":f"/home/{USER}","XDG_RUNTIME_DIR":RUNTIME,
                "DBUS_SESSION_BUS_ADDRESS":f"unix:path={RUNTIME}/bus",
                "DISPLAY":":0","WAYLAND_DISPLAY":"wayland-0"})
    subprocess.run(["runuser","-u",USER,"--","fcitx5-remote","-t"], env=env,
                   check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
def open_keyboard():
    for path in list_devices():
        try: dev=InputDevice(path)
        except OSError: continue
        if dev.name==DEVICE_NAME: return dev
    return None
def main():
    while True:
        dev=open_keyboard()
        if dev is None:
            time.sleep(1.0); continue
        pending={}
        try:
            while True:
                ready,_,_=select.select([dev.fd],[],[],2.0)
                if not ready: continue
                for ev in dev.read():
                    if ev.type!=ecodes.EV_KEY or ev.value==2: continue
                    if ev.code in SHIFTS:
                        if ev.value==1: pending[ev.code]=(ev.timestamp(), False)
                        elif ev.value==0 and ev.code in pending:
                            t0,dirty=pending.pop(ev.code)
                            if not dirty and (ev.timestamp()-t0)<=TAP_SEC: toggle()
                    elif pending:
                        pending={k:(t0,True) for k,(t0,_) in pending.items()}
        except OSError:
            time.sleep(0.3)
if __name__=="__main__":
    main()
EOF
cat >/etc/systemd/system/dagu-fcitx5-shift-tap.service <<'EOF'
[Unit]
Description=dagu folio Shift tap toggles fcitx5
After=systemd-udevd.service
[Service]
Type=simple
ExecStart=/usr/local/bin/dagu-fcitx5-shift-tap.py
Restart=always
RestartSec=1
[Install]
WantedBy=multi-user.target
EOF
systemctl enable dagu-fcitx5-shift-tap.service >/dev/null 2>&1 || true

# Mineradio is Electron + Three.js WebGL + CSS backdrop-filter. Same Ozone
# / LINEAR / grayscale-DPR contract as Chrome. Never notile (WebGL hang).
if [ -x /opt/Mineradio/mineradio ]; then
	cat >/usr/local/bin/mineradio <<'EOF'
#!/bin/sh
export ELECTRON_OZONE_PLATFORM_HINT=wayland
export FONTCONFIG_PATH="${FONTCONFIG_PATH:-/etc/fonts}"
export FREETYPE_PROPERTIES="${FREETYPE_PROPERTIES:-truetype:interpreter-version=40}"
if [ -f /usr/local/lib/dagu-mesa/libgallium-26.0.8-1ubuntu0.3.so ]; then
	export LD_LIBRARY_PATH="/usr/local/lib/dagu-mesa${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
# Native UBWC: do not LD_PRELOAD libdagu-linear-mod.so.
exec /opt/Mineradio/mineradio \
	--ozone-platform=wayland \
	--ozone-platform-hint=wayland \
	--in-process-gpu \
	--use-gl=angle \
	--use-angle=gles \
	--start-maximized \
	--enable-features=WaylandFractionalScaleV1,WaylandLinuxDrmSyncobj \
	--disable-lcd-text \
	--font-render-hinting=none \
	--disable-partial-swap \
	--disable-features=Vulkan,DefaultANGLEVulkan,VulkanFromANGLE,WaylandOverlayDelegation,PartialSwap \
	--no-sandbox \
	"$@"
EOF
	chmod 755 /usr/local/bin/mineradio
	python3 - <<'PY'
from pathlib import Path
p = Path("/opt/Mineradio/resources/app/desktop/main.js")
if not p.exists():
    raise SystemExit(0)
text = p.read_text(encoding="utf-8")
orig = text
text = text.replace(
    "process.env.FD_MESA_DEBUG = 'noubwc,notile';",
    "process.env.FD_MESA_DEBUG = process.env.FD_MESA_DEBUG || 'noubwc';",
    1,
)
needle = "['disable-features', 'Vulkan,DefaultANGLEVulkan,VulkanFromANGLE,WaylandOverlayDelegation,PartialSwap'],"
if needle not in text:
    needle = "['disable-features', 'Vulkan,DefaultANGLEVulkan,VulkanFromANGLE,WaylandOverlayDelegation'],"
extra = needle + """
    ['enable-features', 'WaylandFractionalScaleV1,WaylandLinuxDrmSyncobj'],
    ['disable-lcd-text'],
    ['font-render-hinting', 'none'],"""
if "['disable-lcd-text']" not in text and needle in text:
    text = text.replace(needle, extra, 1)
if text != orig:
    p.write_text(text, encoding="utf-8")
PY
fi

# Default first-boot scale. Fonts must keep working if the user picks
# 1.0 / 1.25 / 1.33 / 1.67 / 2.0 — do not treat scale 2 as the only fix.
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
  "description": "Show GNOME OSK after tap on Chrome text; fit landscape height.",
  "shell-version": ["50"],
  "session-modes": ["user"]
}
EOF
	cat >"$d/extension.js" <<'EOF'
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const VERSION = 'osk-gate-7';

// Chrome/GNOME open the OSK via KeyboardActor.open() and the delayed
// Actor._open() rest timer. Those bypass KeyboardManager.open. Gate both,
// and only allow a show after a page-content tap plus a caret move.
export default class DaguOskFocus extends Extension {
    enable() {
        this._im = Main.inputMethod;
        this._openTimeout = 0;
        this._closeTimeout = 0;
        this._expireTimeout = 0;
        this._userRequested = false;
        this._awaitContent = false;
        this._conns = [];
        this._visId = 0;
        this._winTitleId = 0;
        this._trackedWin = null;
        this._log(`${VERSION} enable`);
        this._gateAllOpens();
        this._connect(this._im, 'notify::current-focus', () => {
            this._log(`focus=${!!this._im.currentFocus}`);
            if (!this._im.currentFocus)
                this._close('im-blur');
        });
        this._connect(this._im, 'cursor-location-changed', () => {
            this._log(`caret await=${this._awaitContent}`);
            if (this._awaitContent)
                this._requestOpen('caret');
        });
        this._connect(Main.layoutManager, 'monitors-changed', () => {
            this._gateAllOpens();
        });
        this._connect(global.display, 'notify::focus-window', () => {
            this._trackFocusWindow();
            const chrome = this._isChrome();
            this._log(`focus chrome=${chrome} ${this._winLabel()}`);
            if (!chrome)
                this._close('not-chrome');
        });
        this._connect(global.stage, 'captured-event', (_a, event) => {
            this._onPointer(event);
            return Clutter.EVENT_PROPAGATE;
        });
        this._trackFocusWindow();
        this._connectVis();
        this._writeStatus();
    }

    _log(msg) {
        const line = `${Math.round(GLib.get_monotonic_time() / 1000)} ${msg}\n`;
        try {
            const f = Gio.File.new_for_path('/tmp/dagu-osk.log');
            const out = f.append_to(Gio.FileCreateFlags.NONE, null);
            out.write(line, null);
            out.close(null);
        } catch (e) {
        }
    }

    _writeStatus() {
        const actor = Main.keyboard?.keyboardActor;
        const win = global.display.focus_window;
        const vis = !!(actor && actor.visible);
        const text = [
            `ver=${VERSION}`,
            `visible=${vis}`,
            `user=${this._userRequested}`,
            `await=${this._awaitContent}`,
            `title=${win ? win.get_title() : ''}`,
            `wm=${win ? win.get_wm_class() : ''}`,
            `actorOpen=${!!actor?._daguActorOpen}`,
            `actor_open=${!!actor?._daguInternalOpen}`,
            `mgrGate=${!!Main.keyboard?._daguOpenGate}`,
            '',
        ].join('\n');
        try {
            Gio.File.new_for_path('/tmp/dagu-osk.status').replace_contents(
                new TextEncoder().encode(text),
                null, false, Gio.FileCreateFlags.REPLACE_DESTINATION, null);
        } catch (e) {
        }
    }

    _connect(obj, sig, cb) {
        this._conns.push([obj, obj.connect(sig, cb)]);
    }

    _connectVis() {
        const actor = Main.keyboard?.keyboardActor;
        if (!actor || this._visId)
            return;
        this._visId = actor.connect('visibility-changed', () => {
            this._log(`vis=${actor.visible} user=${this._userRequested} chrome=${this._isChrome()}`);
            if (actor.visible && this._isChrome() && !this._userRequested)
                this._close('vis-unrequested');
            this._writeStatus();
        });
    }

    _trackFocusWindow() {
        if (this._trackedWin && this._winTitleId) {
            try {
                this._trackedWin.disconnect(this._winTitleId);
            } catch (e) {
            }
        }
        this._winTitleId = 0;
        this._trackedWin = global.display.focus_window;
        if (!this._trackedWin)
            return;
        this._winTitleId = this._trackedWin.connect('notify::title', () => {
            this._log(`title=${this._trackedWin.get_title()}`);
            this._close('title');
        });
    }

    _winLabel() {
        const win = global.display.focus_window;
        if (!win)
            return 'none';
        const bits = [
            win.get_wm_class?.(),
            win.get_wm_class_instance?.(),
            win.get_gtk_application_id?.(),
            win.get_sandboxed_app_id?.(),
            win.get_title?.(),
        ].filter(Boolean);
        try {
            const pid = win.get_pid();
            bits.push(`pid=${pid}`);
            const [ok, data] = Gio.File.new_for_path(`/proc/${pid}/comm`)
                .load_contents(null);
            if (ok)
                bits.push(new TextDecoder().decode(data).trim());
        } catch (e) {
        }
        return bits.join('|');
    }

    _isChrome() {
        return /chrome|chromium/i.test(this._winLabel());
    }

    _chromeZone(event) {
        const win = global.display.focus_window;
        if (!win || !this._isChrome())
            return 'other';
        const [x, y] = this._eventXY(event);
        const rect = win.get_frame_rect();
        if (x < rect.x || x > rect.x + rect.width ||
            y < rect.y || y > rect.y + rect.height)
            return 'other';
        // Tab strip / close-tab (~36-48px). Omnibox sits in the next band.
        const tabH = Math.max(64, Math.round(rect.height * 0.055));
        if (y <= rect.y + tabH)
            return 'toolbar';
        const boxH = Math.max(170, Math.round(rect.height * 0.15));
        if (y <= rect.y + boxH)
            return 'omnibox';
        return 'content';
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

    _onPointer(event) {
        const type = event.type();
        if (type !== Clutter.EventType.TOUCH_BEGIN &&
            type !== Clutter.EventType.BUTTON_PRESS)
            return;
        const zone = this._chromeZone(event);
        const [x, y] = this._eventXY(event);
        this._log(`tap zone=${zone} xy=${Math.round(x)},${Math.round(y)}`);
        this._awaitContent = false;
        if (zone === 'omnibox') {
            this._requestOpen('omnibox-tap');
            return;
        }
        if (zone !== 'content') {
            this._close(`tap-${zone}`);
            return;
        }
        this._awaitContent = true;
        if (this._closeTimeout)
            GLib.source_remove(this._closeTimeout);
        this._closeTimeout = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 450, () => {
            this._closeTimeout = 0;
            if (this._awaitContent) {
                this._awaitContent = false;
                this._close('content-miss');
            }
            return GLib.SOURCE_REMOVE;
        });
    }

    _requestOpen(why) {
        if (this._closeTimeout) {
            GLib.source_remove(this._closeTimeout);
            this._closeTimeout = 0;
        }
        this._awaitContent = false;
        if (this._openTimeout)
            GLib.source_remove(this._openTimeout);
        this._log(`request ${why}`);
        this._openTimeout = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 30, () => {
            this._openTimeout = 0;
            this._open();
            return GLib.SOURCE_REMOVE;
        });
    }

    _wrapFn(obj, key, flag, fn) {
        if (!obj || obj[flag])
            return;
        obj[flag] = obj[key].bind(obj);
        obj[key] = fn;
    }

    _gateAllOpens() {
        const mgr = Main.keyboard;
        if (mgr && !mgr._daguOpenGate) {
            mgr._daguOpenGate = true;
            this._origMgrOpen = mgr.open.bind(mgr);
            mgr.open = monitor => {
                if (this._isChrome() && !this._userRequested) {
                    this._log('block mgr.open');
                    return;
                }
                this._origMgrOpen(monitor);
            };
            if (typeof mgr.close === 'function')
                this._origMgrClose = mgr.close.bind(mgr);
        }
        const actor = mgr?.keyboardActor;
        if (!actor)
            return;
        this._wrapFn(actor, 'open', '_daguActorOpen', immediate => {
            if (this._isChrome() && !this._userRequested) {
                this._log('block actor.open');
                return;
            }
            actor._daguActorOpen(immediate);
        });
        this._wrapFn(actor, '_open', '_daguInternalOpen', () => {
            if (this._isChrome() && !this._userRequested) {
                this._log('block actor._open');
                return;
            }
            actor._daguInternalOpen();
        });
        if (!actor._daguRelayout) {
            const origRelayout = actor._relayout.bind(actor);
            actor._daguRelayout = true;
            actor._relayout = () => {
                origRelayout();
                const mon = Main.layoutManager.keyboardMonitor;
                if (!mon)
                    return;
                actor.width = mon.width;
                if (mon.width > mon.height)
                    actor.height = Math.round(Math.min(mon.height * 0.46, 380));
            };
        }
        this._connectVis();
    }

    _open() {
        this._gateAllOpens();
        this._userRequested = true;
        this._log('open');
        try {
            const idx = Main.layoutManager.focusIndex;
            Main.layoutManager.keyboardIndex = idx;
            if (this._origMgrOpen)
                this._origMgrOpen(idx);
            else
                Main.keyboard?.open(idx);
            const actor = Main.keyboard?.keyboardActor;
            actor?._relayout?.();
            actor?._daguInternalOpen?.();
        } catch (e) {
            this._log(`open-err ${e}`);
        }
        if (this._expireTimeout)
            GLib.source_remove(this._expireTimeout);
        this._expireTimeout = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 180, () => {
            this._expireTimeout = 0;
            this._userRequested = false;
            this._writeStatus();
            return GLib.SOURCE_REMOVE;
        });
        this._writeStatus();
    }

    _cancelActorTimers() {
        const actor = Main.keyboard?.keyboardActor;
        try {
            actor?._clearKeyboardRestTimer?.();
        } catch (e) {
        }
        try {
            actor?._clearShowIdle?.();
        } catch (e) {
        }
    }

    _close(why) {
        if (this._openTimeout) {
            GLib.source_remove(this._openTimeout);
            this._openTimeout = 0;
        }
        this._awaitContent = false;
        this._userRequested = false;
        this._cancelActorTimers();
        const actor = Main.keyboard?.keyboardActor;
        const was = !!(actor && actor.visible);
        try {
            actor?.close?.(true);
        } catch (e) {
        }
        try {
            if (this._origMgrClose)
                this._origMgrClose();
            else
                Main.keyboard?.close?.();
        } catch (e) {
        }
        if (was || why)
            this._log(`close ${why || ''} was=${was}`);
        this._writeStatus();
    }

    disable() {
        if (this._openTimeout)
            GLib.source_remove(this._openTimeout);
        if (this._closeTimeout)
            GLib.source_remove(this._closeTimeout);
        if (this._expireTimeout)
            GLib.source_remove(this._expireTimeout);
        this._openTimeout = 0;
        this._closeTimeout = 0;
        this._expireTimeout = 0;
        const actor = Main.keyboard?.keyboardActor;
        if (actor) {
            if (this._visId) {
                try {
                    actor.disconnect(this._visId);
                } catch (e) {
                }
            }
            if (actor._daguActorOpen) {
                actor.open = actor._daguActorOpen;
                delete actor._daguActorOpen;
            }
            if (actor._daguInternalOpen) {
                actor._open = actor._daguInternalOpen;
                delete actor._daguInternalOpen;
            }
        }
        this._visId = 0;
        if (this._trackedWin && this._winTitleId) {
            try {
                this._trackedWin.disconnect(this._winTitleId);
            } catch (e) {
            }
        }
        this._winTitleId = 0;
        this._trackedWin = null;
        const mgr = Main.keyboard;
        if (mgr?._daguOpenGate && this._origMgrOpen) {
            mgr.open = this._origMgrOpen;
            mgr._daguOpenGate = false;
        }
        for (const [obj, id] of this._conns)
            obj.disconnect(id);
        this._conns = [];
        this._log(`${VERSION} disable`);
    }
}

EOF
}
install_dagu_osk /usr/share/gnome-shell/extensions/dagu-osk-focus@dagu
install_dagu_osk /home/dagu/.local/share/gnome-shell/extensions/dagu-osk-focus@dagu
install_dagu_present_pump() {
	local d="$1"
	mkdir -p "$d"
	cp -a /dev/null "$d/metadata.json" 2>/dev/null || true
	cat >"$d/metadata.json" <<'EOF'
{
  "uuid": "dagu-present-pump@local",
  "name": "dagu present pump",
  "description": "Keep Mutter frame clock alive: schedule_update on touch, 1×1 only while maximized idle. Do not 1×1 during swipe (that destile is a 100–340 ms kickoff hole).",
  "shell-version": ["50"]
}
EOF
	cat >"$d/extension.js" <<'EOF'
import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import St from 'gi://St';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const HOLD_US = 800 * 1000;
const TICK_MS = 8;

export default class DaguPresentPumpExtension extends Extension {
    enable() {
        this._until = 0;
        this._pump = 0;
        this._nudgeBit = 0;
        this._stage = global.stage;
        this._dot = new St.Bin({
            width: 1,
            height: 1,
            opacity: 1,
            reactive: false,
            x: 0,
            y: 0,
            style: 'background-color: rgba(0,0,0,0.02);',
        });
        this._stage.add_child(this._dot);
        this._handler = this._stage.connect('captured-event', (_s, ev) => {
            switch (ev.type()) {
            case Clutter.EventType.TOUCH_BEGIN:
            case Clutter.EventType.TOUCH_UPDATE:
            case Clutter.EventType.BUTTON_PRESS:
            case Clutter.EventType.MOTION:
                this._until = GLib.get_monotonic_time() + HOLD_US;
                break;
            default:
                break;
            }
            return Clutter.EVENT_PROPAGATE;
        });
        this._pump = GLib.timeout_add(GLib.PRIORITY_DEFAULT, TICK_MS, () => {
            const mode = this._pumpMode();
            if (mode === 'touch')
                this._tickClock();
            else if (mode === 'idle')
                this._nudge();
            return GLib.SOURCE_CONTINUE;
        });
    }

    _tickClock() {
        if (typeof this._stage.schedule_update === 'function')
            this._stage.schedule_update();
        else
            this._stage.queue_redraw();
    }

    _nudge() {
        this._nudgeBit ^= 1;
        this._dot.opacity = this._nudgeBit ? 2 : 1;
        this._dot.set_position(this._nudgeBit, 0);
    }

    _pumpMode() {
        if (GLib.get_monotonic_time() < this._until)
            return 'touch';
        const win = global.display.focus_window;
        if (!win)
            return '';
        let maxed = false;
        try {
            maxed = typeof win.is_maximized === 'function'
                ? win.is_maximized()
                : (typeof win.get_maximized === 'function'
                    ? win.get_maximized() !== Meta.MaximizeFlags.NONE
                    : false);
        } catch (_e) {
            maxed = false;
        }
        if (maxed || win.is_fullscreen())
            return 'idle';
        return '';
    }

    disable() {
        if (this._handler) {
            this._stage.disconnect(this._handler);
            this._handler = 0;
        }
        if (this._pump) {
            GLib.source_remove(this._pump);
            this._pump = 0;
        }
        if (this._dot) {
            this._dot.destroy();
            this._dot = null;
        }
    }
}
EOF
}
install_dagu_present_pump /usr/share/gnome-shell/extensions/dagu-present-pump@local
install_dagu_present_pump /home/dagu/.local/share/gnome-shell/extensions/dagu-present-pump@local
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
enabled-extensions=['ding@rastersoft.com', 'ubuntu-dock@ubuntu.com', 'tiling-assistant@ubuntu.com', 'dagu-osk-focus@dagu', 'dagu-present-pump@local']

[org/gnome/desktop/input-sources]
sources=[('xkb', 'us'), ('ibus', 'libpinyin')]

[org/gnome/desktop/interface]
toolkit-accessibility=true
scaling-factor=uint32 0
font-antialiasing='grayscale'
font-hinting='none'
color-scheme='default'

[org/gnome/mutter]
# Do NOT enable scale-monitor-framebuffer on dagu. 270° + 1.25 +
# that feature empties Mutter unobscured_region, drops Chrome damage,
# and interlocks Ozone WaitForSwap (80–180 ms kickoff holes).
# Fractional 1.25 still comes from DisplayConfig scale.
experimental-features=@as []

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
mkdir -p /etc/fonts/conf.d
cat >/etc/fonts/conf.d/99-dagu-gray-fonts.conf <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <match target="font">
    <edit name="rgba" mode="assign"><const>none</const></edit>
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
  </match>
</fontconfig>
EOF

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
# Ubuntu puts resize2fs in /usr/sbin, not /sbin.
dev=$(awk '$2 == "/" { print $1; exit }' /proc/mounts)
[ -n "$dev" ] || exit 0
for bin in /usr/sbin/resize2fs /sbin/resize2fs resize2fs; do
	command -v "$bin" >/dev/null 2>&1 || continue
	exec "$bin" "$dev"
done
exit 1
EOF
chmod 755 /usr/local/sbin/dagu-resize-root.sh
cat >/etc/systemd/system/dagu-resize-root.service <<'EOF'
[Unit]
Description=Grow Ubuntu ext4 on userdata
After=local-fs.target
ConditionPathExists=|/usr/sbin/resize2fs
ConditionPathExists=|/sbin/resize2fs

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
		cset "name='TL PCM Source' DSP"
		cset "name='TR PCM Source' DSP"
		cset "name='BL PCM Source' DSP"
		cset "name='BR PCM Source' DSP"
		cset "name='TL DRE Switch' on"
		cset "name='TR DRE Switch' on"
		cset "name='BL DRE Switch' on"
		cset "name='BR DRE Switch' on"
		cset "name='TL Analog PCM Volume' 18"
		cset "name='TR Analog PCM Volume' 18"
		cset "name='BL Analog PCM Volume' 18"
		cset "name='BR Analog PCM Volume' 18"
		cset "name='TL Digital PCM Volume' 817"
		cset "name='TR Digital PCM Volume' 817"
		cset "name='BL Digital PCM Volume' 817"
		cset "name='BR Digital PCM Volume' 817"
		cset "name='TL ASP TX1 Source' VMON"
		cset "name='TR ASP TX1 Source' VMON"
		cset "name='BL ASP TX1 Source' VMON"
		cset "name='BR ASP TX1 Source' VMON"
		cset "name='TL ASP TX2 Source' IMON"
		cset "name='TR ASP TX2 Source' IMON"
		cset "name='BL ASP TX2 Source' IMON"
		cset "name='BR ASP TX2 Source' IMON"
		cset "name='TL PCM Soft Ramp' 4ms"
		cset "name='TR PCM Soft Ramp' 4ms"
		cset "name='BL PCM Soft Ramp' 4ms"
		cset "name='BR PCM Soft Ramp' 4ms"
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
		PlaybackFormat "S24_LE"
		# No PlaybackMixerElem: GNOME must not move Digital PCM.
	}
}
EOF
cat >/usr/local/sbin/dagu-speaker-route.sh <<'EOF'
#!/bin/sh
set -eu
CARD="${DAGU_ALSA_CARD:-0}"
FWDIR=/lib/firmware/cirrus
STAMP=/run/dagu/speaker-dsp-loaded
cset() {
	amixer -c "$CARD" cset "name=$1" "$2" >/dev/null 2>&1 || true
}
cset "TERT_TDM_RX_0 Audio Mixer MultiMedia1" on
mkdir -p /run/dagu
if [ ! -f "$STAMP" ]; then
	for p in TL TR BL BR; do
		cset "$p DSP1 Preload" off || cset "$p DSP1 Preload Switch" off || true
	done
	for p in TL TR BL BR; do
		bin="$FWDIR/${p}-cs35l41-dsp1-spk-prot.bin"
		[ -f "$bin" ] && cp -f "$bin" "$FWDIR/cs35l41-dsp1-spk-prot.bin"
		cset "$p DSP1 Firmware" Protection
		cset "$p DSP RX1 Source" ASPRX1
		cset "$p DSP RX2 Source" ASPRX2
		cset "$p ASP TX1 Source" VMON
		cset "$p ASP TX2 Source" IMON
		cset "$p DSP1 Preload" on || cset "$p DSP1 Preload Switch" on || true
	done
	date -u +%s >"$STAMP"
fi
for p in TL TR BL BR; do
	cset "$p DSP1 Firmware" Protection
	cset "$p DSP RX1 Source" ASPRX1
	cset "$p DSP RX2 Source" ASPRX2
	cset "$p ASP TX1 Source" VMON
	cset "$p ASP TX2 Source" IMON
	cset "$p PCM Soft Ramp" 4ms
	cset "$p DRE" on || cset "$p DRE Switch" on || true
	cset "$p Analog PCM" 18 || cset "$p Analog PCM Volume" 18 || true
	cset "$p Digital PCM" 817 || cset "$p Digital PCM Volume" 817 || true
	cset "$p Boost Class-H Tracking Enable" 1
	cset "$p Boost Target Voltage" 0
	cset "$p PCM Source" DSP
done
WP_STAMP=/run/dagu/wireplumber-kicked
if [ ! -f "$WP_STAMP" ]; then
	uid="$(id -u dagu 2>/dev/null || true)"
	if [ -n "$uid" ] && [ -d "/run/user/$uid" ]; then
		sudo -u dagu XDG_RUNTIME_DIR="/run/user/$uid" \
			systemctl --user try-restart pipewire.service >/dev/null 2>&1 || true
	fi
	date -u +%s >"$WP_STAMP"
fi
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
        api.alsa.split-enable = false
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
        alsa.resolution_bits = 24
        api.alsa.soft-mixer = true
        audio.position = [ FL FR ]
        node.nick = "Speakers"
        priority.session = 2000
      }
    }
  }
]
EOF
# Chrome getUserMedia must not see spa-libcamera (12MP CPU demosaic starves
# mutter). SoftISP stays in dagu-camera-loopback-watch → video20/21.
# spa-v4l2 cannot open CAMSS MPLANE RDI; hide those nodes. Venus is 14/15.
cat >/etc/wireplumber/wireplumber.conf.d/60-dagu-camera.conf <<'EOF'
wireplumber.profiles = {
  main = {
    monitor.libcamera = disabled
  }
}
monitor.v4l2.rules = [
  {
    matches = [
      { api.v4l2.path = "/dev/video0" }
      { api.v4l2.path = "/dev/video1" }
      { api.v4l2.path = "/dev/video2" }
      { api.v4l2.path = "/dev/video3" }
      { api.v4l2.path = "/dev/video4" }
      { api.v4l2.path = "/dev/video5" }
      { api.v4l2.path = "/dev/video6" }
      { api.v4l2.path = "/dev/video7" }
      { api.v4l2.path = "/dev/video8" }
      { api.v4l2.path = "/dev/video9" }
      { api.v4l2.path = "/dev/video10" }
      { api.v4l2.path = "/dev/video11" }
      { api.v4l2.path = "/dev/video12" }
      { api.v4l2.path = "/dev/video13" }
      { api.v4l2.path = "/dev/video14" }
      { api.v4l2.path = "/dev/video15" }
    ]
    actions = {
      update-props = {
        node.disabled = true
      }
    }
  }
  {
    matches = [
      { api.v4l2.path = "/dev/video20" }
    ]
    actions = {
      update-props = {
        node.description = "dagu Front Camera"
        media.role = "Camera"
        api.libcamera.location = "front"
        priority.session = 810
        node.always-process = false
        session.suspend-timeout-seconds = 3
      }
    }
  }
  {
    matches = [
      { api.v4l2.path = "/dev/video21" }
    ]
    actions = {
      update-props = {
        node.description = "dagu Rear Camera"
        media.role = "Camera"
        api.libcamera.location = "back"
        priority.session = 800
        node.always-process = false
        session.suspend-timeout-seconds = 3
      }
    }
  }
]
EOF
# SIGKILL/WP-only restart leaves CSIPHY→CSID enabled; next match is EBUSY
# and Snapshot shows No Camera Found. Reset mutable links before PW/WP.
cat >/usr/local/sbin/dagu-camss-graph-reset.sh <<'EOF'
#!/bin/sh
set -eu
MC="${DAGU_CAMSS_MEDIA:-/dev/media0}"
[ -e "$MC" ] || exit 0
command -v media-ctl >/dev/null || exit 0
media-ctl -d "$MC" -r >/dev/null 2>&1 || true
exit 0
EOF
chmod 755 /usr/local/sbin/dagu-camss-graph-reset.sh
mkdir -p /etc/systemd/user/pipewire.service.d \
	/etc/systemd/user/wireplumber.service.d
cat >/etc/systemd/user/pipewire.service.d/dagu-camss-reset.conf <<'EOF'
[Service]
ExecStartPre=/usr/local/sbin/dagu-camss-graph-reset.sh
EOF
cat >/etc/systemd/user/wireplumber.service.d/dagu-camss-reset.conf <<'EOF'
[Service]
ExecStartPre=/usr/local/sbin/dagu-camss-graph-reset.sh
EOF
rm -f /etc/systemd/user/dagu-camera-pw-source.service \
	/etc/systemd/user/default.target.wants/dagu-camera-pw-source.service
mkdir -p /etc/udev/rules.d /etc/modprobe.d /etc/modules-load.d
cat >/etc/udev/rules.d/90-dagu-udmabuf.rules <<'EOF'
KERNEL=="udmabuf", GROUP="video", MODE="0660"
EOF
cat >/etc/udev/rules.d/90-dagu-v4l2loopback.rules <<'EOF'
SUBSYSTEM=="video4linux", ATTR{name}=="dagu-front", GROUP="video", MODE="0660"
SUBSYSTEM=="video4linux", ATTR{name}=="dagu-rear", GROUP="video", MODE="0660"
SUBSYSTEM=="video4linux", ATTR{name}=="msm_vfe*", GROUP="root", MODE="0600", TAG-="uaccess"
EOF
cat >/etc/modprobe.d/v4l2loopback.conf <<'EOF'
# exclusive_caps=0: on-demand producer starts after the V4L2 client opens.
# PipeWire lists video20/21. spa-libcamera is disabled.
options v4l2loopback devices=2 video_nr=20,21 exclusive_caps=0 card_label=dagu-front,dagu-rear
EOF
echo v4l2loopback >/etc/modules-load.d/dagu-v4l2loopback.conf
# Keep in sync with linux-mainline/scripts/dagu-camera-loopback.sh
# The live copy is the canonical script; embed it below.
cat >/usr/local/sbin/dagu-camera-loopback.sh <<'LOOPEOF'
#!/bin/sh
# Push libcamera SoftISP NV12 into v4l2loopback /dev/video20 (front) and
# /dev/video21 (rear) **on demand**. No app → no gst, no CAMSS STREAMON.
# PipeWire must not monitor spa-libcamera: Chrome would CPU-debayer 12MP
# on the session CPUs and starve mutter. Snapshot/Chromium open these
# V4L2 nodes. Not Spectra ISP.
set -eu

FRONT_DEV="${DAGU_LOOPBACK_FRONT:-/dev/video20}"
REAR_DEV="${DAGU_LOOPBACK_REAR:-/dev/video21}"
# libcamera simple IDs from sm8250-xiaomi-dagu.dts (cam --list).
FRONT_NAME="${DAGU_LIBCAMERA_FRONT:-/base/soc@0/cci@ac50000/i2c-bus@1/camera@10}"
REAR_NAME="${DAGU_LIBCAMERA_REAR:-/base/soc@0/cci@ac4f000/i2c-bus@0/camera@10}"
# Viewfinder skip: imx596 2592/2, s5kjn1 4080/4. Not 1280x720 (rear cannot).
FRONT_W="${DAGU_LOOPBACK_FRONT_WIDTH:-1296}"
FRONT_H="${DAGU_LOOPBACK_FRONT_HEIGHT:-976}"
REAR_W="${DAGU_LOOPBACK_REAR_WIDTH:-1020}"
REAR_H="${DAGU_LOOPBACK_REAR_HEIGHT:-764}"
POLL_S="${DAGU_LOOPBACK_POLL_S:-0.5}"
IDLE_S="${DAGU_LOOPBACK_IDLE_S:-1}"
RESET="${DAGU_CAMSS_RESET:-/usr/local/sbin/dagu-camss-graph-reset.sh}"

log() { printf 'dagu-camera-loopback: %s\n' "$*"; }

usage() {
	printf 'usage: %s [watch|front|rear|all]\n' "$0" >&2
	exit 2
}

cmd=${1:-watch}

resolve_names() {
	front_name="${DAGU_LIBCAMERA_FRONT:-$FRONT_NAME}"
	rear_name="${DAGU_LIBCAMERA_REAR:-$REAR_NAME}"
	list=$(cam --list 2>/dev/null || cam --list-cameras 2>/dev/null || true)
	parsed_front=$(printf '%s\n' "$list" | sed -n 's/.*Internal front camera (\([^)]*\)).*/\1/p' | head -1)
	parsed_rear=$(printf '%s\n' "$list" | sed -n 's/.*Internal back camera (\([^)]*\)).*/\1/p' | head -1)
	[ -z "${DAGU_LIBCAMERA_FRONT:-}" ] && [ -n "$parsed_front" ] && front_name=$parsed_front
	[ -z "${DAGU_LIBCAMERA_REAR:-}" ] && [ -n "$parsed_rear" ] && rear_name=$parsed_rear
}

pipe() {
	src_name=$1
	sink=$2
	w=$3
	h=$4
	if [ -z "$src_name" ]; then
		log "no camera id for $sink"
		exit 1
	fi
	if ! command -v gst-launch-1.0 >/dev/null; then
		log "gst-launch-1.0 missing"
		exit 1
	fi
	log "pipe $src_name -> $sink ${w}x${h} NV12"
	# libcamerasrc emits ABGR8888; NV12/size must come after videoconvert.
	exec gst-launch-1.0 \
		libcamerasrc camera-name="$src_name" \
		! videoconvert \
		! "video/x-raw,format=NV12,width=$w,height=$h" \
		! v4l2sink device="$sink" sync=false
}

run_one() {
	which=$1
	i=0
	dev=$FRONT_DEV
	[ "$which" = rear ] && dev=$REAR_DEV
	while [ ! -e "$dev" ]; do
		i=$((i + 1))
		[ "$i" -gt 60 ] && { log "no $dev"; exit 1; }
		sleep 0.5
	done
	resolve_names
	case "$which" in
	front) pipe "$front_name" "$FRONT_DEV" "$FRONT_W" "$FRONT_H" ;;
	rear) pipe "$rear_name" "$REAR_DEV" "$REAR_W" "$REAR_H" ;;
	*) log "bad camera $which"; exit 2 ;;
	esac
}

run_all() {
	resolve_names
	log "all front=$front_name $FRONT_W x $FRONT_H rear=$rear_name $REAR_W x $REAR_H"
	pipe "$front_name" "$FRONT_DEV" "$FRONT_W" "$FRONT_H" &
	p1=$!
	pipe "$rear_name" "$REAR_DEV" "$REAR_W" "$REAR_H" &
	p2=$!
	trap 'kill $p1 $p2 2>/dev/null || true' INT TERM
	wait $p1 $p2
}

watch() {
	log "watch $FRONT_DEV $REAR_DEV idle=${IDLE_S}s (SoftISP off until a client streams)"
	exec python3 - "$FRONT_DEV" "$REAR_DEV" "$0" "$POLL_S" "$IDLE_S" "$RESET" <<'PY'
import os, signal, sys, time, subprocess

front, rear, script, poll_s, idle_s, reset = (
    sys.argv[1], sys.argv[2], sys.argv[3],
    float(sys.argv[4]), float(sys.argv[5]), sys.argv[6],
)
GST = {"gst-launch-1.0", "gst-laun"}
MONITOR = {"pipewire", "wireplumber", "pipewire-pulse"}
POLL = {"dagu-camera-loop", "dagu-camera-lo"}


def comm_of(pid: str) -> str:
    try:
        return open(f"/proc/{pid}/comm", encoding="utf-8", errors="ignore").read().strip()
    except OSError:
        return ""


def holders(dev: str) -> dict[int, str]:
    found: dict[int, str] = {}
    try:
        pids = os.listdir("/proc")
    except OSError:
        return found
    for pid in pids:
        if not pid.isdigit():
            continue
        comm = comm_of(pid)
        if comm in GST or comm.startswith("gst-launch") or comm in POLL:
            continue
        fd_dir = f"/proc/{pid}/fd"
        try:
            fds = os.listdir(fd_dir)
        except OSError:
            continue
        for fd in fds:
            try:
                target = os.readlink(f"{fd_dir}/{fd}")
            except OSError:
                continue
            if target == dev:
                found[int(pid)] = comm
                break
    return found


def buf_count(dev: str) -> int:
    name = os.path.basename(dev)
    for path in (
        f"/sys/devices/virtual/video4linux/{name}/buffers",
        f"/sys/class/video4linux/{name}/device/buffers",
    ):
        try:
            return int(open(path, encoding="utf-8").read().strip() or "0")
        except (OSError, ValueError):
            continue
    return 0


def client_wants(dev: str) -> bool:
    if not os.path.exists(dev):
        return False
    found = holders(dev)
    if not found:
        return False
    if all(c in MONITOR for c in found.values()) and buf_count(dev) == 0:
        return False
    return True


procs: dict[str, subprocess.Popen] = {}
started_at: dict[str, float] = {}
fail_until: dict[str, float] = {}
idle_since: dict[str, float] = {}
hw_held = False


def release_hw() -> None:
    global hw_held
    if procs:
        return
    if not hw_held:
        return
    if os.path.isfile(reset) and os.access(reset, os.X_OK):
        subprocess.run([reset], check=False)
    print("dagu-camera-loopback: idle, CAMSS graph reset", flush=True)
    hw_held = False


def stop(name: str) -> None:
    p = procs.pop(name, None)
    started_at.pop(name, None)
    idle_since.pop(name, None)
    if p is None:
        return
    print(f"dagu-camera-loopback: stop {name}", flush=True)
    try:
        os.killpg(p.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError, OSError):
        p.terminate()
    try:
        p.wait(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError, OSError):
            p.kill()
        p.wait(timeout=2)


def start(name: str) -> None:
    global hw_held
    now = time.monotonic()
    if name in procs and procs[name].poll() is None:
        return
    if now < fail_until.get(name, 0):
        return
    print(f"dagu-camera-loopback: start {name}", flush=True)
    procs[name] = subprocess.Popen(
        [script, name],
        start_new_session=True,
    )
    started_at[name] = now
    idle_since.pop(name, None)
    hw_held = True


try:
    while True:
        now = time.monotonic()
        want = {"front": client_wants(front), "rear": client_wants(rear)}
        for name, needed in want.items():
            if needed:
                idle_since.pop(name, None)
                start(name)
                continue
            if name not in procs:
                continue
            since = idle_since.setdefault(name, now)
            if now - since >= idle_s:
                stop(name)
        dead = [n for n, p in procs.items() if p.poll() is not None]
        for n in dead:
            rc = procs[n].returncode
            age = now - started_at.get(n, now)
            procs.pop(n, None)
            started_at.pop(n, None)
            print(f"dagu-camera-loopback: {n} exited rc={rc}", flush=True)
            if age < 2.0:
                fail_until[n] = now + 8.0
        release_hw()
        time.sleep(poll_s)
finally:
    for n in list(procs):
        stop(n)
    hw_held = True
    release_hw()
PY
}

case "$cmd" in
watch) watch ;;
front|rear) run_one "$cmd" ;;
all) run_all ;;
-h|--help) usage ;;
*) usage ;;
esac
LOOPEOF
chmod 755 /usr/local/sbin/dagu-camera-loopback.sh
cat >/etc/systemd/system/dagu-camera-loopback.service <<'EOF'
[Unit]
Description=dagu v4l2loopback NV12 both-nodes (not Spectra ISP)
After=systemd-modules-load.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/dagu-camera-loopback.sh all
CPUAffinity=0-3
Restart=on-failure
RestartSec=5
EOF
rm -f /etc/systemd/system/multi-user.target.wants/dagu-camera-loopback.service
cat >/etc/systemd/system/dagu-camera-loopback-watch.service <<'EOF'
[Unit]
Description=dagu: SoftISP on video20/21 only while a client is open
After=systemd-modules-load.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/dagu-camera-loopback watch
ExecStopPost=/usr/local/sbin/dagu-camss-graph-reset.sh
CPUAffinity=0-5
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/dagu-camera-loopback-watch.service \
	/etc/systemd/system/multi-user.target.wants/dagu-camera-loopback-watch.service
mkdir -p /etc/libcamera
cat >/etc/libcamera/configuration.yaml <<'EOF'
version: 1
configuration:
  software_isp:
    mode: cpu
    threads: 2
EOF
# Do not put hw:0,0 in pipewire context.objects. Opening the PCM
# before /proc/asound/cards exists exits PipeWire 234 and systemd
# start-limits the socket for the whole session.
rm -f /etc/pipewire/pipewire.conf.d/50-dagu-alsa-sink.conf
install -m755 /usr/local/sbin/dagu-audio-up.sh /usr/local/sbin/dagu-audio-up.sh 2>/dev/null || true
cat >/usr/local/sbin/dagu-audio-up.sh <<'EOF'
#!/bin/sh
set -eu
CARD="${DAGU_ALSA_CARD:-0}"
PCM="/dev/snd/pcmC${CARD}D0p"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1001}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
i=0
while [ ! -e "$PCM" ]; do
	i=$((i + 1))
	[ "$i" -gt 60 ] && { echo "dagu-audio-up: no $PCM" >&2; exit 1; }
	sleep 0.5
done
[ -x /usr/local/sbin/dagu-speaker-route.sh ] && /usr/local/sbin/dagu-speaker-route.sh || true
if [ "$(id -u)" -eq 0 ]; then
	exec sudo -u dagu env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
		DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
		HOME=/home/dagu USER=dagu LOGNAME=dagu "$0" "$@"
fi
systemctl --user reset-failed pipewire.service pipewire.socket \
	pipewire-pulse.service pipewire-pulse.socket wireplumber.service >/dev/null 2>&1 || true
systemctl --user start pipewire.socket pipewire.service \
	pipewire-pulse.socket pipewire-pulse.service wireplumber.service
j=0
while [ "$j" -lt 20 ]; do
	wpctl status >/dev/null 2>&1 && break
	j=$((j + 1)); sleep 0.25
done
id=$(wpctl status 2>/dev/null | awk '
	$0 ~ /Sinks:/{s=1}
	s && /Audio\/Source/{exit}
	s && /\*/ && /Speakers|Speaker/{
		for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}
	}
	s && /Speakers|Speaker/ && $1 ~ /^[0-9]+/{print $1; exit}
')
if [ -n "${id:-}" ]; then
	wpctl set-default "$id" >/dev/null 2>&1 || true
	wpctl set-mute "$id" 0 >/dev/null 2>&1 || true
	wpctl set-volume "$id" 1.0 >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 755 /usr/local/sbin/dagu-audio-up.sh
mkdir -p /etc/systemd/user/pipewire.service.d \
	/etc/systemd/user/graphical-session.target.wants \
	/etc/systemd/user/default.target.wants
cat >/etc/systemd/user/pipewire.service.d/dagu-restart.conf <<'EOF'
[Service]
Restart=on-failure
RestartSec=2
StartLimitBurst=30
StartLimitIntervalSec=180
EOF
cat >/etc/systemd/user/dagu-audio-up.service <<'EOF'
[Unit]
Description=dagu: start PipeWire Speakers after ALSA pcm exists
After=pipewire.service pipewire-pulse.service wireplumber.service
Wants=pipewire.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/dagu-audio-up.sh
RemainAfterExit=yes

[Install]
WantedBy=graphical-session.target
WantedBy=default.target
EOF
ln -sf /etc/systemd/user/dagu-audio-up.service \
	/etc/systemd/user/graphical-session.target.wants/dagu-audio-up.service
ln -sf /etc/systemd/user/dagu-audio-up.service \
	/etc/systemd/user/default.target.wants/dagu-audio-up.service

# DSP + analog 18 is the Android path. Do not stack GNOME over-amplification
# (that is extra digital gain).
mkdir -p /etc/dconf/db/local.d /etc/dconf/profile
if [ ! -f /etc/dconf/profile/user ]; then
	cat >/etc/dconf/profile/user <<'EOF'
user-db:user
system-db:local
EOF
fi
cat >/etc/dconf/db/local.d/00-dagu-sound <<'EOF'
[org/gnome/desktop/sound]
allow-volume-above-100-percent=false
EOF
dconf update 2>/dev/null || true

# Hold-drag / Chrome-video clock boost. Idle GPU stays 587 MHz /
# ondemand; do not set governor=performance. Keep in sync with
# linux-mainline/scripts/dagu-touch-boost.py
cat >/usr/local/sbin/dagu-touch-boost.py <<'EOF'
#!/usr/bin/env python3
"""Raise GPU/CPU floors while touching, Chrome video, or camera SoftISP.

Idle stays on simple_ondemand / schedutil (GPU min 587 MHz). A hold-drag
or a <video> used to bounce 587↔670 and leave the prime core at 845 MHz,
which is the felt hitch / dropped frame. This does not change Chrome
CPU vs GPU raster. Do not set governor=performance.

Himax is spi-gpio bitbang (IRQF_ONESHOT thread). SoftISP on 5MP/12MP RAW
saturates the cluster and mutter's libinput loop starves — taps still
wake the backlight via logind, but folders/close-window do not respond.
Do not pin SoftISP to the big cluster: pin it to silver CPU0-3 and keep
Himax/mutter on Gold. Signal is any userspace fd on `/dev/video0` or
`/dev/video3` (plus gst-launch holding the loopback nodes).
"""
from __future__ import annotations

import glob
import os
import struct
import time

EV_KEY, EV_ABS = 0x01, 0x03
ABS_MT_TRACKING_ID = 0x39
BTN_TOUCH = 0x14A
EVENT = struct.Struct("llHHi")

GPU_MIN = "/sys/class/devfreq/3d00000.gpu/min_freq"
GPU_IDLE = "587000000"
GPU_HOLD = "670000000"

CPU = (
    ("/sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq", "300000", "1248000"),
    ("/sys/devices/system/cpu/cpufreq/policy4/scaling_min_freq", "710400", "1766400"),
    ("/sys/devices/system/cpu/cpufreq/policy7/scaling_min_freq", "844800", "1977600"),
)

HOLD_TAIL_S = 0.18
VIDEO_SCAN_S = 0.5
SOFTISP_CPUS = frozenset({0, 1, 2, 3})
ALL_CPUS = frozenset(range(os.cpu_count() or 8))
# comm is TASK_COMM_LEN=16 including NUL → 15 chars.
SKIP_PIN = {
    "gnome-shell",
    "Xwayland",
    "dagu-touch-boo",
    "dagu-himax-irq",
}


def write(path: str, value: str) -> None:
    try:
        with open(path, "w") as f:
            f.write(value + "\n")
    except OSError:
        pass


def find_himax() -> str:
    for name in sorted(glob.glob("/sys/class/input/event*/device/name")):
        try:
            text = open(name, "r", encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        if "Himax" in text or "HX83121" in text:
            return "/dev/input/" + name.split("/")[4]
    return "/dev/input/event3"


def apply(hold: bool) -> None:
    write(GPU_MIN, GPU_HOLD if hold else GPU_IDLE)
    for path, idle, boosted in CPU:
        write(path, boosted if hold else idle)


BROWSER_MARKERS = (
    b"/opt/google/chrome/chrome",
    b"/usr/lib/chromium/chromium",
    b"/usr/bin/chromium",
)
CAM_NODES = ("/dev/video0", "/dev/video3")
LOOP_NODES = ("/dev/video20", "/dev/video21")
CAM_COMMS = {
    "snapshot",
    "gnome-snapshot",
    "pipewire",
    "wireplumber",
    "cam",
    "gst-launch-1.0",
}
VENUS_NODES = (
    "/dev/video14",
    "/dev/video15",
    "/dev/video-dec0",
    "/dev/video-enc0",
)


def _is_browser(cmd: bytes) -> bool:
    return any(m in cmd for m in BROWSER_MARKERS)


def _comm(pid: str) -> str:
    try:
        with open(f"/proc/{pid}/comm", "r", encoding="utf-8", errors="ignore") as f:
            return f.read().strip()
    except OSError:
        return ""


def _is_cam_comm(comm: str) -> bool:
    if comm in CAM_COMMS:
        return True
    return comm.startswith("gst-launch") or comm.startswith("gnome-snapsho")


def _has_fd(pid: str, nodes: tuple[str, ...]) -> bool:
    try:
        fds = os.listdir(f"/proc/{pid}/fd")
    except OSError:
        return False
    for fd in fds:
        try:
            target = os.readlink(f"/proc/{pid}/fd/{fd}")
        except OSError:
            continue
        if target in nodes:
            return True
    return False


def _has_venus_fd(pid: str) -> bool:
    return _has_fd(pid, VENUS_NODES)


def chrome_video_playing() -> bool:
    """True while Chromium/Chrome is in a Venus or video-compositor path."""
    for pid in _iter_pids():
        comm = _comm(pid)
        if not comm.startswith(("chrome", "chromium", "Chrome")):
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                cmd = f.read()
        except OSError:
            continue
        if not _is_browser(cmd):
            continue
        if _has_venus_fd(pid):
            return True
        if b"--type=" in cmd and b"--type=renderer" not in cmd:
            continue
        task = f"/proc/{pid}/task"
        try:
            tids = os.listdir(task)
        except OSError:
            continue
        for tid in tids:
            try:
                with open(f"{task}/{tid}/comm", "r", encoding="utf-8", errors="ignore") as f:
                    name = f.read().strip()
            except OSError:
                continue
            if name.startswith(("VideoFrame", "FFmpeg", "VideoDecod", "V4L2", "Media")):
                return True
    return False


def _iter_pids():
    try:
        pids = os.listdir("/proc")
    except OSError:
        return
    for pid in pids:
        if pid.isdigit():
            yield pid


def _has_softisp_thread(pid: str) -> bool:
    task = f"/proc/{pid}/task"
    try:
        tids = os.listdir(task)
    except OSError:
        return False
    for tid in tids:
        try:
            with open(f"{task}/{tid}/comm", "r", encoding="utf-8", errors="ignore") as f:
                name = f.read().strip()
        except OSError:
            continue
        if name.startswith(("SWIspWorker", "DebayerCpu")):
            return True
    return False


def _is_softisp_proc(comm: str) -> bool:
    return comm.startswith(("dagu-camera-lo", "gst-launch", "cam")) or comm in {
        "snapshot",
        "gnome-snapshot",
    }


def camera_streaming() -> bool:
    """True while Snapshot/cam/gst is up, or the loopback child has SWIsp.

    Do not walk every process's fd/task table. Cursor keeps thousands of
    fds; doing that at 8 Hz starves mutter SCHED_DEADLINE.
    """
    for pid in _iter_pids():
        comm = _comm(pid)
        if comm in ("snapshot", "gnome-snapshot", "cam") or comm.startswith(
            ("gst-launch", "gnome-snapsho")
        ):
            return True
        if comm.startswith("dagu-camera-lo") and _has_softisp_thread(pid):
            return True
        if _is_cam_comm(comm) and _has_fd(pid, LOOP_NODES):
            return True
    return False


def pin_softisp(enable: bool) -> None:
    """Keep DebayerCpu/libcamera off Gold so mutter and Himax still run."""
    cpus = SOFTISP_CPUS if enable else ALL_CPUS
    for pid in _iter_pids():
        comm = _comm(pid)
        if comm in SKIP_PIN or comm.startswith("dagu-camera-lo") or not _is_softisp_proc(comm):
            continue
        try:
            os.sched_setaffinity(int(pid), cpus)
        except (OSError, ValueError, PermissionError):
            continue


def main() -> None:
    dev = find_himax()
    fd = os.open(dev, os.O_RDONLY | os.O_NONBLOCK)
    apply(False)
    pin_softisp(False)
    contacts = 0
    holding = False
    drop_at = None
    video = False
    last_scan = 0.0
    pinned = False
    while True:
        now = time.monotonic()
        try:
            buf = os.read(fd, EVENT.size * 64)
        except BlockingIOError:
            buf = b""
        if buf:
            for off in range(0, len(buf) - EVENT.size + 1, EVENT.size):
                _sec, _usec, typ, code, value = EVENT.unpack_from(buf, off)
                if typ == EV_ABS and code == ABS_MT_TRACKING_ID:
                    if value >= 0:
                        contacts += 1
                    elif contacts > 0:
                        contacts -= 1
                elif typ == EV_KEY and code == BTN_TOUCH:
                    contacts = 1 if value else 0
        if now - last_scan >= VIDEO_SCAN_S:
            video = chrome_video_playing() or camera_streaming()
            if video and not pinned:
                pin_softisp(True)
                pinned = True
            elif not video and pinned:
                pin_softisp(False)
                pinned = False
            last_scan = now
        want = contacts > 0 or video
        if want:
            drop_at = None
            if not holding:
                holding = True
                apply(True)
        elif holding:
            if drop_at is None:
                drop_at = now + HOLD_TAIL_S
            elif now >= drop_at:
                holding = False
                drop_at = None
                apply(False)
        time.sleep(0.004)


if __name__ == "__main__":
    main()

EOF
chmod 755 /usr/local/sbin/dagu-touch-boost.py
cat >/etc/systemd/system/dagu-touch-boost.service <<'EOF'
[Unit]
Description=dagu: raise GPU/CPU floors while touching, Chrome video, or camera
After=dagu-resources-fix.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/dagu-touch-boost.py
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/dagu-touch-boost.service \
	/etc/systemd/system/multi-user.target.wants/dagu-touch-boost.service
systemctl enable --now dagu-touch-boost.service >/dev/null 2>&1 || true

# Venus is extra/*.ko (not depmod autoload). Chrome/gst need /dev/video14.
# Keep in sync with linux-mainline/scripts/dagu-venus-load.sh
cat >/usr/local/sbin/dagu-venus-load.sh <<'EOF'
#!/bin/sh
# Keep in sync with linux-mainline/scripts/dagu-venus-load.sh
set -eu
KVER=$(uname -r)

log() {
	echo "dagu-venus-load: $*"
	echo "dagu-venus-load: $*" >/dev/kmsg 2>/dev/null || true
}

insmod_one() {
	ko=$1
	if [ ! -f "$ko" ]; then
		log "missing $ko"
		return 1
	fi
	if insmod "$ko"; then
		log "insmod $ko"
		return 0
	fi
	log "insmod failed $ko"
	return 1
}

insmod_ko() {
	ko=$1
	insmod_one "$ko" && return 0
	objcopy=$(command -v objcopy 2>/dev/null || command -v llvm-objcopy 2>/dev/null || true)
	[ -n "$objcopy" ] || return 1
	mkdir -p /run/dagu-venus
	tmp=/run/dagu-venus/$(basename "$ko")
	if "$objcopy" --remove-section=.BTF --remove-section=.BTF.ext "$ko" "$tmp" 2>/dev/null \
		|| "$objcopy" --remove-section=.BTF "$ko" "$tmp" 2>/dev/null; then
		log "retry stripped BTF $ko"
		insmod_one "$tmp"
		return $?
	fi
	return 1
}

core_loaded() {
	lsmod | grep -q '^venus_core '
}

load_dir() {
	dir=$1
	[ -f "$dir/venus-core.ko" ] || return 1
	if core_loaded; then
		return 1
	fi
	log "using $dir"
	insmod_ko "$dir/venus-core.ko" || return 1
	insmod_ko "$dir/venus-dec.ko" || true
	insmod_ko "$dir/venus-enc.ko" || true
	[ -e /dev/video14 ]
}

modprobe videobuf2-v4l2 2>/dev/null || true
modprobe v4l2-mem2mem 2>/dev/null || true
if [ ! -e /dev/video14 ]; then
	for dir in /root/venus-new /lib/modules/$KVER/extra /root/venus-ko; do
		if load_dir "$dir"; then
			break
		fi
	done
fi
if [ -e /dev/video14 ]; then
	chgrp video /dev/video14 /dev/video15 2>/dev/null || true
	chmod 660 /dev/video14 /dev/video15 2>/dev/null || true
	ln -sfn video14 /dev/video-dec0
	ln -sfn video15 /dev/video-enc0
	log "ready /dev/video14 /dev/video15"
	exit 0
fi
log "no /dev/video14 — need matching venus-*.ko for $KVER"
exit 1
EOF
chmod 755 /usr/local/sbin/dagu-venus-load.sh
install -m644 /dev/null /etc/udev/rules.d/90-dagu-chromium-video.rules
cat >/etc/udev/rules.d/90-dagu-chromium-video.rules <<'EOF'
SUBSYSTEM=="video4linux", ATTR{name}=="qcom-venus-decoder", SYMLINK+="video-dec0", GROUP="video", MODE="0660"
SUBSYSTEM=="video4linux", ATTR{name}=="qcom-venus-encoder", SYMLINK+="video-enc0", GROUP="video", MODE="0660"
EOF
cat >/etc/systemd/system/dagu-venus-load.service <<'EOF'
[Unit]
Description=dagu: load qcom-venus decoder
After=systemd-modules-load.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/dagu-venus-load.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/dagu-venus-load.service \
	/etc/systemd/system/multi-user.target.wants/dagu-venus-load.service
systemctl enable --now dagu-venus-load.service >/dev/null 2>&1 || true

cat >/etc/systemd/system/dagu-wq-affinity.service <<'EOF'
[Unit]
Description=dagu: unbound workqueue affinity=system (DRM commit_work)
DefaultDependencies=no
After=sysinit.target
Before=display-manager.service gdm.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo system > /sys/module/workqueue/parameters/default_affinity_scope'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/dagu-wq-affinity.service \
	/etc/systemd/system/multi-user.target.wants/dagu-wq-affinity.service
systemctl enable --now dagu-wq-affinity.service >/dev/null 2>&1 || true

# Himax IRQ 193 (number can move) must stay on Gold after reboot.
# Keep in sync with linux-mainline/scripts/dagu-himax-irq-affinity.sh
cat >/usr/local/sbin/dagu-himax-irq-affinity.sh <<'EOF'
#!/bin/sh
set -eu
AFFINITY="${DAGU_HIMAX_IRQ_AFFINITY:-f0}"
find_irq() {
	irq=""
	while read -r line; do
		case "$line" in
		*himax-dagu*|*himax*)
			irq=${line%%:*}
			irq=${irq#"${irq%%[![:space:]]*}"}
			break
			;;
		esac
	done </proc/interrupts
	[ -n "$irq" ] && [ -d "/proc/irq/$irq" ]
}
i=0
while ! find_irq; do
	i=$((i + 1))
	[ "$i" -gt 40 ] && {
		echo "dagu-himax-irq-affinity: no himax IRQ" >&2
		exit 1
	}
	sleep 0.5
done
echo "$AFFINITY" >"/proc/irq/$irq/smp_affinity"
printf 'dagu-himax-irq-affinity: irq %s smp_affinity=%s list=%s\n' \
	"$irq" "$(cat "/proc/irq/$irq/smp_affinity")" \
	"$(cat "/proc/irq/$irq/smp_affinity_list")"
EOF
chmod 755 /usr/local/sbin/dagu-himax-irq-affinity.sh
cat >/etc/systemd/system/dagu-himax-irq-affinity.service <<'EOF'
[Unit]
Description=dagu: Himax IRQ affinity CPU4-7 (spi-gpio vs SoftISP)
DefaultDependencies=no
After=sysinit.target
Before=display-manager.service gdm.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/dagu-himax-irq-affinity.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/dagu-himax-irq-affinity.service \
	/etc/systemd/system/multi-user.target.wants/dagu-himax-irq-affinity.service
systemctl enable --now dagu-himax-irq-affinity.service >/dev/null 2>&1 || true

# HMCL JavaFX libprism_es2.so is X11/GLX. Native Wayland Glass → SWPipeline.
# Keep in sync with linux-mainline/scripts/dagu-hmcl.sh
install -m755 /dev/stdin /usr/local/bin/dagu-hmcl <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

uid=$(id -u)
runtime="${XDG_RUNTIME_DIR:-/run/user/${uid}}"
export XDG_RUNTIME_DIR="$runtime"

if [ -z "${DISPLAY:-}" ]; then
	export DISPLAY=:0
fi
if [ -z "${XAUTHORITY:-}" ]; then
	for f in "${runtime}"/.mutter-Xwaylandauth.*; do
		if [ -f "$f" ]; then
			export XAUTHORITY="$f"
			break
		fi
	done
fi
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "${runtime}/bus" ]; then
	export DBUS_SESSION_BUS_ADDRESS="unix:path=${runtime}/bus"
fi

export GDK_BACKEND=x11
unset LIBGL_ALWAYS_SOFTWARE
unset MESA_LOADER_DRIVER_OVERRIDE

_prism_gpu='-Dprism.order=es2 -Dprism.forceGPU=true'
if [ -n "${HMCL_JAVA_OPTS+x}" ]; then
	case " ${HMCL_JAVA_OPTS} " in
	*' -Dprism.order='*|*' -Dprism.forceGPU='*) ;;
	*) export HMCL_JAVA_OPTS="${HMCL_JAVA_OPTS} ${_prism_gpu}" ;;
	esac
else
	export HMCL_JAVA_OPTS="-XX:MinHeapFreeRatio=5 -XX:MaxHeapFreeRatio=15 ${_prism_gpu}"
fi

if [ -z "${HMCL_USER_HOME:-}" ]; then
	if [ -z "${XDG_DATA_HOME:-}" ]; then
		export HMCL_USER_HOME="${HOME}/.local/share/hmcl"
	else
		export HMCL_USER_HOME="${XDG_DATA_HOME}/hmcl"
	fi
fi
if [ -z "${HMCL_LOCAL_HOME:-}" ]; then
	export HMCL_LOCAL_HOME="${HMCL_USER_HOME}/local-stable"
fi
if [ -z "${HMCL_DEPENDENCIES_DIR:-}" ]; then
	export HMCL_DEPENDENCIES_DIR="${HMCL_USER_HOME}/dependencies"
fi

hmcl_jar=""
for c in /usr/share/java/hmcl/HMCL-*.sh; do
	[ -f "$c" ] && hmcl_jar=$c
done
if [ -z "$hmcl_jar" ]; then
	echo "dagu-hmcl: HMCL jar not found under /usr/share/java/hmcl" >&2
	exit 1
fi
cd "${HOME}"
exec "$hmcl_jar" "$@"
EOF
ln -sfn dagu-hmcl /usr/local/bin/hmcl-stable
if [ -f /usr/local/share/applications/hmcl-stable.desktop ]; then
	sed -i 's|^Exec=.*|Exec=/usr/local/bin/dagu-hmcl|' \
		/usr/local/share/applications/hmcl-stable.desktop
fi

rm -f /usr/sbin/policy-rc.d
echo "==> desktop setup done"
