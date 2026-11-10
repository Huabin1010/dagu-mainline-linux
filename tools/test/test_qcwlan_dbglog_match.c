#include <stdio.h>
#include <string.h>

#include "../../port/dagu/windows-drivers/qcwlan-dbglog/match.h"

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
	const char *line = "Failed to register miniport with NDIS WDI";

	expect(dbg_text_has(line, (unsigned)strlen(line), "WDI"), "keeps WDI");
	expect(dbg_text_has(line, (unsigned)strlen(line), "miniport"), "keeps miniport");
	expect(!dbg_text_has(line, (unsigned)strlen(line), "firmware"), "drops unrelated");
	expect(!dbg_text_has(line, 3, "WDI"), "respects the cap");
	expect(dbg_text_has("PBL dump", 8, "PBL"), "keeps a prefix");
	expect(!dbg_text_has("", 0, "WDI"), "empty body");
	if (failed)
		return 1;
	puts("ok");
	return 0;
}
