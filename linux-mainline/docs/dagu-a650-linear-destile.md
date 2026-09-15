# dagu Adreno 650：LINEAR resolve / CSS 毛玻璃花屏

记录日期：**2026-09-12**。  
状态：**GMEM store / restore / 同 batch FB fetch 都绿（FIXED）。** 主 fb 已收复 UBWC。`dagu-chrome.sh` 已不设 `DAGU_LINEAR_SYSMEM` 也不设 `DAGU_LINEAR_DESTILE`。UCHE 读 LINEAR 的 GMEM 要用 **cbuf 偏移 0**，不是 msm 的 `gmem_base=0x100000`。详见 §9.6 / §9.7。  
设备：小米平板 5 Pro 12.4（`dagu` / SM8250 / Adreno 650）。  
系统：Linux 7.0 + Ubuntu userdata，只刷 **B 槽**。

本文是这件事的**稳定底稿**。总表只留摘要：`linux-mainline/docs/dagu-adaptation-status.md`。  
以后改 Mesa / GBM / 包装器之前，先读「禁止再试」和「为什么 destile 没做成」。不要靠聊天记录复盘。

---

## 1. 一句话

**专用 LINEAR 色 FBO 的 GMEM event-store / restore / 同 batch FB fetch，CPU mmap 已是真线性。**  
之前 PASS3 整幅 `00 00 ff` 不是「颜色卡在 CCU」，而是 `patch_fb_read_gmem` 把采样器指到了 `gmem_base+cbuf`（`0x100000`）。a650 的 UCHE 按 blob 那样读 **GMEM 偏移 0**。A2D/`CP_BLIT` 仍不是正路。

毛玻璃算法、GPU blur、WebGL 彩虹底都不是根因。`filter:blur` 糊自己的层一直是好的。坏的是 **「先拷/取背后那张 LINEAR 图，再 blur」**。

---

## 2. 机器与铁律

| 项 | 值 |
|----|-----|
| 面板 | L81A，物理 1600×2560@120，transform **270°**，逻辑横屏 |
| 主 fb | mutter scanout **XR24 `QCOM_COMPRESSED`**（`modifier=0x0500000000000001`），DPU 双 SSPP 800+800。Chrome 窗口仍是 LINEAR |
| KMS 裁剪 | `linux-mainline/scripts/dagu-kms-land-crop.py`，平板 `/usr/local/sbin/dagu-kms-land-crop.py` |
| SSH | `ssh -i linux-mainline/out/id_dagu root@192.168.7.2`，会话用户 `dagu` uid=1001 |
| Mesa 发行 | Ubuntu 26.04 `libgallium-26.0.8-1ubuntu0.3.so` |
| 活补丁源码 | `/tmp/mesa-26.0.8`（**不在 git 树里**） |
| 交叉构建 | `ninja -C /tmp/mesa-dagu-build src/gallium/targets/dri/libgallium-26.0.8.so` |
| 只给 Chrome/Mineradio 的 so | `/usr/local/lib/dagu-mesa/libgallium-26.0.8-1ubuntu0.3.so` |
| 仓库副本 | `linux-mainline/out/libgallium-26.0.8-1ubuntu0.3.so`（勿当系统 Mesa） |
| 仓库说明补丁 | `linux-mainline/patches/mesa-26.0.8-linear-sysmem.patch`（**说明文，不是完整 diff**） |
| GBM 挂钩 | `linux-mainline/scripts/dagu-linear-mod.c` → `/usr/local/lib/libdagu-linear-mod.so` |

启动安全（与毛玻璃无关，但改内核时仍成立）：

- 只刷 B 槽。救砖：`linux-mainline/scripts/flash-boot-legacy.sh restore-a`
- **禁止** `DAGU_PRIMARY_ENTRY_PROBE=1`
- **禁止** `geni_load_se_fw()`、`CONFIG_SPI_QCOM_GENI`
- 刷写用 `linux-mainline/scripts/fb-usb.py`，不要 Google `fastboot reboot`

用户态铁律：

- **禁止**把 `FD_MESA_DEBUG` / `TU_DEBUG` / `DAGU_LINEAR_SYSMEM` / `DAGU_LINEAR_DESTILE` / `libdagu-linear-mod.so` / `dagu-mesa` 放进 **gnome-shell**
- **禁止**全局 `FD_MESA_DEBUG=notile` 或 `sysmem`（unused-depth 的 TILE6_3 WebGL 会 CCU hang，irq `00800005`）
- **禁止**用软件栅格、`--disable` backdrop-filter、CSS 假霜来「修」这个问题
- LINEAR+stencil 整段 sysmem 会把 mutter scanout 写黑，所以 gnome-shell 不能开 `DAGU_LINEAR_SYSMEM`

---

## 3. 名词（读后面章节前先对齐）

### 3.1 内存铺法

| 名字 | 含义 |
|------|------|
| **LINEAR** | 行主序。第 `y` 行地址 = `base + y * stride`。CPU、Wayland `modifier=0,0`、DPU 主 fb 都按这个读。Mesa 内部 `TILE6_LINEAR` / `tile_mode=0` / `FD_LAYOUT_LINEAR`。 |
| **macrotile / TILE6_3** | Adreno 把一块矩形打成固定形状的 tile 再线性排进 BO。stride、pitch 公式和 LINEAR 不同。同一块像素，LINEAR 采样器读 TILE 内存 = 彩砖/雪花。 |
| **UBWC** | 在 TILE 上再压缩。modifier `QCOM_COMPRESSED`。导入时若当 LINEAR 读，比纯 TILE 更花。 |
| **TILE6_2** | GMEM 里的 bin 铺法。`patch_fb_read_gmem` 用它描述「当前 tile 在 GMEM」。不是 sysmem 的 LINEAR。 |

「花屏」在本机的典型样子：整卡彩色静电、32px 砖纹、字形变成 1-bit 块。**不是**普通模糊或色彩偏。

### 3.2 两条渲染通路

| 通路 | 怎么走 | 何时好 |
|------|--------|--------|
| **GMEM / binning** | 把 RT 切成 bin，在片上 GMEM 画，再 **store** 回 sysmem | dest 是 TILE/UBWC **或** 已修好的 LINEAR 时，这是正路 |
| **sysmem / bypass / direct render** | 不进 GMEM，3D 管道直接写 sysmem | 旧绕开；`DAGU_LINEAR_SYSMEM=1` 仍可强迫走这里 |

