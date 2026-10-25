# dagu 蓝牙配对修复记录（2026-10）

记录日期：**2026-10-26**。内核 `#654`（slot B），BlueZ `5.85-4ubuntu0.4+dagu1`，GNOME Settings 50。  
设备：Logitech K380（经典 BR/EDR HID，传统 PIN 配对）、BT5.0 Mouse（BLE HOG，每次进配对模式换一个 `23:15:1D:17:xx:xx` 地址）。  
目标：和安卓一样，在 GNOME 设置里点一下就配上、立刻能用；不靠改 BlueZ 策略、不靠后台脚本。  
相关文档：`dagu-adaptation-status.md`（总表）、`dagu-mainline-adaptation-handbook.md` §17。

---

## 1. 结论

| 问题 | 根因 | 修法 | 位置 |
|---|---|---|---|
| K380 配对一直转圈，最后 Not Set up | QCA6390 的 RF 天线开关电源 VDD_ASD（PM8150 L16）主线从没打开，射频收不到对端 | DT 加 `vreg_l16a_3p0` 和 `vddasd-supply`；QCA6390 电源时序申请 `vddasd`；S5A 按原厂改 2.0 V | `dts/sm8250-xiaomi-dagu.dts`，`apply-overlays.sh` → `pwrseq-qcom-wcn.c` |
| 设置里一个设备都扫不出来 | MGMT Stop Discovery 先入队、后写 `STOPPING`。工作 56 µs 就做完并写了 `STOPPED`，又被调用方的 `STOPPING` 盖掉，之后每次 Start Discovery 都回 Busy | 入队前写状态，入队失败恢复 | `apply-overlays.sh` → `net/bluetooth/mgmt.c` |
| BT5.0 鼠标首配不连，要动一下鼠标才连上 | BlueZ 在 SMP 密钥分发结束前就发 ATT Exchange MTU，这只鼠标丢掉不回，等 30 s ATT 超时 | 自己发起 LE 绑定时，GATT client 等绑定完成再起 | `patches/bluez-5.85-gatt-after-bonding.patch`，`scripts/dagu-build-bluez.sh` |

验收（同一块板、同一位置）：

| 测试 | 修前 | 修后 |
|---|---|---|
| 平板寻呼主机 PC 蓝牙 10 次（`scripts/dagu-bt-page-loop.sh`） | 0/10，全部 Page Timeout | 9/10，中位 0.9 s |
| 平板 inquiry 能否收到 PC | 一次都没有 | 能，−60 dBm |
| GNOME 设置配 K380 | 转圈 20 s 后 Not Set up | 弹出 PIN，键盘输入后连上 |
| GNOME 设置配 BT5.0 Mouse（不碰鼠标） | 31 s 后失败，动鼠标才连 | 点完直接连上，指针可用 |

修完以后，之前堆的蓝牙改动全部撤掉了：内核 `net/bluetooth`、`drivers/bluetooth` 回到 v7.0 原版（只留 mgmt 这一处修复）；BlueZ 用打包默认的 `main.conf` / `input.conf`；`libgnome-bluetooth` 回到 Ubuntu 原版；GNOME Shell 的蓝牙 overlay、`dagu-bt-hid-host` 服务/定时器/udev 规则都删掉了。

---

## 2. 先把旧补丁撤掉

开始时仓库里有约 1600 行蓝牙内核补丁（inquiry/page 分时、改 LE 连接参数、改 sniff、交错 page scan、clock offset 缓存……），BlueZ 打了 5 个补丁，gnome-bluetooth 打了 1 个，还有一个开机后反复改 pairable / page scan / Trusted 的服务。K380 照样转圈，鼠标照样慢。

每一个补丁都在绕某个现象，但没人回答"为什么安卓上同一颗芯片不用这些"。所以第一步是全撤掉，看原版栈到底坏在哪：

1. 内核 `net/bluetooth`、`drivers/bluetooth`、`include/net/bluetooth` 恢复 v7.0（`#650`）。
2. 平板上 BlueZ、`libgnome-bluetooth` 重装 Ubuntu 官方包，配置删掉让包恢复默认。
3. `btmon -w` 一直录，`bluetoothd` 用 `SIGUSR2` 打开调试日志。

原版栈上 `l2ping` K380 能通，inquiry 也能看到 K380 和鼠标。所以协议栈默认值本身不是问题。

## 3. K380：射频收不到

### 3.1 看见什么

btmon 里 K380 的配对：

```
Create Connection → Connect Complete      (4.2 s，链路建起来了)
IO Capability Response: KeyboardOnly       (应该进入 Passkey Entry)
Connection Packet Type Changed             (+1.3 s，之后对端再无任何包)
Simple Pairing Complete: Connection Timeout (0x08)   (+20 s，监督超时)
```

