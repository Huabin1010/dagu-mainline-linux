# Sensor information nodes

Source: [https://docs.qualcomm.com/doc/80-88500-1/topic/60_Sensor_information_nodes.html](https://docs.qualcomm.com/doc/80-88500-1/topic/60_Sensor_information_nodes.html)

## slaveInfo

This node specifies the information that the sensor driver uses while probing the sensor. The following table lists the fields available in the `slaveInfo` node:

Table : Sensor slave information node

| Field | Description |
| --- | --- |
| `slaveInfo` | Contains the sensor slave information and power settings. |
| `sensorName` | Specifies name of the sensor.<br><br><br>                <br>Example: imx230 |
| `slaveAddress` | Specifies slave address (8‑bit or 10‑bit)<br><br><br>                <br>Example: For 0x20 slave address, the field value is 32. |
| `regAddrType` | Specifies register address size in bytes.<br><br><br>                <br>Example:<br>                  <ul class="ul"><br>                    <li class="li">1 = Byte address</li><br><br>                    <li class="li">2 = Word address</li><br><br>                    <li class="li">3 = 3 byte address</li><br><br>                    <li class="li">4 = Address type max</li><br><br>                  </ul> |
| `regDataType` | Specifies register data size in bytes.<br><br><br>                <br>Example:<br>                  <ul class="ul" id="Sensor_information_nodes_60__ul_2"><br>                    <li class="li">1 = Byte data</li><br><br>                    <li class="li">2 = Word data</li><br><br>                    <li class="li">3 = Double word data</li><br><br>                    <li class="li">4 = Data type max</li><br><br>                  </ul> |
| `sensorIdRegAddr` | Specifies register address for sensor ID.<br><br><br>                <br>Example: 22 |
| `sensorId` | Specifies ID of the sensor ID.<br><br><br>                <br>Example: 560 |
| `sensorIDMask` | Specifies mask for sensor ID.<br><br><br>                <br>Example: 4294967295 |
| `i2cFrequencyMode` | Specifies I^2^C frequency mode of slave.<br><br><br>                <br>The supported frequency modes are:<br>                  <ul class="ul" id="Sensor_information_nodes_60__ul_3"><br>                    <li class="li">STANDARD (100 kHz)</li><br><br>                    <li class="li">FAST (400 kHz)</li><br><br>                    <li class="li">FAST_PLUS (1 MHz)</li><br><br>                    <li class="li">CUSTOM (custom frequency in DTSI)</li><br><br>                  </ul><br><br>                  Example: FAST |
| `powerUpSequence` | Contains the power-up configuration sequence required to control the power to the device while turning it on.<br><br><br>                <br>Example:<br><br><br>                <br><br>    <powerUpSequence><br>    <powerSetting><br>    <configType>RESET</configType><br>    <configValue>0</configValue><br>    <delayMs>0</delayMs><br>    </powerSetting><br>    </powerUpSequence >Copy to clipboard |
| `powerSetting` | Contains power configuration details such as power configuration type, configuration value, and delay. |
| `configType` | Specifies power configuration type. Example: MCLK<br><br><br>                <br>Supported configuration types are:<br>                  <ul class="ul" id="Sensor_information_nodes_60__ul_4"><br>                    <li class="li">MCLK</li><br><br>                    <li class="li">VANA</li><br><br>                    <li class="li">VDIG</li><br><br>                    <li class="li">VIO</li><br><br>                    <li class="li">VAF</li><br><br>                    <li class="li">RESET</li><br><br>                    <li class="li">STANDBY</li><br><br>                  </ul> |
| `configValue` | Specifies power configuration value. Example: 19200000<br><br><br>                <br>The recommended value for MCLK is 19200000 (19.2 MHz). |
| `delayMs` | Specifies delay in milliseconds.<br><br><br>                <br>Example: 1 |
| `powerDownSequence` | Contains the power-down configuration sequence that is required to control the power while turning off the device.<br><br><br>                <br>Example:<br>                  <br><br>    <powerDownSequence><br>    <powerSetting><br>    <configType>RESET</configType><br>    <configValue>0</configValue><br>    <delayMs>0</delayMs><br>    </powerSetting><br>    </ powerDownSequence>Copy to clipboard |
| `moduleType` | Specifies the type of sensor module. The supported sensor module types are:<br>                  <ul class="ul" id="Sensor_information_nodes_60__ul_5"><br>                    <li class="li">REAL</li><br><br>                    <li class="li">VIRTUAL</li><br><br>                    <li class="li">EXTERNAL</li><br><br>                  </ul> |

## regAddrInfo node

This node specifies the configuration of register addresses for various sensor features such as to set gain, frame length lines, and test pattern generation. The following table lists the fields available in the `regAddrInfo` node:

Table : regAddrInfo node

| Field | Description |
| --- | --- |
| `regAddrInfo` | Contains the information about the register addresses for various sensor settings. |
| `xOutput` | Controls the program width.<br><br><br>                <br>Example: If the register address is 0x34C, then the value of this field is 844. |
| `yOutput` | Controls the program height.<br><br><br>                <br>Example: 846 |
| `frameLengthLines` | Programs the frame length lines.<br><br><br>                <br>Example: 832 |
| `lineLengthPixelClock` | Programs the line length pixel clock.<br><br><br>                <br>Example: 834 |
| `coarseIntgTimeAddr` | Programs the coarse integration time.<br><br><br>                <br>Example: 514 |
| `middleCoarseIntgTimeAddr` | Programs the coarse integration time of the middle exposure frame.<br><br><br>                <br>Example: 400 |
| `shortCoarseIntgTimeAddr` | Programs the coarse integration time of the short exposure frame.<br><br><br>                <br>Example: 350 |
| `globalGainAddr` | Programs the gain channel.<br><br><br>                <br>Example: 516 |
| `middleGlobalGainAddr` | Programs the gain channel corresponding to the middle exposure.<br><br><br>                <br>Example: 14 |
| `shortGlobalGainAddr` | Programs the gain channel corresponding to the short exposure.<br><br><br>                <br>Example: 10 |
| `digitalGlobalGainAddr` | Programs the digital gain channel.<br><br><br>                <br>Example: 3 |
| `middleDigitalGlobalGainAddr` | Programs the digital gain channel corresponding to the middle exposure.<br><br><br>                <br>Example: 2 |
| `shortDigitalGlobalGainAddr` | Programs the digital gain channel corresponding to the short exposure.<br><br><br>                <br>Example: 1 |
| `digitalGainRedAddr` | Programs the digital gain for the red channel.<br><br><br>                <br>This address is optional but is required if supported by the sensor. Example: 528 |
| `digitalGainGreenRedAddr` | Programs the digital gain for the green-red channel.<br><br><br>                <br>This address is optional but is required if supported by the sensor. Example: 526 |
| `digitalGainBlueAddr` | Programs the digital gain for the blue channel.<br><br><br>                <br>This address is optional but is required when supported by the sensor.<br><br><br>                <br>Example: 530 |
| `digitalGainGreenBlueAddr` | Programs the digital gain for the green-blue channel.<br><br><br>                <br>The address is optional but is required when supported by the sensor. Example: 532 |
| `testPatternRAddr` | Programs the manual test pattern value for the red channel.<br><br><br>                <br>Example: 1538 |
| `testPatternGRAddr` | Programs the manual test pattern value for the green-red channel.<br><br><br>                <br>Example: 1540 |
| `testPatternBAddr` | Programs the manual test pattern value for the blue channel.<br><br><br>                <br>Example: 1542 |
| `testPatternGBAddr` | Programs the manual test pattern value for the green-blue channel.<br><br><br>                <br>Example: 1544 |

## resolutionInfo node

This node specifies the resolution configuration information.

Table : resolutionInfo node

| Field | Description |
| --- | --- |
| `resolutionInfo` | Specifies the configuration and settings for all the resolutions. |
| `resolutionData` | Specifies the configuration data for one resolution.<br><br><br>                <br>The number of sensor-supported resolutions is equal to the number of `resolutionData` nodes.<br>                  <br>Note: First node of the `resolutionData` should always point to the full resolution configuration of the sensor. |
| `colorFilterArrangement` | Specifies the color filter arrangement of the sensor.<br><br><br>                <br>The supported filter arrangements are:<br>                  <ul class="ul" id="Sensor_information_nodes_60__ul_6"><br>                    <li class="li"><code class="ph codeph">BAYER_BGGR</code></li><br><br>                    <li class="li"><code class="ph codeph">BAYER_GBRG</code></li><br><br>                    <li class="li"><code class="ph codeph">BAYER_GRBG</code></li><br><br>                    <li class="li"><code class="ph codeph">BAYER_RGGBn</code></li><br><br>                    <li class="li"><code class="ph codeph">BAYER_Y</code></li><br><br>                    <li class="li"><code class="ph codeph">YUV_UYVY</code></li><br><br>                    <li class="li"><code class="ph codeph">YUV_YUYV</code></li><br><br>                  </ul> |
| `numPixelsPerColor` | Specifies the number of pixels per color in the color filter arrangement.<br><br><br>                <br>The default value is 1. Set this field to 4 for quadra color filter arrangement (QCFA) modes. |
| `streamInfo` | Specifies the stream configuration information.<br><br><br>                <br>For example:<br>                  <br><br>    <streamInfo><br>    <streamConfiguration><br>    <vc range="[0,3]">0</vc><br>    <dt>43</dt><br>    <frameDimension><br>    <xStart>0</xStart><br>    <yStart>0</yStart><br>    <width>4608</width><br>    <height>2592</height><br>    </frameDimension><br>    <bitWidth>10</bitWidth><br>    <type>IMAGE</type><br>    </streamConfiguration><br>    </streamInfo>Copy to clipboard<br><br><br>                  <br>Note: The `frameDimension` in each resolution should not be larger than the `activeDimension`. |
| `streamConfiguration` | Specifies the stream data information. |
| `vc` | Specifies the virtual channel of the data. Valid value range for the virtual channel is from 0 to 31.<br><br><br>                <br>The maximum of two virtual channels per stream can be defined, one even and one odd.<br><br><br>                <br>These virtual channels must be defined for modes that support the seamless mode switch.<br><br><br>                <br>When supporting multiple virtual channels for seamless mode switch as well as staggered high dynamic range (SHDR) or QCFA, add even and odd values for virtual channel.<br><br><br>                <br>For details, see the sensor-specific documentation. |
| `dt` | Specifies the `DT` of the stream.<br><br><br>                <br>Default value is 0x2B (10 bit RAW). |
| `frameDimension` | Specifies the frame dimensions. Contains X and Y start coordinates, and the total width and height of the image. |
| `xStart` | Specifies the X coordinate of start of the image. |
| `yStart` | Specifies the Y coordinate of start of the image. |
| `width` | Specifies the width of the image. |
| `height` | Specifies the height of the image. |
| `bitWidth` | Specifies the bit width of the data. |
| `type` | Specifies the stream type. For example: IMAGE.<br><br><br>                <br>The supported stream types are:<br>                  <ul class="ul" id="Sensor_information_nodes_60__ul_7"><br>                    <li class="li"><code class="ph codeph">BLOB</code>: format type of snapshots</li><br><br>                    <li class="li"><code class="ph codeph">IMAGE</code>: long exposure frame when there are multiple image frames generated, and default image frame when there is a single image frame.</li><br><br>                    <li class="li"><code class="ph codeph">IMAGE_SHORT</code>: short exposure frame when there are multiple image frames generated.</li><br><br>                    <li class="li"><code class="ph codeph">PDAF</code>: phase difference autofocus (PDAF) data generated by the sensor during the same frame blanking period as the image.</li><br><br>                    <li class="li"><code class="ph codeph">HDR</code>: any histogram static data generated by the sensor during the same frame blanking period as the image.</li><br><br>                    <li class="li"><code class="ph codeph">META</code>: sensor frame meta stream output data.</li><br><br>                  </ul> |
| `lineLengthPixelClock` | Specifies line length pixel clock of the frame. Typically, this value is sum of the active width and blanking width. |
| `frameLengthLines` | Specifies frame length lines of the frame. Typically, this value is the sum of active height and blanking height. |
| `minHorizontalBlanking` | Specifies the minimum horizontal blanking interval in pixels. |
| `minVerticalBlanking` | Specifies the minimum vertical blanking interval in lines. |
| `outputPixelClock` | This value should be obtained from the sensor vendor for a given mode of operation.<br>                  <br>Note: The incorrect setting can cause issues such as PHY/CSID errors, incorrect IFE resource/clock selection. |
| `horizontalBinning` | Specifies the horizontal binning value. |
| `verticalBinning` | Specifies the vertical binning value. |
| `framerate` | Specifies the maximum frame rate. |
| `laneCount` | Specifies the number of data lanes on which the sensor sends output data for a given mode of operation. The maximum datalane capability (given in the datasheet) of the sensor along with the sensor register settings configured in the driver determines the value. |
| `settleTimeNs` | Specifies the settle time in nanoseconds. This field is configured based on the output characteristics of the sensor to ensure that the PHY transmitter of the sensor does not have synchronization issues with the PHY receiver of the device.<br><br><br>                <ul class="ul" id="Sensor_information_nodes_60__ul_8"><br>                  <li class="li">D‑PHY: <p class="p"><code class="ph codeph">settleTimeNs = ((85ns + 6UI)/T(Timer_clk) ) –<br>                      10</code></p><br><br>                    <p class="p">Where, <code class="ph codeph">TIMER_CLK</code> refers to the operating frequency of the<br>                      PHY interface to which the camera sensor is connected. </p><br><br>                    <p class="p">For example, <code class="ph codeph">CAMSS_PHY0_CSI0PHYTIMER_CLK</code> for PHY0. This<br>                      value is set in the <span class="ph filepath">camera.dtsi</span> file. Mostly the value of<br>                      this field is 300 MHz but review the clock log before configuring the value.<br>                      For more details, see MIPI D-PHY v1.2 specification.</p><br><br>                  </li><br><br>                  <li class="li">C-PHY:<br>                    <p class="p"><code class="ph codeph">Ideal settleTimeNs = {t3-prepare+[t3-preamble]/3}/Ttimer_clock-10</code></p><br><br>                    <div class="p">Work with the sensor vendor to set <code class="ph codeph">t3-prepare</code> as minimum of a value as possible and see MIPI C-PHY v1.2/v2.0 specification. For sensors supporting C-PHY v1.2/v2.0, ensure that the values of <code class="ph codeph">T3-CALPREAMBLE</code>, <code class="ph codeph">T3-ASID</code> and <code class="ph codeph">T3-CALALTSEQ</code> timing parameters are compliant to MIPI C-PHY v1.2/v2.0 specifications as described in section 6.12.1.2 Calibration pattern format 2.<br>                      <ul class="ul" id="Sensor_information_nodes_60__ul_13"><br>                        <li class="li"><code class="ph codeph">Ttimer_clock</code>: The value for this parameter is equal to the PHY timer clock cycle time. For customization scenarios, use the correct value based on the sensor configuration and output data rate. The unit for this parameter is nanoseconds.</li><br><br>                        <li class="li"><code class="ph codeph">t3-prepare</code>: Confirm the value with the sensor vendor. When not sure, measure using the logic analyzer. The value of this parameter can be different for each resolution mode setting. The unit for this parameter is nanoseconds.</li><br><br>                        <li class="li"><code class="ph codeph">t3-preamble</code>: Confirm with the sensor vendor. The value for this parameter can be different for each resolution mode setting. The unit for this parameter is nanoseconds.</li><br><br>                      </ul><br><br>                      Confirm with the sensor vendor that the sensor meets the minimum requirements of the receiver.<br>                      <div class="note note"><span class="notetitle">Note:</span> The UI here is calculated as the cycle time for symbols throughput rate per trio. For example, for the sensor sending output at the rate of 1 Gsps per trio, UI is 1 ns.</div><br><br>                      Time in ns = number of UIs x (1/data rate). The data rate should be in giga samples per second.<br>                      <table cellpadding="4" cellspacing="0" summary="" id="Sensor_information_nodes_60__simpletable_3" border="1" class="simpletable"><col style="width:50%"><col style="width:50%"><thead><tr class="sthead"><br>                          <th style="vertical-align:bottom;text-align:left;" id="d11480e1451" class="stentry"><strong class="ph b">Timing parameter</strong></th><br><br>                          <th style="vertical-align:bottom;text-align:left;" id="d11480e1455" class="stentry"><strong class="ph b">Minimum value (not data rate dependent)</strong></th><br><br>                        </tr><br></thead><tbody><tr class="strow"><br>                          <td style="vertical-align:top;" headers="d11480e1451" class="stentry"><br>                            <p class="p">Preamble</p><br><br>                          </td><br><br>                          <td style="vertical-align:top;" headers="d11480e1455" class="stentry"><br>                            <p class="p">168 UI</p><br><br>                          </td><br><br>                        </tr><br><tr class="strow"><br>                          <td style="vertical-align:top;" headers="d11480e1451" class="stentry"><br>                            <p class="p">POST</p><br><br>                          </td><br><br>                          <td style="vertical-align:top;" headers="d11480e1455" class="stentry"><br>                            <p class="p">168 UI</p><br><br>                          </td><br><br>                        </tr><br><tr class="strow"><br>                          <td style="vertical-align:top;" headers="d11480e1451" class="stentry"><br>                            <p class="p">LP001</p><br><br>                          </td><br><br>                          <td style="vertical-align:top;" headers="d11480e1455" class="stentry"><br>                            <p class="p">50 ns</p><br><br>                          </td><br><br>                        </tr><br><tr class="strow"><br>                          <td style="vertical-align:top;" headers="d11480e1451" class="stentry"><br>                            <p class="p">LP111 (between data packets) 100 ns </p><br><br>                          </td><br><br>                          <td style="vertical-align:top;" headers="d11480e1455" class="stentry"><br>                            <p class="p">100 ns</p><br><br>                          </td><br><br>                        </tr><br><tr class="strow"><br>                          <td style="vertical-align:top;" headers="d11480e1451" class="stentry"><br>                            <p class="p">LP000</p><br><br>                          </td><br><br>                          <td style="vertical-align:top;" headers="d11480e1455" class="stentry"><br>                            <p class="p">7050 ns</p><br><br>                          </td><br><br>                        </tr><br></tbody></table><br><br>                    </div><br><br>                  </li><br><br>                </ul> |
| `Is3Phase` | Indicates if the sensor is a 3-phase sensor (C-PHY) or 1-phase sensor (D-PHY). |
| `resSettings` | Specifies register settings to configure the device for a particular resolution.<br><br><br>                <br>Note: Do not add `streamOn` settings for the sensor in the initialization settings, as this setting enables the sensor streaming before the actual software stream is turned on and may cause PHY to miss the LP sequence.<br><br><br>                <br>For example:<br>                  <br><br>    <resSettings><br>    <regSetting><br>    <registerAddr>0x114</registerAddr><br>    <registerData>0x3</registerData><br>    <regAddrType range="[1,4]">2</regAddrType><br>    <regDataType range="[1,4]">1</regDataType><br>    <operation>WRITE</operation><br>    <delayUs>0x0</delayUs><br>    </regSetting><br>    <resSettings>Copy to clipboard |
| `regSetting` | Holds one register configuration and forms a unit of large-resolution register settings sequence. |
| `registerAddr` | Specifies the register address that is accessed. |
| `registerData` | Specifies the size of data to be read or written.<br>                  <ul class="ul" id="Sensor_information_nodes_60__ul_19"><br>                    <li class="li">If the operation is <code class="ph codeph">WRITE</code>, this field specifies the data value to be written into the specified register address.</li><br><br>                    <li class="li">If the operation is <code class="ph codeph">READ</code>, this field specifies the number of bytes to be read from the specified register address.</li><br><br>                  </ul> |
| `regAddrType` | Specifies the type of register address. |
| `regDataType` | Specifies the type of register data. |
| `operation` | Specifies the type of operation. The supported values are:<br><br><br>                <ul class="ul" id="Sensor_information_nodes_60__ul_20"><br>                  <li class="li">WRITE</li><br><br>                  <li class="li">READ</li><br><br>                  <li class="li">POLL</li><br><br>                </ul> |
| `delayUs` | Specifies the delay in microseconds. If not explicitly specified, the delay is zero. |
| `cropInfo` | Specifies the crop information of the frame. For example:<br><br><br>                <br><br>    <cropInfo><br>    <left>0</left><br>    <right>0</right><br>    <top>0</top><br>    <bottom>0</bottom><br>    </cropInfo>Copy to clipboard |
| `Left` | Specifies the left crop pixel information. |
| `Right` | Specifies the right crop pixel information. |
| `Top` | Specifies the top crop pixel information. |
| `Bottom` | Specifies the bottom crop pixel information. |
| `exposureInfo` | Specifies the resolution-specific exposure control information. Update this field if the resolution-specific exposure control is different from the common resolution exposure control information. If this information is not available, then information from the common exposure control is used. |
| `exposureType` | Specifies the information about the exposure type for which the exposure control information is being provided. The supported values are:<br>                  <ul class="ul" id="Sensor_information_nodes_60__ul_21"><br>                    <li class="li">DEFAULT: corresponds to the long exposure when there are multiple exposures and default exposure for a single exposure mode.</li><br><br>                    <li class="li">SHORT: corresponds to the short exposure when there are multiple exposures.</li><br><br>                    <li class="li">MIDDLE: corresponds to the middle exposure when there are multiple exposures.</li><br><br>                  </ul> |
| `coarseIntgTimeAddr` | Specifies register address to program the coarse integration time for this exposure type. |
| `globalGainAddr` | Specifies register address to program the gain channel for this exposure type. |
| `digitalGlobalGainAddr` | Specifies register address to program the digital gain channel for this exposure type. |
| `maxAnalogGain` | Specifies maximum analog gain supported by the sensor. |
| `minAnalogGain` | Specifies minimum analog gain supported by the sensor. |
| `maxDigitalGain` | Specifies maximum digital gain supported by the sensor. |
| `minDigitalGain` | Specifies minimum digital gain supported by the sensor. |
| `maxLineCount` | Specifies maximum line count supported by the sensor. |
| `minLineCount` | Specifies minimum line count supported by the sensor. |
| `verticalOffset` | Specifies minimum offset to be maintained between the line count and frame length lines. |
| `frameOffsetInfo` | Holds addresses of various frame offset registers. |
| `middleFrameOffsetRegister` | Specifies register address to program the frame-offset value of the middle exposure frame. |
| `shortFrameOffsetRegister` | Specifies register address to program the frame-offset value of the short exposure frame. |
| `HDRExposureType` | Specifies information about the HDR exposure type of this resolution.<br><br><br>                <br>**Note:** This value must be provided for the HDR resolution.<br><br><br>                <br>The supported values are:<br>                  <ul class="ul" id="Sensor_information_nodes_60__ul_22"><br>                    <li class="li">ONEEXPOSURE: indicates that one exposure is used in the HDR mode.</li><br><br>                    <li class="li">TWOEXPOSURE: indicates that both long and short exposures are used in the<br>                      HDR mode.</li><br><br>                    <li class="li">THREEEXPOSURE: indicates that long, middle and short exposures are used in<br>                      the HDR mode.</li><br><br>                  </ul> |
| `ZZHDRInfo` | zzHDR color pattern and first exposure information. The supported values are:<br>                  <ul class="ul" id="Sensor_information_nodes_60__ul_23"><br>                    <li class="li"><code class="ph codeph">ZZHDRPattern</code>: represents the zzHDR pattern such as <code class="ph codeph">P0P1P0P0</code></li><br><br>                    <li class="li"><code class="ph codeph">ZZHDRFirstExposure</code>: represents whether the short exposure or long exposure field comes first such as <code class="ph codeph">SHORTEXPOSURE</code></li><br><br>                  </ul> |
| `HDR3ExposureInfo` | Information of in-sensor HDR 3 exposure.<br><br><br>                <ul class="ul" id="Sensor_information_nodes_60__ul_ikh_srm_1xb"><br>                  <li class="li"><code class="ph codeph">HDR3ExposureType</code>: Exposure type for 3HDR nonseamless mode.</li><br><br>                  <li class="li"><code class="ph codeph">numberOfLTCRatioRegCount</code>: Number of LTC ratio registers.</li><br><br>                  <li class="li"><code class="ph codeph">sensorLTCRatioAddr</code>: Register address to program LTC ratio.</li><br><br>                  <li class="li"><code class="ph codeph">InSensorHDR3ExpLineLengthPixelClock</code>: <code class="ph codeph">LineLengthPixelClock</code> for seamless in-sensor HDR 3 exposure mode switching.</li><br><br>                  <li class="li"><code class="ph codeph">InSensorHDR3ExpFrameLengthLines</code>: <code class="ph codeph">FrameLengthLines</code> for seamless in-sensor HDR 3 exposure mode switching.</li><br><br>                </ul><br><br>                <ul class="ul"><br>                  <li class="li"><code class="ph codeph">InSensorHDR3ExpMaxAnalogGain</code>: <code class="ph codeph">MaxAnalogGain</code> for seamless in-sensor HDR 3 exposure mode switching.</li><br><br>                  <li class="li"><code class="ph codeph">InSensorHDR3ExpStartSettings</code>: <code class="ph codeph">StartSetting</code> sequence for seamless in-sensor HDR 3 exposure mode switching.</li><br><br>                  <li class="li"><code class="ph codeph">InSensorHDR3ExpStopSettings</code>: <code class="ph codeph">StopSetting</code> sequence for seamless in-sensor HDR3 exposure mode switching.</li><br><br>                </ul> |
| `RemosaicTypeInfo` | Specifies the remosaic type. The supported types are:<br>                  <ul class="ul" id="Sensor_information_nodes_60__ul_24"><br>                    <li class="li"><code class="ph codeph">SWRemosaic</code></li><br><br>                    <li class="li"><code class="ph codeph">HWRemosaic</code></li><br><br>                    <li class="li"><code class="ph codeph">NoRemosaic</code></li><br><br>                  </ul> |
| `capability` | Specifies the features or capabilities supported by the sensor. The supported features are:<br>                  <ul class="ul" id="Sensor_information_nodes_60__ul_32"><br>                    <li class="li">ONFD</li><br><br>                    <li class="li">AONFDMIPI</li><br><br>                    <li class="li">AONMD</li><br><br>                    <li class="li">DEPTH</li><br><br>                    <li class="li">FASTAEC</li><br><br>                    <li class="li">FS</li><br><br>                    <li class="li">HFR</li><br><br>                    <li class="li">IHDR</li><br><br>                    <li class="li">INSENSORZOOM</li><br><br>                    <li class="li">INTERNAL</li><br><br>                    <li class="li">NORMAL</li><br><br>                    <li class="li">PDAF</li><br><br>                    <li class="li">QHDR</li><br><br>                    <li class="li">QUADCFA</li><br><br>                    <li class="li">SHDR</li><br><br>                    <li class="li">ZZHDR</li><br><br>                  </ul> |
| `ADCReadoutTime` | Specifies analog-to-digital conversion duration for the sensor. The value is specified in milliseconds. Example: 2. |
| `mipiFlags` | Defines any extra MIPI parameters that the receiver should take care of. The supported flags are:<br><br><br>                <ul class="ul" id="Sensor_information_nodes_60__ul_mkh_srm_1xb"><br>                  <li class="li"><code class="ph codeph">EPDEnabled</code></li><br><br>                  <li class="li"><code class="ph codeph">DSKEWCalibEnabled</code></li><br><br>                  <li class="li"><code class="ph codeph">PN9PatternEnabled</code></li><br><br>                </ul> |
| `maxAnalogGain` | Specifies maximum analog gain supported by current sensor mode. |
| `QHDRInfo` | Specifies QCFAHDR feature information.<br><br><br>                <ul class="ul" id="Sensor_information_nodes_60__ul_nkh_srm_1xb"><br>                  <li class="li"><code class="ph codeph">QHDRType</code>:<br>                    <ul class="ul" id="Sensor_information_nodes_60__ul_okh_srm_1xb"><br>                      <li class="li"><code class="ph codeph">PIXELINTERLEAVED</code>: QCFA format like native pixel arrangement.</li><br><br>                      <li class="li"><code class="ph codeph">ROWINTERLEAVED</code>: Each exposure on different line through the same VC-DT.</li><br><br>                      <li class="li"><code class="ph codeph">OWINLINEINTERLEAVED</code>: Each exposure on different line through the different VC-DT.</li><br><br>                    </ul><br><br>                  </li><br><br>                  <li class="li"><code class="ph codeph">QHDRPattern</code>: Valid patterns are MLSM, SMML, MSLM, LMMS, MLMS, SMLM, MSML, and LMSM.<br>                    <p class="p">In direction of readout: first exposure, second exposure, third exposure, fourth exposure. </p><br><br>                  </li><br><br>                </ul><br><br>                <br>Note: L is long exposure, M is middle exposure, and S is short exposure. |
| `transitionGroups` | Specifies list of seamless mode switch use cases that the sensor mode can support.<br><br><br>                <br>The supported modes are:<br><br><br>                <ul class="ul" id="Sensor_information_nodes_60__ul_pkh_srm_1xb"><br>                  <li class="li">NONE</li><br><br>                  <li class="li">BINCROP43</li><br><br>                  <li class="li">BINQCFA43</li><br><br>                  <li class="li">BINHDR43</li><br><br>                  <li class="li">BINCROP169</li><br><br>                  <li class="li">BINQCFA169</li><br><br>                  <li class="li">BINHDR169</li><br><br>                  <li class="li">SHDR1SHDR2</li><br><br>                  <li class="li">SHDR2SHDR3</li><br><br>                  <li class="li">SHDR1SHDR3</li><br><br>                  <li class="li">SHDRALL</li><br><br>                  <li class="li">TRANSITIONGROUPMAX</li><br><br>                </ul><br><br>                <br>For more details, see the imx686 sensor XML file.<br><br><br>                <br>`<transitionGroups>BINCROP43BINCROP169</transitionGroups>` |

If `INSENSORZOOM` is defined, then the resolution information should be the same. For example, assuming Mode 0 `resolutionInfo` is 8000 \* 6000 and Mode 9 is the corresponding mode with `INSENSORZOOM`. So, the Mode 9 `resolutionInfo` should be the same as Mode 0 as there is no sensor reconfiguration during the mode switch, which means the sensor hardware PLL clock settings remain the same in both the modes.

The `frameDimension` is based on the sensor full output resolution.

For example,`frameDim` = (0,517,4208,2104), `fullResolutionWidth`=4208, and `fullResolutionHeight`=3120. Then, 517 is an invalid value, as 517 \* 2 + 2104 is larger than the frame boundary that is 3120.

## exposureControlInfo node

This node specifies the exposure details such as maximum gain, maximum line count, and conversion formulas for gain manipulation.

Table : exposureControlInfo node

| **Field** | **Description** |
| --- | --- |
| `exposureControlInfo` | This node holds the information about the exposure details such as maximum gain, maximum line count, and conversion formulas for gain manipulation. Example:<br><br><br>                <br><br>    <exposureControlInfo><br>    <maxAnalogGain>8</maxAnalogGain><br>    <maxDigitalGain>2</maxDigitalGain><br>    <verticalOffset>20</verticalOffset><br>    <maxLineCount>65515</maxLineCount><br>    <realToRegGain>512-(512/realGain)</realToRegGain><br>    <regToRealGain>512/(512-regGain)</regToRealGain><br>    </exposureControlInfo>Copy to clipboard |
| `maxAnalogGain` | Maximum analog gain supported by the sensor. |
| `maxDigitalGain` | Maximum digital gain supported by the sensor. |
| `verticalOffset` | Minimum offset to be maintained between the line count and frame length lines. |
| `maxLineCount` | Maximum line count supported by the sensor. |
| `minLineCount` | Minimum line count supported by the sensor. |
| `middleMaxLineCount` | Maximum line count supported by the sensor for middle exposure. |
| `middleMinLineCount` | Minimum line count supported by the sensor for middle exposure. |
| `shortMaxLineCount` | Maximum line count supported by the sensor for short exposure. |
| `shortMinLineCount` | Minimum line count supported by the sensor for short exposure. |
| `realToRegGain` | Specifies the real gain to register gain equation. The equation must contain real gain. |
| `regToRealGain` | Specifies the register gain to real gain equation. The equation must contain register gain in the equation. |

## streamOnSettings node

This node specifies the register settings required to start streaming.

| **Field** | **Description** |
| --- | --- |
| `streamOnSettings` | Specifies the sequence of register settings to configure the device to start streaming. Do the following configuration and take the clock and data lanes from LP11 to HS TxState:<br><br><br>                <br><br>    <streamOnSettings><br>    <regSetting><br>    <registerAddr>0x0100</registerAddr><br>    <registerData>0x1</registerData><br>    <regAddrType range="[1,4]">2</regAddrType><br>    <regDataType range="[1,4]">1</regDataType><br>    <operation>WRITE</operation><br>    <delayUs>0</delayUs><br>    </regSetting><br>    </streamOnSettings>Copy to clipboard |
| `regSetting` | This field contains register address, register data, register address type, register DT, operation, and delay in micro seconds. |
| `streamOffSettings` | Specifies the sequence of register settings to configure the device to stop streaming. Do the following configuration and take the clock and data lanes to LP11 state:<br><br><br>                <br><streamOffSettings><br>    <regSetting><br>    <registerAddr>0x0100</registerAddr><br>    <registerData>0x0</registerData><br>    <regAddrType range="[1,4]">2</regAddrType><br>    <regDataType range="[1,4]">1</regDataType><br>    <operation>WRITE</operation><br>    <delayUs>0</delayUs><br>    </regSetting><br>    </streamOffSettings>Copy to clipboard |
| `regSetting` | This field contains register address, register data, register address type, register DT, operation, and delay in micro seconds. |

## groupHoldOnSettings node

This node specifies the register settings to configure the group hold settings of the device.

| **Field** | **Description** |
| --- | --- |
| `groupHoldOnSettings` | Specifies sequence of register settings to configure the device to start group hold settings.<br><br><br>                <br>Example:<br><br><br>                <br><br>    <groupHoldOnSettings><br>    <regSetting><br>    <registerAddr>0x0104</registerAddr><br>    <registerData>0x1</registerData><br>    <regAddrType range="[1,4]">2</regAddrType><br>    <regDataType range="[1,4]">1</regDataType><br>    <operation>WRITE</operation><br>    <delayUs>0</delayUs><br>    </regSetting><br>    </groupHoldOnSettings>Copy to clipboard |
| `regSetting` | Specifies register address, register data, register address type, register data type, operation, and delay in micro seconds. |
| `groupHoldOffSettings` | Specifies sequence of register settings to configure the device to stop group hold settings.<br><br><br>                <br>Example:<br><br><br>                <br><br>    <groupHoldOffSettings><br>    <regSetting><br>    <registerAddr>0x0104</registerAddr><br>    <registerData>0x0</registerData><br>    <regAddrType range="[1,4]">2</regAddrType><br>    <regDataType range="[1,4]">1</regDataType><br>    <operation>WRITE</operation><br>    <delayUs>0</delayUs><br>    </regSetting><br>    </groupHoldOffSettings>Copy to clipboard |

## initSettings node

This node specifies the sequence of register settings required to initialize the sensor.

| **Field** | **Description** |
| --- | --- |
| `initSettings` | Sequence of register settings to initialize the sensor.<br><br><br>                <br>**Note**: Do not add `stream on` settings for the sensor in the initialization settings, as this setting enables the sensor streaming before the actual software stream turns on and may cause PHY to miss the LP sequence.<br><br><br>                <br>Example:<br><br><br>                <br><br>    <initSettings><br>    <regSetting><br>    <registerAddr>0x136</registerAddr><br>    <registerData>0x18</registerData><br>    <regAddrType range="[1,4]">2</regAddrType><br>    <regDataType range="[1,4]">1</regDataType><br>    <operation>WRITE</operation><br>    <delayUs>0</delayUs><br>    </regSetting><br>    </initSettings>Copy to clipboard |
| `regSetting` | Specifies register settings such as register address, register data, register address type, register data type, operation, and delay in micro seconds. |

## testPatternInfo node

This node specifies the information about the register settings required for test pattern
        generation. 

| **Field** | **Description** |
| --- | --- |
| `testPatternInfo` | Contains the register settings information about the test pattern generation<br>                    node.<br><br><br>                  <br>Example:<br><br><br>                  <br><br>    <testPatternInfo><br>    <testPatternData><br>    <mode>OFF</mode><br>    <settings><br>    <regSetting><br>    <registerAddr>0x136</registerAddr><br>    <registerData>0x18</registerData><br>    <regAddrType range="[1,4]">2</regAddrType><br>    <regDataType range="[1,4]">1</regDataType><br>    <operation>WRITE</operation><br>    <delayUs>0</delayUs><br>    </regSetting><br>    </settings><br>    </testPatternData><br>    </testPatternInfo>Copy to clipboard |

## testPatternData node

This node specifies the information about the test pattern data.

| **Field** | **Description** |
| --- | --- |
| `testPatternData` | This node holds the register and mode settings of a particular test pattern. |
| `Mode` | The supported modes are:<br><br><br>                <ul class="ul"><br>                  <li class="li">OFF</li><br><br>                  <li class="li">SOLID_COLOR</li><br><br>                  <li class="li">COLOR_BARS</li><br><br>                  <li class="li">COLOR_BARS_FADE_TO_GRAY</li><br><br>                  <li class="li">PN9</li><br><br>                  <li class="li">CUSTOM1</li><br><br>                </ul> |
| `settings` | Sequence of register settings to configure the test pattern on the sensor. |
| `regSetting` | This field contains register address, register data, register address type, register data type, operation, and delay in micro seconds. |

## colorLevelInfo node

The node specifies the color level information such as details about the various channels present in complete dark light.

Table : colorLevelInfo node

| **Field** | **Description** |
| --- | --- |
| `colorLevelInfo` | Specifies color level information.<br><br><br>                <br>Defaults to current values in various channels in complete dark light.<br><br><br>                <br>Example:<br><br><br>                <br><br>    <colorLevelInfo><br>    <whiteLevel>1023</whiteLevel><br>    <rPedestal>64</rPedestal><br>    <grPedestal>64</grPedestal><br>    <bPedestal>64</bPedestal><br>    <gbPedestal>64</gbPedestal><br>    </colorLevelInfo>Copy to clipboard |
| `whiteLevel` | Specifies value for White level . |
| `rPedestal` | Specifies pedestal value for the red channel. |
| `grPedestal` | Specifies pedestal value for the green-red channel. |
| `bPedestal` | Specifies pedestal value for the blue channel. |
| `gbPedestal` | Specifies pedestal value for the green-blue channel. |

Table : Black region information

| **Field** | **Description** |
| --- | --- |
| `opticalBlackRegionInfo` | Specifies information about black regions. Multiple black regions are provided, if applicable.<br><br><br>                <br>Example:<br><br><br>                <br><br>    <opticalBlackRegionInfo><br>    <dimension><br>    <xStart>0</xStart><br>    <yStart>0</yStart><br>    <width>4608</width><br>    <height>2592</height><br>    </dimension><br>    </opticalBlackRegionInfo>Copy to clipboard |
| `dimension` | Specifies frame dimension. Contains `xStart`, `yStart`, `width`, and `height` fields. |
| `xStart` | Specifies starting coordinate of the region on the X-axis. |
| `yStart` | Specifies starting coordinate of the region on the Y-axis. |
| `width` | Specifies width of the region. |
| `height` | Specifies height of the region. |

Table : Pixel array information

| **Field** | **Description** |
| --- | --- |
| `pixelArrayInfo` | Specifies information about the pixel array such as active dimension, dummy pixels width. |
| `activeDimension` | Width and height of the frame or subframe.<br><br><br>                <br>Example:<br><br><br>                <br><br>    <activeDimension><br>    <xStart>0</xStart><br>    <yStart>0</yStart><br>    <width>4608</width><br>    <height>2592</height><br>    </activeDimension>Copy to clipboard |
| `xStart` | Specifies starting coordinate of the frame on the X-axis. |
| `yStart` | Specifies starting coordinate of the frame on the Y-axis. |
| `width` | Total width of the frame in pixels. |
| `height` | Total height of the frame in pixels. |
| `dummyInfo` | Specifies dummy pixels surrounding the active pixel array.<br><br><br>                <br>Example:<br><br><br>                <br><br>    <dummyInfo><br>    <left>0</left><br>    <right>0</right><br>    <top>0</top><br>    <bottom>0</bottom><br>    </dummyInfo>Copy to clipboard |
| `left` | Specifies starting coordinate of the left dummy pixel. |
| `right` | Specifies starting coordinate of the right dummy pixel. |
| `top` | Specifies starting coordinate of the top dummy pixel. |
| `bottom` | Specifies starting coordinate of the bottom dummy pixel. |

Table : Delay information

| **Field** | **Description** |
| --- | --- |
| `linecount` | Specifies number of frames required to apply the line count. |
| `gain` | Specifies number of frames required to apply the gain. |
| `maxPipeline` | Specifies maximum pipeline delay in number of frames. |
| `frameSkip` | Specifies number of initial bad frames to skip. |
| `frameLengthLines` | Specifies number of frames required to apply frame length lines. |
| `modeSwitch` | Specifies number of frames required to apply mode switch settings. |
| `virtualChannelSwitch` | Specifies number of frames required to apply virtual channel settings. |

Table : Sensor property information

| **Field** | **Description** |
| --- | --- |
| `sensorProperty` | Specifies sensor property information. Example:<br><br><br>                <br><br>    <sensorProperty><br>    <pixelSize>0</pixelSize><br>    <cropFactor>0</cropFactor><br>    <sensingMethod>ONE_CHIP_COLOR_AREA</sensingMethod><br>    </sensorProperty>Copy to clipboard |
| `pixelSize` | Specifies pixel size in micro meters. |
| `cropFactor` | Specifies crop factor. |
| `sensingMethod` | Specifies sensing method of the sensor. The supported sensing methods are:<br><br><br>                <ul class="ul" id="Sensor_information_nodes_60__ul_mph_bgn_1xb"><br>                  <li class="li">UNDEFINED</li><br><br>                  <li class="li">ONE_CHIP_COLOR_AREA TWO_CHIP_COLOR_AREA</li><br><br>                  <li class="li">THREE_CHIP_COLOR_AREA</li><br><br>                  <li class="li">COLOR_SEQUENCE_AREA</li><br><br>                  <li class="li">TRILINEAR</li><br><br>                  <li class="li">COLOR_SEQUENCE_LINEAR</li><br><br>                </ul> |

## frameSyncInfo node

This node specifies the frame sync information required to configure or switch sensor in master/slave mode.

Table : Frame sync information

| **Field** | **Description** |
| --- | --- |
| `masterSettings` | Specifies sequence of register settings to configure the sensor to hardware master mode. Valid only when hardware sync is enabled. Example:<br><br><br>                <br><br>    < masterSettings><br>    <regSetting><br>    <registerAddr>0x0350</registerAddr><br>    <registerData>0x0</registerData><br>    <regAddrType range="[1,4]">2</regAddrType><br>    <regDataType range="[1,4]">1</regDataType><br>    <operation>WRITE</operation><br>    <delayUs>0</delayUs><br>    </regSetting><br>    </ masterSettings>Copy to clipboard |
| `slaveSettings` | Specifies sequence of register settings to configure the sensor to hardware slave mode. It is similar to master settings. |

Table : Mode switch register information

| **Field** | **Description** |
| --- | --- |
| `modeSwitchRegInfo` | Specifies register settings and virtual channel register addresses to be programmed during seamless mode switch for the following data types:<br><br><br>                <ul class="ul" id="Sensor_information_nodes_60__ul_cft_sc1_4xb_auppara_05-22-23-2302-42-784"><br>                  <li class="li"><code class="ph codeph">PDAFVCAddress</code></li><br><br>                  <li class="li"><code class="ph codeph">ImageLongVCAddress</code></li><br><br>                  <li class="li"><code class="ph codeph">ImageShortVCAddress</code></li><br><br>                  <li class="li"><code class="ph codeph">ImageMiddleVCAddress</code></li><br><br>                  <li class="li"><code class="ph codeph">BlobVCAddress</code></li><br><br>                  <li class="li"><code class="ph codeph">HDRVCAddress</code></li><br><br>                  <li class="li"><code class="ph codeph">MetaVCAddress</code></li><br><br>                </ul><br><br>                <br>Example:<br>                  <br><br>    <modeSwitchRegInfo><br>    <regAddrType>2</regAddrType><br>    <regDataType>1</regDataType><br>    <ImageLongVCAddress>0x0110</ ImageLongVCAddress><br>    <PDAFVCAddress>0x3076</PDAFVCAddress><br>    </modeSwitchRegInfo>Copy to clipboard |

Table : Register setting group information

| **Field** | **Description** |
| --- | --- |
| `registerSettings` | Specifies register settings that must be programmed as a part of this group. |
| `registerSettingsType` | Specifies the register setting type. The supported values are:<br><br><br>                <ul class="ul" id="Sensor_information_nodes_60__ul_33"><br>                  <li class="li"><code class="ph codeph">StreamOn</code>: Specifies stream on settings for special use cases.</li><br><br>                  <li class="li"><code class="ph codeph">StreamOff</code>: Specifies stream off settings for special use cases.</li><br><br>                </ul> |
| `registerSettingsFlag` | Specifies any settings specially applied for certain use cases. The supported value is `PN9Test`. This value indicates settings to be used during PN9 pattern testing case. |

**Parent Topic:** [Sensor software configuration](https://docs.qualcomm.com/doc/80-88500-1/topic/59_Sensor_software_configuration.html)

Last Published: Aug 18, 2023

[Previous Topic
Sensor software configuration](https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/59_Sensor_software_configuration.md) [Next Topic
Module configuration](https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/61_Module_configuration_.md)