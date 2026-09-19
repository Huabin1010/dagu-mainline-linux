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
	network-manager onboard \
	ibus ibus-gtk3 ibus-gtk4 ibus-libpinyin \
	bluez systemd-timesyncd pci.ids \
	iio-sensor-proxy \
	g++ make pkg-config rustc libcamera-dev

apt-get clean
rm -rf /var/lib/apt/lists/*

is_elf() { [ "$(head -c 4 "$1" 2>/dev/null)" = $'\x7fELF' ]; }

install_product_bins() {
	mkdir -p /usr/local/sbin
	if [ -d /tmp/dagu-userspace ]; then
		make -C /tmp/dagu-userspace clean
		make -C /tmp/dagu-userspace PREFIX=/usr/local
		make -C /tmp/dagu-userspace PREFIX=/usr/local install
	fi
	if [ -d /tmp/dagu-camera-loopback ]; then
		make -C /tmp/dagu-camera-loopback clean
		make -C /tmp/dagu-camera-loopback PREFIX=/usr/local
		make -C /tmp/dagu-camera-loopback PREFIX=/usr/local install
	fi
	for b in dagu-camera-loopback dagu-touch-boost dagu-power-button dagu-fcitx5-shift-tap dagu-ssc dagu-cdsp-rpc; do
		is_elf /usr/local/sbin/$b || {
			echo "rootfs-desktop-setup: $b is not an ELF product binary" >&2
			exit 1
		}
	done
	rm -f /usr/local/sbin/dagu-camera-loopback.sh \
		/usr/local/sbin/dagu-touch-boost.py \
		/usr/local/sbin/dagu-power-button.py \
		/usr/local/sbin/dagu-tablet-mode.py \
		/usr/local/sbin/dagu-time-sync.py \
		/usr/local/bin/dagu-fcitx5-shift-tap.py \
		/usr/local/sbin/dagu-camera-pw-source.py \
		/usr/local/sbin/dagu-camera-preview.py
}

install_product_bins

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
# GNOME setup-mode writes Pairable=no when the user clicks Connect, then
# Pair/Connect. AlwaysPairable keeps outgoing/incoming pairing alive.
# hid-host still restores bondable/PSCAN after QCA HCI reset (0x03).
bt_main_set AlwaysPairable true
bt_main_set MinConnectionInterval 24
bt_main_set MaxConnectionInterval 40
# Device-initiated classic HID (K380 ReconnectMode=device): GNOME
# Device1.Connect must wait for the keypress page. Outgoing page drops
# PSCAN on QCA6390. Rebuild bluetoothd with dagu-build-bluez-hid.sh
# (DAGU_PATCH_BLUEZ=1 during image build, or live on the tablet).
if [ -f /tmp/dagu-bluez-hid/dagu-bluez-hid-wait-incoming.py ]; then
	install -m 755 /tmp/dagu-bluez-hid/dagu-bluez-hid-wait-incoming.py \
		/usr/local/sbin/dagu-bluez-hid-wait-incoming.py
	install -m 755 /tmp/dagu-bluez-hid/dagu-build-bluez-hid.sh \
		/usr/local/sbin/dagu-build-bluez-hid.sh
	if [ "${DAGU_PATCH_BLUEZ:-0}" = 1 ]; then
		DAGU_BLUEZ_BUILD=/usr/local/src/dagu-bluez-hid \
			/usr/local/sbin/dagu-build-bluez-hid.sh || true
	fi
fi
# GNOME 未设置: unnamed LE rows must Pair immediately; AlreadyExists after
# a CLI pair is success; Connect after Pair has 25s
# (DAGU_PATCH_GNOMEBT=1 during image build, or live on the tablet).
if [ -f /tmp/dagu-gnome-bt/dagu-gnome-bt-setup-unnamed.py ]; then
	install -m 755 /tmp/dagu-gnome-bt/dagu-gnome-bt-setup-unnamed.py \
		/usr/local/sbin/dagu-gnome-bt-setup-unnamed.py
	install -m 755 /tmp/dagu-gnome-bt/dagu-build-gnome-bt.sh \
		/usr/local/sbin/dagu-build-gnome-bt.sh
	if [ "${DAGU_PATCH_GNOMEBT:-0}" = 1 ]; then
		DAGU_GNOMEBT_BUILD=/usr/local/src/dagu-gnome-bt \
			/usr/local/sbin/dagu-build-gnome-bt.sh || true
	fi
fi
# Keep HCI_CONNECTABLE / bondable after GNOME closes the bluetooth panel.
# Forget of the last classic HID device otherwise drops SCAN_PAGE and the
# next K380 pair attempt is Create Connection with Pairable=no → device gone.
# Re-run on udev change: QCA setup after Add Device 0x03 is not udev add.
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
# GNOME Settings 未设置 is !Paired && !Trusted. bluetoothctl pair leaves
# Trusted=no; the row stays 未设置 and Device1.Pair returns AlreadyExists.
# Trust every bonded device so Settings shows Disconnected and Connects.
timeout 3 bluetoothctl devices Paired 2>/dev/null | awk '{print $2}' | while read -r addr; do
	[ -n "$addr" ] || continue
	timeout 2 bluetoothctl trust "$addr" >/dev/null 2>&1 || true
done
EOF
chmod 755 /usr/local/sbin/dagu-bt-hid-host.sh
mkdir -p /etc/systemd/system/bluetooth.service.d
cat >/etc/systemd/system/bluetooth.service.d/dagu-hid-host.conf <<'EOF'
[Service]
ExecStartPost=/usr/local/sbin/dagu-bt-hid-host.sh
EOF
cat >/etc/systemd/system/dagu-bt-hid-host.service <<'EOF'
[Unit]
Description=dagu Bluetooth HID host pairable/PSCAN after QCA setup
After=bluetooth.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/dagu-bt-hid-host.sh
EOF
cat >/etc/systemd/system/dagu-bt-hid-host.timer <<'EOF'
[Unit]
Description=Re-apply dagu Bluetooth HID host after HCI UP race
[Timer]
OnBootSec=20
AccuracySec=1s
Unit=dagu-bt-hid-host.service
[Install]
WantedBy=timers.target
EOF
systemctl enable dagu-bt-hid-host.timer >/dev/null 2>&1 || true
cat >/etc/udev/rules.d/90-dagu-bt-hid-host.rules <<'EOF'
ACTION!="remove", SUBSYSTEM=="bluetooth", KERNEL=="hci[0-9]*", RUN+="/usr/local/sbin/dagu-bt-hid-host.sh"
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

# Folio letters stay on hid-generic (same path as Bluetooth). keyd EVIOCGRAB
# on 15d9:00a3 made Wayland skip hold-repeat until a second key-down.
# Tap Shift → fcitx5: C watcher, no grab. Do not re-enable keyd on this HID.
is_elf /usr/local/sbin/dagu-fcitx5-shift-tap || {
	echo "rootfs-desktop-setup: missing dagu-fcitx5-shift-tap" >&2
	exit 1
}
systemctl disable --now keyd.service >/dev/null 2>&1 || true
rm -f /etc/keyd/dagu.conf \
	/usr/local/bin/dagu-fcitx5-shift-tap.py
cat >/etc/systemd/system/dagu-fcitx5-shift-tap.service <<'EOF'
[Unit]
Description=dagu folio Shift tap toggles fcitx5
After=systemd-udevd.service

[Service]
Type=simple
User=dagu
Group=dagu
SupplementaryGroups=input
Environment=HOME=/home/dagu
Environment=XDG_RUNTIME_DIR=/run/user/1001
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus
Environment=DISPLAY=:0
Environment=WAYLAND_DISPLAY=wayland-0
ExecStart=/usr/local/sbin/dagu-fcitx5-shift-tap
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/dagu-fcitx5-shift-tap.service \
	/etc/systemd/system/multi-user.target.wants/dagu-fcitx5-shift-tap.service
systemctl enable dagu-fcitx5-shift-tap.service >/dev/null 2>&1 || true

# Folio hold-repeat verdict: evdev KEY stays down ≥500ms and two-key handoff.
# Does not grab the device. JSON at /tmp/folio-repeat-verify.json.
if [ -f /usr/local/sbin/dagu-folio-repeat-verify.py ]; then
	cat >/etc/systemd/system/dagu-folio-repeat-verify.service <<'EOF'
[Unit]
Description=dagu folio evdev hold-repeat verdict
After=systemd-udevd.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/sbin/dagu-folio-repeat-verify.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
	ln -sf /etc/systemd/system/dagu-folio-repeat-verify.service \
		/etc/systemd/system/multi-user.target.wants/dagu-folio-repeat-verify.service
	systemctl enable dagu-folio-repeat-verify.service >/dev/null 2>&1 || true
fi

if [ -f /usr/local/sbin/folio-hold-live.py ]; then
	cat >/etc/systemd/system/dagu-folio-hold-live.service <<'EOF'
[Unit]
Description=dagu folio evdev hold logger
After=systemd-udevd.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/sbin/folio-hold-live.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
	ln -sf /etc/systemd/system/dagu-folio-hold-live.service \
		/etc/systemd/system/multi-user.target.wants/dagu-folio-hold-live.service
	systemctl enable dagu-folio-hold-live.service >/dev/null 2>&1 || true
fi

# mutter 50.1: only the repeating key's release clears compositor EV_REP.
# Stock 50.1 cancels on any release (GNOME #4675). Keep the patched so.
if [ -x /usr/local/sbin/dagu-mutter-repeat-keep.sh ]; then
	cat >/etc/systemd/system/dagu-mutter-repeat-keep.service <<'EOF'
[Unit]
Description=dagu mutter 50.1 keep compositor hold-repeat
DefaultDependencies=no
After=local-fs.target
Before=gdm.service display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/dagu-mutter-repeat-keep.sh

[Install]
WantedBy=multi-user.target
EOF
	ln -sf /etc/systemd/system/dagu-mutter-repeat-keep.service \
		/etc/systemd/system/multi-user.target.wants/dagu-mutter-repeat-keep.service
	systemctl enable dagu-mutter-repeat-keep.service >/dev/null 2>&1 || true
	/usr/local/sbin/dagu-mutter-repeat-keep.sh || true
fi

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

[org/gnome/settings-daemon/peripherals/touchscreen]
orientation-lock=false

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
power-button-action='suspend'
lid-close-ac-action='suspend'
lid-close-battery-action='suspend'
lid-close-suspend-with-external-monitor=true
idle-dim=false
ambient-enabled=false

[org/gnome/desktop/media-handling]
automount=false
automount-open=false
autorun-never=true
EOF
mkdir -p /etc/dconf/db/local.d/locks
cat >/etc/dconf/db/local.d/locks/dagu-brightness <<'EOF'
/org/gnome/settings-daemon/plugins/power/idle-dim
/org/gnome/settings-daemon/plugins/power/ambient-enabled
/org/gnome/desktop/session/idle-delay
EOF
cat >/etc/dconf/db/local.d/00-dagu-power <<'EOF'
[org/gnome/settings-daemon/plugins/power]
power-button-action='suspend'
lid-close-ac-action='suspend'
lid-close-battery-action='suspend'
lid-close-suspend-with-external-monitor=true
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
idle-dim=false
ambient-enabled=false

[org/gnome/desktop/screensaver]
lock-enabled=false
ubuntu-lock-on-suspend=false
EOF
cat >/etc/dconf/db/local.d/locks/dagu-power <<'EOF'
/org/gnome/settings-daemon/plugins/power/power-button-action
/org/gnome/settings-daemon/plugins/power/lid-close-ac-action
/org/gnome/settings-daemon/plugins/power/lid-close-battery-action
/org/gnome/settings-daemon/plugins/power/lid-close-suspend-with-external-monitor
/org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-type
/org/gnome/settings-daemon/plugins/power/sleep-inactive-battery-type
/org/gnome/desktop/screensaver/lock-enabled
/org/gnome/desktop/screensaver/ubuntu-lock-on-suspend
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

# GPIO110 hall is SW_LID. Folio close and short KEY_POWER are s2idle.
# Panel disable/unprepare are no-ops (no GPIO139 HWEN drop, no DCS 0x51).
# Do not grab the pwrkey. Do not ship a power card.
mkdir -p /etc/systemd/logind.conf.d /etc/xdg/autostart /usr/local/bin /usr/local/sbin
cat >/etc/systemd/logind.conf.d/dagu-power.conf <<'EOF'
[Login]
HandlePowerKey=suspend
HandlePowerKeyLongPress=ignore
HandleSuspendKey=suspend
HandleHibernateKey=ignore
HandleLidSwitch=suspend
HandleLidSwitchExternalPower=suspend
HandleLidSwitchDocked=suspend
LidSwitchIgnoreInhibited=yes
HoldoffTimeoutSec=2s
IdleAction=ignore
EOF
systemctl unmask sleep.target suspend.target >/dev/null 2>&1 || true
systemctl mask hibernate.target hybrid-sleep.target >/dev/null 2>&1 || true
systemctl unmask systemd-backlight@backlight:l81a-wled.service >/dev/null 2>&1 || true
# Hall SW_LID / SW_TABLET_MODE are gpio-keys in DT — do not inject.
rm -f /usr/local/sbin/dagu-power-menu \
	/usr/share/applications/org.dagu.PowerMenu.desktop \
	/usr/local/sbin/dagu-power-button.py \
	/usr/local/sbin/dagu-tablet-mode.py \
	/etc/systemd/system/dagu-tablet-mode.service \
	/etc/systemd/system/multi-user.target.wants/dagu-tablet-mode.service \
	/etc/systemd/system/dagu-power-button.service \
	/etc/systemd/system/multi-user.target.wants/dagu-power-button.service
systemctl disable --now dagu-power-button.service >/dev/null 2>&1 || true
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
# USB ACM has no UART CD until the host raises DTR. Without -L, agetty
# clock_nanosleeps and the host sees a tty timeout / empty ACM reads.
# TERM=dumb: systemd otherwise sends CSI 6n / 32766;32766H size probes and
# waits for a cursor report that a dumb ACM never replies.
mkdir -p /etc/systemd/system/serial-getty@ttyGS0.service.d
cat >/etc/systemd/system/serial-getty@ttyGS0.service.d/local.conf <<'EOF'
[Service]
Environment=TERM=dumb
Environment=SYSTEMD_OSC_CONTEXT=0
ExecStart=
ExecStart=-/usr/sbin/agetty -L --noreset --noclear --keep-baud 115200,57600,38400,9600 %I dumb
EOF
systemctl enable ssh.service || true
systemctl enable NetworkManager.service || true
# QCA6390 stays associated across s2idle (ath11k wowlan + NM).
# Folio open is gpio-keys GPIO110 wakeup; unlock on resume.
mkdir -p /etc/NetworkManager/conf.d /etc/udev/rules.d \
	/usr/lib/systemd/system-sleep /usr/local/sbin
cat >/etc/NetworkManager/conf.d/20-dagu-wifi-wowlan.conf <<'EOF'
[connection]
wifi.wake-on-wlan=disconnect,magic,gtk-rekey-failure
EOF
cat >/etc/udev/rules.d/70-dagu-wifi-wakeup.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x17cb", ATTR{device}=="0x1101", ATTR{power/wakeup}="enabled"
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x17cb", ATTR{device}=="0x010b", ATTR{power/wakeup}="enabled"
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlp1s0", ATTR{device/power/wakeup}="enabled"
EOF
cat >/usr/lib/systemd/system-sleep/dagu-folio-resume <<'EOF'
#!/bin/sh
[ "${1-}" = post ] || exit 0
loginctl unlock-sessions >/dev/null 2>&1 || true
EOF
chmod 755 /usr/lib/systemd/system-sleep/dagu-folio-resume
cat >/usr/local/sbin/dagu-wifi-wowlan-apply <<'EOF'
#!/bin/sh
set -eu
WOW='disconnect,magic,gtk-rekey-failure'
for pci in /sys/bus/pci/devices/*; do
	[ -f "$pci/vendor" ] || continue
	v=$(cat "$pci/vendor")
	id=$(cat "$pci/device")
	if [ "$v" = "0x17cb" ] && { [ "$id" = "0x1101" ] || [ "$id" = "0x010b" ]; }; then
		echo enabled >"$pci/power/wakeup" 2>/dev/null || true
	fi
done
if [ -f /sys/class/net/wlp1s0/device/power/wakeup ]; then
	echo enabled >/sys/class/net/wlp1s0/device/power/wakeup
fi
command -v nmcli >/dev/null 2>&1 || exit 0
nmcli -t -f UUID,TYPE connection show | while IFS=: read -r uuid type; do
	[ "$type" = "802-11-wireless" ] || continue
	cur=$(nmcli -g 802-11-wireless.wake-on-wlan connection show "$uuid" 2>/dev/null || true)
	case $cur in
	*disconnect*) ;;
	*)
		nmcli connection modify "$uuid" \
			802-11-wireless.wake-on-wlan "$WOW" || true
		;;
	esac
done
if command -v iw >/dev/null 2>&1 && [ -d /sys/class/ieee80211/phy0 ]; then
	iw phy phy0 wowlan enable disconnect magic-packet gtk-rekey-failure \
		>/dev/null 2>&1 || true
fi
EOF
chmod 755 /usr/local/sbin/dagu-wifi-wowlan-apply
/usr/local/sbin/dagu-wifi-wowlan-apply || true

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
mkdir -p /etc/systemd/timesyncd.conf.d
cat >/etc/systemd/timesyncd.conf.d/dagu.conf <<'EOF'
[Time]
NTP=ntp.aliyun.com ntp.tencent.com ntp.tuna.tsinghua.edu.cn
FallbackNTP=ntp.ubuntu.com pool.ntp.org
EOF
rm -f /usr/local/sbin/dagu-time-sync.py \
	/etc/systemd/system/dagu-time-sync.service \
	/etc/systemd/system/dagu-time-sync.timer \
	/etc/systemd/system/multi-user.target.wants/dagu-time-sync.service \
	/etc/systemd/system/timers.target.wants/dagu-time-sync.timer \
	/etc/NetworkManager/dispatcher.d/50-dagu-time-sync
systemctl enable systemd-timesyncd.service 2>/dev/null || true

# Hide internal UFS partitions from Files/Nautilus (USB sticks stay visible).
mkdir -p /etc/udev/rules.d
cat >/etc/udev/rules.d/99-dagu-hide-internal-ufs.rules <<'EOF'
ACTION=="add|change", SUBSYSTEM=="block", DEVPATH=="*/1d84000.ufshc/*", ENV{UDISKS_IGNORE}="1"
EOF
cat >/etc/udev/rules.d/90-dagu-nanosic-keyboard.rules <<'EOF'
ACTION=="add|change", SUBSYSTEM=="input", KERNEL=="event*", \
  ATTRS{id/bustype}=="0018", ATTRS{id/vendor}=="15d9", ENV{ID_BUS}="i2c"
ACTION=="add|change", SUBSYSTEM=="input", KERNEL=="event*", \
  ATTRS{name}=="xiaomi keyboard WakeUp", \
  ENV{ID_INPUT}="0", ENV{ID_INPUT_KEY}="0", ENV{LIBINPUT_IGNORE_DEVICE}="1"
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

Comment "Xiaomi Pad 5 Pro 12.4 speakers and built-in mic"

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

SectionDevice."Mic" {
	Comment "Built-in microphone (WCD9385 AMIC5)"
	EnableSequence [
		cset "name='MultiMedia2 Mixer TX_CODEC_DMA_TX_3' on"
		cset "name='TX DEC0 MUX' SWR_MIC"
		cset "name='TX SMIC MUX0' ADC3"
		cset "name='TX_AIF1_CAP Mixer DEC0' 1"
		cset "name='ADC4_MIXER Switch' on"
		cset "name='ADC4 MUX' INP5"
		cset "name='ADC4 Switch' on"
		cset "name='TX3 MODE' ADC_NORMAL"
		cset "name='ADC4 Volume' 12"
		cset "name='Fluence AEC NS' AEC_NS"
	]
	DisableSequence [
		cset "name='ADC4 Switch' off"
		cset "name='ADC4_MIXER Switch' off"
		cset "name='TX SMIC MUX0' ZERO"
		cset "name='TX_AIF1_CAP Mixer DEC0' 0"
		cset "name='TX3 MODE' ADC_INVALID"
		cset "name='MultiMedia2 Mixer TX_CODEC_DMA_TX_3' off"
		cset "name='Fluence AEC NS' Off"
	]
	Value {
		CapturePriority 200
		CapturePCM "hw:${CardId},1"
		CaptureChannels 1
		CaptureRate 48000
		# No CaptureMixerElem: GNOME must not slam ADC4 Volume.
	}
}

SectionDevice."VoiceUI" {
	Comment "ADSP VA macro capture (keyword-spotting frontend, not CPU KWS)"
	EnableSequence [
		cset "name='MultiMedia3 Mixer VA_CODEC_DMA_TX_0' on"
	]
	DisableSequence [
		cset "name='MultiMedia3 Mixer VA_CODEC_DMA_TX_0' off"
	]
	Value {
		CapturePriority 100
		CapturePCM "hw:${CardId},2"
		CaptureChannels 1
		CaptureRate 48000
	}
}

SectionDevice."Bluetooth" {
	Comment "Q6 SLIMBUS_7_RX A2DP offload (not HCI SBC on the AP)"
	EnableSequence [
		cset "name='SLIMBUS_7_RX Audio Mixer MultiMedia4' on"
	]
	DisableSequence [
		cset "name='SLIMBUS_7_RX Audio Mixer MultiMedia4' off"
	]
	Value {
		PlaybackPriority 150
		PlaybackPCM "hw:${CardId},3"
		PlaybackChannels 2
		PlaybackRate 48000
		PlaybackFormat "S24_LE"
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
if [ -x /usr/local/sbin/dagu-mic-route.sh ]; then
	/usr/local/sbin/dagu-mic-route.sh || true
fi
exit 0
EOF
chmod 755 /usr/local/sbin/dagu-speaker-route.sh
cat >/usr/local/sbin/dagu-mic-route.sh <<'EOF'
#!/bin/sh
# Android overlay_static speaker-mic: AMIC5 / ADC4 INP5 / TX SMIC ADC3.
set -eu
CARD="${DAGU_ALSA_CARD:-0}"
cset() {
	amixer -c "$CARD" cset "name=$1" "$2" >/dev/null 2>&1 || true
}
cset "MultiMedia2 Mixer TX_CODEC_DMA_TX_3" on
cset "TX DEC0 MUX" SWR_MIC
cset "TX SMIC MUX0" ADC3
cset "TX_AIF1_CAP Mixer DEC0" 1
cset "ADC4_MIXER Switch" 1
cset "ADC4 MUX" INP5
cset "ADC4 Switch" 1
cset "TX3 MODE" ADC_NORMAL
cset "ADC4 Volume" 12
cset "TX_DEC0 Volume" 84
cset "Fluence AEC NS" AEC_NS
exit 0
EOF
chmod 755 /usr/local/sbin/dagu-mic-route.sh
cat >/usr/local/sbin/dagu-va-route.sh <<'EOF'
#!/bin/sh
# VA_CODEC_DMA_TX_0 is the ADSP Voice Activation capture port (KWS frontend).
set -eu
CARD="${DAGU_ALSA_CARD:-0}"
amixer -c "$CARD" cset "name=MultiMedia3 Mixer VA_CODEC_DMA_TX_0" on >/dev/null 2>&1 || true
amixer -c "$CARD" cset "name=VA DEC0 MUX" VA_DMIC >/dev/null 2>&1 || true
amixer -c "$CARD" cset "name=VA_AIF1_CAP Mixer DEC0" 1 >/dev/null 2>&1 || true
echo "dagu-va-route: VA_CODEC_DMA_TX_0 -> MultiMedia3 (hw:${CARD},2)"
exit 0
EOF
cat >/usr/local/sbin/dagu-bt-a2dp-route.sh <<'EOF'
#!/bin/sh
# Q6 SLIMBUS_7_RX A2DP playback backend. Encoding stays on ADSP.
set -eu
CARD="${DAGU_ALSA_CARD:-0}"
amixer -c "$CARD" cset "name=SLIMBUS_7_RX Audio Mixer MultiMedia4" on >/dev/null 2>&1 || true
echo "dagu-bt-a2dp-route: SLIMBUS_7_RX <- MultiMedia4 (hw:${CARD},3)"
exit 0
EOF
chmod 755 /usr/local/sbin/dagu-va-route.sh /usr/local/sbin/dagu-bt-a2dp-route.sh
mkdir -p /etc/wireplumber/wireplumber.conf.d
cat >/etc/wireplumber/wireplumber.conf.d/50-dagu-bt-offload.conf <<'EOF'
# QCA6390 A2DP must stay on Q6 SLIMBUS_7, not PipeWire SBC on the AP.
monitor.bluez.properties = {
  bluez5.hw-offload-sco = true
  bluez5.enable-sbc-xq = false
  bluez5.enable-msbc = false
}
monitor.bluez.rules = [
  {
    matches = [
      { device.name = "~bluez_card.*" }
    ]
    actions = {
      update-props = {
        api.bluez5.hw-offload = true
        bluez5.hw-offload-sco = true
      }
    }
  }
]
EOF
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
  {
    matches = [
      { node.name = "~alsa_input.platform-sound.*" }
    ]
    actions = {
      update-props = {
        audio.channels = 1
        audio.rate = 48000
        api.alsa.soft-mixer = true
        node.nick = "Microphone"
        node.description = "Built-in Microphone"
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
# Chrome getUserMedia on Wayland uses portal Camera.AccessCamera.
# Snapshot already had devices/camera=yes; Chromium/Chrome did not.
cat >/usr/local/sbin/dagu-camera-portal-perm.py <<'EOF'
#!/usr/bin/env python3
import sys
try:
    import dbus
except ImportError as e:
    raise SystemExit(f"need python3-dbus: {e}")
APPS = (
    "",
    "org.gnome.Snapshot",
    "org.chromium.Chromium",
    "org.chromium.Chromium.desktop",
    "google-chrome",
    "com.google.Chrome",
    "chromium",
)
bus = dbus.SessionBus()
store = bus.get_object(
    "org.freedesktop.impl.portal.PermissionStore",
    "/org/freedesktop/impl/portal/PermissionStore",
)
iface = dbus.Interface(store, "org.freedesktop.impl.portal.PermissionStore")
for app in APPS:
    iface.SetPermission("devices", True, "camera", app, ["yes"])
EOF
chmod 755 /usr/local/sbin/dagu-camera-portal-perm.py
mkdir -p /etc/xdg/autostart
cat >/etc/xdg/autostart/dagu-camera-portal-perm.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=dagu camera portal permission
Exec=/usr/local/sbin/dagu-camera-portal-perm.py
X-GNOME-Autostart-Phase=Application
NoDisplay=true
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
cat >/etc/udev/rules.d/90-dagu-bms.rules <<'EOF'
SUBSYSTEM=="power_supply", KERNEL=="bq27z561-*", ENV{UPOWER_IGNORE}="1", ENV{UPOWER_BATTERY_TYPE}=""
EOF
cat >/etc/udev/rules.d/90-dagu-backlight.rules <<'EOF'
# Persist l81a-wled on every slider change (shutdown save misses reboot -f).
ACTION=="change", SUBSYSTEM=="backlight", KERNEL=="l81a-wled", RUN+="/usr/lib/systemd/systemd-backlight save backlight:l81a-wled"
EOF
cat >/etc/udev/rules.d/90-dagu-dsp.rules <<'EOF'
KERNEL=="fastrpc-*", MODE="0660", GROUP="video"
KERNEL=="fastrpc-sdsp", TAG+="systemd", ENV{SYSTEMD_WANTS}="hexagonrpcd-sdsp.service"
ACTION=="add", KERNEL=="event*", ATTRS{name}=="dagu-lsm6dso-accel", ENV{ID_INPUT_ACCELEROMETER}="1", ENV{ACCEL_MOUNT_MATRIX}="-1, 0, 0; 0, 1, 0; 0, 0, -1"
EOF
is_elf /usr/local/sbin/dagu-ssc || {
	echo "rootfs-desktop-setup: missing dagu-ssc" >&2
	exit 1
}
is_elf /usr/local/sbin/dagu-cdsp-rpc || {
	echo "rootfs-desktop-setup: missing dagu-cdsp-rpc" >&2
	exit 1
}
if is_elf /usr/local/bin/hexagonrpcd; then
cat >/etc/systemd/system/hexagonrpcd-sdsp.service <<'EOF'
[Unit]
Description=dagu SLPI FastRPC reverse tunnel (sns registry fopen)
ConditionPathExists=/dev/fastrpc-sdsp
After=local-fs.target
Before=dagu-ssc.service

[Service]
Type=simple
Environment=LD_LIBRARY_PATH=/usr/local/lib
StandardOutput=journal
StandardError=journal
ExecStart=/usr/bin/stdbuf -oL -eL /usr/local/bin/hexagonrpcd -f /dev/fastrpc-sdsp -d sdsp -s -R /usr/share/qcom/sm8250/Xiaomi/dagu
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/hexagonrpcd-sdsp.service \
	/etc/systemd/system/multi-user.target.wants/hexagonrpcd-sdsp.service
else
	echo "rootfs-desktop-setup: hexagonrpcd not staged (run dagu-dsp-deploy on the board)" >&2
fi
cat >/etc/systemd/system/dagu-ssc.service <<'EOF'
[Unit]
Description=dagu SLPI SEE sensors (LSM6DSO / tcs3701)
After=local-fs.target hexagonrpcd-sdsp.service
Wants=hexagonrpcd-sdsp.service iio-sensor-proxy.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/dagu-ssc
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
cat >/etc/systemd/system/dagu-cdsp-rpc.service <<'EOF'
[Unit]
Description=dagu CDSP Hexagon 698 FastRPC session
After=local-fs.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/dagu-cdsp-rpc
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/dagu-ssc.service \
	/etc/systemd/system/multi-user.target.wants/dagu-ssc.service
ln -sf /etc/systemd/system/dagu-cdsp-rpc.service \
	/etc/systemd/system/multi-user.target.wants/dagu-cdsp-rpc.service
systemctl enable iio-sensor-proxy.service >/dev/null 2>&1 || true
mkdir -p /etc/dconf/db/local.d/locks
cat >/etc/dconf/db/local.d/00-dagu-brightness <<'EOF'
[org/gnome/settings-daemon/plugins/power]
idle-dim=false
ambient-enabled=false

[org/gnome/desktop/session]
idle-delay=uint32 0
EOF
cat >/etc/dconf/db/local.d/locks/dagu-brightness <<'EOF'
/org/gnome/settings-daemon/plugins/power/idle-dim
/org/gnome/settings-daemon/plugins/power/ambient-enabled
/org/gnome/desktop/session/idle-delay
EOF
dconf update 2>/dev/null || true
cat >/etc/udev/rules.d/90-dagu-v4l2loopback.rules <<'EOF'
SUBSYSTEM=="video4linux", ATTR{name}=="dagu-front", GROUP="video", MODE="0660", ENV{ID_V4L_CAPABILITIES}=":capture:"
SUBSYSTEM=="video4linux", ATTR{name}=="dagu-rear", GROUP="video", MODE="0660", ENV{ID_V4L_CAPABILITIES}=":capture:"
SUBSYSTEM=="video4linux", ATTR{name}=="msm_vfe*", GROUP="root", MODE="0600", TAG-="uaccess"
EOF
# RustDesk 1.4.9 single-display uinput uses DRM physical 1600x2560. Daily
# Mutter is transform 270 / scale 1.25 (logical 2048x1280, capture 2560x1600).
# Keep in sync with linux-mainline/scripts/dagu-rustdesk-uinput-abs.py and
# linux-mainline/udev/90-dagu-rustdesk-uinput.rules.
install -m755 /dev/null /usr/local/sbin/dagu-rustdesk-uinput-abs
cat >/usr/local/sbin/dagu-rustdesk-uinput-abs <<'ABS_EOF'
#!/usr/bin/env python3
from __future__ import annotations
import ctypes, fcntl, glob, os, syslog, sys, xml.etree.ElementTree as ET
MOUSE_NAME = "mouce-library-fake-mouse"
DEFAULT_PHY = (1600, 2560)
ABS_X, ABS_Y = 0, 1
ROTATED = {1, 3}
class AbsInfo(ctypes.Structure):
    _fields_ = [
        ("value", ctypes.c_int), ("minimum", ctypes.c_int),
        ("maximum", ctypes.c_int), ("fuzz", ctypes.c_int),
        ("flat", ctypes.c_int), ("resolution", ctypes.c_int),
    ]
def _ioc(dir_, nr):
    return dir_ | (ctypes.sizeof(AbsInfo) << 16) | (ord("E") << 8) | nr
def eviocgabs(code):
    return _ioc(0x80000000, 0x40 + code)
def eviocsabs(code):
    return _ioc(0x40000000, 0xC0 + code)
def log(msg: str) -> None:
    syslog.syslog(syslog.LOG_INFO, f"dagu-rustdesk-uinput-abs: {msg}")
    print(f"dagu-rustdesk-uinput-abs: {msg}", file=sys.stderr)
def drm_mode() -> tuple[int, int]:
    for path in glob.glob("/sys/class/drm/card*-DSI-1/modes"):
        try:
            line = open(path, encoding="ascii").read().splitlines()
        except OSError:
            continue
        if line and "x" in line[0]:
            w, h = line[0].split("x", 1)
            return int(w), int(h)
    return DEFAULT_PHY
def xml_transform() -> int | None:
    try:
        rot = ET.parse("/home/dagu/.config/monitors.xml").getroot().findtext(
            ".//logicalmonitor/transform/rotation")
    except (OSError, ET.ParseError):
        return None
    if rot in ("right", "left"):
        return 3
    if rot == "upside_down":
        return 2
    if rot in ("normal", None):
        return 0
    return None
def target_abs(phy_w: int, phy_h: int) -> tuple[int, int]:
    transform = xml_transform()
    if transform is None:
        transform = 3 if phy_h > phy_w else 0
    if transform in ROTATED:
        return phy_h, phy_w
    return phy_w, phy_h
def find_mouse_nodes(explicit: str | None) -> list[str]:
    if explicit:
        return [explicit]
    nodes = []
    for path in glob.glob("/sys/class/input/event*/device/name"):
        try:
            name = open(path, encoding="utf-8").read().strip()
        except OSError:
            continue
        if name == MOUSE_NAME:
            ev = os.path.basename(os.path.dirname(os.path.dirname(path)))
            nodes.append(f"/dev/input/{ev}")
    return nodes
