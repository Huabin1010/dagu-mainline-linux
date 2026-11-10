#include "pon-off.h"
#include <stdio.h>

int
main(void)
{
    if (pon_cmd(0x5b) != 0x5b0)
        return 1;
    if (pon_cmd(0x5a) != 0x5a0)
        return 2;
    if (pon_type(0) != 4 || pon_type(1) != 7)
        return 3;
    if (pon_enable_clear(0x80) != 0 || pon_enable_set(0) != 0x80)
        return 4;
    if (pon_with_type(0x17, 4) != 0x14)
        return 5;
    if ((pon_cmd(0x5b) >> 27) != 0)
        return 6;
    printf("ok\n");
    return 0;
}
