# 小米平板5 Pro 12.4 (dagu) Bootloader 解锁指南

> 适用设备：**dagu / 22081281AC / 国行 HyperOS**（如 `OS2.0.10.0.ULZCNXM`）  
> 当前设备状态（采集时）：Bootloader **locked**，`sys.oem_unlock_allowed=1`

本仓库已下载工具至 `tools/downloads/`，解压后可用。

---

## ⚠️ 解锁前必读

| 风险 | 说明 |
|------|------|
| **数据清空** | 解锁过程会恢复出厂，**所有数据丢失** |
| **保修失效** | 官方保修通常终止 |
| **安全下降** | 指纹、查找设备等依赖 BL 锁的功能变弱 |
| **账号限制** | 国行账号每年解锁设备数有限制 |
| **WoA 前置** | 本项目需要 unlocked BL 才能 `fastboot boot` UEFI |

**解锁前请完整备份照片、文件、分区表信息**（见 [hardware-debug-workflow.md](hardware-debug-workflow.md)）。

---

## 一、国行 HyperOS 2 解锁流程概览

你的平板是 **国行版 (ULZCNXM)**，不能只用 PC 工具直接解，需先获得 **解锁资格**：

```
1. 小米社区 App → 申请解锁资格（答题 + 等级 + 审核）
2. 平板 → 开发者选项 → 绑定账号和设备（需移动数据）
3. 等待 168 小时（7 天，以页面提示为准）
4. PC → Mi Unlock 工具 → Fastboot 模式 → 点击解锁
5. fastboot getvar unlocked 验证
```