def set_abs(node: str, max_x: int, max_y: int) -> None:
    fd = os.open(node, os.O_RDWR)
    try:
        for code, maximum in ((ABS_X, max_x), (ABS_Y, max_y)):
            info = AbsInfo()
            fcntl.ioctl(fd, eviocgabs(code), info)
            info.minimum = 0
            info.maximum = maximum
            info.value = min(max(info.value, 0), maximum)
            fcntl.ioctl(fd, eviocsabs(code), info)
        ax, ay = AbsInfo(), AbsInfo()
        fcntl.ioctl(fd, eviocgabs(ABS_X), ax)
        fcntl.ioctl(fd, eviocgabs(ABS_Y), ay)
        log(f"{node} ABS {ax.minimum}:{ax.maximum} x {ay.minimum}:{ay.maximum}")
        if ax.maximum != max_x or ay.maximum != max_y:
            raise OSError(f"EVIOCSABS did not stick on {node}")
    finally:
        os.close(fd)
def main() -> int:
    syslog.openlog("dagu-rustdesk-uinput-abs")
    explicit = sys.argv[1] if len(sys.argv) > 1 else None
    nodes = find_mouse_nodes(explicit)
    if not nodes:
        log(f"no {MOUSE_NAME} node yet")
        return 0
    phy_w, phy_h = drm_mode()
    max_x, max_y = target_abs(phy_w, phy_h)
    log(f"panel {phy_w}x{phy_h} -> uinput 0:{max_x} x 0:{max_y}")
    for node in nodes:
        set_abs(node, max_x, max_y)
    return 0
