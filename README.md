# dagu-mainline-linux

**Language:** English | [简体中文](README.zh-CN.md)

Mainline Linux bring-up for **Xiaomi Pad 5 Pro 12.4** (codename **dagu**, Qualcomm **SM8250** / Snapdragon 870).

This tree builds Linux 7.0 + an Ubuntu arm64 desktop, then flashes them onto the tablet. The kernel goes to **slot B**; Ubuntu lives on **userdata**. Slot A stays a recovery computer (TWRP / stock). Display, touch, Wi-Fi, GNOME, Adreno 650 (Turnip), Venus, and both cameras already work on the L81A dual-DPHY panel.

| Stage | Goal | Status |
|-------|------|--------|
| P0 | USB gadget serial / ramdisk | Done (`0525:a4a7`) |
| P1 | UFS + Ubuntu on userdata | Done |
| P2 | CPUFreq + TSENS | Done |
| P3 | L81A 120 Hz DSC dual-DPHY | Done |
| P4 | Himax SPI touch | Done |
| P5 | QCA6390 Wi-Fi (ath11k) | Done |
| P6 | Adreno 650 / Turnip + GNOME | Done |
| P7 | CS35L41 speakers + WCD9385 mics | Done |
| P8 | Venus 4K60 + front/rear cameras | Done (IFE hardware path) |

Hardware notes and the full bring-up record live under [`linux-mainline/docs/`](linux-mainline/docs/dagu-adaptation-status.md). The board status table is [`linux-mainline/docs/dagu-adaptation-status.md`](linux-mainline/docs/dagu-adaptation-status.md). The end-to-end adaptation record and lessons learned (Chinese) are in [`linux-mainline/docs/dagu-mainline-adaptation-handbook.md`](linux-mainline/docs/dagu-mainline-adaptation-handbook.md).

An unfinished Windows-on-ARM / edk2-msm port lives under [`port/dagu/`](port/dagu/) and [`docs/uefi-port-dagu.md`](docs/uefi-port-dagu.md). That is **not** the daily system.

