# Provenance

Local copies of Qualcomm **public** camera chapters and upstream kernel
CAMSS docs. Fetched 2026-09-19 from `docs.qualcomm.com` markdown:

```
https://docs.qualcomm.com/bundle/publicresource/{document-id}/topics/{topic-name}.md
```

HTML `/doc/{id}/topic/` is a JavaScript chrome shell. Extract
`data:image/png;base64` (and webp) into `images/`.

Refresh: `python3 linux-mainline/scripts/dagu-fetch-qcom-public-docs.py`

These are architecture / bring-up / V4L2 chapters, **not** a Titan 480
software interface (software interface，软件接口手册).

## Archived

| File | Public HTML | Notes |
|---|---|---|
| `80-PV086-5P-camera-support.md` | https://docs.qualcomm.com/doc/80-PV086-5P/topic/camera-support.html | 2023-07-07 |
| `80-PV086-5P-dphy-routing.md` | https://docs.qualcomm.com/doc/80-PV086-5P/topic/mipi-csi-d-phy-routing-constraints-up-to-2dot5-Gbps.html | PCB D-PHY |
| `80-88500-1-sensor-driver.md` | https://docs.qualcomm.com/doc/80-88500-1/topic/58_Camera_sensor_driver_.html | TOC |
| `80-88500-1-sensor-bringup.md` | https://docs.qualcomm.com/doc/80-88500-1/topic/camera_sensor_driver_bringup.html | |
| `80-88500-1-sensor-software.md` | https://docs.qualcomm.com/doc/80-88500-1/topic/59_Sensor_software_configuration.html | |
| `80-88500-1-sensor-info-nodes.md` | https://docs.qualcomm.com/doc/80-88500-1/topic/60_Sensor_information_nodes.html | settleTimeNs / Is3Phase |
| `80-88500-1-module-config.md` | https://docs.qualcomm.com/doc/80-88500-1/topic/61_Module_configuration_.html | laneAssign |
| `80-88500-1-sensor-hw.md` | https://docs.qualcomm.com/doc/80-88500-1/topic/62_Sensor_hardware_configuration.html | TOC |
| `80-88500-1-sensor-kernel-nodes.md` | https://docs.qualcomm.com/doc/80-88500-1/topic/63_Sensor_kernel_nodes.html | DTSI |
| `80-88500-1-cci-timing.md` | https://docs.qualcomm.com/doc/80-88500-1/topic/64_CCI_timing_and_debug.html | |
| `80-88500-1-cci-speed.md` | https://docs.qualcomm.com/doc/80-88500-1/topic/65_Configure_CCI_operation_speed.html | |
| `80-88500-1-ife-clock.md` | https://docs.qualcomm.com/doc/80-88500-1/topic/68_Camera_IFE_clock_configuration.html | |
| `80-88500-1-power-regulator.md` | https://docs.qualcomm.com/doc/80-88500-1/topic/69_Power_regulator_configuration.html | |
| `80-88500-1-clock.md` | https://docs.qualcomm.com/doc/80-88500-1/topic/70_Clock_configuration.html | MCLK |
| `80-88500-1-cci-master.md` | https://docs.qualcomm.com/doc/80-88500-1/topic/71_CCI_master_index_configuration.html | CCI0/1 map |
| `80-88500-1-cam-res-mgr.md` | https://docs.qualcomm.com/doc/80-88500-1/topic/72_Camera_resource_manager_configuration.html | |
| `80-88500-1-sensor-library.md` | https://docs.qualcomm.com/doc/80-88500-1/topic/73_Sensor_library_configuration.html | |
| `80-88500-4-camera.md` | https://docs.qualcomm.com/doc/80-88500-4/topic/122_Camera.html | QMMF stack |
| `80-88500-4-capture-encode.md` | https://docs.qualcomm.com/doc/80-88500-4/topic/123_Camera_capture_and_encode.html | RB5 sensors |
| `80-88500-4-spectra-480.md` | https://docs.qualcomm.com/doc/80-88500-4/topic/124_Qualcomm_Spectra_480.html | |
| `80-88500-4-isp-tuning.md` | https://docs.qualcomm.com/doc/80-88500-4/topic/125_ISP_tuning_process.html | after bringup |
| `80-88500-4-chi.md` | https://docs.qualcomm.com/doc/80-88500-4/topic/126_CHI.html | |
| `80-88500-4-chi-architecture.md` | https://docs.qualcomm.com/doc/80-88500-4/topic/127_CHI_architecture_model.html | |
| `80-88500-4-topology-xml.md` | https://docs.qualcomm.com/doc/80-88500-4/topic/128_Topology_graph_XML.html | |
| `80-88500-4-camx.md` | https://docs.qualcomm.com/doc/80-88500-4/topic/129_CamX.html | |
| `80-70015-17-v4l2.md` | https://docs.qualcomm.com/doc/80-70015-17/topic/v4l2_interface.html | upstream CamSS |
| `80-70020-17-camera-overview.md` | https://docs.qualcomm.com/doc/80-70020-17/topic/camera-overview.html | CamSS vs QMMF |
| `80-70020-17-stream-cameras.md` | https://docs.qualcomm.com/doc/80-70020-17/topic/stream-cameras.html | media-ctl |
| `80-70030-17-troubleshoot.md` | https://docs.qualcomm.com/doc/80-70030-17/topic/troubleshooting.html | CSID IRQ mask |
| `kernel-qcom-camss.html` | https://www.kernel.org/doc/html/latest/admin-guide/media/qcom_camss.html | 8x16/8x96 |
| `qcom-sm8250-camss.yaml` | kernel `Documentation/devicetree/bindings/media/qcom,sm8250-camss.yaml` | SM8250 clocks |
| `80-80022-17-stream-cameras.md` | https://docs.qualcomm.com/doc/80-80022-17/topic/stream-cameras.html | 2026-05-26 excerpt: V4L2（Video for Linux 2，Linux 视频接口）CAMSS（Camera Subsystem，相机子系统）is raw dump only. Full page is QCS GStreamer; not auto-fetched |
| `80-70022-17-offline-ife.md` | https://docs.qualcomm.com/doc/80-70022-17/topic/support-multi-camera-using-offline-IFE.html | QCS9075 Lite→DDR→offline IFE（Image Front End，图像前端）. Not dagu PIX（Pixel path，像素通路） dest |
| `80-88500-3-ubwc.md` | https://docs.qualcomm.com/doc/80-88500-3/topic/61_UBWC_control_use_cases.html | QMMF（Qualcomm Multimedia Framework，高通多媒体框架）UBWC（Universal Bandwidth Compression，高通带宽压缩）. Forbidden as Linux linear dest |
| `cam_isp_ife.h` | https://github.com/StatiXOS/android_hardware_qcom-caf_kernel-headers/blob/f2c161d0372a939ef5598ba254f815be8dcf145a/msm-4.19/media/cam_isp_ife.h | `CAM_ISP_IFE_OUT_RES_FULL_DISP` = base+19 |
| `cam_vfe_bus_ver3.c` | https://github.com/LineageOS/android_kernel_xiaomi_sm8250/blob/lineage-18.1/techpack/camera/drivers/cam_isp/isp_hw_mgr/isp_hw/vfe_hw/vfe_bus/cam_vfe_bus_ver3.c | CAF SM8250: WM（Write Master，AXI 写通道）4-5 = FULL_DISP; NV12（YUV 4:2:0 semi-planar，半平面亮度/色度）packer PLAIN_8_LSB_MSB_10; IMAGE_CFG_1 = h_init; chroma height/2 |

