# dagu 主线固件暂存

blob **不进 git**。从本机 `dumps/` 解开：

```bash
./scripts/stage-firmware.sh
```

来源：`dumps/dagu-20260826-linux-bringup/wireless/`（蓝牙 TLV、QCA6390 BDF、persist MAC、CS35L41 wmfw、a650 zap）。

| Linux 路径 | 文件 |
|------------|------|
| `ath11k/QCA6390/hw2.0/board.bin` | dump `bd_l81a.elf`（不要 `board-2.bin`） |
| `ath11k/QCA6390/hw2.0/amss.bin` | `amss20.bin` |
| `qca/htbtfw20.tlv` | 蓝牙 |
| `qcom/sm8250/xiaomi/dagu/a650_zap.mbn` | 本机 Adreno650，不要 elish |
| `cirrus/` | CS35L41 wmfw / `TL-` `TR-` `BL-` `BR-` 校准 |
| persist MAC | 写进 gitignored `dts/local-addresses.dtsi`，不要把单机地址提交进 DTS |

`build-initramfs.sh` / `build-rootfs.sh` 会把 `firmware/dagu/lib/firmware` 拷进镜像。