这段时间没有 LE 扫描、没有 inquiry，平板这边电台是空闲的。链路建起来后对端就"听不见了"，是射频问题，不是调度问题。

### 3.2 为什么

对照安卓 DT（`vendor/android-dagu/.../xiaomi-sm8250-common.dtsi`）：

```
qca,bt-vdd-asd-supply = <&pm8150_l16>;
qca,bt-vdd-asd-voltage-level = <3024000 3304000>;
```

`dagu-sm8250.dtsi` 还把 `qca,bt-vdd-rfa1` 改成 `pm8150_s5` 2.0 V。主线 `sm8250-xiaomi-elish-common.dtsi` 写的是 "L15 & L16 are unused"，`pwrseq-qcom-wcn.c` 的 QCA6390 电源表里也没有 `vddasd`（binding 里有，WCN6750 在用）。所以在 Linux 下 L16 从来没被打开，天线开关没电。

### 3.3 什么证明因没了

用主机 PC 的蓝牙当对端，同一位置做 A/B/A：

| 内核 | L16 | 寻呼成功 | 平板 inquiry 看到 PC |
|---|---|---|---|
| `#651` | 开 | 9/10，中位 0.9 s | 能，−60 dBm |
| `#652` | 关（只去掉 `vddasd-supply`） | 0/10 | 一次都没有 |
| `#653` | 开 | 3/4，中位 0.9 s | 能 |

只差这一路电，结果从 0 变成正常。K380 之后在 GNOME 设置里正常弹 PIN、配对、连上。

## 4. 扫不出设备：mgmt 状态竞争

### 4.1 看见什么

GNOME 每 10 秒调一次 `StartDiscovery`，内核每次回 `Busy (0x0a)`，抓包里没有一条广播。用 kprobe 读活的 `hdev->discovery.state`（偏移来自 `pahole`）：值是 4，`DISCOVERY_STOPPING`。

再往前看：上一次 `Stop Discovery` 的 Command Complete 在命令发出后 **56 µs** 就回来了，中间没有任何 HCI 命令，紧跟着有 `Discovering: Disabled` 事件（只有切到 `STOPPED` 时才发）。

### 4.2 为什么

上游 `mgmt.c`：

```c
err = hci_cmd_sync_queue(hdev, stop_discovery_sync, cmd, stop_discovery_complete);
...
hci_discovery_set_state(hdev, DISCOVERY_STOPPING);
```

cmd_sync 工作不拿 `hdev->lock`。当时 LE 扫描和 inquiry 都没在跑，`hci_stop_discovery_sync()` 什么都不用发，在另一个 CPU 上（或抢占调用方）直接做完：回 Success、写 `STOPPED`。然后调用方才执行下一行，把状态写成 `STOPPING`。除了 `stop_discovery()` 和挂起路径，没有别的代码写 `STOPPING`，也没有代码再把它改回去。`start_discovery` 和 `start_service_discovery` 的 `STARTING` 也是同样的先入队后写。

### 4.3 修法

入队前写状态，入队失败再恢复（`STARTING` 失败回 `STOPPED`，`STOPPING` 失败回原值）。bluetooth-next 的 `mgmt.c` 到 2026-10-26 仍是旧顺序。

注意：这次卡死之前，内核已经处在"状态是 FINDING、实际没有扫描"的情况里 47 s，那是 Stop 能走到 56 µs 快路径的前提。这个前提是怎么来的这一轮没复现出来；`scripts/dagu-bt-disc-trace.sh` 的 kprobe（状态切换、关 LE 扫描、inquiry 结束，带调用栈）可以再抓。

## 5. 鼠标：ATT 发早了

### 5.1 看见什么

第一次配对（相对点击时刻）：

| 时间 | 事件 |
|---|---|
| +0.01 s | LE Enhanced Connection Complete |
| +0.4 s | SMP Pairing Request / Response / Confirm / Random，`LE Start Encryption` |
| **+0.86 s** | `Encryption Change`，同一毫秒发出 `ATT: Exchange MTU Request` |
| +0.89 s | Number of Completed Packets：链路层已经确认送达 |
| +0.93 / +0.97 s | 鼠标发 `Encryption Information`、`Central Identification`，绑定成功 |
| +1.0 s | 鼠标要 8.75 ms / latency 32，更新成功 |
| 30 s 内 | 鼠标再没回任何 ATT |
| +30.9 s | `att.c:timeout_cb()`，GATT 失败，Pair 返回，断开 |

