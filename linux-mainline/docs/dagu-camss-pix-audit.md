# SM8250 CAMSS VFE PIX audit (dagu)

Date: 2026-09-16.  
Tree: `linux-mainline/linux/drivers/media/platform/qcom/camss/` (live compile tree, not committed).  
Question: can Viewfinder leave `DebayerCpu` and take IFE PIX NV12 on this SoC?

## Verdict: Linux no-go (Android PIX is proven)

Mainline `qcom-camss` on SM8250 is still **CSIPHY + CSID + VFE RDI** only. That is a Linux gap, not a hardware gap.

HyperOS rear preview on 53dcc70 (Magisk, 2026-09-16) runs **Titan 480 IFE PIX**, not CPU SoftISP:

- VFE1 CAMIF ver3 SOF/EOF/EPOCH (`reg_update` `0x41` @ `0x34`)
- BUS WM4/WM5 **DISP Y/C** `en_cfg=0x1` (`MODE_QCOM_PLAIN`) **1920×1080 / 1920×540 UBWC**
- WM23 RDI0 stays on for ZSL RAW (`en_cfg=0x10001` `MODE_MIPI_RAW`)
- CSID1 + IFE1 IRQs live; IFE0 idle
- CamX graph name `RealTimeFeatureZSLPreviewRaw` (IFE + IPE). `com.qti.feature2.softispprocess.so` is on the filesystem and is not this path

Dump: `dumps/dagu-android-live/camera-ife-20260916/INDEX.txt`. `/dev/mem` MMIO is `STRICT_DEVMEM` ENODEV; CLC (demux/demosaic/MNDS21) is still CamX CDM, not a kernel table.

Do **not** okay `&cdsp` to “fix” this. Hexagon cannot replace IFE. Keep rear D-PHY `0x0114=0x0300` skip 4×4 and front skip 2×2 until Linux PIX NV12 is proven. Do **not** `STREAMON` PIX with BUS DISP alone — missing CLC hangs CAMNOC.

## Evidence in the live tree

`camss-vfe-480.c` is the SM8250 VFE ops (`vfe_ops_480`). Write-master start programs **MIPI RAW only**:

```c
writel_relaxed(1 << WM_CFG_EN | MODE_MIPI_RAW << WM_CFG_MODE,
               vfe->base + VFE_BUS_WM_CFG(wm));
```

WM index is `RDI_WM(wm)`. IRQ enable is `BUS_IRQ_MASK_0_RDI_RUP`. There is no PIX WM, no YUV packer, no IFE 3A stats node.

`enum vfe_line_id` has `VFE_LINE_PIX = 3`. SM8250 VFE0/VFE1 set `line_num = 3` in `vfe_res_8250`, so the init loop

```c
for (i = VFE_LINE_RDI0; i < vfe->res->line_num; i++)
```

creates **RDI0–RDI2 only**. PIX is never instantiated on the full IFEs.

`formats_pix = &vfe_formats_pix_845` is copied in the resource table. That is a leftover from the SM845 table, not a working ISP pipeline. `vfe_ops_480` never programs those formats onto a PIX master.

VFE lite uses `line_num = 4` (would allocate a PIX subdev) but still the same `vfe_ops_480` RAW WM programming. Not a YUV product path.

Overlay CAMSS in this repo does not add PIX.

## What this means for SoftISP

| Path | Status |
|------|--------|
| Viewfinder DebayerCpu skip 4×4 / 2×2 | **Flight-qualified preview**, not a temporary flag |
| libcamera GPU EGL SoftISP | **Forbidden** — `configuration.yaml` notes EGL ignores skip |
| CamX blob / `-Dipmbs` | **Forbidden** as a deliverable |
| `&cdsp` for “AI denoise” | **Forbidden** without PIX evidence and a real workload |

## SLPI (before CDSP)

`stage-firmware.sh` already stages `slpi.mbn`. `&slpi` stays `status = "disabled"` until:

1. `qcom_scm_pas_auth_and_reset` succeeds on this QHEE
2. `remoteproc` is `running` with no SSR
3. `g_serial` `0525:a4a7` still up >30s
4. A mainline SSC/QMI / IIO client exists

No client → do not leave the DSP okay “because it is running”. Do not guess LSM6DSO on AP I2C. Hall already is gpio-keys (`SW_LID` / `SW_TABLET_MODE`).

## CDSP

Default remains `status = "disabled"`. Open only when PAS auth works **and** there is a userspace workload that is not an empty remoteproc. Do not enable it as a side effect of Venus or ICC. WebNN / TFLite Hexagon is not a tablet deliverable.

## Revisit trigger

Linux `vfe_ops_480` must program, without CamX blobs:

1. CSID1 IPP (`pxl_cfg0` `0x200`, D-PHY 4-lane, no C-PHY)
2. CAMIF `0x2660` + `reg_update` `0x41`
3. CLC demux13 + demosaic34 + MNDS21 to 1920×1080 (offsets still from dump/reverse, not guessed)
4. BUS WM4/WM5 DISP Y/C **linear** NV12 (`en_cfg=0x1`, no UBWC)

Proven on B slot: NV12 frames, skip-aligned full FOV, `g_serial` `0525:a4a7` >30s, CSID SOT still masked. Until then DebayerCpu remains the flight preview.
