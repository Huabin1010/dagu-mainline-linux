/* Image-range test for the Wi-Fi call hook.
 * A value is wrapped only when it points inside the loaded miniport image.
 */
#ifndef QCWLAN_DBGLOG_RANGE_H
#define QCWLAN_DBGLOG_RANGE_H

static int dbg_ptr_in_image(unsigned long long p, unsigned long long base,
			    unsigned long long size)
{
	if (size == 0 || p < base)
		return 0;
	return (p - base) < size;
}

#endif
