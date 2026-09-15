# dagu-vulkan-truth：A650 GMEM → LINEAR 硬件探底

记录日期：**2026-09-12**。  
代号：`dagu-vulkan-truth`。  
设备：同机型安卓 A 槽，小米平板 5 Pro 12.4（`dagu` / `<android-serial>` / Android 14 / `Adreno650v3` / `vulkan.adreno.so` + `kgsl`）。  
Linux 对照机：`g_serial 0525:a4a7`，`192.168.7.2`（本轮未改 Mesa，只当对照床）。

相关底稿：`linux-mainline/docs/dagu-a650-linear-destile.md`。

---

## 1. 一句话判决

**可能性 A，但不是「藏在 A2D 里的 magic bit」。**  
官方 blob **会**把 LINEAR color RT 送进 GMEM，并用 **`BLIT_EVENT_STORE_AND_CLEAR` + `RB_RESOLVE_SYSTEM_BUFFER_INFO.TILE_MODE = TILE6_LINEAR`** 写回；CPU 直读 1024×1024 行主序 **100% 对齐**。  
A2D/`CP_BLIT` 在这条路上只做 clear / `vkCmdCopyImageToBuffer`，不是 GMEM store。  
Mesa 已经会写 `TILE6_LINEAR` 的 event-store，却仍落成 macrotile——缺的是 blob 那条 **16 dword resolve IB** 的其余寄存器，不是「硬件不会」。

heist 补丁让 **专用 LINEAR FBO** 的 GMEM store/restore 变成真线性。同 batch FB fetch 的死穴是 UCHE 基址：blob `TEX_CONST` base=0，Mesa 曾写成 `gmem_base+cbuf`（`0x100000`）。现已对齐，PASS3 GMEM `FETCH_OK`。`dagu-chrome.sh` 已不设 `DAGU_LINEAR_SYSMEM` / `DAGU_LINEAR_DESTILE`（destile 底稿 §9.6）。

---

## 2. 环境

| 项 | 值 |
|----|-----|
| 安卓 | Magisk root，`Adreno650v3`，`/vendor/lib64/hw/vulkan.adreno.so` |
| GPU 节点 | `/dev/kgsl-3d0`，`usesgmem=1` |
| 探针 | `linux-mainline/tools/dagu-vulkan-truth/probe/probe.c` |
| 设备路径 | `/data/local/tmp/dagu-vulkan-truth/dagu-vk-probe` |
| QGL 开关 | `/data/vendor/gpu/qgl_config.txt`（`pm4dumpenable=True`，`0x0=0x8675309`） |
| 解码 | `/tmp/mesa-cffdump/src/freedreno/decode/cffdump`（Mesa 26.0.8 主机编） |
| 抓包 | QGL `cmdbuf_*.log` / `ib_cmdbuf_*.log`。`LD_PRELOAD libkgsl_wrap.so` **没挂上**（vendor HAL 在 sphal namespace，见第 6 节） |

NDK：`$HOME/android-ndk-r26d`（本机，不进 git）。

---

## 3. 探针合同

`VkImage`：`R8G8B8A8_UNORM`，`COLOR_ATTACHMENT | TRANSFER_SRC`，1024×1024。  
RenderPass：`loadOp=CLEAR`，`storeOp=STORE`。  
片元把 `(x,y)` 编进 RGB。LINEAR 用 `vkMapMemory` + `rowPitch` 直读；两边都再 `vkCmdCopyImageToBuffer`。

blob **声明并创建成功**：LINEAR 也可当 color RT（`COLOR_ATT` bit 在 `linearTilingFeatures` 里）。

---

## 4. 两轮抓包

### Pass 1：自然路径（1 个 triangle）

产物：`linux-mainline/tools/dagu-vulkan-truth/out/captures/pass1-sysmem/`

| | LINEAR | OPTIMAL |
|--|--------|---------|
| 像素 | `TRUE_LINEAR`（direct-map 245760/245760） | copy-buffer 真线性（TILE 图，copy 会解开） |
| 3D | `RM6_DIRECT_RENDER` | `RM6_DIRECT_RENDER` |
| `RB_MRT[0].BUF_INFO` | `COLOR_TILE_MODE=TILE6_LINEAR` | `COLOR_TILE_MODE=TILE6_3` |
| A2D | 全屏 SOLID_COLOR clear → dest `TILE6_LINEAR` pitch=4096 | 16×256 `FMT6_32_UINT` 辅助 blit；copy 到 LINEAR staging |

