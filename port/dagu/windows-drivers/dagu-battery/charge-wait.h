/* SPDX-License-Identifier: MIT
 * IOCTL 0x294050 (IOCTL_BATTERY_CHARGING_SOURCE_CHANGE) is a wait, not a
 * query. CAD.sys's completion routine resends it whenever the completion
 * status is success. Completing it inside the dispatch that received it
 * therefore nests until the kernel stack guard page (bugcheck 0x2B).
 *
 * Park the wait and complete it only after the charger-present bit changes,
 * from the poll thread. A failure completion (cancel, remove) does not
 * resend. Replacing a parked wait completes the old one with failure.
 */
#ifndef DAGU_CHARGE_WAIT_H
#define DAGU_CHARGE_WAIT_H

#define CHARGE_SOURCE_IOCTL 0x294050u
#define CHARGE_SOURCE_USB   2u

typedef struct _CHARGE_SOURCE_INFO {
    unsigned int Type;            /* 1 AC, 2 USB, 3 wireless */
    unsigned char SourceOnline;   /* 0 unplugged, 1 present */
} CHARGE_SOURCE_INFO;

typedef struct _CHARGE_WAIT {
    int pending;
    int base_valid;
    int base_online;
} CHARGE_WAIT;

static inline void
charge_source_fill(CHARGE_SOURCE_INFO *info, int online)
{
    info->Type = CHARGE_SOURCE_USB;
    info->SourceOnline = online ? 1u : 0u;
}

static inline void
charge_wait_init(CHARGE_WAIT *w)
{
    w->pending = 0;
    w->base_valid = 0;
    w->base_online = 0;
}

/* Returns 1 when a wait was already parked and must be completed with a
 * failure status so the sender does not resend it. */
static inline int
charge_wait_park(CHARGE_WAIT *w, int online_now)
{
    int replace = w->pending;

    w->pending = 1;
    w->base_valid = 1;
    w->base_online = online_now ? 1 : 0;
    return replace;
}

/* Returns 1 when the parked wait should be completed with success. */
static inline int
charge_wait_on_sample(CHARGE_WAIT *w, int online_now)
{
    int now = online_now ? 1 : 0;

    if (!w->pending || !w->base_valid || w->base_online == now)
        return 0;
    w->pending = 0;
    w->base_valid = 0;
    return 1;
}

/* Returns 1 when a parked wait was dropped. */
static inline int
charge_wait_cancel(CHARGE_WAIT *w)
{
    int had = w->pending;

    w->pending = 0;
    w->base_valid = 0;
    return had;
}

#endif
