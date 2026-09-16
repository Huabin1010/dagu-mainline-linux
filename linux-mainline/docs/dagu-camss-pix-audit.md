# SM8250 CAMSS VFE PIX audit (dagu)

Date: 2026-09-16.  
Tree: `linux-mainline/linux/drivers/media/platform/qcom/camss/` (live compile tree, not committed).  
Question: can Viewfinder leave `DebayerCpu` and take IFE PIX NV12 on this SoC?

## Verdict: no-go

Mainline `qcom-camss` on SM8250 is **CSIPHY + CSID + VFE RDI** (RAW dump to memory). There is **no product PIX/ISP path** that writes YUV/NV12. Android preview IFE 3A/3DNR is CamX, not a Kconfig.

Do **not** okay `&cdsp` to “fix” this. Hexagon cannot replace IFE. Keep rear D-PHY `0x0114=0x0300` skip 4×4 and front skip 2×2.

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

A later mainline `vfe_ops` that programs IFE PIX NV12 **without** CamX, proven on this board with skip-aligned full FOV, would reopen the PIX path. Until then this note is the go/no-go record.
