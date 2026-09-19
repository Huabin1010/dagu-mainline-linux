# Camera sensor driver bringup

Source: [https://docs.qualcomm.com/doc/80-88500-1/topic/camera_sensor_driver_bringup.html](https://docs.qualcomm.com/doc/80-88500-1/topic/camera_sensor_driver_bringup.html)

## Before you begin

- Review the schematic to understand the sensor module pin connections such as VDD\_IO, camera control interface, and camera serial interface (CSI).
- Ensure that the sensor submodules such as OIS are integrated.
- The recommended MCLK value is 19.2 MHz.
- Ensure that all register settings and power on/off sequences are aligned to data sheets.

Note: If any CSID issue is occurring frequently for a specific sensor mode, such as higher data rate, run a MIPI compliance test and ensure that there are no board-level design issues.

## About this task
To bring up the camera sensor driver, do the following:

## Procedure

1. Locate the following sensor driver and module configuration XML files:
        
- Sensor driver XML files:
                cdk\oem\qcom\sensor\sensor\_name\sensor\_name\_sensor.xml
        Example:
                  imx586\imx586\_sensor.xml and imx586\imx586\_pdaf.xml
    - Module configuration files:
                cdk\oem\qcom\module\module\_name\_module.xml
              
        Example: xxx\_imx586\_module.xml
    - Kernel DTSI files:
        - `target_name-camera-sensor-platform.dtsi`
            - Linux Ubuntu:
                        kernel/msm-5.4/arch/arm64/boot/dts/vendor/qcom/camera/target\_name-camera-sensor-platform.dtsi
            - Linux Embedded:
                        kernel/msm-5.15/arch/arm64/boot/dts/vendor/qcom/camera/target\_name-camera-sensor-platform.dtsi
        - vendor\qcom\proprietary\camera-devicetree\target\_name-camera-sensor-platform.dtsi
    - Submodule driver XML files: chi-cdk\oem\qcom\sub-module\_name\sub-
                module\_name\_sub-module.xml
        Example:
                  chi-cdk\oem\qcom\actuator\ak7374\_actuator.xml
    - The driver binary in the device vendor makefile to be included in the build is
              available at:
                src/vendor/qcom/proprietary/chi-cdk/configs/product.mk.
                
        Example: MM\_CAMERA +=
                  com.qti.sensormodule.&lt;sensor\_name&gt;.bin.
2. Ensure that the sensor binary files are available with the appropriate root permissions
          at: tmp-glibc\sysroots-components\aarch64\chicdk\usr\lib
        
Note: As part of building the CHI-CDK code, the sensor binary files are automatically
            generated.
3. Compile the module.

**Parent Topic:** [Camera sensor driver](https://docs.qualcomm.com/doc/80-88500-1/topic/58_Camera_sensor_driver_.html)

Last Published: Aug 18, 2023

[Previous Topic
Camera sensor driver](https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/58_Camera_sensor_driver_.md) [Next Topic
Sensor software configuration](https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/59_Sensor_software_configuration.md)