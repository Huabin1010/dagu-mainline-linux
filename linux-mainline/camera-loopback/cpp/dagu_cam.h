#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Pin this process and every thread to CPU 0-3 (A55). Call before libcamera. */
void dagu_pin_cpu_0_3(void);
void dagu_pin_all_threads(void);

/* Stamp YUYV + keep_format + timeout so spa.v4l2 does not EnumFormat
 * NV12 2x1 (EINVAL) and STREAMON does not EIO before SoftISP. No sensor. */
int dagu_stamp_loopback(const char *dev, unsigned w, unsigned h);

/* One slot per camera. 0 = front, 1 = rear. */
int dagu_pipe_start(int slot, const char *camera_id, const char *loopback_dev,
		    unsigned w, unsigned h);
void dagu_pipe_stop(int slot);
int dagu_pipe_running(int slot);

#ifdef __cplusplus
}
#endif