**Flash tutorial:** [English](docs/flash-guide.md) · [简体中文](docs/zh-CN/flash-guide.md)
**Rootfs / desktop image:** [English](docs/rootfs-guide.md) · [简体中文](docs/zh-CN/rootfs-guide.md)
**Latest images:** [GitHub Releases](https://github.com/Huabin1010/dagu-mainline-linux/releases) (`v0.1.5`)

## Recent updates (`v0.1.5`)

Since `v0.1.4` (22 Oct 2026). Kernel `#630`.

- **Cameras on the hardware ISP:** Both cameras stream through the Titan 480 IFE1 pixel path as linear NV12, with auto exposure and auto white balance in the producer. SoftISP is only the fallback. 30 fps, about 23% of one core.
- **Front camera keeps streaming:** The blocks the driver used as display crop and clamp are the face-detection branch. With no write master behind it, it stalled the pipeline after one frame. It stays off now.
- **Off-mode charging like Android:** Power off with the cable in is a real power-off. The screen goes dark at once, the tablet powers back up into the battery screen, and a long press boots the desktop. Before, a shutdown inhibitor held logind for 20 s and GDM brought the greeter back first.
- **Smooth charger animation:** Frames are built off-screen and only the changed columns reach the scanout, at 30 fps. The screen no longer flickers. About 9% of one core.
- **Boot and blank:** The backlight stays off while the panel is reset and comes on after the first frame, so the white flash at boot is gone. A charger boot keeps the kernel log off the panel. Blanked screens are dark instead of a dim glow.
- **Docs:** [`linux-mainline/docs/dagu-mainline-adaptation-handbook.md`](linux-mainline/docs/dagu-mainline-adaptation-handbook.md), the full adaptation record and lessons (Chinese).

Prebuilt login is unchanged: `dagu` / `dagu` (change it on first boot). Only flash **slot B**. Existing userdata stays: install `dagu-userspace-v0.1.5.tar.gz` from the release on the tablet (`sudo ./install.sh`). Without it the new kernel still boots, but cameras stay on SoftISP and a charger boot stays dark for 60 s.

## Quick start

```bash
# 1. Host packages (once, needs sudo)
./linux-mainline/scripts/setup-deps.sh

# 2. Fetch kernel sources (once)
./linux-mainline/scripts/setup-kernel.sh

# 3. Extract firmware from a local dump (blobs are not in git)
./linux-mainline/scripts/stage-firmware.sh

# 4. Optional: persist Wi-Fi / BT addresses
cp linux-mainline/dts/local-addresses.dtsi.example \
   linux-mainline/dts/local-addresses.dtsi
# Fill local-addresses.dtsi from this unit's persist. Do not commit it.

# 5. Build kernel + dagu DTB
./linux-mainline/scripts/build-kernel.sh

# 6. Pack boot.img
./linux-mainline/scripts/build-bootimg.sh

# 7. Ubuntu desktop on userdata (or download rootfs-desktop.ext4.zst)
ROOT_PASSWORD=... ./linux-mainline/scripts/build-rootfs-desktop.sh

# 8. Flash (device in fastboot). Use the in-tree USB tool, not Google fastboot 37.
./linux-mainline/scripts/flash-rootfs.sh          # userdata — wipes Android /data
./linux-mainline/scripts/flash-boot.sh flash-b    # kernel → slot B only
```

Kernel sources (`linux-mainline/linux/`) and build outputs (`linux-mainline/out/`) are not in git.

## Flash rules

- **Only write slot B.** Slot A is the rescue computer.
- **Do not use Google `fastboot` 37** on AMD hosts (it can stall in `USBDEVFS_REAPURB`). Flash with `linux-mainline/scripts/fb-usb.py` / `flash-boot.sh`.
- Empty DTBO (`dt_entry_count=0`) returns to fastboot in ~6 s. Do not flash it.
- After userdata is Ubuntu, **do not** `fastboot reboot` into the stock Android `boot` of the current slot. Use the in-tree boot/flash scripts.
- Every `set_active` (`flash-b` does one) resets slot B to 7 retries and `slot-successful:b: no`. Until the slot is marked successful, each boot (charger wakes included) costs one retry, and on the 8th ABL marks B unbootable and stops in fastboot. `dagu-boot-success.service` marks it on every boot and must stay enabled. If the tablet is stuck in fastboot with `slot-unbootable:b: yes`: `python3 linux-mainline/scripts/fb-usb.py set-active b`, then `timeout 3 python3 linux-mainline/scripts/fb-usb.py reboot`.
- Brick recovery: volume-down + power → fastboot, or EDL 9008 with the official `flash_all` (**do not relock**). See [EDL playbook](docs/dagu-edl-recovery-full-playbook.md).

Login: USB ACM `ttyACM0`, or SSH over USB RNDIS (`root@192.168.7.2`) / the tablet's Wi-Fi address. The **prebuilt** desktop uses `dagu` / `dagu`. Local builds: export `ROOT_PASSWORD` or write `linux-mainline/out/root-password` (gitignored).

## Layout

```
linux-mainline/config/     Kernel config fragments
linux-mainline/dts/        Board DTS (unit MAC is gitignored)
linux-mainline/overlays/   Out-of-tree drivers (panel, Himax, cameras, …)
linux-mainline/scripts/    Build, flash, USB, desktop helpers
linux-mainline/docs/       Bring-up notes and subsystem write-ups
linux-mainline/firmware/   Staging dir; blobs are gitignored
port/dagu/                 edk2-msm device overlay (WoA, not daily)
docs/                      Unlock, UART, EDL, hardware inventory
devices/                   Stock boot-header notes (no dump blobs)
```

## Hardware (L81A SKU)

| Item | Value |
|------|--------|
| Product | Xiaomi Pad 5 Pro 12.4 (`22081281AC`) |
| SoC | SM8250-AC, Adreno 650 |
| Panel | L81A 1600×2560, 120 Hz, DSC dual-DPHY |
| Touch | Himax over `spi-gpio` (not GENI SPI) |
| Wi-Fi / BT | QCA6390, ath11k + uart6 / hci_qca |
| Cameras | imx596 front skip 2×2 (1296×976), s5kjn1 rear skip 4×4 (1020×764) |
| Decode | Venus stateful V4L2 (`/dev/video14`) |

Do not copy C-PHY / `0x0114=0x0301` onto the rear sensor. Do not set Himax `reset-gpios` to GPIO100. Do not raise `vreg_l3a_0p9` to 1.104 V.

## Environment

See `linux-mainline/scripts/env.sh`:

| Variable | Default | Meaning |
|----------|---------|---------|
| `KERNEL_TAG` | v7.0 | Kernel version |
| `KBUILD_OUTPUT` | `linux-mainline/out/kernel` | Build tree |
| `ROOT_PASSWORD` | *(unset)* | Root / desktop user password for the image |
| `DAGU_SSH_HOST` | `192.168.7.2` | Probe-script SSH target (USB RNDIS) |
| `DAGU_ADB_SERIAL` | *(required)* | Serial of the Android extract tablet |

## What this repo does not contain

- Kernel git clone and `out/` images
- Qualcomm / Xiaomi firmware blobs (stage them from your own dump)
- Device serial numbers, persist MAC / BD addresses, LAN IPs, SSH keys, passwords
- Editor / agent workspace (`.cursor/`, `.vscode/`)

## License

Build scripts, overlays, and original documentation in this repository are [GPL-2.0-only](LICENSE), same as the Linux kernel. Device-tree files keep the SPDX identifier in each file (typically BSD-3-Clause, matching upstream Qualcomm DTS). Device firmware blobs are proprietary; they are provided only for running Linux on the device they were extracted from, and they are not checked in.

UEFI fragments under `port/dagu/` follow edk2-msm licensing.
