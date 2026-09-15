# dagu 调试 UART 硬件飞线指南

> 设备：小米 Pad 5 Pro **12.4"** · 代号 **dagu** · 型号 **22081281AC** · SoC **SM8250-AC（骁龙 870）**  
> 图纸：蓝锐图纸 · **原理图 L81A** / **位号图 L81A**（`小米平板5Pro-12-4-351L81AMQ`）  
> 状态：**原理图 + 位号图均已核对**（2026-09-02）

本文档记录从原理图到位号图确认的 **AP 调试串口焊点**，用于飞线接 USB-TTL 抓取内核 / UEFI 日志。

---

## 1. 一句话结论

| 焊哪里 | 信号 | 接 USB-TTL |
|--------|------|------------|
| **TP7308** | 平板 TX（DEBUG_UART_TX / GPIO34） | **RX** |
| **TP7307** | 平板 RX（DEBUG_UART_RX / GPIO35） | **TX** |
| **GND**（同区域 TP 或 USB 口壳） | 地 | **GND** |

- 电平：**1.8V**（禁止直连 3.3V 模块）
- 波特率：**115200 8N1**

---

## 2. 信号链路（原理图已确认）

```
SM8250 (U3100)
  GPIO_34 (Ball E36) ── DEBUG_UART_TX ── R7303 (1kΩ) ── TP7308
  GPIO_35 (Ball F36) ── DEBUG_UART_RX ── R7304 (1kΩ) ── TP7307
```

### 2.1 软件对应关系

| 层级 | 值 |
|------|-----|
| 控制器 | UART12 / QUP12 / `qup_uart@a90000` |
| TX 引脚 | GPIO 34 |
| RX 引脚 | GPIO 35 |
| 内核 console | `console=ttyMSM0,115200n8` |
| 主线 7.0 | `CONFIG_SERIAL_QCOM_GENI_CONSOLE` 已开 |

> 仓库 `tools/test/uart_expectations.py` 中的 `qup_uart@988000`（GPIO117/118）是 **UEFI 固件构建配置**，与本板飞线焊点无关。

### 2.2 可选：Type-C SBU 复用

| 位号 | 说明 |
|------|------|
| GPIO_23 | `SBU_UART_EN` |
| S7301 | WAS3157 模拟开关，标 **NM**（可能未贴） |
| 飞线影响 | S7301 未贴时 DEBUG_UART 直连测试点，**不影响焊 TP7307/7308** |

---

## 3. 位号图物理位置（已确认）

在位号图 L81A 搜索 `TP7307`、`TP7308` 可跳转。两测试点位于 **U73xx 调试 UART 区域**。

### 3.1 TP7308（TX，优先焊这里）

- 网络：`DEBUG_UART_TX`
- 串阻：**R7303**（1kΩ）在信号路径上
- 地标：靠近 **LCN 1A** 排线座一侧；同区可见 **TP7318**、**U5800** / **U5904**

### 3.2 TP7307（RX，优先焊这里）

- 网络：`DEBUG_UART_RX`
- 串阻：**R7304**（1kΩ）在 TP7307 **正上方**
- 地标：位于 **SH7305** 屏蔽罩下方、**U5600** 大芯片右上方
- 同排左侧可见 **R7303**（与 TP7308 同一水平排）

### 3.3 区域示意

```
        SH7305（屏蔽罩）
    … R7303 ── R7304 …
         │       │
      TP7308   TP7307   ← 焊这两个
              U5600（下方大芯片）
```

### 3.4 GND

同区域可尝试 **TP7302**、**TP7303**，或用万用表对 USB 口金属壳确认连通后作地线。必须 **共地** 才有输出。

---

## 4. 接线与工具

### 4.1 飞线

```
平板 TP7308  ──→  USB-TTL RX
平板 TP7307  ──→  USB-TTL TX
平板 GND     ──→  USB-TTL GND
```

**TX/RX 必须交叉。** 只接 TX+GND 看不到完整双向交互。

### 4.2 推荐工具