> 国行与全球版规则不同：**国行设备需国区小米账号**，且 2025 年起社区审核更严（等级 5 段、答题、14 天有效期内完成绑定+解锁）。  
> 参考：[Uotan Wiki — 解锁 Bootloader](https://wiki.uotan.cn/index.php?title=%E8%A7%A3%E9%94%81Bootloader) · [小米官方解锁页](https://www.miui.com/unlock/download.html)

---

## 二、平板端准备

### 2.1 登录小米账号

- 设置 → 小米账号，登录 **与 PC 解锁工具相同的账号**
- 国行机请使用 **中国区注册** 的小米账号

### 2.2 开启开发者选项

1. 设置 → **关于平板** → 连续点击 **HyperOS 版本** 7 次  
2. 提示「您已处于开发者模式」

### 2.3 开发者选项内开启

路径：**设置 → 更多设置 → 开发者选项**

| 选项 | 操作 |
|------|------|
| **USB 调试** | 开启 |
| **USB 调试（安全设置）** | 开启（如有） |
| **OEM 解锁** | 开启 |

### 2.4 申请解锁资格（国行 HyperOS 2）

1. 安装 **小米社区 App**（应用商店）
2. 完成 **实名认证**，社区等级达到 **5 段**
3. **我 → 内测中心 / 解锁资格申请 → 去答题**（必须在 App 内进入，勿用第三方入口）
4. 通过答题并等待审核（规则以 App 当前说明为准）
5. 审核通过后，在 **14 天有效期** 内完成绑定与解锁

> 答题题库变更记录：[Xiaomi-BootLoader-Questionnaire](https://github.com/MlgmXyysd/Xiaomi-BootLoader-Questionnaire)

### 2.5 绑定账号与设备

路径：**设置 → 更多设置 → 开发者选项 → 设备解锁状态**

1. 插入 **SIM 卡**，关闭 Wi-Fi，使用 **移动数据**（重要）
2. 点击 **绑定账号和设备**
3. 等待成功提示

若提示「请 XXX 小时后再试」→ 需等待 **168 小时（7 天）** 后再用 PC 解锁。

常见错误：
- 使用 Wi-Fi 绑定 → 失败，改移动数据
- 账号与设备地区不匹配 → 国行机用国区账号
- 「账号权限不足」→ 未完成社区申请或审核未过

---

## 三、PC 端工具（本仓库已下载）

### 3.1 目录结构

```
tools/
├── downloads/                          # 原始 zip
│   ├── miflash_unlock_7.6.727.43_cn.zip   ← 国行用这个
│   ├── miflash_unlock_en_7.6.727.43.zip
│   └── platform-tools-latest-windows.zip
├── mi-unlock-cn/                       # 已解压
│   ├── miflash_unlock.exe              # 解锁主程序
│   ├── MiUsbDriver.exe                 # USB 驱动
│   └── driver/                         # 驱动 INF
└── platform-tools/                     # adb / fastboot
    ├── adb.exe
    └── fastboot.exe
```

详见 [tools/downloads/README.md](../tools/downloads/README.md)

### 3.2 安装 USB 驱动

1. 运行 `tools\mi-unlock-cn\MiUsbDriver.exe`（或 `driver_install_64.exe`）
2. 按提示安装完成后 **重启 PC**

### 3.3 验证 adb / fastboot

```powershell
cd E:\Projects\xiaomi-pad870-win11-arm\tools\platform-tools
.\adb.exe devices
```

---

## 四、执行解锁

### 4.1 进入 Fastboot

**方法一（推荐）：** 关机 → 按住 **电源 + 音量下** → 出现兔子 Fastboot 界面  

**方法二：**

```powershell
.\adb.exe reboot bootloader
```

### 4.2 运行 Mi Unlock

1. 双击 `tools\mi-unlock-cn\miflash_unlock.exe`
2. 登录 **与平板相同** 的小米账号
3. USB 连接平板（建议 **USB 2.0 口**、原装线）
4. 工具显示 **已连接** 后，点击 **解锁**
5. 确认警告 → 等待进度完成 → 自动重启

### 4.3 验证

重启后进入 Fastboot 或系统，执行：

```powershell
cd E:\Projects\xiaomi-pad870-win11-arm\tools\platform-tools
.\fastboot.exe getvar unlocked
# 期望: unlocked: yes

.\fastboot.exe getvar product
# 期望: product: dagu
```

或在 adb 下：

```powershell
.\adb.exe shell getprop ro.secureboot.lockstate
# 期望: unlocked
```

---

## 五、解锁后：补采硬件信息

解锁完成后，请重新采集 Golden Baseline（可获取 iomem / DTB）：

```powershell
cd E:\Projects\xiaomi-pad870-win11-arm
.\tools\collect-hw-dump.ps1
adb reboot bootloader
.\tools\platform-tools\fastboot.exe getvar all > dumps\fastboot-getvar-all.txt
```

然后更新 [hardware-inventory.md](hardware-inventory.md)。

---

## 六、救砖与线刷（备用）

解锁失败或刷机变砖时：

| 工具 | 说明 |
|------|------|
| **Mi Flash** | 小米线刷工具（与 Mi Unlock 不同） |
| **dagu Fastboot ROM** | 国行稳定版，[MiFirm 搜索 dagu](https://mifirm.net/model/dagu.ttt) |
| **EDL 9008** | 深度刷机，需对应授权或短接 |

线刷注意：
- 刷机包扩展名 `.tgz`，需解压
- Mi Flash 选 **clean all**（全部清除），否则可能 **重新上锁**
- Bootloader **已解锁** 时可直接 Fastboot 刷；未解锁需 EDL

---

## 七、常见问题

| 现象 | 处理 |
|------|------|
| 工具找不到设备 | 重装 `MiUsbDriver.exe`；换 USB 2.0 口/数据线 |
| 请 168 小时后再解锁 | 绑定未满 7 天，继续等待 |
| 当前账号未绑定此设备 | 重新在「设备解锁状态」绑定 |
| 账号注册地与手机销售地不符 | 国行机必须用国区小米账号 |
| 解锁卡在 50% / 99% | 换 Intel PC、USB 2.0 口（社区经验） |
| 解锁后仍显示 locked | 确认用的是成功解锁的同一账号；重进 fastboot 查 `getvar unlocked` |

---

## 八、参考链接

- [小米解锁官方页（中文）](https://www.miui.com/unlock/download.html)
- [Mi Unlock 7.6.727.43 国行 CDN](https://cdn.cnbj1.fds.api.mi-img.com/flash-tool/miflash_unlock_7.6.727.43.zip)
- [Google platform-tools](https://developer.android.com/tools/releases/platform-tools)
- [Uotan Wiki — 小米解锁](https://wiki.uotan.cn/index.php?title=%E8%A7%A3%E9%94%81Bootloader)
- [erdilS — nabu WoA 解锁指南](https://github.com/erdilS/Port-Windows-11-Xiaomi-Pad-5/blob/main/guide/English/unlock-bootloader-en.md)（流程类似，SoC 不同）

---

**文档版本：** 2026-07