单 draw 被 autotune 拍成 sysmem。这一轮只能证明：**3D 直写 LINEAR 是好的**（和 Mesa sysmem bypass 一致），还不能回答 GMEM store。

### Pass 2：`forcegmemstore=True` + 128 draws

产物：`linux-mainline/tools/dagu-vulkan-truth/out/captures/pass2-forcegmem/`  
配置：`linux-mainline/tools/dagu-vulkan-truth/qgl_config_force_gmem.txt`

两边 IB1 都出现完整 binning 骨架：

```text
RM6_BIN_VISIBILITY
RM6_BIN_END_OF_DRAWS | USES_GMEM
RM6_BIN_RESOLVE      | USES_GMEM
  RB_RESOLVE_OPERATION = BLIT_EVENT_STORE_AND_CLEAR
RM6_BIN_RENDER_END
```

bin 尺寸：`RB_RESOLVE_CNTL_3 { BINW=480, BINH=512 }`（1024×1024 RGBA8，GMEM 1MB 量级）。

| | LINEAR | OPTIMAL |
|--|--------|---------|
| 像素 | **仍 `TRUE_LINEAR`** | copy 真线性 |
| GMEM 3D MRT | `TILE6_LINEAR` | `TILE6_3` |
| LOAD 的 sysmem 描述 | `TILE6_LINEAR`，pitch=4096，array=4194304，**无 FLAGS** | `TILE6_3 \| FLAGS`（UBWC） |
| STORE | `BLIT_EVENT_STORE_AND_CLEAR`；resolve IB 本体 16 dword **QGL 没吐出来**（`could not find 0x500464060`） | 同 opcode，resolve IB 20 dword 也缺失 |

**硬件结论**：A650 的 event-store **能**按 `TILE6_LINEAR` 编址写回。不是残疾。

---

## 5. 和 Mesa 的差在哪

Mesa 活源码（不在 git 树）：

- `/tmp/mesa-26.0.8/src/gallium/drivers/freedreno/a6xx/fd6_gmem.cc` — `emit_blit` 已经写 `RB_RESOLVE_SYSTEM_BUFFER_INFO.tile_mode`，LINEAR 时就是 `TILE6_LINEAR`；store 用 `BLIT_EVENT_STORE`。
- `/tmp/mesa-26.0.8/src/gallium/drivers/freedreno/a6xx/fd6_blitter.h` — 本机注释：`BLIT_EVENT_STORE` 进 LINEAR 仍是 macrotile；A2D 无 window offset。

blob 对照说明：

1. **不要再把 A2D/`fd6_resolve_linear_tile` 当 GMEM→LINEAR 的正路。** blob 的 store 是 event-store。A2D 只出现在 `RM6_BLIT2DSCALE`（clear / copy）。
2. `TILE6_LINEAR` 这一位 blob 和 Mesa **都写了**。Mesa 仍 macrotile，所以缺的是 store IB 里尚未抓到的东西（window、pitch、GMEM 描述、`LAST`/`BUFFER_ID`、CCU、每 tile 的 `RB_RESOLVE_CNTL_1/2` 等）。
3. OPTIMAL 的 FLAGS/UBWC 不要抄到 LINEAR 上。blob 的 LINEAR resolve **没有** `FLAGS`。

已做完的 heist 移植步骤：

- 抓到 LINEAR 的 16 dword resolve IB 全文（`kgsl_spy`，见第 9.2 / 9.3 节）。
- 和 `/tmp/mesa-26.0.8/src/gallium/drivers/freedreno/a6xx/fd6_gmem.cc` 的 `emit_blit` / `emit_resolve_blit` 对拍并补进活树。
- Linux dagu 关掉 sysmem 钩子验收：专用 FBO **过**，Chrome 毛玻璃 **不过**（第 9.4 节）。下一缺口是 `FD_GMEM_FB_READ`，不是再猜 store IB 的隐藏位。

---

## 6. 工具链坑

