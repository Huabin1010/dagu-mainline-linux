**Language:** English | [简体中文](zh-CN/rootfs-guide.md)

# Ubuntu desktop rootfs (Xiaomi Pad 5 Pro 12.4 / dagu)

Ubuntu lives on **userdata** (one copy, not A/B). Flashing it **wipes Android `/data`**. The kernel still only goes to **slot B**. Images are for `dagu` / `22081281AC` only.

Boot chain: [flash guide](flash-guide.md). This page is rootfs only.

## Simplest path: download the desktop image

Releases ship a compressed GNOME desktop (Ubuntu 26.04 `resolute`). First boot runs `dagu-resize-root` and grows the filesystem across userdata:

| Asset | Notes |
|-------|--------|
| `rootfs-desktop.ext4.zst` | Desktop userdata image (zstd) |
| `rootfs-desktop.SHA256SUMS` | Checksums |

Prebuilt login (**change the password on first desktop session**):

| User | Password | Use |
|------|----------|-----|
| `dagu` | `dagu` | GNOME autologin |
| `root` | `dagu` | USB serial / SSH |

Scripts never hardcode a password. Only this public image uses the pair above so the tablet can boot unattended. Do not commit your own password or ship it in git.

```bash
git clone https://github.com/Huabin1010/dagu-mainline-linux.git
cd dagu-mainline-linux

gh release download --repo Huabin1010/dagu-mainline-linux --dir linux-mainline/out \
  --pattern 'rootfs-desktop.*' --pattern 'boot-dagu.img' --pattern 'vendor_boot-dagu.img' \
  --pattern 'dtbo-stub.img' --pattern 'vbmeta-disabled.img' --pattern 'SHA256SUMS'

cd linux-mainline/out
sha256sum -c SHA256SUMS
sha256sum -c rootfs-desktop.SHA256SUMS
cd ../..

# unlocked, volume-down + power, product must be dagu
python3 linux-mainline/scripts/fb-usb.py getvar product

./linux-mainline/scripts/flash-rootfs.sh          # userdata — Android /data is gone
./linux-mainline/scripts/flash-boot.sh flash-b    # slot B only, then reboot
```

`flash-rootfs.sh` decompresses `.zst` and writes with in-tree `fb-usb.py -S 256M` (ABL `max-download-size` is ~768 MiB). Do **not** use Google platform-tools 37 `fastboot`.

USB gadget `0525:a4a7` must stay up **>30 s**. A bounce to rabbit `18d1:d00d` in ~6 s is usually empty DTBO.

## After boot

| Path | How |
|------|-----|
| Desktop | GNOME autologin as `dagu` |
| USB serial | `python3 linux-mainline/scripts/dagu-console.py` |
| Serial login | `root` / `dagu` (prebuilt) |
| Wi-Fi SSH | same password after the tablet joins a network |

First boot grows the 8 GiB image across userdata (~228 GiB). Speakers and the built-in mic (WCD9385 AMIC5) are in UCM. Then:

```bash
passwd
sudo passwd root
```

## Build it yourself

Needs staged firmware (`./linux-mainline/scripts/stage-firmware.sh`; blobs are not in git), host `qemu-user`, and a long qemu apt for GNOME.

### Desktop (same path as the prebuilt)

```bash
./linux-mainline/scripts/setup-deps.sh
./linux-mainline/scripts/stage-firmware.sh

ROOT_PASSWORD='your-secret' ./linux-mainline/scripts/build-rootfs-desktop.sh
# writes linux-mainline/out/rootfs-desktop.ext4 and .zst

./linux-mainline/scripts/flash-rootfs.sh
./linux-mainline/scripts/flash-boot.sh flash-b
```

`build-rootfs-desktop.sh` does Ubuntu 26.04 minbase → `rootfs-desktop-setup.sh` (GNOME, GDM, ALSA UCM, tablet session) → 8 GiB hole-free ext4 (so sparse flash cannot skip the journal) → zstd. Do **not** commit `ROOT_PASSWORD` or `out/root-password`. Public images keep `SKIP_HOST_SSH_KEY=1` (the script default).

### Console only (no GNOME)

```bash
ROOT_PASSWORD='your-secret' ./linux-mainline/scripts/build-rootfs.sh
./linux-mainline/scripts/build-rootfs-image.sh
IMG=linux-mainline/out/rootfs.ext4 ./linux-mainline/scripts/flash-rootfs.sh
```

Default `SUITE=noble`. The desktop prebuilt is `resolute` (26.04) so Mesa / mutter match the board contract.

## Do not

- Flash rootfs to `boot` / `super` / slot A
- Use Google `fastboot` 37 for a 4–8 GiB userdata image (AMD hosts stall in `USBDEVFS_REAPURB`; also exceeds the 768 MiB download cap)
- Re-flash userdata after Ubuntu is already there (wipes packages you installed)
- Put passwords, `id_dagu`, or persist MACs in a public image
- `fastboot reboot` into stock Android `boot` after userdata is Ubuntu (it cannot mount ext4). Run `flash-boot.sh flash-b` first
