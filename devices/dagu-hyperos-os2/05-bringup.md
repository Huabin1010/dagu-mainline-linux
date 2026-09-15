# 主线 7.0 做到哪

P0 目标：ramdisk + USB RNDIS `192.168.7.2` + dropbear。屏 / fbcon 不做。

## 已证明

- 主机刷写走 `linux-mainline/scripts/fb-usb.py`（不要 Google fastboot 37）
- ABL **会跳** 7.0 Image（USB 掉线后不是 6 秒回 fastboot）
- stub DTBO + 主线 DTB `-@`：能 apply idx=15 并 jump
- `flash-boot.sh restore` 能回 HyperOS

## 当前墙

jump 之后主机 **无** `1d6b:0104`。Logo 冻 + USB 全黑。分不清 PID1 没到 vs 无 UDC（无串口）。

## 不要再做

空 DTBO、双槽都写成 7.0（救砖差）、为启动刷 rootfs/super、elish CPHY、`qcom,snps-dwc3` combined。

## 下一轮（未做）

1. `flash-boot.sh` 只写 **B** + `set-active b`，A 留本机 HyperOS  
2. 用 USB 时间判断：6s=ABL 没跳；掉回安卓=B 没站住；Logo+USB 黑=核在跑无 UDC；`1d6b:0104`=P0 过