| 现象 | 原因 | 现行办法 |
|------|------|----------|
| `libkgsl_wrap.so` 只有 `wrap: loaded`，没有 `.rd` | Android 14 vendor HAL（`vulkan.adreno.so` / GSL）在 **sphal** namespace，吃不到 app 的 `LD_PRELOAD` | `qgl_config.txt` 的 `pm4dumpenable` |
| 现代 Mesa `cffdump` 是解码器，不是拦截器 | wrap 已迁出 mesa 主树 | 本目录 `wrap/kgsl_wrap.c` 留给以后塞进 `/vendor/lib64` |
| 单 triangle 看不到 GMEM | blob autotune 走 `RM6_DIRECT_RENDER` | `forcegmemstore=True` + `--draws 128` |

QGL 配置模板：

- `linux-mainline/tools/dagu-vulkan-truth/qgl_config.txt`
- `linux-mainline/tools/dagu-vulkan-truth/qgl_config_force_gmem.txt`

复跑：

```bash
linux-mainline/tools/dagu-vulkan-truth/scripts/build.sh
linux-mainline/tools/dagu-vulkan-truth/scripts/run-android.sh
python3 linux-mainline/tools/dagu-vulkan-truth/scripts/qgl_markers.py \
  linux-mainline/tools/dagu-vulkan-truth/out/captures/pass2-forcegmem/qgl/ib_cmdbuf_*.log
/tmp/mesa-cffdump/src/freedreno/decode/cffdump --once --no-color \
  linux-mainline/tools/dagu-vulkan-truth/out/captures/pass2-forcegmem/linear_gmem.rd
```

---

## 7. 文件索引

| 路径 | 角色 |
|------|------|
| `linux-mainline/docs/dagu-vulkan-truth.md` | 本文 |
| `linux-mainline/tools/dagu-vulkan-truth/probe/probe.c` | Vulkan 裸探针 |
| `linux-mainline/tools/dagu-vulkan-truth/probe/shader.vert` / `shader.frag` | 坐标色 |
| `linux-mainline/tools/dagu-vulkan-truth/wrap/kgsl_wrap.c` | sphal 重定向成功；libgsl 裸 svc，ioctl 仍看漏 |
| `linux-mainline/tools/dagu-vulkan-truth/scripts/build.sh` | NDK 交叉编 |
| `linux-mainline/tools/dagu-vulkan-truth/scripts/run-android.sh` | 推送 + 跑 + 拉取 |
| `linux-mainline/tools/dagu-vulkan-truth/scripts/qgl_hex_to_rd.py` | QGL hex → `.rd` |
| `linux-mainline/tools/dagu-vulkan-truth/scripts/qgl_markers.py` | 快速扫 marker / A2D |
| `linux-mainline/tools/dagu-vulkan-truth/scripts/rd_scan.py` | `.rd` 粗扫 |
| `linux-mainline/tools/dagu-vulkan-truth/out/captures/pass1-sysmem/` | 自然 sysmem 对照 |
| `linux-mainline/tools/dagu-vulkan-truth/out/captures/pass2-forcegmem/` | GMEM + event-store 对照 |
| `linux-mainline/tools/dagu-vulkan-truth/out/captures/pass3-heist/` | 击穿 sphal 后的 wrap / spy `.rd` |
| `linux-mainline/tools/dagu-vulkan-truth/adreno_icd.json` | 伪造 ICD，把 blob 拉到 `/data/local/tmp` |
| `linux-mainline/tools/dagu-vulkan-truth/wrap/kgsl_spy.c` | ptrace 拦 `ioctl`，不吃 linker namespace |
| `linux-mainline/tools/dagu-vulkan-truth/scripts/run-heist.sh` | 主机编排 heist |
| `linux-mainline/tools/dagu-linear-gmem-probe.c` | Linux 9.4.2：GBM LINEAR FBO mmap，勿信 `glReadPixels` |
| `linux-mainline/out/display-stress/glass-heist-sysmem0-1p000-full.png` | Chrome `SYSMEM=0` A–H 雪 |
| `/tmp/mesa-cffdump/src/freedreno/decode/cffdump` | 主机解码器 |

---

## 8. 修订

