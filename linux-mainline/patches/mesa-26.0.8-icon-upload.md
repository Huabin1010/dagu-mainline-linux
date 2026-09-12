# dagu-mesa：Chrome 矢量 icon / 标签条花屏（2026-09-12）

活树：`/tmp/mesa-26.0.8`  
装到：`/usr/local/lib/dagu-mesa/libgallium-26.0.8-1ubuntu0.3.so`  
包装：`linux-mainline/scripts/dagu-chrome.sh` → `/usr/local/bin/dagu-chrome`  
仓库副本：`linux-mainline/out/libgallium-26.0.8-1ubuntu0.3.so`  
不要覆盖发行版 Mesa。不要把 dagu-mesa 放进 gnome-shell。

## 根因

页内 SVG / iconfont / 标签条矢量走 **Skia GPU raster**。a650 把这些路径画进 LINEAR 图集时写入仍是 macrotile，ANGLE 按 LINEAR 采 → 花砖。

对照：

- CPU `glTexSubImage` 的头像 / 关闭叉 / 刷新一直锐利
- 页内汉字（「下载客户端」）走 R8 TILE 字形图集，一直锐利
- `--disable-gpu-rasterization` 后矢量改走 CPU 栅格再上传，首页小电视、下载箭头、搜索放大镜、登录气泡标全部锐利

8× 金样：`linux-mainline/out/display-stress/chrome-cpuras-shouye-8x.png`、`linux-mainline/out/display-stress/chrome-cpuras-dl-8x.png`

## 现用修复

`linux-mainline/scripts/dagu-chrome.sh` 增加 `--disable-gpu-rasterization`。只影响 Chrome，不进 gnome-shell。合成 / WebGL / 大窗 LINEAR GMEM destile 仍开。

## Mesa 侧仍保留（不要回退）

- `fd_dagu_is_icon_atlas()`：小 RGBA / 短宽条走 LINEAR，staging 先于 icon 钩子
- 禁止把 `PIPE_USAGE_STAGING` 标 TILE
- 短 LINEAR（icon_atlas 或 `height<=128`，含 `1819×89` 标签条）强制 GMEM event-store `LAST=2`，不要再走 sysmem
- dest 任一边 ≤512 或任一端 LINEAR：跳过 A2D

## 不要再试

- 无差别 4bpp / GBM 全 LINEAR
- ≤1024 一律 UBWC（`832×576` 绿块）
- 把 icon 图集逼 TILE + `fdl6_memcpy`（采样器仍按 LINEAR，只改砖纹）
- 全局 `DAGU_LINEAR_SYSMEM=1` / `DAGU_LINEAR_DESTILE=1`
- 用软件栅格「修」毛玻璃（那是另一条合同）
