# Troubleshoot camera

If the camera app doesn’t work, check the following:

1. Check the camera module connection and DIP switch settings. See [Getting started](https://docs.qualcomm.com/doc/80-70030-17/topic/stream-cameras.html#getting-started).
2. Restart the cam-server:

# systemctl restart cam-server
        
        or:
        
        # pkill cam-server
        Copy to clipboard
3. Run a single stream video recording use case:

# mount -o rw,remount /usr
        
        gst-launch-1.0 -e qtiqmmfsrc name=camsrc camera=0 ! \
        video/x-raw,format=NV12,width=1280,height=720,framerate=30/1,\
        interlace-mode=progressive,colorimetry=bt601 ! v4l2h264enc \
        capture-io-mode=4 output-io-mode=5 extra-controls="controls,video_bitrate=6000000,\
        video_bitrate_mode=0;" ! h264parse ! mp4mux ! filesink location=/opt/mux_avc.mp4
        Copy to clipboard
4. Check the sensor probe.

    1. Collect logs using following command:

# journalctl -f > /opt/log.txt
            Copy to clipboard
    2. Search for “probe success” in the log. Probe success means the camera module is powered up and responding to I2C control. If there is no ‘probe success’ log for a particular sensor, the flex cable connection or camera module may be the problem.

        The following log indicates one IMX577 (0x34), one OV9282 (0xc0), and two GMSL deserializer (0x90) are probed:

CAM_INFO: CAM-SENSOR:cam_sensor_driver_cmd: 938: Probe success,slot:0,slave_addr: 0x34,sensor_id:0x577, is always on:0
            CAM_INFO: CAM-SENSOR:cam_sensor_driver_cmd: 938: Probe success,slot:1,slave_addr: 0xc0,sensor_id:0x9281, is always on:0
            CAM_INFO: CAM-SENSOR:cam_sensor_driver_cmd: 938: Probe success,slot:4,slave_addr: 0x90,sensor_id:0x94, is always on:0
            CAM_INFO: CAM-SENSOR:cam_sensor_driver_cmd: 938: Probe success,slot:5,slave_addr: 0x90,sensor_id:0x94, is always on:0
            Copy to clipboard
5. Check the camera sensor driver command.

    Collect logs and search for `cam_sensor_driver_cmd`. `CAM_START_DEV Success` indicates camera sensor streaming starts. `CAM_STOP_DEV Success` indicates camera sensor streaming stops. For example:

CAM_INFO: CAM-SENSOR:cam_sensor_driver_cmd: 1017: CAM_ACQUIRE_DEV Success, sensor_id: 0x577,sensor_slave_addr:0x34
        CAM_INFO: CAM-SENSOR:cam_sensor_driver_cmd: 1128: CAM_START_DEV Success, sensor_id: 0x577,sensor_slave_addr:0x34
        CAM_INFO: CAM-SENSOR:cam_sensor_driver_cmd: 1156: CAM_STOP_DEV Success, sensor_id:0x577,sensor_slave_addr:0x34
        CAM_INFO: CAM-SENSOR:cam_sensor_driver_cmd: 1070: CAM_RELEASE_DEV Success, sensor_id: 0x577,sensor_slave_addr:0x34
        Copy to clipboard
6. Check sensor streaming.

    To enable CSID IRQ logs dynamically, use the appropriate mask value(s) with the following command.

    - QCS6490

> 
> 
> # mount -o rw,remount /usr
>             # mount -t debugfs none /sys/kernel/debug/
>             # echo MASKVALUE > /sys/kernel/debug/camera_ife/ife_csid_debug
>             Copy to clipboard
    - QCS9075/QCS8275

> 
> 
> # mount -o rw,remount /usr
>             # mount -t debugfs none /sys/kernel/debug/
>             # echo MASKVALUE > /sys/kernel/debug/camera/ife/ife_csid_debug
>             Copy to clipboard

    The following table lists the CSID debug groups.

    | CSID debug group | Value | Description |
    | --- | --- | --- |
    | CSID\_DEBUG\_ENABLE\_SOF\_IRQ | (1&lt;&lt; 0) | Start of frame |
    | CSID\_DEBUG\_ENABLE\_EOF\_IRQ | (1&lt;&lt; 1) | End of frame |
    | CSID\_DEBUG\_ENABLE\_SOT\_IRQ | (1&lt;&lt; 2) | Start of transmission |
    | CSID\_DEBUG\_ENABLE\_EOT\_IRQ | (1&lt;&lt; 3) | End of transmission |
    | CSID\_DEBUG\_ENABLE\_SHORT\_PKT\_CAPTURE | (1&lt;&lt; 4) | Short packet capture |
    | CSID\_DEBUG\_ENABLE\_LONG\_PKT\_CAPTURE | (1&lt;&lt; 5) | Long packet capture |
    | CSID\_DEBUG\_ENABLE\_CPHY\_PKT\_CAPTURE | (1&lt;&lt; 6) | CPHY packet capture |

    For example:

    - To enable SOF, EOF, SOT, and EOT IRQs:

> 
> 
> # echo 0xf > /sys/kernel/debug/camera/ife/ife_csid_debug
>             Copy to clipboard
    - To set only short packet and long packet capture IRQs:

> 
> 
> # echo 0x30 > /sys/kernel/debug/camera/ife/ife_csid_debug
>             Copy to clipboard

    The captured logs can help provide the details about the SOF and EOF and indicate which sensor is streaming. The following is an example log:

> 
> 
> CAM_INFO: CAM-ISP: cam_ife_csid_irq: 5288 CSID:1 IPP SOF received
>         CAM_INFO: CAM-ISP: cam_ife_csid_irq: 5300 CSID:1 IPP EOF received
>         CAM_INFO: CAM-ISP: cam_ife_csid_irq: 5288 CSID:1 IPP SOF received
>         CAM_INFO: CAM-ISP: cam_ife_csid_irq: 5300 CSID:1 IPP EOF received
>         CAM_INFO: CAM-ISP: cam_ife_csid_irq: 5288 CSID:1 IPP SOF received
>         CAM_INFO: CAM-ISP: cam_ife_csid_irq: 5300 CSID:1 IPP EOF received
>         Copy to clipboard

Last Published: Jun 22, 2026

[Previous Topic
Switch linear vs. SHDR mode automatically](https://docs.qualcomm.com/bundle/publicresource/80-70030-17/topics/auto-linear-vs-shdr-mode-switch.md)