| 日期 | 内容 |
|------|------|
| 2026-09-12 | 首轮实机。Pass1 sysmem；Pass2 强迫 GMEM。判决：硬件能 LINEAR event-store；下一步抓 16 dword resolve IB。 |
| 2026-09-12 | 开 `dagu-event-store-heist`：伪造 ICD + sphal hook + ptrace `kgsl_spy`，目标抠出 `0x500464060` 的 16 dword。见第 9 节。 |
| 2026-09-12 | heist 得手：16 dword 已解码；Mesa 补 `LAST=2` / `STORE_AND_CLEAR` / `CNTL_0` / GMEM_INFO / `concurrent_resolve`。桌面绕开未撤。 |
| 2026-09-12 | 9.4 实跑：FBO GMEM store 真线性；Chrome 毛玻璃 `SYSMEM=0` 雪。判决：不能撤 `DAGU_LINEAR_SYSMEM`。 |
| 2026-09-12 | fb-fetch-hunt：blob LOAD IB 已抓；Mesa restore mmap 绿；同 batch GMEM fetch 红。 |
| 2026-09-12 | LINEAR+FB_READ 自动 sysmem。Chrome `SYSMEM=0` 真霜。已拔 `dagu-chrome.sh` 的 `DAGU_LINEAR_SYSMEM`。 |

---

## 9. 代号 `dagu-event-store-heist`（2026-09-12）

任务书已归档并开跑。桌面 **`DAGU_LINEAR_SYSMEM` 在 destile 底稿 9.4 五条验收之前不准拔**。

### 9.1 已知缺口

Pass 2 的 IB1 已经写出：

```text
RB_RESOLVE_OPERATION = BLIT_EVENT_STORE_AND_CLEAR | CLEAR_MASK=0xf | LAST=0x2
CP_INDIRECT_BUFFER IB_BASE=0x500464060 IB_SIZE=0x10
CP_EVENT_WRITE EVENT=PC_CCU_RESOLVE_TS
```

`cffdump` 对 `0x500464060` 报 `could not find (16)`。QGL 只吐了 IB1 + draw IB，没吐这条 resolve IB。  
Mesa 对应路径是 `/tmp/mesa-26.0.8/src/gallium/drivers/freedreno/a6xx/fd6_gmem.cc` 的 `emit_blit` / `emit_resolve_blit`（**没有**名叫 `fd6_gmem_emit_store_ib` 的函数）。颜色 store 用 `BLIT_EVENT_STORE`，blob 用 `STORE_AND_CLEAR`。

### 9.2 阶段一：击穿 sphal

不改内核、不装 Magisk 模块。三路并行：

1. 把 `/vendor/lib64/hw/vulkan.adreno.so` 拷到 `/data/local/tmp/dagu-vulkan-truth/`，伪造 ICD：`linux-mainline/tools/dagu-vulkan-truth/adreno_icd.json`。  
   `VK_ICD_FILENAMES` + `LD_PRELOAD=libkgsl_wrap.so` 重跑 Pass 2（`--draws 128` + `forcegmemstore`）。
2. wrap 额外挂钩 `android_load_sphal_library` / `android_dlopen_ext` / `dlopen` / `syscall(ioctl)`，把 HAL 拽进默认 namespace。
3. 若 ICD 仍被 Android `libvulkan.so` 忽略（HAL loader 不走 ICD）：`kgsl_spy` 用 ptrace 在 syscall 边界拦 `IOCTL_KGSL_GPU_COMMAND`，与 linker namespace 无关。

脚本：

- 设备：`linux-mainline/tools/dagu-vulkan-truth/scripts/run-heist-on-device.sh`
- 主机：`linux-mainline/tools/dagu-vulkan-truth/scripts/run-heist.sh`

预期：`.rd` 里出现那 16 个 dword；wrap/spy 日志有 `IB HEX gpu=0x... ndw=16:`。

**阶段一实跑（2026-09-12）**

- 伪造 ICD + `android_load_sphal_library` 重定向 **成功**：`vulkan.adreno.so` 从 `/data/local/tmp/dagu-vulkan-truth/vulkan.adreno.so` 进了默认 ns。  
  但 `libgsl` 仍用裸 `svc` 打 `ioctl`，`libkgsl_wrap.so` 看不到 kgsl（`passA_saw_kgsl=0`）。Android `libvulkan.so` 也忽略 `VK_ICD_FILENAMES`。