if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        log(f"failed: {exc}")
        raise SystemExit(1)
ABS_EOF
chmod 755 /usr/local/sbin/dagu-rustdesk-uinput-abs
cat >/etc/udev/rules.d/90-dagu-rustdesk-uinput.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="mouce-library-fake-mouse", IMPORT{program}="/usr/local/sbin/dagu-rustdesk-uinput-abs /dev/input/%k"
EOF
cat >/etc/modprobe.d/v4l2loopback.conf <<'EOF'
# exclusive_caps=1: Chrome V4L2 skips Capture+Output nodes.
# Watch stamps YUYV 1280x720 so capture is listed before SoftISP STREAMON.
# max_buffers=8: xcast/webrtc REQBUFS(4). Default 2 → meeting preview black.
options v4l2loopback devices=2 video_nr=20,21 exclusive_caps=1,1 max_buffers=8 card_label=dagu-front,dagu-rear
EOF
echo v4l2loopback >/etc/modules-load.d/dagu-v4l2loopback.conf
# Product camera path is the Rust+C++ ELF. Do not cat the lab .sh here.
is_elf /usr/local/sbin/dagu-camera-loopback || {
	echo "rootfs-desktop-setup: missing dagu-camera-loopback ELF" >&2
	exit 1
}
cat >/etc/systemd/system/dagu-camera-loopback.service <<'EOF'
[Unit]
Description=dagu v4l2loopback NV12 both-nodes (not Spectra ISP)
After=systemd-modules-load.service
Documentation=file:///usr/local/sbin/dagu-camera-loopback