GMEM 的写回叫 **resolve / store**。常用两种硬件：

| 硬件 | Mesa 名 | 本机结论 |
|------|---------|----------|
| **Event store** | `BLIT_EVENT_STORE` / `STORE_AND_CLEAR` + `LAST=2` | 按 blob 16-dword IB 写进 LINEAR dest → **真线性**（§9.4 / §9.6） |
| **A2D / CP_BLIT / r2d** | `fd6_resolve_tile`、`fd6_resolve_linear_tile`、`emit_blit_texture` | 即使两端都标 LINEAR，仍写 **macrotile**；在 `RM6_BIN_RESOLVE` 下还会写 **随机 iova**。不要用。 |

**A2D 不是转铺器。** 它按自己的地址生成抄比特，不会「把 TILE 解开成 LINEAR」。

### 3.3 3D blit

`u_blitter` / `fd_blitter_blit`：用 3D 着色器采样 src、画到 dest。在 sysmem 下写出真 LINEAR。卡片 **K**、字形上传（R8 走 TILE 时）、以及「跳过 A2D 之后的回退」都靠它。

不能在 `handle_rgba_blit` / `do_blit` 里面再调 `fd_resource_uncompress`：会 `do_blit: Assertion !ctx->in_blit failed`，Chrome 直接 abort。

### 3.4 FB fetch

`FD_GMEM_FB_READ`：片元着色器读**当前颜色缓冲**（Skia / ANGLE 的 backdrop 常用这条）。

- GMEM：`patch_fb_read_gmem`，描述符是 GMEM 里的 `TILE6_2`
- sysmem：`patch_fb_read_sysmem`（`/tmp/mesa-26.0.8/src/gallium/drivers/freedreno/a6xx/fd6_gmem.cc`），描述符必须是那张 BO 的**真 layout**

`fd6_screen.cc` 的 `gmem_reason_mask` **不含** `FD_GMEM_FB_READ`，autotune 默认拒绝 bypass。旧钩子曾把 LINEAR+FB_READ 整段打进 sysmem；**已撤**。UCHE 必须采 `cbuf` 偏移 0，见 §9.6。

同 batch 里先画底再 FB-fetch，要先 `FLUSH_CCU_COLOR` + cache invalidate，**不要** `PC_CCU_INVALIDATE_COLOR`。钩子在 `/tmp/mesa-26.0.8/src/gallium/drivers/freedreno/a6xx/fd6_emit.cc`。

### 3.5 destile

本文的 destile = **GMEM（或 TILE sysmem）→ 真 LINEAR sysmem**。  
本机没有稳定的硬件 destile。所谓「destile 阴影」是：event-store 先写进一张 **TILE6_3** 影子，再在 tile 结束后 3D blit 到 LINEAR。影子分配必须能绕过「一切 4bpp 都 LINEAR」的钩子（`fd_dagu_set_force_tiled()`）。A2D 做这步 TILE→LINEAR **从未证过**。

---

## 4. 两层合同叠在一起

必须分开看。混在一起会修错层。

### 4.1 第一层：Wayland / Ozone 撒谎

Chromium Ozone 把 modifier 列表 `LINEAR + QCOM_COMPRESSED + QCOM_TILED3 + INVALID` 交给 `gbm_bo_create_with_modifiers`，但 `zwp_linux_buffer_params_v1.add` **永远标 0,0（LINEAR）**。

后果：ANGLE 按 **LINEAR** 采样；若 GBM 实际是 UBWC/TILE，整窗花屏。

mutter 侧（不要改错）：

- `MUTTER_DEBUG_SEND_KMS_MODIFIERS=1`：广告真实 QCOM modifier
- `MUTTER_DEBUG_USE_KMS_MODIFIERS=1`：主 fb 走 `QCOM_COMPRESSED`（2026-09-12 已收复）
- `disable-direct-scanout`：客户端（含 Chrome LINEAR）不要直接上 DPU

客户端：`linux-mainline/scripts/dagu-linear-mod.c` 把窗口/隐式 GBM 做成真 `GBM_BO_USE_LINEAR`，像素和标签一致。  
`eglCreateImageKHR`：若 fd 缓存已是 INVALID/LINEAR，**原样传递**，禁止把 TILED3 降成 LINEAR（那会「标签 LINEAR、像素仍 TILE」）。

这一层 **已经按合同修好**。毛玻璃花屏在合同对齐之后仍然在，说明还有第二层。

### 4.2 第二层：LINEAR 当 GMEM dest（已打通）

高通/blob 的习惯：颜色一直 TILE/UBWC，到 DPU scanout 再换。  
Chrome 窗口仍是 LINEAR（第一层合同 + `libdagu-linear-mod.so`）。以前 Mesa 的 event-store 缺 `LAST=2`，写出 macrotile。

现在两条钥匙都在（从 `vulkan.adreno.so` 对拍）：

1. 完整 event-store IB：`STORE_AND_CLEAR \| CLEAR_MASK=0xf \| LAST=2` + `CNTL_0`
2. UCHE FB fetch 基址 = `cbuf` 偏移 0，不是 msm `gmem_base=0x100000`

干净补丁（相对原版 Mesa 26.0.8）：

- `linux-mainline/patches/0001-freedreno-a6xx-fix-event-store-linear-layout.patch`
- `linux-mainline/patches/0002-freedreno-a6xx-fix-gmem-fb-read-linear-base-offset.patch`

桌面合成走 UBWC，Chrome 走 LINEAR GMEM，互不干扰。详见 §9.6、§9.7。

---

## 5. Skia 两条 blur（探针为什么要有 K）

| | 卡片 K | 卡片 A–H |
|--|--------|----------|
| CSS | 元素自己的层 `filter:blur` | `backdrop-filter`（Mineradio 搜索条/底栏同款） |
| GPU | 3D 画出彩虹，再 blur **同一张** | 先得到「背后」的拷贝/FB fetch，再 blur |
| 未修 destile 时 | **真霜** | **满卡噪点** |
| 现绕开后 | 真霜 | 真霜 |

所以：

- GPU blur **能用**
- 花的是 **backdrop 的源**（快照或 FB fetch 的那张 LINEAR），不是 saturate/brightness 公式
- 与 Mutter 缩放无关（1.0 / 1.25 / 1.33 / 2.0 同一分裂）