动一下鼠标后它回连（已绑定，没有密钥分发）：`Encryption Change` → `Exchange MTU Request` → **50 ms** 后 `Exchange MTU Response`，接着服务发现、HOG、`/dev/input` 都正常。连接参数更新在成功和失败的几次里都有，不是区别所在。

### 5.2 为什么

BlueZ 收到 ATT 连接时（Pairing Request 那一刻）就 `gatt_client_init()`，看到 `device->bonding` 就把 ATT 安全级别提到 medium。内核在加密完成时放行排队的 ATT，比密钥分发结束早约 110 ms。这只鼠标的固件在分发密钥时收到的 ATT 请求直接丢掉，ATT 又不重传，只能等 30 s 超时。

安卓的顺序是：绑定完成（`BOND_BONDED`）之后 HID Host 才开始 GATT 发现，所以第一个 ATT 请求总在密钥分发之后。

### 5.3 修法

`patches/bluez-5.85-gatt-after-bonding.patch`：

- `device_attach_att()`：我们自己发起的 LE 绑定还没完成（`dev->bonding`，非 BR/EDR，安全级别低于 medium）时，不起 GATT client，记 `gatt_client_deferred`。
- `device_bonding_complete()`：不论成功失败，先把被推迟的 GATT client 起来。成功时后面的 `device_browse_gatt()` 会等它 ready 再回 Pair。
- ATT 断开时清掉这个标记。

对端主动配对、已绑定设备回连、BR/EDR 都不受影响。

### 5.4 打包

`scripts/dagu-build-bluez.sh` 在平板上 `apt-get source bluez`，把 `patches/bluez-*.patch` 放进 `debian/patches`，版本号加 `+dagu1`，`dpkg-buildpackage` 后装 `bluez`、`libbluetooth3`、`bluez-obexd` 并 hold。镜像构建由 `dagu-repack-pinned.sh` 从平板 repack 进 `out/dagu-pinned`。

这个 libcups2-dev 报的 `cups_serverbin` 是 `/usr/lib/cups`，Ubuntu 的 `bluez-cups.install` 要的是 multiarch 路径，脚本在 `debian/rules` 里补了一个 `execute_after_dh_auto_install` 搬过去。

## 6. 撤掉的东西

| 撤掉 | 当初为什么加 | 现在 |
|---|---|---|
| 内核约 1600 行蓝牙补丁（LE/inquiry 分时、LE 参数夹紧、HID sniff、交错 page scan、clock offset 缓存、ACL 清理……） | 绕开射频听不见带来的各种超时 | 恢复 v7.0；VDD_ASD 有电后原版行为正常 |
| `hci_qca.c` 去掉 `SIMULTANEOUS_DISCOVERY`、加 `BROKEN_LE_CODED` | 同上 | 恢复上游 |
| BlueZ 5 个补丁（等对端寻呼、LE 重连、扫描暂停、ATT 重传、保留行） | 同上；ATT 重传不合规范 | 换成第 5 节这一个 |
| gnome-bluetooth 补丁（AlreadyExists 当成功、Connect 重试 25 s） | Pair 超时后的界面问题 | 恢复 Ubuntu 原版 |
| `main.conf` / `input.conf` 定制（`ClassicBondedOnly=false`、sniff 6–18、`PageTimeout`、`AlwaysPairable`……） | 同上 | 打包默认值；K380 原版配置下正常 |
| `dagu-bt-hid-host` 服务、定时器、udev 规则 | 开机后反复改 connectable / bondable / Trusted | 删除 |
| GNOME Shell 蓝牙 overlay（20 s 后取消 Connect） | Connect 长时间不返回 | 删除；Connect 自己会返回（睡着的 K380 约 5 s，不广播的 LE 设备 30 s） |

## 7. 教训

- **先撤掉补丁再查。** 一层层绕现象的补丁把真问题盖住了。撤干净以后，第一份原版抓包就指向了射频。
- **对照原厂 DT 的电源。** 主线 board 文件写 "unused" 的稳压器，不代表这块板没用。安卓 DT 里每一路 `-supply` 都要对一遍。
- **用对端做 A/B。** 主机 PC 的蓝牙是可控的对端：寻呼成功率、inquiry RSSI 能在几分钟内给出 0/10 对 9/10 这样的结论，比在 GNOME 里点来点去可靠。
- **读活的内核状态。** 没开 FUNCTION_TRACER 时 bpftrace 用不了，但 `kprobe_events` 加 `pahole` 偏移可以直接读 `hdev->discovery.state`。
- **看顺序，不只看结果。** 鼠标失败和成功的唯一区别是 ATT 请求落在密钥分发之前还是之后，这要把两次抓包逐包对齐才看得出来。
