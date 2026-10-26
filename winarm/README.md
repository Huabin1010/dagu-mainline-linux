# winarm — Windows on ARM firmware for dagu (SM8250)

Device port of the working `xiaomi-pipa` (Xiaomi Pad 6, same SM8250 SoC) UEFI
target in [Project-Aloha/mu_aloha_platforms](https://github.com/Project-Aloha/mu_aloha_platforms)
(KonaPkg) to dagu (Xiaomi Pad 5 Pro 12.4).

```bash
./build-dagu-uefi.sh      # -> out/xiaomi-dagu-uefi-debug.img
```

- `overlay/xiaomi-dagu/` — the dagu-specific files (tracked): panel geometry,
  memory map with PStore serial carveout, generic-kona DTB.
- `docker/Dockerfile.mu` + `mu-run.sh` — Ubuntu 24.04 Mu build container
  (`nuget.exe` via mono; Tsinghua mirror).
- Upstream clone (`mu_aloha_platforms/`) and extracted stock firmware
  (`UEFIFirmwareBackup/`) are git-ignored and re-fetched by the build script.

Flash/boot/log loop and the honest status/ceiling:
[`../docs/woa-dagu-kona-port.md`](../docs/woa-dagu-kona-port.md).
Bring-up tooling: [`../tools/winarm/dagu-uefi-loop.sh`](../tools/winarm/dagu-uefi-loop.sh).

**Not booted on hardware yet. Windows does not run on dagu at this point.**