实机还见过：

- 交换链约 `2477×1560`，`r8g8b8a8_unorm`，sysmem
- 玻璃条 `2496×416`，`b8g8r8a8_unorm`，`fbread=1 draws=7`
- 单卡 FBO `512×256` RGBA，`fbread=1 draws=3`
- `506×187 → 512×256` 的 blit 是 **`r8_unorm` 字形**，**不是**毛玻璃快照。把 R8 也逼 LINEAR，Chrome **所有字消失**（卡片还在）

`1819×89` `draws=0`：分配了但没有 3D 填充，不要当成「已画好的快照」。

---

## 6. 探针页（以后验收只认这一页）

| | 路径 |
|--|------|
| 仓库 | `linux-mainline/scripts/dagu-glass-probe.html` |
| 平板 | `/home/dagu/dagu-glass-probe.html` |
| URL | `file:///home/dagu/dagu-glass-probe.html` |
| 缩放扫 | `linux-mainline/scripts/dagu-glass-sweep.py` → `/usr/local/sbin/dagu-glass-sweep.py` |

底：CSS 彩虹斜条 + 棋盘 + WebGL 全屏（HUD 必须 `webgl=ok`）。

| 卡 | 作用 | 好的样子 | 坏的样子 |
|----|------|----------|----------|
| A | 全宽 `blur(26) saturate`，Mineradio 搜索 | 霜过的彩虹，字可读 | 黑条 / 满卡雪 |
| B | 浅霜 `blur(18)` | 淡彩虹霜 | 雪或死白 |
| C | 中霜 `blur(28)` | 同上，更糊 | 雪 |
| D | 重霜 `blur(48)` | 仍能感到彩虹，不是噪点 | 雪 |
| E | 深色霜，Mineradio 底栏 | 暗霜，字白 | 雪 |
| F | 歌词卡 + brightness | 暗霜 | 雪 |
| G | `blur(16) brightness/contrast` | 偏亮霜 | 雪 |
| H | 小圆 | 圆霜 | 雪 |
| I | 实色，无 backdrop | 整块实色 | — |
| J | 半透明，**无** blur | **锐利条纹透出来** | 若 J 也霜了，页坏了 |
| K | **自己的**彩虹 `filter:blur` | 真霜（对照金样） | 若 K 也雪，是整条 GPU 崩了 |

量化（1.25，`glass-1p250-full.png` 一次实测）：

| 区 | uniq 色 | 邻域 jump | 读法 |
|----|---------|-----------|------|
| 墙纸条纹 | ~27 | 高、周期 | 锐利 LINEAR |
| A / B / C | 1.2万–1.7万 | 低（0.03–0.08） | 真霜 |
| J | ~1259 | 更高（~0.21） | 半透条纹 |
| K | ~1.0万 | 中 | 自己的霜 |
| 雪花（历史） | 极高且 32px 砖 | 又高又碎 | destile/A2D 失败 |

截图：

- `linux-mainline/out/display-stress/glass-1p000-full.png`（`SYSMEM=1` 金样）
- `linux-mainline/out/display-stress/glass-1p250-full.png`
- `linux-mainline/out/display-stress/glass-1p333-full.png`
- `linux-mainline/out/display-stress/glass-2p000-full.png`
- `linux-mainline/out/display-stress/glass-heist-sysmem0-1p000-full.png`（2026-09-12 heist so + `SYSMEM=0`：A–H 雪，J/K 好）
- `linux-mainline/out/display-stress/glass-heist-restore-sysmem1-1p000-full.png`（同机立刻恢复绕开）

Mineradio 对照（应用，不是探针）：

- `linux-mainline/scripts/dagu-mineradio-probe.html`
- `linux-mainline/out/display-stress/mineradio-demo-full.png`
- `linux-mainline/out/display-stress/mineradio-demo-1p25.png`

---

## 7. 当前绕开（2026-09-12 实机）

**仍然是 GPU。** 没有 llvmpipe，没有关 backdrop-filter。

环境（只在 Chrome / Mineradio 包装器）：

```text
DAGU_LINEAR_SYSMEM=1
DAGU_LINEAR_DESTILE=1
LD_LIBRARY_PATH=/usr/local/lib/dagu-mesa
LD_PRELOAD=/usr/local/lib/libdagu-linear-mod.so
```

包装器：

- `linux-mainline/scripts/dagu-chrome.sh` → 平板 `/usr/local/bin/dagu-chrome`
- `linux-mainline/scripts/dagu-mineradio.sh`
- `linux-mainline/scripts/rootfs-desktop-setup.sh` 写入的 `/usr/local/bin/chrome`、`/usr/local/bin/mineradio`

钩子行为（活源码 `/tmp/mesa-26.0.8`）：

1. **4bpp** 非 depth、非 scanout、且 **宽和高都 >1024** 才强制 `FD_LAYOUT_LINEAR`（躲开 Skia `3840×360` 图集）。R8、depth、scanout、单边超 1024 的内部图集 **保持 TILE**。Wayland 窗口/标签长条由 `dagu-linear-mod.c` 带 `PIPE_BIND_LINEAR` 进来，`get_best_layout` 后面的 bind 分支仍走 LINEAR。GBM：`R8` / 两边都 ≤1024 原样传递；任一边 >1024 的 AR24/XR24 强制 LINEAR。
2. 颜色 RT 已是 LINEAR → **整批 sysmem**，**包括** `FD_GMEM_FB_READ`
3. FB-fetch 用 `patch_fb_read_sysmem`；第一次 fb_read draw 前 flush CCU
4. A2D：src 或 dest 任一 LINEAR → `handle_rgba_blit` 返回 false，走 `u_blitter`
5. 小 TILE dest 承接 LINEAR 拷贝：`fd_resource_discard_linear()` 换 LINEAR BO（禁止嵌套 blit）
6. destile 影子可用 `fd_dagu_set_force_tiled(1)` 分配真 TILE6_3
7. **`fd6_resolve_linear_tile` 回退关闭**（`if (false && …)`）

Chrome 额外：`--disable-lcd-text`、`WaylandFractionalScaleV1`（分数 DPR + 灰度字，与毛玻璃正交，见总表字体段）。PartialSwap 保持默认开（LINEAR destile 已修好）；不要 `--in-process-gpu`。

### 这是妥协

