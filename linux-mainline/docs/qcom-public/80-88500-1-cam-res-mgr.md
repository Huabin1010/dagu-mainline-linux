# Camera resource manager configuration

Source: [https://docs.qualcomm.com/doc/80-88500-1/topic/72_Camera_resource_manager_configuration.html](https://docs.qualcomm.com/doc/80-88500-1/topic/72_Camera_resource_manager_configuration.html)

If there are any shared resources such as GPIO, PIN-CTRL between devices, use the `qcom,cam- res-mgr` to configure the shared resources.

The following example shows `sensor#0` and `sensor#1` using
        `mclk0` (GPIO#94) as a shared resource.

For details about the configuration, see vendor\qcom\proprietary\camera-devicetree\bindings\msm-cam-cci.txt file.

Note:  The device node should have the `phandles` of only nonshared pin controls.

    qcom,cam-sensor0 { cell-index = <0>;
    pinctrl-names = "cam_default", "cam_suspend"; pinctrl-0 = <&cam_sensor_active_rear_wide>; pinctrl-1 = <&cam_sensor_suspend_rear_wide>; gpios = <&tlmm 94 0>, //using GPIO#94 as mclk0
    <&tlmm 93 0>;
    gpio-reset = <1>;//using the gpios[1] as reset, which is GPIO 93 gpio-req-tbl-num = <0 1>;
    gpio-req-tbl-flags = <1 0>; //0 indicates GPIO 93 as GPIOF_DIR_OUT gpio-req-tbl-label = "CAMIF_MCLK0",
    "CAM_RESET0";
    sensor-mode = <0>;
    cci-master = <0>; status = "ok";
    clocks = <&clock_camcc CAM_CC_MCLK0_CLK>; clock-names = "cam_clk";
    qcom,cam-sensor1 { cell-index = <1>;
    pinctrl-names = "cam_default", "cam_suspend"; pinctrl-0 = <&cam_sensor_active_rear>; pinctrl-1 = <&cam_sensor_suspend_rear>;
    gpios = <&tlmm 94 0>, //using GPIO#94 as mclk0
    <&tlmm 95 0>;
    gpio-reset = <1>;
    gpio-req-tbl-num = <0 1>;
    gpio-req-tbl-flags = <1 0>; //0 indicates GPIO 95 as GPIOF_DIR_OUT gpio-req-tbl-label = "CAMIF_MCLK0",
    "CAM_RESET1";
    sensor-mode = <0>;
    cci-master = <0>; status = "ok";
    clocks = <&clock_camcc CAM_CC_MCLK0_CLK>; clock-names = "cam_clk";
    cam_res_mgr: qcom,cam-res-mgr { compatible = "qcom,cam-res-mgr";
    gpios-shared-pinctrl = <408>; //Assume 408 is the tlmm pin# for GPIO#94 shared-pctrl-gpio-names = "mclk0";
    pinctrl-names = "mclk0_active", "mclk0_suspend"; pinctrl-0 = <&cam_sensor_mclk0_active>;
    pinctrl-1 = <&cam_sensor_mclk0_suspend>; status = "ok";
    };Copy to clipboard

## Multiple shared GPIOs

If there are multiple shared GPIOs, then those shared GPIO pin control `phandles` should be defined in `cam-res-mgr` section only, and the `phandles` for those shared GPIO pin control should *not* be defined in the device node structures, which are using those shared GPIOs. For multiple shared GPIOs, define the shared GPIO pin control in `cam-res-mgr` node structure as shown in the following example:

    qcom,cam-res-mgr {
        compatible = "qcom,cam-res-mgr";
        gpios-shared-pinctrl = <408 324>; /// shared pinctrls are defined here
        shared-pctrl-gpio-names = "mclk0","rst0"; //
    pinctrl-names = "mclk0_active", "mclk0_suspend","rst0_active", "rst0_suspend";
    pinctrl-0 = <&cam_sensor_mclk0_active>; 
    pinctrl-1 = <&cam_sensor_mclk0_suspend>; 
    pinctrl-2 = <&cam_sensor_active_rst0>;
    pinctrl-3 = <&cam_sensor_suspend_rst0>; 
    status = "ok";
    };Copy to clipboard

For example, assuming that `tlmm pin #408` belongs to GPIO 100 and `tlmm pin #324` belongs to GPIO 16 then the two nodes, `sensor 0` and `ois0` sharing these GPIO pins should have the following structure:

    ois_rear_main: qcom,ois0 {
    …
    gpio-no-mux = <0>;
    //pinctrl-names = "cam_default", "cam_suspend"; // no pinctrl phandles
    //pinctrl-0 = <&cam_sensor_mclk0_active>;
    //pinctrl-1 = <&cam_sensor_mclk0_suspend>; gpios = <&tlmm 100 0>,
    <&tlmm 16 0>;
    gpio-reset = <1>;
    gpio-req-tbl-num = <0 1>;
    gpio-req-tbl-flags = <1 0>;
    gpio-req-tbl-label = "CAMIF_MCLK0","CAM_RESET0";
    …
    }
    Sensor0{
    gpio-no-mux = <0>;
    //pinctrl-names = "cam_default", "cam_suspend"; //no pinctrl phandles needed
    //pinctrl-0 = <&cam_sensor_mclk0_active>;
    //pinctrl-1 = <&cam_sensor_mclk0_suspend>; gpios = <&tlmm 100 0>,
    <&tlmm 16 0>;
    gpio-reset = <1>;
    gpio-req-tbl-num = <0 1>;
    gpio-req-tbl-flags = <1 0>;
    gpio-req-tbl-label = "CAMIF_MCLK0","CAM_RESET0";
    }Copy to clipboard

Ensure that the shared GPIO pin control is properly configured among the devices using it. When there are overlaying DTSI files where a different node is using a shared GPIO, ensure that the node from the overlaying DTSI file is also following the configuration as defined in the preceding examples.

**Parent Topic:** [Sensor hardware configuration](https://docs.qualcomm.com/doc/80-88500-1/topic/62_Sensor_hardware_configuration.html)

Last Published: Aug 18, 2023

[Previous Topic
CCI master index configuration](https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/71_CCI_master_index_configuration.md) [Next Topic
Sensor library configuration](https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/73_Sensor_library_configuration.md)