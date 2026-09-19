#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Pin this process and every thread to CPU 0-3 (A55). Call before libcamera. */
void dagu_pin_cpu_0_3(void);
void dagu_pin_all_threads(void);

/* Stamp YUYV + keep_format + sustain_framerate, write gray frames, and
 * return the OUTPUT fd still open. keep_format keeps ENUM_FMT after
 * this fd closes; sustain re-serves the last gray so xcast DQBUF does
 * not fail while SoftISP opens. Watch keeps this fd across SoftISP
 * spawn (PipeWire POLLERR if OUTPUT closes under a live CAPTURE). -1
 * on error. */
int dagu_stamp_loopback(const char *dev, unsigned w, unsigned h);

/* Watch: drop CLOEXEC so the SoftISP child inherits DAGU_LOOP_FD. */
int dagu_clear_cloexec(int fd);
int dagu_set_cloexec(int fd);

/* One slot per camera. 0 = front, 1 = rear. */
int dagu_pipe_start(int slot, const char *camera_id, const char *loopback_dev,
		    unsigned w, unsigned h);
void dagu_pipe_stop(int slot);
int dagu_pipe_running(int slot);

#ifdef __cplusplus
}
#endif