| 做成了 | 没做成 |
|--------|--------|
| A–H 真霜，字在，无雪（**仅** `SYSMEM=1`） | Chrome 毛玻璃在 GMEM 下 destile |
| 专用 LINEAR FBO 的 GMEM store 真线性 | 撤掉 `DAGU_LINEAR_SYSMEM` |
| K / J 对照仍对 | A2D 转铺 |
| WebGL tiled FBO 仍 GMEM，无新 hangcheck | 4bpp 层的 UBWC / binning 带宽 |
| gnome-shell 不沾这些 env | 单一 Mesa 给所有进程 |

代价：LINEAR 窗和玻璃层不 binning、不 UBWC。对 1600×2560@120 的 Chrome 窗可以接受，不是 Adreno 设计路径。

---

## 8. 禁止再试（实机已付过学费）

再做这些，会回到雪花、黑屏或兔子。不要「优化一下再试」。

| # | 做过什么 | 结果 |
|---|----------|------|
| 1 | `FD_MESA_DEBUG=notile` / `sysmem` 进 gnome-shell 或全局 | 合成器花或黑；WebGL unused-depth sysmem → hangcheck `00800005` |
| 2 | 关 GPU 栅格 / 关 backdrop-filter / CSS 假霜 | 能「看起来不花」，不是本题 |
| 3 | 在 `RM6_BIN_RESOLVE` 里 destile | 随机 iova，**整桌面**雪 |
| 4 | `fd6_resolve_linear_tile`：GMEM(TILE6_2) A2D 进 LINEAR dest | dest 变 macrotile，A–H 雪 |
| 5 | 小缓冲 GBM 改 TILED3，ANGLE 仍按 LINEAR 采样 | 比 LINEAR 更雪 |
| 6 | `eglCreateImageKHR` 把 TILED3 改标 LINEAR | 右半 pill / 整卡雪 |
| 7 | `fd_resource_uncompress` 放进 `handle_rgba_blit` | `!ctx->in_blit` abort |
| 8 | u_blitter LINEAR→TILE，dest layout 仍当 LINEAR | ANGLE 按 LINEAR 读 TILE |
| 9 | dest discard 成 LINEAR 后再 A2D LINEAR→LINEAR | A2D 仍写 macrotile |
| 10 | 只把 4bpp 逼 LINEAR，FB_READ 仍强制 GMEM | destile 影子也被逼 LINEAR，失败后走 #4 |
| 11 | 所有色（含 R8 / fp16）都逼 LINEAR | 字全没。`506×187→512×256` 是 R8 图集 |
| 12 | destile 放进 tile IB 的 A2D，当时影子还是空的 | 不能在 emit 时 `fd_blitter_blit` |
| 13 | `DAGU_PRIMARY_ENTRY_PROBE=1` | 与 GPU 无关，开机即兔子 |

`should_force_linear()`（`linux-mainline/scripts/dagu-linear-mod.c`）曾想「小 BO 不要 LINEAR」，以免 event-store 写 macrotile。小 BO 改 TILE 而 ANGLE 仍 LINEAR 采样会更糟。窗口/scanout 必须真 LINEAR。

---

## 9. 为什么 destile「修不好」（稳定结论）

不是算力不够，不是 Mesa 不会 blur，不是「再改一个寄存器位就行」（至少 **还没有** 被证过的那一位）。

### 9.1 实机事实

1. Event-store → 专用 LINEAR FBO（无 FB fetch）= 补丁后 **真线性**（9.4.2）。
2. Event-store / GMEM 路径 → Chrome backdrop-filter（`FD_GMEM_FB_READ`）= **仍雪**（9.4.1）。
3. A2D，两端都 `TILE6_LINEAR` = 仍 macrotile。
4. A2D 在 `RM6_BIN_RESOLVE` = 乱 iova。
5. a6xx A2D **没有 window offset**：按整张 dest resolve，等于把 **一个 GMEM tile 铺满整张 BO**（见 `/tmp/mesa-26.0.8/src/gallium/drivers/freedreno/a6xx/fd6_blitter.h` 注释）。
6. 3D sysmem 写 LINEAR = 真线性（K、墙纸、绕开后的 A–H）。

因此：坏的是 **2D/event 的地址生成**，好的是 **3D 写 sysmem**。

### 9.2 blob 对照（2026-09-12，安卓 A 槽）

对照已经有了，完整过程：`linux-mainline/docs/dagu-vulkan-truth.md`。

官方 `vulkan.adreno.so` 在 `forcegmemstore` + 128 draws 下：

- 把 LINEAR color RT 送进 GMEM（`RM6_BIN_VISIBILITY` / `RM6_BIN_RESOLVE | USES_GMEM`）
- store 用 **`BLIT_EVENT_STORE_AND_CLEAR`**，不是 A2D/`CP_BLIT`
- `RB_RESOLVE_SYSTEM_BUFFER_INFO.TILE_MODE = TILE6_LINEAR`（无 UBWC `FLAGS`）
- CPU `vkMapMemory` 1024×1024 行主序 **match=1.0**

因此：**不是硬件不会写 LINEAR。** Mesa 的 event-store 已经标 `TILE6_LINEAR` 却仍落 macrotile，缺的是 blob 那条未抓全的 16 dword resolve IB（以及 window / 每 tile `RB_RESOLVE_CNTL_*` 是否和 Mesa 一致）。  
A2D 在 blob 这条路上只做 clear/copy。禁止再把 `fd6_resolve_linear_tile` 当正路。

下一阶段代号 **`dagu-event-store-heist`**：伪造 ICD + sphal hook + ptrace `kgsl_spy`，把 `CP_INDIRECT_BUFFER` 指向的 `0x500464060`（16 dword）抠出来再对拍 Mesa。任务书与跑法：`linux-mainline/docs/dagu-vulkan-truth.md` 第 9 节。桌面绕开在第 9.4 节五条绿之前不准撤。

**已抠出**（2026-09-12）：store IB 是 sysmem 描述 + `CNTL_0=0` + 全幅 `CNTL_1/2` + `CCU_RESOLVE`。IB1 的 OPERATION 是 `STORE_AND_CLEAR|CLEAR_MASK=0xf|LAST=2`。Mesa 活树已按此补并只部署到 `/usr/local/lib/dagu-mesa/`。其后 9.4.1/9.4.2 已齐，`DAGU_LINEAR_SYSMEM` 已从包装脚本撤掉（§9.5）。

### 9.3 影子路径为什么也没落地

