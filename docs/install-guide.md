**Language:** English | [简体中文](zh-CN/install-guide.md)

# Full install: Ubuntu desktop on the Xiaomi Pad 5 Pro 12.4

Follow this page from the top and the tablet ends up with a complete Ubuntu 26.04 GNOME desktop on mainline Linux 7.0. The display, touch, folio keyboard, Wi-Fi, Bluetooth, speakers, microphone, both cameras, hardware video decode, charging and suspend all work.

This page matches Release **v0.1.7**. To upgrade a tablet that already runs Ubuntu, skip to [section 8](#8-ubuntu-is-already-installed-upgrade-only).

## 1. Read this first

- Only for the **Xiaomi Pad 5 Pro 12.4** (`dagu`, model `22081281AC`, Snapdragon 870). Do **not** flash nabu, elish, pipa or any other tablet.
- Installing Ubuntu **erases all Android user data** (`/data`). Back up photos and chats first.
- The bootloader must be **unlocked**. Unlocking erases data too.
- The tablet has slots A and B. This project only writes **slot B**. Keep slot A on stock Android or TWRP as the rescue system.
- **Never relock the bootloader.** Relocking with Ubuntu installed bricks the tablet.

## 2. Prepare

### 2.1 Unlock the bootloader

Use Xiaomi's official unlock flow: [bootloader unlock guide](bootloader-unlock-guide.md). Afterwards, enter fastboot by holding **Volume Down + Power** while the tablet is off. The FASTBOOT bunny appears.

### 2.2 A Linux PC

Ubuntu 24.04 / 26.04 or Debian 13 on x86_64 or arm64. WSL2 with usbipd may work but is untested; a real Linux machine is the safe choice.

```bash
sudo apt update
sudo apt install -y git python3 libusb-1.0-0 zstd curl android-sdk-platform-tools-common
```

`android-sdk-platform-tools-common` installs the USB permission rules for `18d1:d00d`, so a normal user can talk to fastboot. Add this project's rule as well; it turns off USB2 link power management, which hangs flashing on some AMD hosts:

```bash
git clone https://github.com/Huabin1010/dagu-mainline-linux.git
cd dagu-mainline-linux
sudo cp linux-mainline/host/99-dagu-fastboot-nolpm.rules /etc/udev/rules.d/
sudo udevadm control --reload
```

Do **not** flash these images with Google platform-tools 37 `fastboot`. It hangs on some hosts and cannot write a userdata image larger than the 768 MiB download limit. Every step below uses the in-tree `fb-usb.py` and its wrapper scripts.

## 3. Download and verify

From the repository (without `gh`, download the assets from the [Release page](https://github.com/Huabin1010/dagu-mainline-linux/releases/tag/v0.1.7) into `linux-mainline/out/`):

```bash
mkdir -p linux-mainline/out
gh release download v0.1.7 --repo Huabin1010/dagu-mainline-linux --dir linux-mainline/out
cd linux-mainline/out
sha256sum -c SHA256SUMS
sha256sum -c rootfs-desktop.SHA256SUMS
cd ../..
```

Both checks must print `OK`. If one fails, download again; do not flash.

| Asset | Use |
|-------|-----|
| `rootfs-desktop.ext4.zst` | Ubuntu desktop, written to userdata |
| `boot-dagu.img` | Kernel + device tree + initramfs, `boot_b` |
| `vendor_boot-dagu.img` | `vendor_boot_b` |
| `dtbo-stub.img` | `dtbo_b` |
| `vbmeta-disabled.img` | `vbmeta_b` (verified boot off) |
| `dagu-userspace-v0.1.7.tar.gz` | Upgrade package for an installed system (section 8) |
| `SHA256SUMS`, `rootfs-desktop.SHA256SUMS` | Checksums |

## 4. Enter fastboot and check the device

Tablet off, hold **Volume Down + Power**, connect USB:

```bash
python3 linux-mainline/scripts/fb-usb.py getvar product    # must be dagu
python3 linux-mainline/scripts/fb-usb.py getvar unlocked   # must be yes
```

Stop here if `product` is not `dagu` or `unlocked` is not `yes`.

## 5. Flash Ubuntu (erases Android data)

```bash
./linux-mainline/scripts/flash-rootfs.sh
```

The script unpacks the `.zst` (about 10 GiB) and writes it to userdata in 256 MiB pieces. Over USB 2.0 that takes roughly 5 to 10 minutes. Do not unplug the cable or touch the tablet.

## 6. Flash the boot chain (slot B only)

With the tablet still in fastboot:

```bash
./linux-mainline/scripts/flash-boot.sh flash-b
```

It writes `dtbo_b`, `vbmeta_b`, `vendor_boot_b` and `boot_b`, makes B active, waits 5 s and reboots. Every step should print `OKAY`.

After the reboot the PC sees a USB serial device `0525:a4a7` (`lsusb`). If it stays for **more than 30 s**, the kernel is up. If the tablet drops back to the `18d1:d00d` bunny after about 6 s, the bootloader rejected an image: run step 6 again.

## 7. First boot

- The first boot grows the 10 GiB root filesystem across userdata (about 106 GiB) and logs into GNOME. Allow one to two minutes.
- Prebuilt accounts (**change the passwords right away**):

  | User | Password | Use |
  |------|----------|-----|
  | `dagu` | `dagu` | Desktop autologin |
  | `root` | `dagu` | USB serial / SSH |

  ```bash
  passwd
  sudo passwd root
  ```

- Join Wi-Fi from the top-right menu. The tablet has no RTC, so the clock is right only after NTP over the network.
- Landscape and 1.25 scaling are the defaults. The input method is fcitx5; tap Shift to switch between Chinese and English.
- The folio keyboard works as soon as it attaches. The on-screen keyboard only opens where text can be typed.

The system ships with the settings we use every day:

| Area | Default |
|------|---------|
| Wi-Fi | Power save off on the charger (about 2.4 ms to the router), on on battery |
| Bluetooth | Stock BlueZ settings. Classic keyboards (PIN typed on the keyboard) and BLE mice pair from Settings with one tap and are usable right away; bonded devices reconnect when you press a key or move the mouse |
| Storage | Daily TRIM keeps the UFS WriteBooster cache available |
| Cameras | Hardware ISP; the picture appears about 0.5 s after an app opens the camera, 30 fps |
| Charging | The charger IC decides full and recharge, as on stock (230 mA termination, 4.40 V recharge) |
| Suspend | Closing the cover or pressing power suspends; a Wi-Fi magic packet wakes it |
| Shutdown | The system log scrolls while shutting down; the screen goes dark after the filesystem is read-only |
| Browser | The adapted Chromium (hardware decode and WebCodecs hardware encode, Wayland, Chinese input) is preinstalled and first in the dock |
| Updates | The packages we patched (Chromium, mutter/gnome-shell, PipeWire, Mesa, libcamera, BlueZ, Settings) are held, so `apt upgrade` does not replace them with the archive builds |

## 8. Ubuntu is already installed: upgrade only

Do **not** flash the rootfs again on a tablet that already runs Ubuntu (it wipes your apps and files). Two steps:

1. In fastboot, flash the boot chain:

   ```bash
   ./linux-mainline/scripts/flash-boot.sh flash-b
   ```

2. After boot, copy the upgrade package to the tablet and install it:

   ```bash
   scp linux-mainline/out/dagu-userspace-v0.1.7.tar.gz dagu@<tablet-ip>:
   ssh dagu@<tablet-ip>
   tar xzf dagu-userspace-v0.1.7.tar.gz
   sudo ./dagu-userspace-v0.1.7/install.sh
   sudo reboot
   ```

On the tablet, `uname -v` should then show `#654`.

## 9. Status

Working: display (120 Hz), touch, folio keyboard, Wi-Fi, Bluetooth (mice, keyboards, headphones), four speakers, microphone, front and rear cameras, hardware video decode (GStreamer and the bundled V4L2 Chromium), GPU (Turnip Vulkan / Freedreno OpenGL), wired charging, off-mode charging screen, suspend and resume.

Known issues:

- **Accelerometer and light sensor are not available yet**, so there is no auto-rotate and no auto-brightness. The sensor DSP reads one platform file after boot and never reads the sensor configuration; the cause is still being investigated.
- mpv decodes in hardware but copies frames back to memory, so it uses more CPU than the browser.
- The Wi-Fi and Bluetooth MAC addresses in the released kernel are fixed. With two of these tablets on one network, build your own kernel with each tablet's MACs ([flash guide](flash-guide.md)).

## 10. Recovery and going back to Android

- Stuck at the Xiaomi logo: hold power to force off, then hold **Volume Down + Power** for fastboot and repeat step 6.
- Boots straight back to fastboot: run `python3 linux-mainline/scripts/fb-usb.py set-active b`, then repeat step 6.
- Back to Android: boot slot A, or flash the official fastboot ROM with the [EDL recovery playbook](dagu-edl-recovery-full-playbook.md). **Do not relock.**

## 11. Do not

- Write slot A, or use `flash-boot.sh flash` (both slots)
- Flash userdata with Google `fastboot` 37
- Flash `dtbo-empty.img` (bounces to fastboot in about 6 s)
- Reflash the rootfs once Ubuntu is installed (all data is lost)
- Boot stock Android `boot` from fastboot after Ubuntu is on userdata (Android cannot mount the ext4 userdata)

More detail: [flash guide](flash-guide.md) · [rootfs notes](rootfs-guide.md)
