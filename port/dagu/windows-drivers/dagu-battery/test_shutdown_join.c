#include "shutdown-join.h"
#include <stdio.h>

int
main(void)
{
    if (SHUTDOWN_JOIN_MS == 0 || SHUTDOWN_JOIN_MS > 2000u)
        return 1;
    if (!shutdown_cut_after_join(0))
        return 2;
    if (!shutdown_cut_after_join(1))
        return 3;
    printf("ok\n");
    return 0;
}
