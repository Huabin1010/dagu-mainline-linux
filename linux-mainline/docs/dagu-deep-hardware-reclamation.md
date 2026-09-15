# dagu-deep-hardware-reclamation

记录日期：**2026-09-12**。  
代号：`dagu-deep-hardware-reclamation`。  
Linux 机：`androidboot.serialno=<linux-serial>`，槽 `_b`，SSH `ssh -i linux-mainline/out/id_dagu root@192.168.7.2`。可刷内核 / B 槽。  
安卓机：`<android-serial>`（HyperOS `OS2.0.10.0.ULZCNXM`）。**只提取，不刷机。** Magisk `su` 可读 tinymix / `/vendor/firmware`。

总表：`linux-mainline/docs/dagu-adaptation-status.md`。  
线性 GMEM 底稿：`linux-mainline/docs/dagu-a650-linear-destile.md`。

---

## 机器铁律

- 安卓 `<android-serial>`：`adb` / `dumpsys` / `tinymix` / 拷固件。禁止 `fastboot flash`、禁止改槽。
- Linux `<linux-serial>`：只刷 B。禁止 `DAGU_PRIMARY_ENTRY_PROBE=1`。救砖：`linux-mainline/scripts/flash-boot-legacy.sh restore-a`。
- 提取脚本：`linux-mainline/scripts/dagu-android-extract.sh`（写死校验 serial=`<android-serial>`）。

---

## 战役一：Chrome 动态花屏（同步 / 损伤）

### 安卓基线（`<android-serial>`，滚动后 `dumpsys SurfaceFlinger`）

落盘：`linux-mainline/out/android-extract/sf/sf_after_scroll.txt`。

| 项 | 安卓事实 |
|----|----------|
| 合成 | `usesDeviceComposition=true`，`usesClientComposition=false`，浏览器层 `hwc: composition=DEVICE` |
| BufferQueue | BLAST 三槽，`1600x2560`，`default-format=1`（`RGBA_8888`） |
| 活跃 buffer | `activeBuffer=[1600x2560:268437760,RGBA_8888]` |
| SurfaceDamageRegion | 停稳后 `count=0`（没有挂着未对齐的脏矩形） |
| override damage | `[0,0,-1,-1]`（invalid = 整层） |
| Fence | GLES 广告 `EGL_ANDROID_native_fence_sync` + `EGL_KHR_fence_sync`。这是 **SYNC_FD 隐式栅栏**，不是 Vulkan Semaphore |
| 面板 | 1600×2560 @ **120 Hz** |

结论：原厂滚动路径是 **HWC 直送 DPU + native fence**，不是 Mutter 那种「客户端 LINEAR 窗合成进 UBWC 主 fb」。安卓损伤矩形在停稳后是空的；要对照 Linux，必须看 **提交瞬间** 的 `dma_fence`，而不是停稳后的 damage。

### Linux 已做（不是软件 Bypass）

- 包装器打开 `WaylandLinuxDrmSyncobj`（有协议就走显式 timeline，没有就忽略）。PartialSwap 保持默认开：LINEAR destile 修好后不必再 `--disable-partial-swap`。GPU 进程拆出浏览器（不要 `--in-process-gpu`），栅格仍是 ANGLE GLES。
- 文件：
  - `linux-mainline/scripts/dagu-chrome.sh`
  - `linux-mainline/scripts/dagu-mineradio.sh`
  - `linux-mainline/scripts/rootfs-desktop-setup.sh`
- 探针：`linux-mainline/scripts/dagu-chrome-fence-probe.sh`（`--host` 拉回 `linux-mainline/out/display-stress/chrome-fence-*.txt`）
- 读 `/sys/kernel/debug/dma_buf/bufinfo`。主线 **没有** `/sys/kernel/debug/kgsl`。
- 2026-09-12 实机：Chrome 153 已带上 `PartialSwap` off + `WaylandLinuxDrmSyncobj`。`linux-mainline/out/display-stress/chrome-fence-20260912-185351.txt`：11 个 dma-buf 里 **9 个有 `write fence` 且已 signalled**，2 个 768 KiB 对象没有 write fence。不是「完全没锁」。主进程 fd=263。hangcheck 本 boot 仍是 1（空闲 gnome-shell 那次）。滚动时若出现未 signal 的 `write fence` 而花屏仍在，才是 DPU 没等这把锁。

### 右上角标签 / 小图标马赛克（2026-09-12）

不是 KMS 隐式同步，也不是损伤矩形。Skia/ANGLE 内部图集（R8 字形、≤1024² UI）被 `dagu-linear-mod.c` 和无差别 4bpp LINEAR 钩子误伤，A2D / 损坏 LINEAR 寻址打成 1-bit 砖。内部图集不过 DPU，必须保持 TILE/UBWC。