- `kgsl_spy` ptrace **打穿**：`heist_spy_linear.rd` 18 MB，BO `0x500464000` 里有 `0x500464060` 的 16 dword。LINEAR 仍 `TRUE_LINEAR`（`draws=128` + `forcegmemstore`）。
- 产物：`linux-mainline/tools/dagu-vulkan-truth/out/captures/pass3-heist/`

### 9.3 阶段二：解码盲区

`cffdump` 搜 `BLIT_EVENT_STORE_AND_CLEAR`，盯紧随后的寄存器：

- `RB_RESOLVE_CNTL*` 是否有未文档 mask
- `RB_RESOLVE_SYSTEM_BUFFER_INFO` 的 `TILE6_LINEAR` / `FMT` / `PITCH` / 对齐隐藏位
- store 前后的 `CACHE_FLUSH_TS` / `CACHE_CLEAN` / `RB_CCU_CNTL`（IB1 里已见 `PC_CCU_RESOLVE_TS`）

和 Mesa `emit_blit` 逐 dword 对拍。

**16 dword @ `0x500464060`（已抠出）**

```text
4888d785 00001800 00063000 00000005 00000040 00010000
4088d502 00000000 00000000
4088d001 00000000
4888d102 00000000 03ff03ff
70460001 0000001e
```

| 盲区 | blob | Mesa 补丁前 |
|------|------|-------------|
| `RB_RESOLVE_OPERATION`（在 IB1，值 `0x2f1`） | `STORE_AND_CLEAR \| CLEAR_MASK=0xf \| LAST=2` | 颜色 `STORE`，**不写 LAST** |
| `RB_RESOLVE_SYSTEM_BUFFER_INFO` | `TILE6_LINEAR`，无 FLAGS，WZYX，`FMT6_8_8_8_8_UNORM`，pitch=4096 | 已会写 LINEAR（仍 macrotile） |
| `RB_RESOLVE_CNTL_0` | `0`（写在 store IB 里） | store 路径不写 |
| `RB_RESOLVE_CNTL_1/2` | 全幅 `(0,0)-(1023,1023)` | `set_blit_scissor` 近似（宽对齐 16、高对齐 4） |
| `RB_RESOLVE_GMEM_BUFFER_INFO` | `SAMPLES=MSAA_ONE` + BASE=0 | 只写 BASE |
| 缓存 | IB 内 `CCU_RESOLVE(0x1e)`，回到 IB1 再 `PC_CCU_RESOLVE_TS(0x1a)` | 已有 `FD_CCU_RESOLVE` |
| `RB_CCU_CNTL` | `CONCURRENT_RESOLVE` + color cache QUARTER | a650 `concurrent_resolve` 默认 false |

没有未文档 mask。`LAST=2` 在 `a6xx.xml` 里就写着「a650+ last resolve」。每 tile 的窗口在 **外面**：`RB_RESOLVE_WINDOW_OFFSET` + `CNTL_3 {BINW=480,BINH=512}`。

### 9.4 阶段三：Mesa 补全（有 16 dword 才动；未验收不撤绕开）

已复刻进活树，**只**部署到 Chrome 的 dagu-mesa（**未**改 `dagu-chrome.sh` 默认，**未**关绕开）：

- `/tmp/mesa-26.0.8/src/gallium/drivers/freedreno/a6xx/fd6_gmem.cc`
- `/tmp/mesa-26.0.8/src/freedreno/common/freedreno_devices.py`（`a6xx_gen3.concurrent_resolve=True`）
- 说明：`linux-mainline/patches/mesa-26.0.8-a650-event-store-last.patch`
- 活 so：`/usr/local/lib/dagu-mesa/libgallium-26.0.8-1ubuntu0.3.so`（md5 `b83230e8d9d3ba2164fb6809d1ed6ad7`）
- 备份：`/usr/local/lib/dagu-mesa/libgallium-26.0.8-1ubuntu0.3.so.bak-pre-heist`

`linux-mainline/scripts/dagu-chrome.sh` 已不 export `DAGU_LINEAR_SYSMEM`。不要把该变量给 gnome-shell。

**9.4 实跑（2026-09-12）**

