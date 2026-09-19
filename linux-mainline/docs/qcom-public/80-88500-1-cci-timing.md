# CCI timing and debug

Source: [https://docs.qualcomm.com/doc/80-88500-1/topic/64_CCI_timing_and_debug.html](https://docs.qualcomm.com/doc/80-88500-1/topic/64_CCI_timing_and_debug.html)

The I^2^C timing may vary depending on the number of slave devices on the I^2^C bus. Ensure the characteristics of the serial data and serial clock I/O stages (high to low, low to high, and so on) are within the specified range.

Following table lists the IRQ statuses, common CCI errors, and troubleshooting tips:

Table : IRQ statuses and CCI errors

| IRQ status | Error reason | What to check |
| --- | --- | --- |
| NACK\_ERR | I^2^C command of I^2^C Master does not get any `ACK` response from slave. | Check if any slave devices are holding the bus due to improper power on/down, or board-level noise. |
| CMD\_ERR | An unsupported command word is programmed into the hardware. | Check if any slave devices are holding the bus due to improper power on/down, or board-level noise. |
| OVERFLOW | I^2^C command FIFO or I^2^C RD FIFO has overflowed. | Ensure not to load command words more than the available space in I^2^C master command FIFO. |
| UNDERFLOW | I^2^C RD FIFO has underflowed. | Ensure not to read from I^2^C master RD FIFO when it is empty. |

## Commands to enable CCI register dump (CCI\_REGISTERS) 

    adb shell "echo 0xF > /sys/kernel/debug/cam_cci/en_dump_cci0"
    adb shell "echo 0xF > /sys/kernel/debug/cam_cci/en_dump_cci1" Copy to clipboard

For CCI register interpretation, see the hardware register description.

## Common CCI error log

    if (irq_status0 & CCI_IRQ_STATUS_0_I2C_M0_ERROR_BMSK) { cci_dev-
    >cci_master_info[MASTER_0].status = -EINVAL;
    if (irq_status0 & CCI_IRQ_STATUS_0_I2C_M0_Q0_NACK_ERROR_BMSK) { CAM_ERR(CAM_CCI, "Base:%pK, M0_Q0 NACK ERROR: 0x%x",
    base, irq_status0);
    complete_all(&cci_dev->cci_master_info[MASTER_0]
    .report_q[QUEUE_0]);
    }
    if (irq_status0 & CCI_IRQ_STATUS_0_I2C_M0_Q1_NACK_ERROR_BMSK) { CAM_ERR(CAM_CCI, "Base:%pK, M0_Q1 NACK ERROR: 0x%x",
    base, irq_status0);
    complete_all(&cci_dev->cci_master_info[MASTER_0]
    .report_q[QUEUE_1]);
    }
    if (irq_status0 & CCI_IRQ_STATUS_0_I2C_M0_Q0Q1_ERROR_BMSK) CAM_ERR(CAM_CCI, "Base:%pK, M0 QUEUE_OVER/UNDER_FLOW OR CMD ERR: 0x%x",
    base, irq_status0);
    if (irq_status0 & CCI_IRQ_STATUS_0_I2C_M0_RD_ERROR_BMSK) CAM_ERR(CAM_CCI, "Base: %pK, M0 RD_OVER/UNDER_FLOW ERROR: 0x%x",Copy to clipboard

**Parent Topic:** [Sensor hardware configuration](https://docs.qualcomm.com/doc/80-88500-1/topic/62_Sensor_hardware_configuration.html)

Last Published: Aug 18, 2023

[Previous Topic
Sensor kernel nodes](https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/63_Sensor_kernel_nodes.md) [Next Topic
CCI operation speed](https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/65_Configure_CCI_operation_speed.md)