#include <stdio.h>

#include "../../port/dagu/windows-drivers/qcwlan-dbglog/range.h"

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
	expect(dbg_ptr_in_image(0x140001000ULL, 0x140000000ULL, 0x300000ULL),
	       "inside");
	expect(dbg_ptr_in_image(0x140000000ULL, 0x140000000ULL, 0x1000ULL),
	       "at the base");
	expect(!dbg_ptr_in_image(0x140001000ULL, 0x140000000ULL, 0x1000ULL),
	       "at the end");
	expect(!dbg_ptr_in_image(0x1000ULL, 0x140000000ULL, 0x300000ULL),
	       "below the image");
	expect(!dbg_ptr_in_image(0x140000100ULL, 0x140000000ULL, 0),
	       "empty image");
	if (failed)
		return 1;
	puts("ok");
	return 0;
}
