# Camera capture and encode

Source: [https://docs.qualcomm.com/doc/80-88500-4/topic/123_Camera_capture_and_encode.html](https://docs.qualcomm.com/doc/80-88500-4/topic/123_Camera_capture_and_encode.html)

The qmmfsrc plugin can be used to capture camera frames via the QMMF service and
    provide multiple encoded (AVC/HEVC) bitstreams and YUV streams.

The camera capture (encoding) of streams has the following features:

- The Qualcomm Robotics RB5 supports up to 7-camera concurrency (excluding the UVC camera).
- The GST SRC plugin is a client to the QMMF server; the QMMF server runs as a daemon in the system and provides easy RPC APIs to implement the camera/recorder use cases.
- The encoded bitstream provided by the GST plugin can be used by different types of sink elements, such as filesink, to save the bitstream into the file system, and can be used by streaming plugins (RTP over TCP or UDP) to send the stream to the network.
- Raw YUV stream can be used for multiple use cases; the following are a few use cases:
    - The waylandsink element uses this YUV stream to render the camera frames to a physical
            display to achieve a live camera preview use case.
    - The YUV stream can be used by postprocessing elements to improve image quality, for
            example, image quality, downscaling, padding, color convert, and so on.
    - The YUV stream can be used by the machine learning-inferencing engine (Qualcomm Neural
            Processing SDK, TFLite) for the inferencing on live camera.
- The QMMF interacts with HAL3, which further interacts with the camera backend (CamX) and camera
        driver to configure sensors to get a stream from the camera sensor.
- Buffers for each camera stream are allocated by the QMMF using the libGBM and are submitted to
        HAL3.

The Qualcomm Spectra™ 480 ISP camera architecture has six CSI interfaces for external
      cameras.

- Six 4-lane interfaces with CSI D-PHY 1.2 or C-PHY 1.2
- Each D-PHY 1.2 interface has a data rate of 2.5 Gbps/lane
- Each C-PHY 1.2 interface has a data rate of 10.26 Gbps/T (4.5 Gbps/T)

Table : Camera sensors and modules supported by Qualcomm Robotics RB5 Platform

| Type | Camera sensor | Resolution/fps | Format | Module | Interface |
| --- | --- | --- | --- | --- | --- |
| Main camera sensor | IMX577 | 4056x3040/60 fps | RAW Bayer | CMK-IMX577-B-V2.0 | MIPI |
| Tracking camera sensor | OV9282 | <ul class="ul" id="Camera_capture_and_encode_123__ul_ftv_k3d_cxb"><br>                <li class="li">1280x800/120 fps</li><br><br>                <li class="li">640x480/180 fps</li><br><br>              </ul> | RAW Bayer | CMK-VR-OV9282-V1.0 | MIPI |
| ToF camera sensor | MN34906 | 640x480/30 fps | B/W RAW | Panasonic TOF V4T | MIPI |
| GMSL camera sensor | ON SEMI AR0231 Sensor | 1920x1080/28.7 fps | YUV | LI-AR0231-GMSL2-CFM-176H-000 | GMSL |

**Parent Topic:** [Camera](https://docs.qualcomm.com/doc/80-88500-4/topic/122_Camera.html)

Last Published: Aug 18, 2023

[Previous Topic
Camera](https://docs.qualcomm.com/bundle/publicresource/80-88500-4/topics/122_Camera.md) [Next Topic
Qualcomm Spectra 480](https://docs.qualcomm.com/bundle/publicresource/80-88500-4/topics/124_Qualcomm_Spectra_480.md)