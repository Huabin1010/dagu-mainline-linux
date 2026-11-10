/* Byte ring for the Wi-Fi debug-print logger.
 * The caller serializes push, peek, and consume. cap is a power of two.
 */
#ifndef QCWLAN_DBGLOG_RING_H
#define QCWLAN_DBGLOG_RING_H

typedef struct DbgRing {
	unsigned cap;
	unsigned w;
	unsigned r;
	unsigned char *b;
} DbgRing;

static unsigned dbg_ring_used(const DbgRing *g)
{
	return g->w - g->r;
}

static int dbg_ring_push(DbgRing *g, const void *src, unsigned n)
{
	const unsigned char *s = (const unsigned char *)src;
	unsigned i, pos;

	if (n == 0 || n > g->cap || dbg_ring_used(g) + n > g->cap)
		return 0;
	pos = g->w & (g->cap - 1);
	for (i = 0; i < n; i++) {
		g->b[pos] = s[i];
		pos = (pos + 1) & (g->cap - 1);
	}
	g->w += n;
	return 1;
}

static unsigned dbg_ring_peek(const DbgRing *g, void *dst, unsigned max)
{
	unsigned char *d = (unsigned char *)dst;
	unsigned n, i, pos;

	n = dbg_ring_used(g);
	if (n > max)
		n = max;
	pos = g->r & (g->cap - 1);
	for (i = 0; i < n; i++) {
		d[i] = g->b[pos];
		pos = (pos + 1) & (g->cap - 1);
	}
	return n;
}

static void dbg_ring_consume(DbgRing *g, unsigned n)
{
	if (n > dbg_ring_used(g))
		n = dbg_ring_used(g);
	g->r += n;
}

#endif
