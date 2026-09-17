# SM8250 CAMSS VFE PIX audit (dagu)

Date: 2026-09-17.  
Tree: `linux-mainline/overlays/linux/drivers/media/platform/qcom/camss/camss-vfe-480.c` (applied onto the live compile tree).  
Question: can Viewfinder leave `DebayerCpu` and take IFE PIX NV12 on this SoC?

## Verdict: PIX writes linear NV12; Viewfinder still SoftISP

Overlay `vfe_ops_480` programs CSID IPP, CAMIF, CLC, and BUS DISP WM4/5 linear NV12 on **IFE1**. B-slot `#365` STREAMON yields **≥3 nonzero** `/tmp/pix.nv12` frames, UV origin ~133, chroma packer `PLAIN_8`. Saturation is still narrow. Product preview stays RDI + `DebayerCpu` until Viewfinder switches.

Live status: `linux-mainline/docs/dagu-ife-pipeline-status.md`.  
Attempt log: `linux-mainline/docs/dagu-ife-pix-nv12-attempts.md`.

HyperOS rear preview on 53dcc70 (Magisk, 2026-09-16) already runs **Titan 480 IFE PIX**, not CPU SoftISP:

- VFE1 CAMIF ver3 SOF/EOF/EPOCH (`reg_update` `0x41` @ `0x34`)
- BUS WM4/WM5 **DISP Y/C** `en_cfg=0x1` **1920×1080 UBWC NV12** (Linux product path is linear packer 3, not UBWC `0xB`)
- WM23 RDI0 stays on for ZSL RAW
- CSID1 + IFE1 IRQs live; IFE0 idle
- CamX graph `RealTimeFeatureZSLPreviewRaw` (IFE + IPE)

Dump: `dumps/dagu-android-live/camera-ife-20260916/INDEX.txt`. HyperOS `/dev/mem` is `STRICT_DEVMEM`; CLC offsets come from `camera.qcom.so` PackIQ / CreateCmdList, not from an IFE MMIO dump.

Do **not** okay `&cdsp` to “fix” this. Hexagon cannot replace IFE. Keep rear D-PHY `0x0114=0x0300` skip 4×4 and front skip 2×2 until Linux PIX NV12 is proven. Do **not** `STREAMON` PIX with BUS DISP alone — missing CLC hangs CAMNOC.

## Flight preview until the gate

| Path | Status |
|------|--------|
| Viewfinder DebayerCpu skip 4×4 / 2×2 | **Flight-qualified preview**, not a temporary flag |
| libcamera GPU EGL SoftISP | **Forbidden** — `configuration.yaml` notes EGL ignores skip |
| CamX blob / `-Dipmbs` | **Forbidden** as a deliverable |
| `&cdsp` for “AI denoise” | **Forbidden** without PIX evidence and a real workload |

Gate: STREAMON ≥3 non-zero NV12 frames, `r0114=0x300`, `g_serial` `0525:a4a7` >30s. Until then do not switch Viewfinder off SoftISP.

## SLPI + CDSP

`stage-firmware.sh` stages dagu-signed `slpi.mbn` and `cdsp.mbn`. Product DT okays both. Clients: `dagu-ssc` (SEE QMI) and `dagu-cdsp-rpc` (FastRPC). Do not guess LSM6DSO on AP I2C. Do not okay CDSP to “fix” IFE. WebNN stays off.

## Revisit trigger

Proven on B slot: NV12 frames, skip-aligned full FOV, `g_serial` `0525:a4a7` >30s, CSID SOT still masked. The overlay already programs IPP / CAMIF / CLC / WM4/5; the remaining stall is documented in the attempts log, not “PIX missing from `line_num`”.
