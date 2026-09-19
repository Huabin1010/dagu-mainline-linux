# Power regulator configuration

Source: [https://docs.qualcomm.com/doc/80-88500-1/topic/69_Power_regulator_configuration.html](https://docs.qualcomm.com/doc/80-88500-1/topic/69_Power_regulator_configuration.html)

The type of voltage to be applied is specified in the XML file of the driver for a given sensor. The supported values are:

- `MCLK` – mclock
- `VANA` – Analog supply voltage
- `VDIG` – Digital supply voltage
- `VIO` – I/O supply voltage
- `VAF` – Actuator supply voltage
- `RESET` – Reset GPIO
- `STANDBY` – Standby GPIO

The values map to the specific voltage regulators using the DTSI sensor node.

## PMIC-based sensor nodes

`VIO` maps to `cam_vio-supply`, `VANA` maps to
          `cam_vana-supply`, and MCLK maps to `cam_clk-supply`.
        Example:

    cam_vio-supply = <&pm8998_lvs1>;
    cam_vana-supply = <&pmi8998_bob>;
    cam_vdig-supply = <&camera_rear_ldo>;
    cam_clk-supply = <&titan_top_gdsc>;Copy to clipboard

## GPIO-based sensor nodes

    pinctrl-names = "cam_default", "cam_suspend"; pinctrl-0 = <&cam_sensor_mclk0_active
    &cam_sensor_rear_active>; 
    pinctrl-1 = <&cam_sensor_mclk0_suspend
    &cam_sensor_rear_suspend>; 
    gpios = <&tlmm 13 0>,
    <&tlmm 80 0>,
    <&tlmm 79 0>;
    gpio-reset = <1>;
    gpio-vana = <2>;
    gpio-req-tbl-num = <0 1 2>;
    gpio-req-tbl-flags = <1 0 0>;
    gpio-req-tbl-label = "CAMIF_MCLK0","CAM_RESET0","CAM_VANA";
    Copy to clipboard

## Regulator-based sensor nodes

    regulator-names = "cam_vio", "cam_vana", "cam_vdig","cam_clk"; rgltr-cntrl-support;
    rgltr-min-voltage = <0 3312000 1050000 0>;
    rgltr-max-voltage = <0 3600000 1050000 0>;
    rgltr-load-current = <0 80000 105000 0>;
    Copy to clipboard

To configure different power regulators and supply, use the DTSI node parameters.

**Parent Topic:** [Sensor hardware configuration](https://docs.qualcomm.com/doc/80-88500-1/topic/62_Sensor_hardware_configuration.html)

Last Published: Aug 18, 2023

[Previous Topic
Camera IFE clock configuration](https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/68_Camera_IFE_clock_configuration.md) [Next Topic
Clock configuration](https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/70_Clock_configuration.md)