已改：

- `linux-mainline/scripts/dagu-linear-mod.c`：`GBM_FORMAT_R8` 不碰；`width<=1024 && height<=1024` 原样传递；只有窗口级 AR24/XR24（任一边 >1024）强制 LINEAR。`1819×89` 一类标签长条仍 LINEAR（Ozone 永远 `zwp_linux_buffer_params_v1.add(..., 0,0)`）。
- `/tmp/mesa-26.0.8/src/gallium/drivers/freedreno/freedreno_resource.c` `get_best_layout`、`a6xx/fd6_blitter.cc` `fd6_tile_mode`：4bpp 只在宽**和**高都 >1024 时强制 LINEAR。实机 `tile.log` 里的 `3840×360` 是 Skia 图集，单边超 1024 也必须放行。Wayland 长条靠 GBM 的 `PIPE_BIND_LINEAR`。补丁：`linux-mainline/patches/mesa-26.0.8-atlas-passthrough.patch`。
- 只装 `/usr/local/lib/dagu-mesa/` 与 `/usr/local/lib/libdagu-linear-mod.so`。不要进 gnome-shell。

验收走 `linux-mainline/scripts/dagu-gnome-screenshot.sh`（不要 mmap UBWC 主 fb）。

2026-09-12 复测：网页胶囊 4× 已是真字（`linux-mainline/out/display-stress/chrome-atlas4-pill-4x.png` 番剧/国创/电视剧）。**Chrome 工具栏 16–32px 图标仍是 1-bit 砖**（`chrome-atlas9-tb-4x.png`）。`DAGU_LINEAR_SYSMEM=1` 也救不了，不是小 FBO 的 GMEM store。把 ≤1024 一律逼 UBWC 会把 `832×576` 网页 tile 打绿（`chrome-atlas8-full.png`），已撤回。

2026-09-12 晚（icon 专项）：CPU `glTexSubImage` 写进 BO 的像素是**完好的**。证据：

- `linux-mainline/out/display-stress/dagu-icon-25x25-0.png` — 头像，锐利
- `linux-mainline/out/display-stress/dagu-icon-38x38-1.png` — 关闭叉，锐利
- `linux-mainline/out/display-stress/dagu-icon-20x20-11.png` — 刷新，锐利

这些在屏上也一直是好的。花的是 **Skia GPU raster** 画进 LINEAR 图集的矢量（页内 iconfont/SVG、部分标签标）。Mesa 侧改 GMEM/TILE/sysmem 都不改 首页 8× 砖纹。`--disable-gpu-rasterization` 后 CPU 栅格再 `glTexSubImage`，首页小电视 / 下载箭头 / 搜索镜锐利（`linux-mainline/out/display-stress/chrome-cpuras-shouye-8x.png`）。已写入 `linux-mainline/scripts/dagu-chrome.sh`。不要再：忽略所有 `PIPE_BIND_LINEAR`、≤1024 一律 UBWC、把 staging 也逼 TILE、用关 GPU 栅格修毛玻璃。

### 怎么判定

- `exclusive_unset` 很高、滚动仍花：隐式同步没挂上，DPU 扫到未完成的 LINEAR 窗。
- 全帧刷新后花屏消失、fence 却健全：脏矩形 / UBWC 合成错位，不是 Mesa 着色器。
- 标签中文 / 工具栏小图标是 1-bit 砖、大色块正常：图集被逼 LINEAR。
- **不要**再把 `CLUTTER_PAINT=disable-clipped-redraws` 塞进 gnome-shell（会拖死 Himax）。

---

## 战役二：Mineradio 延迟白屏

### `dagu-linear-mod.c` 泄漏

`linux-mainline/scripts/dagu-linear-mod.c` **有** `gbm_bo_destroy()` → 真 `gbm_bo_destroy`。没有「create 后扔掉指针」的路径。  
现加 `live_bos` / `created_bos` / `destroyed_bos`，写 `/tmp/dagu-linear-mod.log`。`live` 单调涨才是泄漏。

### 看门狗

`linux-mainline/scripts/dagu-mineradio-watch.sh`：每 5 s 记 pid / fd / RSS / hangcheck / `mem_info_vram_used`。  
主线没有 KGSL `proc/*/mem`。fd >900 或 dmesg `00800005` 打 WARN。

```bash
linux-mainline/scripts/dagu-mineradio-watch.sh --host
# 白屏后再
linux-mainline/scripts/dagu-mineradio-watch.sh --pull
```

白屏瞬间先看 `dmesg` 是否 `gpu fault status 00800005` + `hangcheck recover`。本 boot 空闲 gnome-shell 已出现过一次（约 171 s），Electron 若没处理 context loss 会只剩空 Wayland surface。

