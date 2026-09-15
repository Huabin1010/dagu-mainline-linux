# dagu 串口 / 原理图搜索备忘（Windows 用）

> 设备：小米 Pad 5 Pro **12.4"** · 代号 **dagu** · 型号 **22081281AC** · SoC **SM8250-AC（骁龙 870）**  
> 用途：在原理图 / BoardView（ZXW 等）里找 **调试 UART 焊点**  
> 仓库路径：`docs/dagu-uart-schematic-search.md`

---

## 1. 软件已确认的串口（优先找这个）

| 项目 | 值 |
|------|-----|
| 控制器 | **UART12** / **QUP12** / `qup_uart@a90000` |
| TX | **GPIO 34**（`qup12`） |
| RX | **GPIO 35**（`qup12`） |
| 电平 | **1.8V**（勿直接接 3.3V USB 转串口） |
| 波特率 | **115200 8N1** |
| 内核 | `console=ttyMSM0,115200n8` |
| 主线 7.0 | 已开 `CONFIG_SERIAL_QCOM_GENI_CONSOLE` |

**接线（USB 转串口）：**

- 平板 TX（GPIO34）→ 转串口 **RX**
- 平板 RX（GPIO35）→ 转串口 **TX**
- **GND ↔ GND**（必须共地）

---

## 2. 原理图 / 点位图里先搜这些（复制到搜索框）

### 最优先

```
GPIO34
GPIO35
GPIO_34
GPIO_35
TLMM_GPIO34
TLMM_GPIO35
qup12
QUP12
UART12
uart12
a90000
```

### 图纸常见别名

```
AP_UART_TX
AP_UART_RX
DEBUG_UART
CONSOLE_UART
MSM_UART
GENI_UART
QUP_UART12_TX
QUP_UART12_RX
```

### 找测试点 / 飞线位

```
DEBUG
UART
TEST
TP_
CON
```

### 中文关键词

```
GPIO34 GPIO35 串口
QUP12 调试串口
UART12 测试点
DEBUG UART
AP_UART 34 35
小米平板5 Pro 12.4 串口
dagu 22081281 UART
```

---

## 3. 备选路径（未完全证实，次要）

Type-C SBU 相关（厂商 pinctrl 里有，dagu 是否引出未知）：

```
sbu_uart
SBU_UART
GPIO23
sbu_uart_en
sbu_uart_en_ctrl
```

---

## 4. 不要搜错

| 不是这个 | 说明 |
|----------|------|
| 蓝牙 `ttyHS0` | UART `@998000`，不是 kernel console |
| `@988000` | 键盘 I2C 共用 QUP，已 disabled |
| **9008 短接点** | EDL 救砖用，**不是** 打印 log 的 UART |
| PS5169 / USB3 | 和调试串口无关 |
| **11 寸 elish** 图纸 | 板型不同，GPIO 可能不一致 |

---

## 5. 在图纸上怎么找（步骤）

1. 原理图搜 **GPIO34 / GPIO35** 或 **UART12 / QUP12**
2. 看网络连到：**测试点 TP**、**0Ω 电阻 R**、**未贴焊盘 NC**、**排针/夹具座**
3. 点位图点同一网络，找主板物理位置
4. 确认旁边有 **GND** 测试点
5. 若经过电平芯片，搜网络名或芯片位号（常见 1.8V ↔ 3.3V 转换）

---

## 6. 焊好后怎么测（Windows）

1. 用 **支持 1.8V** 的 USB 转串口（或电平转换板）
2. 设备管理器里看 COM 口（如 `COM3`）
3. 串口工具：**PuTTY** / **MobaXterm** / **sscom**
   - 波特率：**115200**
   - 数据位 8，无校验，停止位 1
4. 刷 **主线 7.0** `boot-dagu-legacy.img`（B 槽），上电看是否有内核输出  
   - 量产 HyperOS 4.19 **默认没有** console UART 驱动，可能无输出

---

## 7. 本机相关文件（同一仓库）

| 文件 | 内容 |
|------|------|
| `devices/dagu-hyperos-os2/04-uart.md` | 串口软件侧记录 |
| `linux-mainline/dts/sm8250-xiaomi-dagu.dts` | 主线设备树 |
| `docs/hardware-inventory.md` | 硬件清单 |
| https://github.com/MiCode/kernel_devicetree/tree/dagu-s-oss | 小米开源设备树 |

---

## 8. 搜到后可填（自己记笔记）

| 项目 | 你图上的名字 |
|------|----------------|
| GPIO34 网络名 | |
| GPIO35 网络名 | |
| GND 测试点 | |
| 是否经过电平芯片 | |
| 推荐焊接位置（位号） | |

---

*最后更新：2026-09-02 · 与仓库 bring-up 状态一致*
