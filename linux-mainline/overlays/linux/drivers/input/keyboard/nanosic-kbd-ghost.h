/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Leftover empty 0x05 vs real KEY_UP for the Nanosic 803 boot keyboard.
 *
 * Host unit tests compile this with NANOSIC_GHOST_HOST. The driver includes
 * it as-is. Leftover evidence is vendor / GPIO / bounce / stale seq.
 * Do not time-debounce empty KEY_UP: a fast tap (ji / baidu) releases
 * inside 80ms, and dropping it leaves the last letter down.
 */
#ifndef _NANOSIC_KBD_GHOST_H
#define _NANOSIC_KBD_GHOST_H

#ifdef NANOSIC_GHOST_HOST
#include <stdbool.h>
#include <stdint.h>
typedef uint8_t u8;
typedef int8_t s8;
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
	return nanosic_ghost_leftover(seen_vendor, ctx);
}

#endif /* _NANOSIC_KBD_GHOST_H */
