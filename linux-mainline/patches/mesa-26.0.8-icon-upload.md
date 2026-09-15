# dagu-mesa：Chrome GPU 画 SVG（2026-09-12）

活树：`/tmp/mesa-26.0.8`  
装到：`/usr/local/lib/dagu-mesa/libgallium-26.0.8-1ubuntu0.3.so`  
包装：`linux-mainline/scripts/dagu-chrome.sh` → `/usr/local/bin/dagu-chrome`  
**GPU raster 必须开。** 禁止 `--disable-gpu-rasterization`（CPU 画 tile 滚动不跟手）。

## 合同

- 窗口 / Wayland 长条：真 LINEAR（GBM + event-store `LAST=2`）
- Chrome 窗口（`2477×1560` LINEAR）：**不要**强制 GMEM。拖动时每一帧 15 个 bin 会掉帧。合成走 sysmem。
- Skia OOP raster tile（两边 128–1024 的 4bpp，非 scanout / staging）：**TILE6_3**，不要 UBWC，也不要因为 `BIND_LINEAR` 改 LINEAR
- **Chrome Views 矢量 icon（≤128²，后退/前进/刷新/网站设置/标签关闭）**：真 **LINEAR + GMEM**。TILE destile 是锐利箭头（`linux-mainline/out/display-stress/ui-icons/dagu-icon-gmem-tile-25x25-4-10x.png`），按 LINEAR 读就是工具栏乱码。Chrome 采样这些 cache 当 LINEAR。
- **A8 path atlas**（Chrome 153 / Skia `4f574af` `AtlasPathRenderer`）：GPU 用 instanced `MiddleOutShader` 三角形画进 A8（不是 GL TCS/TES）。收 **TILE6_3**，禁止 UBWC；**禁止 autotune sysmem**（CCU 把 TILE 写成行主序条纹）。dump：`linux-mainline/out/display-stress/path-atlas/dagu-path-gmem-tile-512x256-2.png` 是真胶囊/叉/箭头。源码 `a local Chromium checkout/`。活树 `/tmp/mesa-26.0.8/src/gallium/drivers/freedreno/freedreno_gmem.c`。
- staging：LINEAR（CPU `glTexSubImage`）
- 宽 UI 条（1981×40 / 2240×64）：LINEAR + GMEM
- R8 字形（CPU 上传的 2048²）：TILE
- 不要进 gnome-shell

## 不要再试

- 关 GPU 栅格「修」icon
- ≤1024 一律 UBWC（曾把 `832×576` 打绿）
- 把 staging 标 TILE
- 全局 `DAGU_LINEAR_SYSMEM` / `DAGU_LINEAR_DESTILE`