[Service]
Type=simple
ExecStart=/usr/local/sbin/dagu-camera-loopback all
CPUAffinity=0-5
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
    # DebayerCpu packed-10P skip is the Viewfinder FOV path. GPU EGL ignores it.
    mode: cpu
    # DebayerCpu default is already 2 on current libcamera; pin it so a
    # distro rebuild cannot spawn 8 threads and starve mutter/Himax.
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
	# Volume/mute live in WirePlumber default-routes. Do not slam 100%.
fi
src=$(wpctl status 2>/dev/null | awk '
	$0 ~ /Sources:/{s=1}
	s && /Filters:/{exit}
	s && /Streams:/{exit}
	s && /Video/{exit}
	s && /Microphone|Mic/ {
		for (i=1;i<=NF;i++)
			if ($i ~ /^[0-9]+\.?$/) { gsub(/\./,"",$i); print $i; exit }
	}
')
if [ -n "${src:-}" ]; then
	wpctl set-default "$src" >/dev/null 2>&1 || true
	wpctl set-mute "$src" 0 >/dev/null 2>&1 || true
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

# Touch floors: C daemon (evdev + sysfs). Himax driver also votes after a
# kernel flash. SoftISP pin is dagu_cam.cpp, not this process.
is_elf /usr/local/sbin/dagu-touch-boost || {
	echo "rootfs-desktop-setup: missing dagu-touch-boost ELF" >&2
	exit 1
}
cat >/etc/systemd/system/dagu-touch-boost.service <<'EOF'
[Unit]
Description=dagu: raise GPU/CPU floors while touching
After=dagu-resources-fix.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/dagu-touch-boost
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
