/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Leftover empty 0x05 vs real KEY_UP for the Nanosic 803 boot keyboard.
 *
 * Host unit tests compile this with NANOSIC_GHOST_HOST. The driver includes
 * it as-is. Same-envelope vendor, GPIO still low, and a stale sequence
 * are leftover. A fresh seq (+1 or +2) with GPIO83 already high is the
 * release even inside the 16ms keepalive bounce. Do not time-debounce
 * empty KEY_UP: a fast tap (ji / baidu) releases inside 80ms, and
 * dropping it leaves the last letter down.
 */
#ifndef _NANOSIC_KBD_GHOST_H
#define _NANOSIC_KBD_GHOST_H

#ifdef NANOSIC_GHOST_HOST
#include <stdbool.h>
#include <stdint.h>
typedef uint8_t u8;
typedef int8_t s8;
typedef uint16_t u16;
#else
#include <linux/types.h>
#endif

struct nanosic_ghost_ctx {
	bool have_kbd_down;
	bool have_vendor;
	bool rx_have_prev_seq;
	s8 rx_seq_delta;
	bool gpio_pending;
	bool in_vendor_bounce;
};

static inline bool nanosic_keys_zero(const u8 *p)
{
	unsigned int i;

	for (i = 3; i < 9; i++) {
		if (p[i])
			return false;
	}
	return true;
}

static inline bool nanosic_kbd_empty(const u8 *p)
{
	/* p[2] is reserved. GENI leftover there is not a held modifier. */
	if (p[1])
		return false;
	return nanosic_keys_zero(p);
}

/* GENI leftover, not an MCU KEY_UP. */
static inline bool nanosic_ghost_leftover(bool seen_vendor,
					  const struct nanosic_ghost_ctx *ctx)
{
	if (seen_vendor)
		return true;
	if (ctx->gpio_pending)
		return true;
	if (ctx->in_vendor_bounce)
		return true;
	if (ctx->rx_have_prev_seq &&
	    ctx->rx_seq_delta != 1 && ctx->rx_seq_delta != 2)
		return true;
	return false;
}

/*
 * Modifier-only (keys=00, p[1] set) is the HID boot KEY_UP for the last
 * non-modifier key while Ctrl/Shift/Alt stay held. That is a real C
 * release after Ctrl+C, not leftover.
 */
static inline bool nanosic_ghost_mod_only(const u8 *p, bool seen_vendor,
					  const struct nanosic_ghost_ctx *ctx)
{
	if (!nanosic_keys_zero(p) || !p[1])
		return false;
	return nanosic_ghost_leftover(seen_vendor, ctx);
}

/* True: GENI leftover empty 0x05, not the MCU KEY_UP. */
static inline bool nanosic_ghost_empty_ctx(const u8 *p, bool seen_vendor,
					   const struct nanosic_ghost_ctx *ctx)
{
	if (nanosic_keys_zero(p) && p[1])
		return nanosic_ghost_mod_only(p, seen_vendor, ctx);
	if (!nanosic_kbd_empty(p))
		return false;
	if (seen_vendor)
		return true;
	if (!ctx->have_kbd_down)
		return false;
	/*
	 * Fresh MCU sequence, GPIO83 already high: this packet is the
	 * release. A 0x22 keepalive in the previous 16ms is a different
	 * sequence. Board trace: Enter down seq 72, keepalive seq 73,
	 * empty seq 74 d=1 gpio=0. Dropping that empty left KEY_ENTER
	 * down, and mutter repeated it into the focused control.
	 */
	if (!ctx->gpio_pending && ctx->rx_have_prev_seq &&
	    (ctx->rx_seq_delta == 1 || ctx->rx_seq_delta == 2))
		return false;
	return nanosic_ghost_leftover(seen_vendor, ctx);
}

/* Consumer control report ID 0x06: one 16-bit array usage, little endian.
 * 0x00E9 is volume up, 0x00EA is volume down. Usage 0 is the HID array
 * release. GENI padding is also usage 0. Inject that release only when a
 * usage is still latched and this packet is a fresh MCU sequence with
 * GPIO83 already high — the same rule as an empty 0x05 KEY_UP. The 400ms
 * keepalive window must not apply: the MCU sends 0x22 between press and
 * release. Dropping usage 0 leaves KEY_VOLUMEUP down, and mutter
 * compositor-repeat runs the slider to the rail.
 */
struct nanosic_consumer_ctx {
	bool have_consumer_down;
	bool seen_vendor;
	bool rx_have_prev_seq;
	s8 rx_seq_delta;
	bool gpio_pending;
};

static inline u16 nanosic_consumer_usage(const u8 *p)
{
	return (u16)p[1] | ((u16)p[2] << 8);
}

/* True: this usage-0 report is the MCU release, not GENI padding. */
static inline bool nanosic_consumer_release_inject(const u8 *p,
					const struct nanosic_consumer_ctx *ctx)
{
	if (nanosic_consumer_usage(p) != 0)
		return false;
	if (!ctx->have_consumer_down)
		return false;
	if (ctx->seen_vendor)
		return false;
	if (ctx->gpio_pending)
		return false;
	if (!ctx->rx_have_prev_seq)
		return false;
	if (ctx->rx_seq_delta != 1 && ctx->rx_seq_delta != 2)
		return false;
	return true;
}

/* Presses still honor the leftover window (a ghost 0x06 cancels mutter
 * hold-repeat). A latched usage-0 release does not: that window ate the
 * FN+volume KEY_UP, so compositor-repeat held the slider on the rail.
 */
static inline bool nanosic_consumer_inject(const u8 *p, bool leftover_window,
					const struct nanosic_consumer_ctx *ctx)
{
	if (nanosic_consumer_usage(p) == 0)
		return nanosic_consumer_release_inject(p, ctx);
	return !leftover_window;
}

#endif /* _NANOSIC_KBD_GHOST_H */
