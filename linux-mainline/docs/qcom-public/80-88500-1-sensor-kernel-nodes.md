# Sensor kernel nodes

Source: [https://docs.qualcomm.com/doc/80-88500-1/topic/63_Sensor_kernel_nodes.html](https://docs.qualcomm.com/doc/80-88500-1/topic/63_Sensor_kernel_nodes.html)

Table : Camera_LDO

| Field | Description |
| --- | --- |
| `compatible` | Data type to which this node corresponds. |
| `reg` | ID of the node. |
| `regulator-name` | Name of LDO regulator. |
| `regulator-min-microvolt` | Minimum voltage for this LDO. |
| `regulator-max-microvolt` | Maximum voltage for this LDO. |
| `regulator-enable-ramp-delay` | The time taken, in microseconds, for the supply rail to reach the target voltage, ± whatever tolerance the board design requires. This property describes the total system ramp time required due to the combination of internal ramping of the regulator itself, and board design issues such as trace capacitance and load on the supply. |
| `enable-active-high` | Enables with active high. |
| `gpio` | GPIO to be used with this node. |
| `pinctrl-names` | Pin control name. |
| `pinctrl-0` | Pin control handle for this GPIO. |
| `vin-supply` | Name of the input voltage supply node. |

## Example camera LDO configuration

    camera_ldo: gpio-regulator@2 { 
    compatible = "regulator-fixed"; 
    reg = <0x02 0x00>;
    regulator-name = "camera_ldo"; 
    regulator-min-microvolt = <1050000>;
    regulator-max-microvolt = <1050000>;
    regulator-enable-ramp-delay = <233>; 
    enable-active-high;
    gpio = <&pm8998_gpios 9 0>; 
    pinctrl-names = "default";
    pinctrl-0 = <&camera_dvdd_en_default>; 
    vin-supply = <&pm8998_s3>;
    };
          Copy to clipboard

Table : CCI-based sensor driver

| Field | Description |
| --- | --- |
| `qcom,csiphy-sd-index` | Paired CSIPHY node for this DT. |
| `cell-index` | Points to the ID of the sensor node. |
| `reg` | Corresponds to the cell-index of the node. |
| `compatible` | Data type to which this node corresponds. |
| `qcom,sensor-position-roll` | Sensor position roll angle |
| `qcom,sensor-position-pitch` | Sensor position pitch angle |
| `qcom,sensor-position-yaw` | Sensor position yaw angle |
| `qcom,led-flash-src` | LED flash source node name |
| `qcom,actuator-src` | Actuator source node name |
| `qcom,ois-src` | OIS source node name |
| `qcom,eeprom-src` | EEPROM source node name |
| `cam_vio-supply` | I/O voltage supply source |
| `cam_vana-supply` | Analog voltage source |
| `cam_vdig-supply` | Digital voltage source |
| `cam_clk-supply` | Camera clock source |
| `qcom,cam-vreg-name` | Voltage regulator node names |
| `qcom,cam-vreg-min-voltage` | Minimum voltage, in the order: I/O, analog, digital. |
| `qcom,cam-vreg-max-voltage` | Maximum voltage, in the order: I/O, analog, digital. |
| `qcom,cam-vreg-op-mode` | Operation mode of the voltage regulator, in the order: I/O, analog, digital. |
| `regulator-names` | Names of all regulators needed. |
| `rgltr-cntrl-support` | This property is required if the software controls regulator parameters such as<br>                    `rgltr-min-voltage`. |
| `pwm-switch` | This property is required for the regulator to switch into pulse-width modulation<br>                  (PWM) mode. |
| `rgltr-min-voltage` | Minimum voltage level for regulators mentioned in the<br>                    `regulator-names` property, in the order: I/O, analog,<br>                  digital. |
| `rgltr-max-voltage` | Maximum voltage level for regulators mentioned in the<br>                    `regulator-names` property, in the order: I/O, analog,<br>                  digital. |
| `rgltr-load-current` | Optimum voltage level for regulators mentioned in the<br>                    `regulator-names` property, in the order: I/O, analog,<br>                  digital. |
| `qcom,gpio-no-mux` | Indicates whether GPIO muxing is enabled. |
| `pinctrl-names` | Pin control handle names for this GPIO if the device uses pin control. |
| `pinctrl-0` | Binding to GPIO pin and function node. |
| `pinctrl-1` | Binding to GPIO pin and function node. |
| `gpios` | List of GPIO pins used |
| `qcom,gpio-reset` | Index to GPIO used by the `sensors reset_n` property. |
| `qcom,gpio-vana` | Index to GPIO used by sensors analog vreg enable. |
| `qcom,gpio-vaf` | Index to GPIO used by sensors of vreg enable. |
| `qcom,gpio-req-tbl-num` | Index to GPIO specific to this sensor. |
| `qcom,gpio-req-tbl-flags` | Direction of GPIO present in the `qcom,gpio-req-tbl-num` property<br>                  (in the same order). |
| `qcom,gpio-req-tbl-label` | Name of GPIO present in `qcom`, `gpio-req-tbl-num`<br>                  property (in the same order). |
| `qcom,sensor-position` | Mount angle of the sensor<br><br><br>                <ul class="ul"><br>                  <li class="li">0 – back camera</li><br><br>                  <li class="li">1 – front camera</li><br><br>                </ul> |
| `qcom,sensor-mode` | Supported sensor modes:<br><br><br>                <ul class="ul"><br>                  <li class="li">0 – back camera 2D</li><br><br>                  <li class="li">1 – front camera 2D</li><br><br>                  <li class="li">2 – back camera 3D</li><br><br>                  <li class="li">3 – back camera int 3D</li><br><br>                </ul> |
| `qcom,cci-master` | I^2^C master used for this sensor<br><br><br>                <ul class="ul"><br>                  <li class="li">0 – MASTER 0</li><br><br>                  <li class="li">1 – MASTER 1</li><br><br>                </ul> |
| `status` | Indicates whether this node is enabled or disabled. |
| `clocks` | Clock node names |
| `clock-names` | Name of the clocks required for the device. |
| `qcom,clock-rates` | Clock rate in Hz |

For the latest definition, see arm64/vendor/qcom/camera/bindings/msm-cam-cci.txt.

Example of CCI-based sensor driver configuration:

    qcom,cam-sensor@0 { cell-index = <0>;
    compatible = "qcom,cam-sensor"; reg = <0x0>;
    qcom,csiphy-sd-index = <0>;
    qcom,sensor-position-roll = <90>;
    qcom,sensor-position-pitch = <0>;
    qcom,sensor-position-yaw = <180>; qcom,led-flash-src = <&led_flash_rear>; qcom,actuator-src = <&actuator_rear>; qcom,ois-src = <&ois_rear>;
    qcom,eeprom-src = <&eeprom_rear>;
    cam_vio-supply = <&pm8998_lvs1>; cam_vana-supply = <&pmi8998_bob>; cam_vdig-supply = <&camera_rear_ldo>; cam_clk-supply = <&titan_top_gdsc>;
    qcom,cam-vreg-name = "cam_vio", "cam_vana", "cam_vdig", "cam_clk";
    qcom,cam-vreg-min-voltage = <0 3312000 1050000 0>;
    qcom,cam-vreg-max-voltage = <0 3600000 1050000 0>;
    qcom,cam-vreg-op-mode = <0 80000 105000 0>;
    qcom,gpio-no-mux = <0>;
    pinctrl-names = "cam_default", "cam_suspend"; pinctrl-0 = <&cam_sensor_mclk0_active
    &cam_sensor_rear_active>; pinctrl-1 = <&cam_sensor_mclk0_suspend
    &cam_sensor_rear_suspend>; gpios = <&tlmm 13 0>,
    <&tlmm 80 0>,
    <&tlmm 79 0>;
    qcom,gpio-reset = <1>;
    qcom,gpio-vana = <2>;
    qcom,gpio-req-tbl-num = <0 1 2>;
    qcom,gpio-req-tbl-flags = <1 0 0>; qcom,gpio-req-tbl-label = "CAMIF_MCLK0",
    "CAM_RESET0", "CAM_VANA";
    qcom,sensor-mode = <0>;
    qcom,cci-master = <0>; status = "ok";
    clocks = <&clock_camcc CAM_CC_MCLK0_CLK>; clock-names = "cam_clk";
    qcom,clock-rates = <24000000>;
    };Copy to clipboard

Table :  OIS node

| Field | Description |
| --- | --- |
| `cell-index` | Points to the ID of this node. |
| `reg` | Corresponds to the cell-index of the node. |
| `compatible` | Data type to which this node corresponds. |
| `qcom,cci-master` | CCI node that drives this node. |
| `cam_vaf-supply` | Regulator from which AF voltage is supplied. |
| `qcom,cam-vreg-name` | Voltage regulator node names. |
| `qcom,cam-vreg-min-voltage` | Minimum voltage |
| `qcom,cam-vreg-max-voltage` | Maximum voltage |
| `qcom,cam-vreg-op-mode` | Operation mode of the voltage regulator. |
| `status` | Indicates whether this node is enabled or disabled. |

## Example of OIS node configuration

    ois_rear: qcom,ois@0 { 
    cell-index = <0>; 
    reg = <0x0>;
    compatible = "qcom,ois"; 
    qcom,cci-master = <0>;
    cam_vaf-supply = <&actuator_regulator>; 
    qcom,cam-vreg-name = "cam_vaf"; 
    qcom,cam-vreg-min-voltage = <2800000>;
        qcom,cam-vreg-max-voltage = <2800000>;
    qcom,cam-vreg-op-mode = <0>; 
    status = "disabled";
    };Copy to clipboard

Table : EEPROM node

| Field | Description |
| --- | --- |
| `cell-index` | Points to the node ID. |
| `reg` | Corresponds to the cell-index of the node. |
| `compatible` | Data type that this node corresponds to. |
| `qcom,cci-master` | CCI node that drives this node. |
| `cam_vio-supply` | Input/output voltage supply source. |
| `cam_vana-supply` | Analog voltage source |
| `cam_vdig-supply` | Digital voltage source |
| `cam_clk-supply` | Camera clock source |
| `qcom,cam-vreg-name` | Voltage regulator node names. |
| `qcom,cam-vreg-min-voltage` | Minimum voltage, in the order: I/O, analog, digital . |
| `qcom,cam-vreg-max-voltage` | Maximum voltage, in the order: I/O, analog, digital. |
| `qcom,cam-vreg-op-mode` | Operation mode of the voltage regulator, in the order: I/O, analog, digital. |
| `rgltr-load-current` | Optimum voltage level for regulators mentioned in regulator-names property ( in<br>                  the order: I/O, analog, digital). |
| `qcom,gpio-no-mux` | Indicates whether GPIO muxing is enabled. |
| `pinctrl-names` | Pin control handle names |
| `pinctrl-0` | Binding to GPIO pin and function node. |
| `pinctrl-1` | Binding to GPIO pin and function node. |
| `gpios` | List of GPIO pins used |
| `qcom,gpio-reset` | Index to GPIO used by sensors `reset_n`. |
| `qcom,gpio-vana` | Index to GPIO used by sensors analog `vreg` enable. |
| `qcom,gpio-vaf` | Index to GPIO used by sensors `i2af vreg ` enable. |
| `qcom,gpio-req-tbl-num` | Index to GPIO specific to this sensor. |
| `qcom,gpio-req-tbl-flags` | Direction of GPIO present in `qcom, gpio-req-tbl-num` property (<br>                  in the order: I/O, analog, digital). |
| `qcom,gpio-req-tbl-label` | Name of GPIO present in `qcom, gpio-req-tbl-num` property ( in the<br>                  order: I/O, analog, digital). |
| `qcom,sensor-position` | Mount angle of the sensor<br><br><br>                <ul class="ul"><br>                  <li class="li">0 – back camera</li><br><br>                  <li class="li">1 – front camera</li><br><br>                </ul> |
| `qcom,sensor-mode` | Supported sensor mode<br><br><br>                <ul class="ul"><br>                  <li class="li">0 – back camera 2D</li><br><br>                  <li class="li">1 – front camera 2D</li><br><br>                  <li class="li">2 – back camera 3D</li><br><br>                  <li class="li">3 – back camera int 3D</li><br><br>                </ul> |
| `qcom,cci-master` | I^2^C master used for this sensor<br><br><br>                <ul class="ul"><br>                  <li class="li">0 – MASTER 0</li><br><br>                  <li class="li">1 – MASTER 1</li><br><br>                </ul> |
| `Status` | Indicates whether this node is enabled or disabled. |
| `clocks` | Clock node names |
| `clock-names` | Name of the clocks required for the device. |
| `qcom,clock-rates` | Clock rate in Hz |

For the latest definition, see vendor\qcom\proprietary\camera-devicetree\bindings\msm-cam-cci.txt.

Example EEPROM node configuration:

    eeprom_rear: qcom,eeprom@0 { 
            cell-index = <0>;
            reg = <0>;
    compatible = "qcom,eeprom"; 
    cam_vio-supply = <&pm8998_lvs1>; 
    cam_vana-supply = <&pmi8998_bob>;
    cam_vdig-supply = <&camera_rear_ldo>; 
    cam_clk-supply = <&titan_top_gdsc>;
    qcom,cam-vreg-name = "cam_vio", "cam_vana", "cam_vdig", "cam_clk";
            qcom,cam-vreg-min-voltage = <0 3312000 1050000 0>;
            qcom,cam-vreg-max-voltage = <0 3600000 1050000 0>;
            qcom,cam-vreg-op-mode = <0 80000 105000 0>;
            qcom,gpio-no-mux = <0>;
    pinctrl-names = "cam_default", "cam_suspend"; pinctrl-0 = <&cam_sensor_mclk0_active
            &cam_sensor_rear_active>; pinctrl-1 = <&cam_sensor_mclk0_suspend
            &cam_sensor_rear_suspend>; gpios = <&tlmm 13 0>,
            <&tlmm 80 0>,
             <&tlmm 79 0>,
            <&tlmm 27 0>;
            qcom,gpio-reset = <1>;
            qcom,gpio-vana = <2>;
            qcom,gpio-vaf = <3>;
            qcom,gpio-req-tbl-num = <0 1 2 3>;
    qcom,gpio-req-tbl-flags = <1 0 0 0>; 
    qcom,gpio-req-tbl-label = "CAMIF_MCLK0",
            "CAM_RESET0", "CAM_VANA0", "CAM_VAF";
            qcom,sensor-position = <0>;
            qcom,sensor-mode = <0>;
    qcom,cci-master = <0>; 
    status = "ok";
    clocks = <&clock_camcc CAM_CC_MCLK0_CLK>; 
    clock-names = "cam_clk";
            qcom,clock-rates = <24000000>;
    };Copy to clipboard

**Parent Topic:** [Sensor hardware configuration](https://docs.qualcomm.com/doc/80-88500-1/topic/62_Sensor_hardware_configuration.html)

Last Published: Aug 18, 2023

[Previous Topic
Sensor hardware configuration](https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/62_Sensor_hardware_configuration.md) [Next Topic
CCI timing and debug](https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/64_CCI_timing_and_debug.md)