/* Substring match for the debug-print filter.
 * No allocation. The caller passes the already-capped byte count.
 */
#ifndef QCWLAN_DBGLOG_MATCH_H
#define QCWLAN_DBGLOG_MATCH_H

static int dbg_text_has(const char *text, unsigned n, const char *lit)
{
	unsigned m = 0, i, j;

	while (lit[m] != '\0')
		m++;
	if (m == 0 || n < m)
		return 0;
	for (i = 0; i + m <= n; i++) {
		for (j = 0; j < m; j++) {
			if (text[i + j] != lit[j])
				break;
		}
		if (j == m)
			return 1;
	}
	return 0;
}

#endif
