/* PM8150 PON PS_HOLD programming. Pure C, no kernel headers.
 *
 * Linux pm8941_reboot_notify + msm-poweroff on this board:
 *   PON rev2 != 0, so the enable bit is ctl2 (0x5b) bit 7, not ctl.
 *   ctl (0x5a) low nibble is the action taken when PS_HOLD falls:
 *     4 shutdown (rails off, next power press is a cold boot)
 *     7 hard reset (reboot)
 *   The register address is 0x85a, above 0xFF, so the arbiter opcode is
 *   EXT_WRITEL (0). EXT_WRITE (2) reports done and does not change the byte.
 *   Live check on this tablet: ctl was 7 and ctl2 was 0x80; opcode 0
 *   changed them to 4 and 0, then restored 7 and 0x80.
 */
#ifndef DAGU_PON_OFF_H
#define DAGU_PON_OFF_H

#define PON_ARB_WRITEL  0u
#define PON_TYPE_SHUTDOWN 4u
#define PON_TYPE_RESET  7u
#define PON_ENABLE      0x80u
#define PON_TYPE_MASK   0x0fu

static inline unsigned
pon_cmd(unsigned addr_low)
{
    return (PON_ARB_WRITEL << 27) | ((addr_low & 0xffu) << 4);
}

static inline unsigned
pon_type(int reset)
{
    return reset ? PON_TYPE_RESET : PON_TYPE_SHUTDOWN;
}

static inline unsigned
pon_enable_clear(unsigned ctl2)
{
    return ctl2 & ~PON_ENABLE;
}

static inline unsigned
pon_enable_set(unsigned ctl2)
{
    return ctl2 | PON_ENABLE;
}

static inline unsigned
pon_with_type(unsigned ctl, unsigned type)
{
    return (ctl & ~PON_TYPE_MASK) | (type & PON_TYPE_MASK);
}

#endif