正确思路：GMEM store 进 TILE 影子（event-store 对 TILE dest 是好的）→ 3D blit 到 LINEAR。

卡住的地方：

- blit 必须在 **各 tile 跑完之后**，影子里才有像素；不能在 emit 时调 `fd_blitter_blit`
- 放进 tile IB 的 A2D TILE→LINEAR：回到 9.1
- 4bpp 强制 LINEAR 时，影子 `resource_create` 也是 LINEAR，store 又坏
- `fd_dagu_set_force_tiled()` 是为影子准备的，**没有**在毛玻璃主路径上跑通验收

### 9.4 以后若有人声称 destile 修好了

必须同时满足，少一条都不算：

1. 探针 A–H 在 1.0 / 1.25 / 2.0 像 K，J 仍是条纹，字在，无雪
2. **刻意让一张 LINEAR 4bpp 走 GMEM**（临时关掉 sysmem 钩子），store 之后 CPU 或 LINEAR 采样读回的是行主序，不是 32px 砖
3. WebGL tiled FBO 仍 GMEM，无 hangcheck
4. gnome-shell **不要**开 `DAGU_LINEAR_SYSMEM`，主 fb 仍 XR24 LINEAR
5. 有 cmdstream / 寄存器记录：哪个 render mode、dest tile_mode、iova、pitch

只靠「看起来不花」而全部仍是 sysmem bypass，只是本绕开还在，不是 destile 修好。

#### 2026-09-12 heist 桌面实跑（未齐，绕开不撤）

补丁 so：`/usr/local/lib/dagu-mesa/libgallium-26.0.8-1ubuntu0.3.so`（现 md5 `0fe95f569fa6a5eaf2a3ed30625e7953`），只给 Chrome。`linux-mainline/scripts/dagu-chrome.sh` **不再** export `DAGU_LINEAR_SYSMEM`。

| 条 | 结果 | 证据 |
|----|------|------|
| 1 | **红**。`SYSMEM=0` `DESTILE=0`、完整 Ozone flag、DPR=1.0：A–H 雪花，J 锐利条纹，K 真霜，字在。未再扫 1.25 / 2.0（1.0 已否决撤绕开） | `linux-mainline/out/display-stress/glass-heist-sysmem0-1p000-full.png`。A 区 unique=6787 jump=0.277；`SYSMEM=1` 金样 A 区 unique=14083 jump=0.079 |
| 2 | **绿**。GBM LINEAR 1024×1024 mmap，`FD_MESA_DEBUG=gmem`，`using 4 bins of size 576x512`，`65536/65536` **TRUE_LINEAR**。第一版片元用 `x/255.0` 会在 x≥256 钳成 255，假读成「256×256 岛」，已改 `mod(x,256)` | `linux-mainline/tools/dagu-linear-gmem-probe.c`；平板 `/tmp/dagu-linear-gmem-probe` |
| 3 | **弱绿 / 未压满**。HUD `webgl=ok`；本轮 dmesg hangcheck 计数仍是开机留下的 10，**无新增** `00800005`。未单独重跑 tiled FBO 压测 | Chrome HUD；`dmesg` |
| 4 | **绿**。`gnome-shell` environ 无 `DAGU_*` / `dagu-mesa` / `libdagu-linear-mod.so`；主 fb 仍 KMS LINEAR | pid 39417 |
| 5 | **半绿**。安卓 blob `.rd` + Linux 探针 `4 bins 576x512`。Chrome 毛玻璃没有 `.rd`；`/tmp/dagu-gmem.log` 只在 `SYSMEM=1` 钩子里写，GMEM 路径无这条日志 | `linux-mainline/tools/dagu-vulkan-truth/out/captures/pass3-heist/` |

**2026-09-12 傍晚（fb-fetch-hunt）：** 9.4.1 在 `SYSMEM=0` 下已绿（当时 LINEAR+FB_READ 自动 sysmem）。9.4.2 store 仍绿。片上 GMEM FB fetch 随后在 §9.6 打通。真霜：`linux-mainline/out/display-stress/glass-fbread-sysmem0-full.png`。

### 9.5 代号 `dagu-fb-fetch-hunt`（2026-09-12，桌面完成）

阶段一定位（`FD_MESA_DEBUG` 没有 `draw`/`batch` 日志；`gmem` 只是强制 GMEM。真正锚点是 `/tmp/dagu-fb-hunt` → `/tmp/dagu-fb-hunt.log`，源码在 `/tmp/mesa-26.0.8/src/gallium/drivers/freedreno/freedreno_gmem.c`）：

| 观察 | 含义 |
|------|------|
| 毛玻璃条 `2496x416`：`fbread=0` `restore=0x4`（先 24/27 条） | **分支 A 发生在玻璃层**，但不是雪花的充分条件 |
| LINEAR 交换链 `2493x1568`：`tile=0` `restore=0x4` 63 条 | 墙纸仍锐利 → LINEAR restore **视觉上可用** |
| `fbread=1` 全是 `restore=0x0` 的小 FBO（512×256 / 2048×128） | **分支 B：同 pass FB fetch**，清屏后 3 个 draw |
| 关掉 `DAGU_LINEAR_SYSMEM` 后 4bpp 曾变成 `tile=3` | 布局强制误绑在 sysmem 钩子上；已拆开 |

阶段二已做：

1. **4bpp LINEAR 强制与 sysmem 绕开解耦**（`/tmp/mesa-26.0.8/src/gallium/drivers/freedreno/freedreno_resource.c`、`a6xx/fd6_blitter.cc`）。`SYSMEM=0` 时玻璃条变成 `tile=0`。
2. **Restore IB**：Linux mmap `1024×1024` 与 **`2496×416` 都是 PASS2 TRUE_LINEAR**（`restore=0x4`）。安卓 blob `loadOp=LOAD` IB 与 store 的 16 dword **相同**，只是 `RB_RESOLVE_OPERATION=0x203`（`BLIT_EVENT_LOAD|LAST=2`）。产物：`linux-mainline/tools/dagu-vulkan-truth/out/captures/pass4-fb-fetch/heist_spy_load.rd`。
3. **同 batch FB fetch**（`GL_EXT_shader_framebuffer_fetch`）：`SYSMEM=1` → `FETCH_OK`；`SYSMEM=0` GMEM → **`FETCH_BAD` match=0**。Chrome `SYSMEM=0` A–H 仍雪：`linux-mainline/out/display-stress/glass-fb-hunt-linearforce-sysmem0.png`。

