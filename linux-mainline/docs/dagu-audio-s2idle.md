# dagu ADSP / SoundWire 与 S2Idle 探底

记录日期：**2026-09-12**（`#169`，uptime 约 1h24）。  
设备：小米平板 5 Pro 12.4（`dagu` / SM8250，`androidboot.serialno=<linux-serial>`）。  
相关总表：`linux-mainline/docs/dagu-adaptation-status.md`。

---

## 1. 音频（目标二）— 已在跑，不是 WSA 路线

这台板 **没有** WSA881x / WSA883x。外放是 **CS35L41 ×4**（i2c-gpio），耳机/ADC 是 **WCD9385**（SoundWire）。ADSP 早就拉起来了，不是这次才点的。

### 1.1 remoteproc / ADSP

| 项 | 值 |
|----|-----|
| 节点 | `/sys/class/remoteproc/remoteproc0` |
| `name` | `adsp` |
| `state` | **`running`** |
| `firmware` | `qcom/sm8250/xiaomi/dagu/adsp.mbn` |

`dmesg`：

```text
remoteproc remoteproc0: adsp is available
remoteproc remoteproc0: Booting fw image qcom/sm8250/xiaomi/dagu/adsp.mbn, size 8220
remoteproc remoteproc0: remote processor adsp is now up
PDR: Indication received from msm/adsp/audio_pd, state: 0x1fffffff
```

APR 服务 4:3 / 4:4 / 4:7 / 4:8 已加。DT `&adsp` 为 `okay`，`linux-mainline/dts/sm8250-xiaomi-dagu.dts`。  
`&cdsp` / `&slpi` **继续 disabled**。

### 1.2 SoundWire

`/sys/bus/soundwire/devices`：

| 设备 | 角色 |
|------|------|
| `sdw-master-2-0` | `soundwire@3210000`（`swr1` RX） |
| `sdw-master-3-0` | `soundwire@3230000`（`swr2` TX） |
| `sdw:2:0:0217:010d:00:4` | `wcd9385-rx@0,4`，驱动 `wcd9380-codec` |
| `sdw:3:0:0217:010d:00:3` | `wcd9385-tx@0,3`，驱动 `wcd9380-codec` |

```text
qcom-soundwire 3210000.soundwire: din-ports (0) mismatch with controller (1)
qcom-soundwire 3210000.soundwire: dout-ports (5) mismatch with controller (6)
qcom-soundwire 3230000.soundwire: din-ports (5) mismatch with controller (6)
qcom-soundwire 3230000.soundwire: dout-ports (0) mismatch with controller (1)
wcd938x_codec audio-codec: bound sdw:2:0:0217:010d:00:4
wcd938x_codec audio-codec: bound sdw:3:0:0217:010d:00:3
```

端口数 mismatch 是警告，**绑定成功**。`dmesg \| grep -i sdw` **不会**出现 WSA88xx。四颗 CS35L41 在 i2c 20/21，CAL_R 已写入（9497–9696）。

### 1.3 声卡 / 桌面 sink

```text
card 0: XiaomidaguCS35L [Xiaomi-dagu-CS35L41-WCD9385]
  device 0: MultiMedia1
  device 1: MultiMedia2
```

PipeWire 1.6.2：默认 sink 应是 `Speakers`（vol 1.00）。不是 Dummy。  
**2026-09-13：** 登录时若 `hw:0,0` 还不在，`pipewire.conf.d` 里的静态 sink 会让 PW 以 234 退出并被 socket 限频，整段会话无声。桌面恢复走 `linux-mainline/scripts/dagu-audio-up.sh`。  
UCM / 路由见 `linux-mainline/docs/dagu-adaptation-status.md`「扬声器」节。

任务书里的 `WSA881x` 扫线对本板不适用；WCD938x + CS35L41 + ADSP 这一套已经枚举并出声。

---

## 2. S2Idle（目标三）— 能进去，远程软件唤不醒

桌面安装脚本 **mask** 了 `sleep.target` / `suspend.target` / `hibernate.target`（`linux-mainline/scripts/rootfs-desktop-setup.sh`）。短按电源键走 Mutter `PowerSaveMode`，文档写过「禁止 suspend」（GPIO139 HWEN）。这次是 **sysfs 直写**，绕过 systemd。

### 2.1 正确入口（不要写 `/sys/power/mem`）