| 工具 | 说明 |
|------|------|
| USB-TTL | 支持 **1.8V** IO（如部分 FT232H / CP2102N 1.8V 版） |
| 电平转换 | 若只有 3.3V 模块，中间加 1.8V↔3.3V 转换 |
| 焊锡 / 漆包线 | 测试点较小，建议细线、少锡 |
| 万用表 | 焊前确认 TP 对 GND 非电源短路 |

### 4.3 备选焊点

若 TP 不好焊，可焊 **R7303 / R7304** 靠外侧焊盘（与 TP 同网络）。**优先仍推荐 TP7307 / TP7308**。

---

## 5. 上机测试（Windows）

1. 接好线，USB-TTL 插入 PC，设备管理器确认 **COM 口**
2. 打开 **PuTTY** / **MobaXterm** / **sscom**：**115200 8N1**
3. 刷入 **主线 7.0** `boot-dagu-legacy.img` 到 **B 槽** 后上电
4. 串口应出现内核启动 log

| 情况 | 说明 |
|------|------|
| 有 COM 无输出 | 可能仍在量产系统（HyperOS 4.19 默认无 console UART） |
| 完全无 COM | 检查驱动、线序、共地 |
| 乱码 | 检查波特率 115200、电平是否 1.8V |

---

## 6. 常见误认（勿焊）

以下位号在位号图搜索时容易误点，**均不是 AP 调试串口**：

| 位号 / 区域 | 实际功能 |
|-------------|----------|
| **U7208 GP0/GP1**、R72xx | 无线充电芯片 RA9530 |
| **HST_WLAN_UART_TX/RX**、U2400 | WiFi QCA6391 通信 UART |
| **HST_BT_UART_*** | 蓝牙 UART |
| **R5604**、U5600 电源区 R56xx | 电源管理，非串口 |
| **TP1311**、JLCW1A 附近 | 摄像头相关 |
| **R6000**、J6900 LCM 附近 | 屏幕接口区域 |
| **9008 短接点** | EDL 救砖，不输出 log |
| **11 寸 elish** 图纸 | 板型不同，GPIO 不一致 |

---

## 7. 蓝锐图纸查找流程

```
1. 打开「原理图 L81A」
2. 搜索 GPIO34 或 GPIO35
3. 确认网络名 DEBUG_UART_TX / DEBUG_UART_RX
4. 跟线到 R7303/R7304 → TP7308/TP7307
5. 双击网络或 TP → 跳转「位号图」看物理位置
6. 焊接 TP7308（TX）、TP7307（RX）
```

**不要**只在位号图搜 `TX`/`RX`（会命中 WiFi 射频、WLAN UART 等）；**不要**只看阻值图而缺原理图。

### 原理图搜索关键词

```
GPIO34
GPIO35
DEBUG_UART_TX
DEBUG_UART_RX
TP7307
TP7308
```

---

## 8. 硬件记录表

| 项目 | 值 |
|------|-----|
| GPIO34 网络名 | DEBUG_UART_TX |
| GPIO35 网络名 | DEBUG_UART_RX |
| SoC Ball | E36 / F36 |
| 串阻 | R7303 / R7304（1kΩ） |
| 推荐焊点 | **TP7308**（TX）、**TP7307**（RX） |
| 电平转换 | 无（1.8V 直连 + ESD） |
| SBU 复用 | S7301（NM），GPIO23 = SBU_UART_EN |
| 图纸包 | 蓝锐 L81A 原理图 + 位号图 |
| 确认日期 | 2026-09-02 |

---

## 9. 相关文档

| 文件 | 内容 |
|------|------|
| `docs/dagu-uart-schematic-search.md` | 原理图搜索关键词速查 |
| `docs/hardware-debug-workflow.md` | 无 UART 时用屏幕 + USB 调试 |
| `tools/test/uart_expectations.py` | TestLab / UEFI UART 构建预期 |
| [MiCode dagu 设备树](https://github.com/MiCode/kernel_devicetree/tree/dagu-s-oss) | 软件侧 pinctrl / serial 节点 |

---

*最后更新：2026-09-02*