| 条 | 结果 |
|----|------|
| 1 毛玻璃 | **红**。完整 `dagu-chrome` Ozone flag + `SYSMEM=0` `DESTILE=0` + heist so：A–H 雪，J 条纹，K 霜。图：`linux-mainline/out/display-stress/glass-heist-sysmem0-1p000-full.png` |
| 2 LINEAR GMEM mmap | **绿**。`linux-mainline/tools/dagu-linear-gmem-probe.c`，`using 4 bins of size 576x512`，mmap `TRUE_LINEAR` 65536/65536。片元必须 `mod(x,256)`，否则 x≥256 钳位假失败 |
| 3 WebGL hangcheck | 本轮无新增 `hangcheck recover` / `00800005`（dmesg 仍有开机留下的 10 条） |
| 4 gnome-shell | **绿**。environ 无 DAGU / dagu-mesa；主 fb KMS LINEAR |
| 5 cmdstream | 安卓 `pass3-heist` `.rd` + 探针 4-bin 日志。Chrome 毛玻璃无 `.rd` |

**2026-09-12 傍晚：** store/restore 仍绿。GMEM FB fetch 仍红（PASS3 512 整幅 invert(清屏)）。LINEAR+FB_READ 改为自动 sysmem 后，Chrome `SYSMEM=0` A–H 真霜，`dagu-chrome.sh` 已拔掉 `DAGU_LINEAR_SYSMEM`。图：`linux-mainline/out/display-stress/glass-fbread-sysmem0-full.png`。

### 9.5 `dagu-fb-fetch-hunt`：LOAD IB 与同 batch fetch

安卓 `--load-second`（`forcegmemload=True`）+ `kgsl_spy`：

- `linux-mainline/tools/dagu-vulkan-truth/out/captures/pass4-fb-fetch/heist_spy_load.rd`
- LOAD 的 16 dword 与 store **逐字相同**，OPERATION 是 `0x00000203` = `BLIT_EVENT_LOAD|LAST=2`（store 是 `0x000002f1`）。
- CPU map 仍 `TRUE_LINEAR`。

Linux（`linux-mainline/tools/dagu-linear-gmem-probe.c`，`SYSMEM=0` `FD_MESA_DEBUG=gmem`）：

| 步 | 结果 |
|----|------|
| PASS1 store 1024 / 2496×416 | TRUE_LINEAR |
| PASS2 restore（无 clear，8×8 scissor） | TRUE_LINEAR（hunt：`restore=0x4`） |
| PASS3 同 batch `gl_LastFragData` | **GMEM FETCH_BAD**（512：`00 00 ff`）；无 `FD_MESA_DEBUG=gmem` 时自动 sysmem → **FETCH_OK** |

Chrome hunt：`fbread=1` 从不带 restore。强迫 GMEM 时雪花与 PASS3 对齐。自动 sysmem 后 62 条 `fbread=1` 全 `sys=1`，A–H 真霜。`linux-mainline/scripts/dagu-chrome.sh` 已不设 `DAGU_LINEAR_SYSMEM`。

### 9.6 `dagu-gmem-fbread-sync`：两 Subpass Input Attachment

探针：`--tiling linear --draws 128 --input-second`（`linux-mainline/tools/dagu-vulkan-truth/probe/input_att.c`）。  
QGL：`forcegmemstore=True` `forcegmemload=True`。spy：`kgsl_spy`。  
产物：`linux-mainline/tools/dagu-vulkan-truth/out/captures/pass5-input-att/`

| 项 | 值 |
|----|-----|
| 像素 | `FETCH_OK` 245760/245760（invert B of `x^y`） |
| 判决 | **A**：两个 Subpass 留在 GMEM |
| 中间屏障 | `PC_CCU_FLUSH_COLOR_TS` + `CACHE_INVALIDATE`（无 `PC_CCU_INVALIDATE_COLOR`） |
| 收尾 | `STORE_AND_CLEAR` 16-dword LINEAR event-store |
| fetch `TEX_CONST` | `TILE6_2` pitch=1920 base=**0** `FMT6_8_8_8_8_UNORM` |

Linux Mesa：`patch_fb_read_gmem` 对 LINEAR sysmem RT 使用 `base = cbuf_base`（0），不再加 `screen->gmem_base`。512 与 1024 PASS3 在强迫 GMEM 和自动 bin 下都是 `FETCH_OK`。已撤 LINEAR+FB_READ 的 sysmem 回退。
