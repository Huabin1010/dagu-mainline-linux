# Module configuration 

Source: [https://docs.qualcomm.com/doc/80-88500-1/topic/61_Module_configuration_.html](https://docs.qualcomm.com/doc/80-88500-1/topic/61_Module_configuration_.html)

The module configuration is an XML file used to store the camera module-specific information,
      such as the lens information, mount angles and flash-related information. The following tables
      list the fields present in this file:

Table : CameraPosition

| **Field** | **Description** |
| --- | --- |
| `CameraPosition` | Position of the sensor module. The supported values are:<br><br><br>              <ul class="ul"><br>                <li class="li">REAR</li><br><br>                <li class="li">FRONT</li><br><br>                <li class="li">REAR_AUX</li><br><br>                <li class="li">FRONT_AUX</li><br><br>                <li class="li">EXTERNAL</li><br><br>              </ul> |

Table : LensInformation

| **Field** | **Description** |
| --- | --- |
| `LensInformation` | This node holds sensor lens-specific information. |
| `focalLength` | Focal length of the lens in millimeters. |
| `fNumber` | F-Number of the optical system. |
| `minFocusDistance` | Minimum focus distance in meters. |
| `maxFocusDistance` | Total focus distance in meters. |
| `horizontalViewAngle` | Horizontal view angle in degrees. |
| `verticalViewAngle` | Vertical view angle in degrees. |
| `maxRollDegree` | Maximum roll degree. |
| `maxPitchDegree` | Maximum pitch degree. |
| `maxYawDegree` | Maximum yaw degree. |

Table : LensInformationList

| Field | Description |
| --- | --- |
| `LensInformationList` | This node holds sensor list of lens-specific information based on version number. |
| `version` | Module version defined in EEPROM. |
| `chromatixName` | Chromatix name corresponding to this version. |
| `lensInfo` | Lens-specific information. See [LensInformation](https://docs.qualcomm.com/doc/80-88500-1/topic/61_Module_configuration_.html#Module_configuration__61__table_fkv_lpl_1xb). |

Table : ModuleConfiguration

| **Field** | **Description** |
| --- | --- |
| `ModuleConfiguration` | Module configuration. |
| `cameraId` | Specifies the `cameraId` mapped to the DTSI node. Typically, `cameraId` is the slot ID for a Noncombo mode. |
| `moduleName` | Name of the module integrator. |
| `sensorName` | Name of the sensor in the image sensor module. |
| `sensorSlaveAddress` | Sensor slave address to override the value present in the binary. This is an optional field.<br>                <br>Note: Do not use this field if override is not required. |
| `sensorI2CFrequencyMo de` | Sensor operation frequency mode. The supported frequency modes are:<br><br><br>              <ul class="ul"><br>                <li class="li">STANDARD</li><br><br>                <li class="li">FAST</li><br><br>                <li class="li">FAST_PLUS</li><br><br>                <li class="li">CUSTOM</li><br><br>              </ul> |
| `actuatorName` | Name of the actuator in the image sensor module. Optional element.<br>              <br>Note: Do not use this field if actuator is not present. |
| `eepromName` | Name of the EEPROM in the image sensor module. Optional element.<br>                <br>Note: Do not use this element if EEPROM is not present. |
| `flashName` | Flash name to open a binary. The format of binary name flashName\_flash.bin. Example: pmic\_flash.bin. |
| `chromatixName` | Chromatix name to open a binary. The format of binary name is: sensor\_model\_chromatix.bin. |
| `position` | Camera position. The supported positions are:<br>                <ul class="ul" id="Module_configuration__61__ul_1"><br>                  <li class="li">REAR</li><br><br>                  <li class="li">FRONT</li><br><br>                  <li class="li">REAR_AUX</li><br><br>                  <li class="li">FRONT_AUX</li><br><br>                  <li class="li">EXTERNAL</li><br><br>                </ul> |
| `CSIInfo` | CSI information that includes lane assignment, combo mode, and C-PHY-D-PHY combo mode flags. |
| `laneAssign` | Indicates the value used to determine the C-PHY and D-PHY lanes that should be assigned to this sensor.<br><br><br>              <br>Example: 0x2310 |
| `isComboMode` | Flag to enable Combo mode. This flag is enabled when multiple sensors are using the same CSI-PHY receiver:<br><br><br>              <ul class="ul"><br>                <li class="li">First camera: connected to PHY lanes 2:0. The clock lane is connected to PHY lane 1 and data lanes (up to 2) are connected to either of PHY lanes 0 or 2.</li><br><br>                <li class="li">Second camera: connected to PHY lanes 4:3. The clock lane is connected to PHY lane 4 and the data lanes are connected to PHY lane 3. </li><br><br>              </ul> |
| `cphydphyComboMode` | Flag to enable C-Phy-D-Phy Combo mode under the same CSI. This flag is enabled when multiple sensors are being used in either combination:<br><br><br>              <ul class="ul"><br>                <li class="li">Two sensors using C-PHY receiver and one sensor with D-PHY receiver</li><br><br>                <li class="li">Two sensors using D-PHY receiver and one sensor with C-PHY receiver</li><br><br>              </ul> |
| `pdafName` | Name of the PDAF driver used to configure this image sensor module. This is an optional field. Skip this field if PDAF is not supported. |
| `lensInfoList` | List of lens information nodes. See [LensInformation](https://docs.qualcomm.com/doc/80-88500-1/topic/61_Module_configuration_.html#Module_configuration__61__table_fkv_lpl_1xb). |

Table : ModuleGroup

| **Field** | **Description** |
| --- | --- |
| `ModuleGroup` | Module group can contain one or two modules. Dual camera and stereo camera use cases contain two modules in the group. |
| `moduleConfiguration` | Module configuration information. See [ModuleConfiguration](https://docs.qualcomm.com/doc/80-88500-1/topic/61_Module_configuration_.html#Module_configuration__61__table_qtt_npl_1xb). |

Table : CameraModuleData

| **Field** | **Description** |
| --- | --- |
| `CameraModuleData` | Camera module data. |
| `module_version` | Camera module version. |
| `major_revision` | Contains the driver revision. |
| `minor_revision` | Contains the minor revision number. |
| `incr_revision` | Contains incremental revision number. |
| `moduleGroup` | Specifies the module configuration data such as count, ID, and data. |

## Example camera sensor configuration

    <cameraId>4</cameraId>
    <!--Name of the module integrator -->
    <moduleName>semco</moduleName>
    <!--Name of the sensor in the image sensor module -->
    <sensorName>imx586</sensorName>
    <!--Actuator name in the image sensor module
    This is an optional element. Skip this element if actuator is not present -->
     <actuatorName>lc898217xc</actuatorName>
    <eepromName>cat24c64_imx586</eepromName>
    <flashName>pmic</flashName>
    <!--Chromatix name is used to open binary.
    Binary name is of the form sensor_model_chromatix.bin -->
    <chromatixName>semco_imx586</chromatixName>Copy to clipboard

**Parent Topic:** [Sensor software configuration](https://docs.qualcomm.com/doc/80-88500-1/topic/59_Sensor_software_configuration.html)

Last Published: Aug 18, 2023

[Previous Topic
Sensor information nodes](https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/60_Sensor_information_nodes.md) [Next Topic
Sensor hardware configuration](https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/62_Sensor_hardware_configuration.md)