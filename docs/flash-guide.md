**Language:** English | [简体中文](zh-CN/flash-guide.md)

# Flash guide (Xiaomi Pad 5 Pro 12.4 / dagu)

Only for **Xiaomi Pad 5 Pro 12.4** (`dagu` / `22081281AC` / SM8250). Do not flash these images on nabu, elish, pipa, or ginkgo.

The bootloader must be **unlocked**. Slot **A** is the rescue computer (TWRP / stock). This tree only writes **slot B**.

## What to download

GitHub [Releases](https://github.com/Huabin1010/dagu-mainline-linux/releases) ship the boot chain:

| Asset | Partition | Notes |
|-------|-----------|--------|
| `boot-dagu.img` | `boot_b` | Linux 7.0 Image + DTB + initramfs |
| `vendor_boot-dagu.img` | `vendor_boot_b` | Mainline vendor_boot |
| `dtbo-stub.img` | `dtbo_b` | Stub with board-ids. **Never** flash `dtbo-empty.img` |
| `vbmeta-disabled.img` | `vbmeta_b` | Verification off |
| `SHA256SUMS` | — | Check before flashing |
| `rootfs-desktop.ext4.zst` | `userdata` | GNOME desktop. **Wipes Android `/data`** |

Ubuntu lives on **userdata** (not A/B). Flash or rebuild: [rootfs guide](rootfs-guide.md) · [简体中文](zh-CN/rootfs-guide.md).

## Host USB

Do **not** use Google platform-tools 37 `fastboot` on AMD hosts — it can stall in `USBDEVFS_REAPURB`. Flash with the in-tree tool:

```bash
linux-mainline/scripts/fb-usb.py
# wrappers:
linux-mainline/scripts/flash-boot.sh flash-b
```

Enter fastboot: volume-down + power, or `adb reboot bootloader` from Android.

```bash
# product must be dagu
python3 linux-mainline/scripts/fb-usb.py getvar product
```

If `product` is not `dagu`, stop.

## First install (wipes Android userdata)

```bash
git clone https://github.com/Huabin1010/dagu-mainline-linux.git
cd dagu-mainline-linux
./linux-mainline/scripts/setup-deps.sh
./linux-mainline/scripts/setup-kernel.sh
./linux-mainline/scripts/stage-firmware.sh   # blobs from your own dump, not git

cp linux-mainline/dts/local-addresses.dtsi.example \
   linux-mainline/dts/local-addresses.dtsi
# Fill persist MAC / BT. Do not commit this file.

DAGU_MINIMAL=1 DAGU_DISPLAY=1 ./linux-mainline/scripts/build-kernel.sh
./linux-mainline/scripts/build-bootimg.sh

# Desktop userdata: download rootfs-desktop.ext4.zst from Releases, or:
ROOT_PASSWORD=... ./linux-mainline/scripts/build-rootfs-desktop.sh
./linux-mainline/scripts/flash-rootfs.sh          # userdata — Android /data is gone
./linux-mainline/scripts/flash-boot.sh flash-b    # dtbo_b + vbmeta_b + vendor_boot_b + boot_b
```

Or download the release (boot chain + desktop rootfs):

```bash
gh release download --repo Huabin1010/dagu-mainline-linux --dir linux-mainline/out
cd linux-mainline/out && sha256sum -c SHA256SUMS && sha256sum -c rootfs-desktop.SHA256SUMS
cd ../..
./linux-mainline/scripts/flash-rootfs.sh
./linux-mainline/scripts/flash-boot.sh flash-b
```

After `flash-b` the script reboots. Expect USB gadget `0525:a4a7` to stay up **>30 s**. If it becomes rabbit `18d1:d00d` in ~6 s, ABL rejected the image (empty DTBO is the usual cause).

## Kernel-only update (keep Ubuntu)

Userdata already has Ubuntu. Do **not** flash userdata again.

```bash
# device in fastboot
./linux-mainline/scripts/flash-boot.sh flash-b
```

That writes `dtbo_b`, `vbmeta_b`, `vendor_boot_b`, `boot_b`, then `set_active b`. Slot A is untouched.

Built-in microphone UCM lives in the rootfs. After a kernel-only flash on an older Ubuntu, push userspace:

```bash
DAGU_HOST=<tablet-wifi-ip> ./linux-mainline/scripts/dagu-mic-deploy.sh
```

## After boot

| Path | How |
|------|-----|
| USB serial | `python3 linux-mainline/scripts/dagu-console.py` (`/dev/ttyACM0`, `0525:a4a7`) |
| USB RNDIS SSH | `ssh -i linux-mainline/out/id_dagu root@192.168.7.2` |
| Wi-Fi SSH | tablet LAN address, same key |

The **prebuilt** desktop logs in as `dagu` / `dagu` (root is the same). Change it. Local builds use `ROOT_PASSWORD`; do not commit it.

Desktop: GNOME Speakers + **Built-in Microphone** (WCD9385 AMIC5, Android speaker-mic path). Userdata steps: [rootfs guide](rootfs-guide.md).

## Unbrick

Slot A stays stock / TWRP. Restore it and switch active:

```bash
./linux-mainline/scripts/flash-boot-legacy.sh restore-a
```

Then hold volume-down + power if the logo sticks.

EDL 9008 + official `flash_all`: [dagu EDL playbook](dagu-edl-recovery-full-playbook.md). **Do not relock**.

## Do not

- Flash slot A, or `flash-boot.sh flash` (both slots) as the daily path
- Use Google `fastboot` 37 to write partitions
- Flash `dtbo-empty.img` (`dt_entry_count=0` → ~6 s back to fastboot)
- `fastboot reboot` into stock Android `boot` after userdata is Ubuntu
- Raise `vreg_l3a_0p9` to 1.104 V, bind Himax reset to GPIO100, or set `DAGU_PRIMARY_ENTRY_PROBE=1`
- Put your own passwords, SSH keys, or persist MACs in a public image
