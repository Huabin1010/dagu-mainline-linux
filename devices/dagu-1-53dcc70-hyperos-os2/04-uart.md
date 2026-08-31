# 串口

## 软件侧（活机 FDT + 2026-08-31 adb su）

| 项 | 值 |
|----|-----|
| 控制器 | `qcom,qup_uart@a90000`（主线 uart12） |
| 脚 | GPIO **34 TX / 35 RX**，`function = qup12` |
| 电平 / 波特率 | **1.8V**，cmdline `console=ttyMSM0,115200n8` |
| DT 节点 | `status=ok`，compatible `qcom,msm-geni-console` |
| 量产核 | **没有** `ttyMSM` 驱动；`/proc/tty/drivers` 只有 `msm_geni_serial_hs`（`ttyHS0`=蓝牙 `@998000`） |

不要用 `@988000`（和键盘 I2C 同 QUP，disabled）。  
`sbu_uart_en_ctrl`（GPIO 23）在厂商 pinctrl 里，Type-C SBU 串口 **未证实**。

## 焊点图

网上没有 dagu 公开 UART pad 图。有的是 **EDL 9008 短接图**，不是串口。

## 7.0 调试

没有逐行 dmesg。用主机 USB 时序 + 只刷 B 槽（A 留 HyperOS）当检查点。pstore：量产 reserved-memory **没有 ramoops**，回安卓捞不到 7.0 的 kmsg。
