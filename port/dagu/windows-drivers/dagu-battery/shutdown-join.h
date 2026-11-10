/* Last-chance shutdown must not wait out the poll thread.
 *
 * That callback runs after the filesystems have been asked to stop. The
 * poll thread rewrites \Windows\dagu-battery.txt, so an unbounded join
 * deadlocks there and PS_HOLD stays high: the screen is already off and
 * a short power press does nothing. The thread's SPMI reads use other
 * APIDs and finish in under 2 ms, so cutting power while it is still
 * inside a file write is safe. joined is reported and does not gate the cut.
 */
#ifndef DAGU_SHUTDOWN_JOIN_H
#define DAGU_SHUTDOWN_JOIN_H

#define SHUTDOWN_JOIN_MS 2000u

static inline int
shutdown_cut_after_join(int joined)
{
    (void)joined;
    return 1;
}

#endif