PASS3 像素（`SYSMEM=0` `FD_MESA_DEBUG=gmem`，so md5 `36dadbdc…` 之后）：

| 尺寸 | 结果 |
|------|------|
| 512×256 单 bin | 整幅 `00 00 ff` = invert(清屏)。颜色在 CCU，GMEM bin 空。`gmem_base=0x100000` `cbuf=0` |
| 1024×1024 2×2 `bin=576x512` | store 仍 TRUE_LINEAR；fetch 花（bin 1.12MB > 1MB GMEM） |

`emit_mrt` 改 `TILE6_2`、`patch_fb_read_gmem` 改 `TILE6_LINEAR` 都救不了 512。  
因此 LINEAR+`FD_GMEM_FB_READ` **自动 sysmem**（`freedreno_gmem.c`，不看 `DAGU_LINEAR_SYSMEM`，`FD_MESA_DEBUG=gmem` 除外）。

| 验收 | 结果 |
|------|------|
| PASS3 `SYSMEM=0` 无 gmem debug | **FETCH_OK** 8192/8192 |
| Chrome `SYSMEM=0` 1.0 / 1.25 / 2.0 | A–H 真霜，J 条纹，K 真霜，字在 |
| hunt `fbread=1` | 62 条全 `sys=1` |
| hangcheck | 本轮计数仍为 2，扫 1.25/2.0 未增加 |

图：

- `linux-mainline/out/display-stress/glass-fbread-sysmem0-full.png`
- `linux-mainline/out/display-stress/glass-fbread-sysmem0-1p250-full.png`
- `linux-mainline/out/display-stress/glass-fbread-sysmem0-2p000-full.png`

`linux-mainline/scripts/dagu-chrome.sh` **已去掉** `export DAGU_LINEAR_SYSMEM=1`。片上 GMEM FB fetch 已在 §9.6 打通。

### 9.6 代号 `dagu-gmem-fbread-sync`（2026-09-12）

判决 **A**：官方 blob 在 LINEAR target 上用两个 Subpass（paint + `subpassLoad` invert）留在 GMEM，CPU 直读 `FETCH_OK`。

产物：

- 探针：`linux-mainline/tools/dagu-vulkan-truth/probe/probe.c` `--input-second`、`linux-mainline/tools/dagu-vulkan-truth/probe/shader_fetch.frag`、`linux-mainline/tools/dagu-vulkan-truth/probe/input_att.c`
- 抓包：`linux-mainline/tools/dagu-vulkan-truth/out/captures/pass5-input-att/`
- 像素：`linear_input.report.txt` invert 245760/245760 `FETCH_OK`
- cmdstream：`heist_spy_input.rd`；paint×128 与 fetch×1 之间只有 `PC_CCU_FLUSH_COLOR_TS` + `CACHE_INVALIDATE`，没有中途 STORE。收尾仍是 `STORE_AND_CLEAR` 16-dword event-store。
- Blob `TEX_CONST` @ `0x500466000`：`TILE6_2` `FMT6_8_8_8_8_UNORM` 1024×1024 pitch=1920（bin 480×4）`ARRAY_PITCH=480×512×4` `TILE_ALL` **base=0**

Mesa 对照（`/tmp/mesa-26.0.8`，只部署 dagu-mesa）：

| 试 | PASS3 512 | 含义 |
|----|-----------|------|
| 采样 `gmem_base+cbuf`（`0x100000`）+ `TILE6_2` | `00 00 ff` 或 destile 垃圾 `6f 2a b4` | UCHE 没打到 GMEM SRAM |
| 采样 `cbuf`（**0**）+ `TILE6_2` + bin pitch | **FETCH_OK** 8192/8192 | 与 blob 一致 |
| 无 `FD_MESA_DEBUG=gmem` 自动 bin | hunt `sys=0 fbread=1`，仍 **FETCH_OK** | 已撤 LINEAR+FB_READ sysmem 回退 |

`msm` 的 `gmem_base=0x100000` 是 RB resolve 窗口。a650 纹理单元读 GMEM 用 **bin 内偏移**（首个 color = 0）。TILE 的 sysmem RT 仍加 `gmem_base`。

`DAGU_LINEAR_DESTILE` 已从 `dagu-chrome.sh` / `dagu-mineradio.sh` / `rootfs-desktop-setup.sh` 的 Chrome/Mineradio 包装里撤掉。`dagu_destile_on()` 仍在 `fd6_gmem.cc`，env 不设就是关。event-store LINEAR 已够，不需要影子 destile。

Chrome 毛玻璃（无 `DAGU_LINEAR_SYSMEM` / `DAGU_LINEAR_DESTILE`，hunt `sys=0 fbread=1` 61 条）：A–H 真霜，J 条纹，K 真霜，`webgl=ok`。图：`linux-mainline/out/display-stress/glass-gmem-fbread-full.png`。

活 so md5：`9222c92152933e232f2bf302bd482b5d`（图集放行后；`/usr/local/lib/dagu-mesa/libgallium-26.0.8-1ubuntu0.3.so` 与 `linux-mainline/out/libgallium-26.0.8-1ubuntu0.3.so`）。4bpp 尺寸门：`linux-mainline/patches/mesa-26.0.8-atlas-passthrough.patch`。主线系列：`linux-mainline/patches/0001-freedreno-a6xx-fix-event-store-linear-layout.patch`、`linux-mainline/patches/0002-freedreno-a6xx-fix-gmem-fb-read-linear-base-offset.patch`。

### 9.7 代号 `dagu-ubwc-reclamation`（2026-09-12）

解开 Mutter `MUTTER_DEBUG_USE_KMS_MODIFIERS=1`（仍 `disable-direct-scanout`，仍不给 gnome-shell 灌 dagu-mesa / linear-mod）。

实机主 fb：`format=XR24` `modifier=0x050000000000001`（`QCOM_COMPRESSED`），BO `16777216`（LINEAR 是 `16384000`），DPU `sspp_8`+`sspp_9` 各 800×2560。gnome-shell 用发行版 `/usr/lib/aarch64-linux-gnu/libgallium-26.0.8-1ubuntu0.3.so`。

