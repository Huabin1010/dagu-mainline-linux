# Sensor software configuration

Source: [https://docs.qualcomm.com/doc/80-88500-1/topic/59_Sensor_software_configuration.html](https://docs.qualcomm.com/doc/80-88500-1/topic/59_Sensor_software_configuration.html)

Every sensor has an associated XML file that defines configurations, such as power settings, resolution, initialization settings, and exposure settings. All sensor settings are present in the `<sensorDriverData></sensorDriverData>` node of this XML file. For more details, see chi-cdk/api/sensor/camxsensordriver.xsd.

To avoid sensor transmitting data in Burst mode, the active duration of the sensor should be between the `FS (Frame start) – FE (Frame end) ~= 1/fps`. Example,

- For 30 fps mode: FS – FE &gt; 30 ms
- For 60 fps mode: FS – FE &gt; 14 ms

- **[Sensor information nodes](https://docs.qualcomm.com/doc/80-88500-1/topic/60_Sensor_information_nodes.html)**
- **[Module configuration](https://docs.qualcomm.com/doc/80-88500-1/topic/61_Module_configuration_.html)**

**Parent Topic:** [Camera sensor driver](https://docs.qualcomm.com/doc/80-88500-1/topic/58_Camera_sensor_driver_.html)

Last Published: Aug 18, 2023

[Previous Topic
Camera sensor driver bringup](https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/camera_sensor_driver_bringup.md) [Next Topic
Sensor information nodes](https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/60_Sensor_information_nodes.md)