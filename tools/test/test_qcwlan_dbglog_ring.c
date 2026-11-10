/* Ring used by qcwlan-dbglog. Run: gcc -Wall -Werror -o /tmp/ring-test this && /tmp/ring-test */
#include <stdio.h>
#include <string.h>

#include "../../port/dagu/windows-drivers/qcwlan-dbglog/ring.h"

static unsigned char storage[16];
static DbgRing ring;

static void reset(void)
{
	memset(storage, 0, sizeof(storage));
	ring.cap = 16;
	ring.w = 0;
	ring.r = 0;
	ring.b = storage;
}

static int failed;

static void expect(int cond, const char *what)
{
	if (!cond) {
		fprintf(stderr, "fail: %s\n", what);
		failed = 1;
	}
}

int main(void)
{
	unsigned char out[16];
	unsigned n;

	reset();
	expect(dbg_ring_push(&ring, "abc", 3) == 1, "push abc");
	n = dbg_ring_peek(&ring, out, sizeof(out));
	expect(n == 3 && memcmp(out, "abc", 3) == 0, "peek abc");
	dbg_ring_consume(&ring, 3);
	expect(dbg_ring_used(&ring) == 0, "empty after consume");

	reset();
	expect(dbg_ring_push(&ring, "0123456789abcdef", 16) == 1, "fill");
	expect(dbg_ring_push(&ring, "x", 1) == 0, "full rejects");
	dbg_ring_consume(&ring, 16);
	expect(dbg_ring_push(&ring, "xyz", 3) == 1, "push after wrap");
	n = dbg_ring_peek(&ring, out, sizeof(out));
	expect(n == 3 && memcmp(out, "xyz", 3) == 0, "peek wrapped");

	reset();
	expect(dbg_ring_push(&ring, "", 0) == 0, "zero rejected");
	expect(dbg_ring_push(&ring, "too-long-for-ring!!", 17) == 0, "oversize rejected");
	dbg_ring_push(&ring, "hello", 5);
	dbg_ring_consume(&ring, 2);
	n = dbg_ring_peek(&ring, out, sizeof(out));
	expect(n == 3 && memcmp(out, "llo", 3) == 0, "partial consume");

	if (failed)
		return 1;
	puts("ok");
	return 0;
}