Chrome 仍 `LD_LIBRARY_PATH=/usr/local/lib/dagu-mesa` + `LD_PRELOAD=libdagu-linear-mod.so`。UBWC 桌面下 hunt：`sys=0 fbread=1` 68 条，`sys=1 fbread=1` 0 条。主 fb 仍是 COMPRESSED。

UBWC 之后 `grim` 的 `wlr-screencopy` 不可用；`linux-mainline/scripts/dagu-kms-land-crop.py` 按 LINEAR mmap 主 fb 会得到压缩噪声，不要当验收图。改走 `linux-mainline/scripts/dagu-gnome-screenshot.sh`（xdg-desktop-portal，Mutter 会 GL blit 成 LINEAR）。回退：平板 `/root/dagu-ubwc-revert.sh`（`USE=0` + `systemctl restart gdm`）。

hangcheck 现场：`linux-mainline/scripts/dagu-gpu-hangwatch.sh --host`（平板 `/usr/local/sbin/dagu-gpu-hangwatch.sh`）。未 hang 时 `hangrd` 是 `EBUSY`。35s 压测（`linux-mainline/scripts/dagu-gpu-stress.sh`）未增加 recover。

---

## 10. 复现与日志

不要 `systemctl reboot`、不要刷机，除非题目要求。

唤醒（必须用 **dagu** 的 session bus）：

```text
PowerSaveMode=0
ScreenSaver.SetActive(false)
ApplyMonitorsConfig：6 元组，transform=3，mode 1600x2560@120.000
```

开探针：

```bash
KEY=linux-mainline/out/id_dagu
ssh -i "$KEY" -o StrictHostKeyChecking=no root@192.168.7.2
# 平板上：
pkill -u dagu chrome || true
rm -f /home/dagu/.config/google-chrome/SingletonLock \
      /home/dagu/.config/google-chrome/SingletonSocket \
      /home/dagu/.config/google-chrome/SingletonCookie
touch /tmp/dagu-gmem-enable /tmp/dagu-blit-enable /tmp/dagu-tile-log
sudo -u dagu env XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY=wayland-0 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \
  /usr/local/bin/dagu-chrome --new-window file:///home/dagu/dagu-glass-probe.html
# 等绘制后：
# 主 fb 已是 UBWC：不要再用 KMS mmap 当验收图。
# touch /tmp/dagu-fb-hunt 之后看 /tmp/dagu-fb-hunt.log
# 或：
python3 /usr/local/sbin/dagu-glass-sweep.py
```

日志闸（进程起来之后 `touch`，看 `/tmp/dagu-*.log`）：

| 闸文件 | 日志 |
|--------|------|
| `/tmp/dagu-gmem-enable` | `/tmp/dagu-gmem.log`：`sys= fbread= r= WxH fmt=` |
| `/tmp/dagu-blit-enable` | `/tmp/dagu-blit.log`：`skip-a2d-linear` / `u_blitter` / `copy_region` |
| `/tmp/dagu-tile-log` | `/tmp/dagu-tile.log`：`force-linear` / `alloc layout=` |

绕开正常时可见：

```text
sys=1 fbread=1 r=20 2496x416 zs=0 draws=7 fmt=b8g8r8a8_unorm
sys=1 fbread=1 r=20 512x256 zs=0 draws=3 fmt=r8g8b8a8_unorm
```

`sys=0 fbread=1` 出现在 LINEAR 玻璃上，就是走修好的 GMEM fetch（现在是绿）。`sys=1 fbread=1` 才是旧绕开。

确认加载的是 dagu-mesa：

```text
grep dagu-mesa /proc/$(pgrep -n -u dagu chrome)/maps
# 不应再有 DAGU_LINEAR_SYSMEM；玻璃 hunt 里应是 sys=0 fbread=1
```

---

## 11. 构建与部署（只覆盖 dagu-mesa）

```bash
ninja -C /tmp/mesa-dagu-build src/gallium/targets/dri/libgallium-26.0.8.so
DEST=linux-mainline/out/libgallium-26.0.8-1ubuntu0.3.so
cp /tmp/mesa-dagu-build/src/gallium/targets/dri/libgallium-26.0.8.so "$DEST"
aarch64-linux-gnu-strip --strip-unneeded "$DEST"
# SONAME 必须是 libgallium-26.0.8-1ubuntu0.3.so
```

`pkill` Chrome 后再 `install` 到 `/usr/local/lib/dagu-mesa/`。  
**不要**覆盖 `/usr/lib/aarch64-linux-gnu/libgallium-26.0.8-1ubuntu0.3.so`（gnome-shell 用发行版 Mesa）。

交叉文件：`/tmp/dagu-aarch64-cross.ini`，sysroot `/tmp/dagu-sysroot`。

---

## 12. 文件索引