```text
/sys/power/state      = freeze mem disk
/sys/power/mem_sleep  = [s2idle]          # 只有这一种，没有 deep
```

`echo s2idle > /sys/power/mem` **不是**内核接口。应：

```bash
echo s2idle > /sys/power/mem_sleep   # 已是默认
echo mem > /sys/power/state          # 或 echo freeze
```

挂起前基线：`linux-mainline/out/display-stress/dagu-s2idle-pre.txt`。  
脚本：`linux-mainline/scripts/dagu-s2idle-probe.sh`。

| 项 | 挂起前 |
|----|--------|
| ADSP | `running` |
| Venus | `video14`/`video15`，三模块在 |
| 主 fb | `XR24` + `modifier=0x0500000000000001` |
| hangcheck recover | **0**（本 boot） |
| `suspend_stats` | success=0 fail=0 |
| `pwrkey` wakeup | **enabled** |
| RTC | **无** `/dev/rtc*`，`rtcwake` 用不了 |
| WoWLAN | disabled（挂起前没武装） |

### 2.2 实测

2026-09-12 17:25 对 root 执行延迟 `echo mem > /sys/power/state`。

| 观察 | 结果 |
|------|------|
| Wi‑Fi `192.168.7.2` | 立刻 **No route**（ath11k 进低功耗） |
| USB `0525:a4a7` | 主机仍枚举 Device 100（半活僵尸） |
| ACM 写数据 | 不唤醒 |
| `dagu-console.py --port /dev/ttyACM1` | **卡住**（gadget 不处理） |
| libusb open/reset | 无权限 / handle=NULL |
| systemd | 仍 masked，与本次无关 |

结论：**S2Idle 已经进去了**。无 RTC、未开 WoWLAN 时，远程 **没有**软件唤醒路径。USB gadget wakeup 虽已 `enabled`，ACM 流量唤不醒。只剩 PMIC **电源键**（`c440000.spmi:pmic@0:pon@800:pwrkey`）。

### 2.3 电源键唤醒（2026-09-12 18:30）

同一开机（uptime 连续，没有重进 ramdisk）。墙钟大约 **65.5 分钟**（`[5189.19] PM: suspend entry (s2idle)` → `[9117.63] PM: suspend exit`）。`echo mem` 的 rc=0。

后测：`linux-mainline/out/display-stress/dagu-s2idle-post.txt`。  
画面：`linux-mainline/out/display-stress/s2idle-resume.png`（GNOME 桌面 + 快速设置，Wi‑Fi 已连回 `CMC-2WFA-5G`，电量 57%，无花屏）。

| 项 | 唤醒后 |
|----|--------|
| `suspend_stats` | **success=1** fail=0，各 failed_* 全 0 |
| DPU 主 fb | 仍是 `XR24` + `modifier=0x0500000000000001`（`QCOM_COMPRESSED`） |
| hangcheck / `gpu fault` | **0**（本 boot 仍无 recover） |
| Venus | `/dev/video14` `/dev/video15` 还在；三模块还在；**无 SSR** |
| Venus 烟测 | `v4l2h264dec ! fakesink` 10s 片 `rc=0`，墙钟 1.24s |
| ADSP | 仍 `running` |
| `aplay -l` | card 0 仍在 |
| ath11k | resume 时 `mhi0` Power ON，固件重新起来，Wi‑Fi SSH 恢复 |

挂起瞬间的已知噪音（没挡住唤醒）：

```text
dwc3 a600000.usb: request ... was not queued to ep1in
dwc3-qcom-legacy a6f8800.usb: port-1 HS-PHY not in L2
wlp1s0: deauthenticating ... Reason: 3=DEAUTH_LEAVING
```

唤醒后 CS35L41 `POST_PMD: T{L,R,B}L/BR Main AMP event failed: -110`（和开机时 Enable timeout 同类），声卡节点还在。

救砖若变兔子：`linux-mainline/scripts/flash-boot-legacy.sh restore-a`。只动 B 槽。

### 2.4 下一步不要做的

- 不要为了 S2Idle 去开 `CONFIG_INTERCONNECT_QCOM_SM8250`
- 不要开 `&cdsp` / `&slpi`
- 不要在没 RTC / 没人按电源键时再远程 `echo mem`（会再次失联）
- 不要拉低 GPIO139 HWEN