## Still missing for chroma 1984 (not on the public web)

Linux Display Full writes 4591616 / 4593600 (last chroma line 336 of 2320).
Public chapters and CAF `cam_vfe_bus_ver3.c` do **not** document that remainder.

| What would close it | Status |
|---|---|
| Titan 480 SWI（Software Interface，软件接口手册） / `viol_id` / Crop 9-word / WM（Write Master，AXI 写通道）FRAME_INCR vs last chroma line | Never published |
| CamX（Camera eXtension，高通相机用户态框架）`camxifehw.cpp` / titan480 `CreateCmdList` source | Proprietary (`camera.qcom.so`); overlay already reversed live CDM（Camera Data Mover，相机命令搬运器） |
| HyperOS **linear** Display Full WM（Write Master，AXI 写通道）4/5 dump (compressor off, dest 2320×1320) | Camera ID 1 live is UBWC（Universal Bandwidth Compression，高通带宽压缩）identity 2592 for IPE（Image Processing Engine，图像处理引擎）. Heap packet 2 has Crop/MNDS（MN Down Scaler，M/N 下采样器） dest, not a linear AXI（Advanced eXtensible Interface，高级可扩展接口） image |
| CamX（Camera eXtension，高通相机用户态框架）`autoImageDumpIFEoutputPortMask IFEOutputPortDisplayFull=0x400000` NV12（YUV 4:2:0 semi-planar，半平面亮度/色度） dump | Possible **read-only** HyperOS dump. Mask table: https://www.iopenv.com/V4AQRIU7Y/Camx-Dump-Raw-Frames . Execution: `docs/dagu-ife-android-dump-reverse.md` |
| `80-PC212-1` CHI（Camera HAL Interface，相机硬件抽象层接口） API / `80-PN984-4` CHI（Camera HAL Interface，相机硬件抽象层接口） Customization | NDA |
| Dual-IFE（Image Front End，图像前端） `COMP_CFG` / COMP_DONE wait for WM（Write Master，AXI 写通道）4+WM（Write Master，AXI 写通道）5 | Software; Dual-IFE（Image Front End，图像前端） COMP_CFG already forbidden on this board |

## Not here (public page named them, or fetch blocked)

| What | Why |
|---|---|
| `80-PC212-1` CHI API Reference | NDA, named by Topology XML |
| `80-PN984-4` CHI Customization Guide | NDA |
| `80-70020-17A` Camera Addendum | extras / access-gated |
| C-PHY (DSI and CSI) routing constraints | markdown HTTP 403 |
| `80-PV086-1` QRB5165 datasheet PDF | export-controlled pinout; RB5 balls ≠ Xiaomi pad |
| `84_EEPROM_bring_up_guidelines` | EEPROM, not IFE PIX |
| Titan 480 SWI / `viol_id` table | never published |