| 路径 | 角色 |
|------|------|
| `linux-mainline/docs/dagu-a650-linear-destile.md` | 本文 |
| `linux-mainline/docs/dagu-adaptation-status.md` | 总表摘要 |
| `linux-mainline/docs/dagu-wifi-gpu-turnip-cpu.md` | GPU 总览（细节以本文为准） |
| `linux-mainline/patches/mesa-26.0.8-linear-sysmem.patch` | 钩子说明（非完整 diff） |
| `linux-mainline/patches/0001-freedreno-a6xx-fix-event-store-linear-layout.patch` | 相对原版 26.0.8 的 event-store 正式补丁 |
| `linux-mainline/patches/0002-freedreno-a6xx-fix-gmem-fb-read-linear-base-offset.patch` | 相对原版 26.0.8 的 UCHE cbuf 正式补丁 |
| `linux-mainline/patches/mesa-26.0.8-a650-event-store-last.patch` | heist 说明（非正式 diff） |
| `linux-mainline/patches/mesa-26.0.8-gmem-fbread-sync.patch` | UCHE 说明（非正式 diff） |
| `linux-mainline/scripts/dagu-gpu-hangwatch.sh` | hangcheck → `/var/log/dagu-gpu/*.rd` |
| `linux-mainline/scripts/dagu-gpu-stress.sh` | 多玻璃窗 + 可选 videotestsrc |
| `linux-mainline/scripts/dagu-gnome-screenshot.sh` | UBWC 下 portal 截图（Mutter GL blit） |
| `linux-mainline/tools/dagu-linear-gmem-probe.c` | 9.4.2 GBM LINEAR mmap 探针 |
| `linux-mainline/patches/mesa-26.0.8-linear-cbuf-sysmem.patch` | 更早的 LINEAR cbuf 说明 |
| `linux-mainline/patches/mesa-26.0.8-tex-seqno-rebuild.patch` | layout 变了要重建采样器 |
| `/tmp/mesa-26.0.8/src/gallium/drivers/freedreno/freedreno_gmem.c` | LINEAR+FB_READ → sysmem；`DAGU_LINEAR_SYSMEM=1` 仍绕开全部 LINEAR |
| `/tmp/mesa-26.0.8/src/gallium/drivers/freedreno/freedreno_resource.c` | 4bpp LINEAR；`fd_dagu_set_force_tiled` |
| `/tmp/mesa-26.0.8/src/gallium/drivers/freedreno/a6xx/fd6_gmem.cc` | `patch_fb_read_sysmem`；destile 阴影；关掉 A2D resolve |
| `/tmp/mesa-26.0.8/src/gallium/drivers/freedreno/a6xx/fd6_blitter.cc` | 跳过 LINEAR A2D；`fd6_resolve_linear_tile` |
| `/tmp/mesa-26.0.8/src/gallium/drivers/freedreno/a6xx/fd6_blitter.h` | A2D 无 window offset |
| `/tmp/mesa-26.0.8/src/gallium/drivers/freedreno/a6xx/fd6_emit.cc` | fb_read 前 CCU flush |
| `/tmp/mesa-26.0.8/src/gallium/drivers/freedreno/freedreno_blitter.c` | u_blitter / copy_region 日志 |
| `linux-mainline/scripts/dagu-linear-mod.c` | GBM/EGL 合同 |
| `linux-mainline/scripts/dagu-chrome.sh` | Chrome 包装 |
| `linux-mainline/scripts/dagu-mineradio.sh` | Mineradio 包装 |
| `linux-mainline/scripts/rootfs-desktop-setup.sh` | 装进 rootfs 的同一套 |
| `linux-mainline/scripts/dagu-glass-probe.html` | 验收页 |
| `linux-mainline/scripts/dagu-glass-sweep.py` | 多缩放裁剪 |
| `linux-mainline/scripts/dagu-kms-land-crop.py` | 270° KMS → 横屏 PNG |
| `linux-mainline/scripts/patch-mineradio-electron.py` | Electron 侧不要 `notile` |
| `linux-mainline/out/display-stress/glass-*.png` | 验收图 |
| `linux-mainline/docs/dagu-vulkan-truth.md` | 安卓 blob GMEM→LINEAR 探底 |
| `linux-mainline/tools/dagu-vulkan-truth/` | 探针 / QGL 配置 / 解码脚本 |

---

## 13. 和字体 / 缩放问题的边界

同一次适配里还有、但**不是** destile：

- 270° 扫出上 LCD RGB 在逻辑横屏是错轴 → 必须灰度 AA（`--disable-lcd-text` 等）
- 关掉 `WaylandFractionalScaleV1` 后 Chrome 按整数 DPR 栅格、mutter 再缩放 → 1.25「乱码」
- 字体花、界面不花：曾经也是 LINEAR 被 event-store 写成 macrotile；大色块还能认

毛玻璃探针上「字全没、盒子还在」= R8 图集被逼 LINEAR，回到第 8 节 #11，不要当新花屏。

---

## 14. 修订

| 日期 | 内容 |
|------|------|
| 2026-09-12 | 首版。探针 A–H/K 真霜，J 条纹，webgl=ok，无 hangcheck。结论：sysmem 绕开；GMEM→LINEAR destile 未打通。 |
| 2026-09-12 | 安卓 blob 探底：硬件能 event-store 进真 LINEAR。桌面仍走绕开。见 `linux-mainline/docs/dagu-vulkan-truth.md`。 |
| 2026-09-12 | 开 `dagu-event-store-heist`，目标捕获幽灵 resolve IB。见 `linux-mainline/docs/dagu-vulkan-truth.md` 第 9 节。 |
| 2026-09-12 | 16 dword 已捕获并对拍；Mesa 补 LAST/STORE_AND_CLEAR。9.4 未跑，绕开未撤。 |
| 2026-09-12 | 9.4 实跑：9.4.2 专用 FBO GMEM store 真线性；9.4.1 Chrome 毛玻璃 `SYSMEM=0` A–H 雪。绕开不撤。 |
| 2026-09-12 | `dagu-fb-fetch-hunt`：restore/LOAD 已绿；同 batch GMEM FB fetch 仍红。见 §9.5。 |
| 2026-09-12 | LINEAR+FB_READ 自动 sysmem。Chrome `SYSMEM=0` 1.0/1.25/2.0 真霜。已从 `dagu-chrome.sh` 拔掉 `DAGU_LINEAR_SYSMEM`。 |
| 2026-09-12 | `dagu-gmem-fbread-sync`：blob 判决 A。UCHE 读 GMEM 用偏移 0。PASS3 GMEM `FETCH_OK`。已撤 FB_READ sysmem 回退和 `DAGU_LINEAR_DESTILE`。 |
| 2026-09-12 | `dagu-ubwc-reclamation`：Mutter `USE=1`，主 fb `QCOM_COMPRESSED`，Chrome LINEAR GMEM 仍 `sys=0 fbread=1`。正式 patchset 0001/0002。 |
| 2026-09-12 | 图集放行：`dagu-linear-mod.c` 对 R8 / ≤1024² 原样传递，Wayland 长条仍 LINEAR。dagu-mesa 4bpp 只在宽**和**高都 >1024 时动手（躲开 Skia `3840×360`）。补丁 `linux-mainline/patches/mesa-26.0.8-atlas-passthrough.patch`。 |
| 2026-09-13 | **撕花屏合同**。official-152 `gbm_bo_get_modifier()` 已报 `QCOM_COMPRESSED`。卸 `libdagu-linear-mod.so` 后窗口 2477×1560 stride=9984 为 UBWC，CDP 大字可读。Turnip `--use-angle=vulkan`：`chrome://gpu` Vulkan=Enabled，WebGL Turnip a650，H.264 仍 `/dev/video14` irq=443。Mutter 去掉 `disable-direct-scanout`，主 fb 仍 UBWC；270° 最大化窗还没有第二块 DPU plane。包装 `linux-mainline/scripts/dagu-chromium-native.sh`，探针 `linux-mainline/scripts/dagu-ubwc-reclaim-probe.sh`。 |
