# Sensor library configuration

Source: [https://docs.qualcomm.com/doc/80-88500-1/topic/73_Sensor_library_configuration.html](https://docs.qualcomm.com/doc/80-88500-1/topic/73_Sensor_library_configuration.html)

Sensor infrastructure provides an interface to write customized gain or exposure update
      functions. With this interface, each sensor can have its own custom library, which implements
      the API exposed in the `camxsensordriverAPI.h` file. After the API methods are
      implemented, generate the library with the name `com.<vendor
        name>.sensor.<sensor name>.so`. Include this file in the `device-
        vendor.mk` file along with the other library files that must be generated.

Generated library is available at /usr/lib/camera/.

Once the library with the specified syntax name in the specified path is available, the sensor
      software module loads the binary and accesses the API methods to use for exposure-related
      functionality.

Sample library implementation for the imx318 sensor is available at
        src/vendor/qcom/proprietary/chi-cdk/oem/qcom/sensor/imx318/.

This infrastructure also allows data published using the `vendor` tag
        `org.quic.camera2.sensor_register_control` to read and pass it to the sensor
      library as `SensorFillExposureData->additionalInfo`.

## Library functions

You can define an addition to the sensor driver using a library. This library can only
        contain gain-specific functions with the following definitions:

    static double RegisterToRealGain(unsigned int regGain);
    static unsigned int RealToRegisterGain(double realGain);Copy to clipboard

**Example:**

    static double RegisterToRealGain(unsigned int regGain){ 
    double realGain;
    if(regGain > SENSOR_MAkX_AGAIN_REG_VAL){ regGain = IMX318_MAX_AGAIN_REG_VAL;}realGain = 512.0 / (512.0 - regGain); return realGain;
    }
    static unsigned int RealToRegisterGain(double realGain){ 
    unsigned int regGain = 0;
    if (realGain < IMX318_MIN_AGAIN){ realGain = SENSOR_MIN_AGAIN;
    }
    regGain = (unsigned int)(512.0 - (512.0 / realGain)); return regGain;
    }
    void GetSensorLibraryAPIs(SensorLibraryAPI* pSensorLibraryAPI){ pSensorLibraryAPI->pRealToRegisterGain = RealToRegisterGain; pSensorLibraryAPI->pRegisterToRealGain = RegisterToRealGain;
    }Copy to clipboard

**Parent Topic:** [Camera sensor driver](https://docs.qualcomm.com/doc/80-88500-1/topic/58_Camera_sensor_driver_.html)

Last Published: Aug 18, 2023

[Previous Topic
Camera resource manager configuration](https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/72_Camera_resource_manager_configuration.md) [Next Topic
EEPROM configuration](https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/84_EEPROM_bring_up_guidelines.md)