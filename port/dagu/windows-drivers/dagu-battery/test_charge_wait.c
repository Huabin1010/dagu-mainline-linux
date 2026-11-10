/* Host test for the charging-source wait. No kernel headers. */
#include "charge-wait.h"

#include <stddef.h>
#include <stdio.h>
#include <string.h>

static int g_fail;

static void
expect(int cond, const char *msg)
{
    if (!cond) {
        fprintf(stderr, "FAIL %s\n", msg);
        g_fail++;
    }
}

static void
test_layout(void)
{
    CHARGE_SOURCE_INFO info;

    expect(CHARGE_SOURCE_IOCTL == 0x294050u, "ioctl code");
    expect(offsetof(CHARGE_SOURCE_INFO, SourceOnline) == 4, "online at +4");
    expect(sizeof(CHARGE_SOURCE_INFO) == 8, "info size");
    charge_source_fill(&info, 1);
    expect(info.Type == CHARGE_SOURCE_USB && info.SourceOnline == 1, "usb online");
    charge_source_fill(&info, 0);
    expect(info.Type == CHARGE_SOURCE_USB && info.SourceOnline == 0, "usb offline");
}

static void
test_stays_pending_until_the_bit_changes(void)
{
    CHARGE_WAIT w;

    charge_wait_init(&w);
    expect(charge_wait_park(&w, 0) == 0, "first park replaces nothing");
    expect(charge_wait_on_sample(&w, 0) == 0, "same offline sample does not complete");
    expect(charge_wait_on_sample(&w, 0) == 0, "still parked");
    expect(charge_wait_on_sample(&w, 1) == 1, "plug completes once");
    expect(w.pending == 0, "not parked after complete");
    expect(charge_wait_on_sample(&w, 0) == 0, "no second complete without a new wait");
    expect(charge_wait_on_sample(&w, 1) == 0, "still idle");
}

static void
test_rearm_uses_the_new_baseline(void)
{
    CHARGE_WAIT w;

    charge_wait_init(&w);
    charge_wait_park(&w, 1);
    expect(charge_wait_park(&w, 1) == 1, "second park replaces the first");
    expect(charge_wait_on_sample(&w, 1) == 0, "baseline is the new sample");
    expect(charge_wait_on_sample(&w, 0) == 1, "unplug completes the replacement");
}

static void
test_cancel_drops_the_wait(void)
{
    CHARGE_WAIT w;

    charge_wait_init(&w);
    charge_wait_park(&w, 0);
    expect(charge_wait_cancel(&w) == 1, "cancel finds the wait");
    expect(charge_wait_cancel(&w) == 0, "cancel is idempotent");
    expect(charge_wait_on_sample(&w, 1) == 0, "cancelled wait does not complete");
}

int
main(void)
{
    test_layout();
    test_stays_pending_until_the_bit_changes();
    test_rearm_uses_the_new_baseline();
    test_cancel_drops_the_wait();
    if (g_fail) {
        fprintf(stderr, "%d failed\n", g_fail);
        return 1;
    }
    printf("ok\n");
    return 0;
}
