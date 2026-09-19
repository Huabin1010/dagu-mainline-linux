/* SPDX-License-Identifier: GPL-2.0-only */
#define NANOSIC_GHOST_HOST 1
#include "nanosic-kbd-ghost.h"

int nanosic_ghost_empty_host(const unsigned char *p, int seen_vendor,
			     int have_kbd_down, int have_vendor,
			     int rx_have_prev_seq, int rx_seq_delta,
			     int gpio_pending, int in_empty_debounce,
			     int in_vendor_bounce)
{
	struct nanosic_ghost_ctx ctx = {
		.have_kbd_down = have_kbd_down,
		.have_vendor = have_vendor,
		.rx_have_prev_seq = rx_have_prev_seq,
		.rx_seq_delta = (s8)rx_seq_delta,
		.gpio_pending = gpio_pending,
		.in_empty_debounce = in_empty_debounce,
		.in_vendor_bounce = in_vendor_bounce,
	};

	return nanosic_ghost_empty_ctx(p, seen_vendor, &ctx) ? 1 : 0;
}

int nanosic_kbd_empty_host(const unsigned char *p)
{
	return nanosic_kbd_empty(p) ? 1 : 0;
}