---

## 战役三：CS35L41（不是 WCD 漏音）

### 安卓 tinymix（Magisk root，空闲 / YouTube 未真正起播）

落盘：`linux-mainline/out/android-extract/audio/android_max_vol.txt`。  
卡名 `kona-mtp-snd-card`。四颗功放 **DSP Booted=On，Preload=On，Firmware=Protection**。

| 控件 | 安卓空闲 | Linux 实机 |
|------|----------|------------|
| `* PCM Source` | `None`（通路没开） | `DSP` |
| `* AMP PCM Gain` / `Analog PCM` | 18 | 18（18.50 dB） |
| `* Digital PCM Volume` / `Digital PCM` | 0（硬件 0 dB） | 817 / 913 = **0.00 dB** |
| `* DRE` | On | On |
| `* AMP Enable` | Off（没在播） | 播 440 Hz 时四颗 `Main AMP: On`，停完回到 Off |
| `* Fast Use Case Switch` | On + `*-music.txt` | **主线没有该控件** |
| `* ASPTX Ref` | 空闲 `None`；speaker path 里是 `Ref` | 无此名；等价 `ASP TX1=VMON` `TX2=IMON` |
| `CAL_R` / `CAL_STATUS` / `CAL_SET_STATUS` | 9497–9696 / 1 / **2** | 内核 preload 后写 CAL_R，**还没写 SET_STATUS=2** |

`POST_PMD ... -110` 是 **关掉** 功放时 `Enable(0)` 等 ASP 时钟超时，不是没上电。四颗芯片开机就 `Revision: B2`，DSP 载入的是小米 L81A `SPK_*_Music.bin`。`apply-overlays.sh` 已把 PUP 超时当成非致命。

speaker path（`linux-mainline/out/android-extract/audio/mixer_paths_overlay_static.xml`）：

```xml
TL/TR/BR/BL PCM Source = DSP
TL/TR/BR/BL ASPTX Ref = Ref
TERT_TDM_RX_0 = Two / S24_LE / 48 kHz
```

### 固件

安卓 `/vendor/firmware/*cs35l41*` 与 Linux `/lib/firmware/cirrus/` **md5 一致**（`linux-mainline/out/android-extract/fw/android.md5`）。不需要再拷一遍。  
`cirrus.cfg`：`firmware_Qfactor=8192.0`（`linux-mainline/out/android-extract/fw/cirrus.cfg`）。

`*-music.txt` 已在 `/lib/firmware/cirrus/`，哈希一致。主线没有 Fast Use Case mixer，这些 delta **现在不会自动灌进 Halo**。prot.bin 本身已经是 Music 调音。

### 控件名坑

主线 ALSA 叫 `TL Analog PCM` / `TL Digital PCM` / `TL DRE` / `TL DSP1 Preload`。  
旧 `dagu-speaker-route.sh` / UCM 用安卓名 `… Volume` / `… Switch`，`|| true` 吞掉失败。增益能对上是因为 **驱动默认就是 18 / 0 dB**，不是脚本写进去的。

已改成主线名字，并显式 `ASP TX1=VMON` `TX2=IMON`：

- `linux-mainline/scripts/dagu-speaker-route.sh`
- `linux-mainline/alsa/ucm2/Xiaomi-dagu/HiFi.conf`
- `linux-mainline/scripts/rootfs-desktop-setup.sh`
- `linux-mainline/scripts/dagu-av-test.sh`

### Halo CAL_SET_STATUS

安卓 `Protection cd CAL_SET_STATUS = 2`、`CAL_R_SELECTED = CAL_R`。  
`linux-mainline/scripts/apply-overlays.sh` 下次编核会在 preload 后再写 `0x02800278=cal_r`、`0x0280027c=2`。  
**还没刷这颗内核。** 现网 `#169` 只写到 `CAL_STATUS=1`。regmap debugfs 扫不到 XM 窗口（mailbox，不是普通寄存器文件）。

不要用 PipeWire softvol / 数字增益「把蚊子声拉大」。

### 设备树复位

`linux-mainline/dts/sm8250-xiaomi-dagu.dts` 的 `reset-gpios` / `VA-supply` / `VP-supply` 与 `linux-mainline/dts/sm8250-xiaomi-dagu-full.dts` 的 CAF 焊盘一致。芯片已探针，**不是**复位/供电没挂。

---

## 复跑

```bash
# 安卓只提取
linux-mainline/scripts/dagu-android-extract.sh

# Linux：fence / 看门狗 / 喇叭通路（会响）
linux-mainline/scripts/dagu-chrome-fence-probe.sh --host
linux-mainline/scripts/dagu-mineradio-watch.sh --host
linux-mainline/scripts/dagu-av-test.sh
```
