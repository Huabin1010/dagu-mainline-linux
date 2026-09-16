#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>

/*
 * Hide AdwActionRow rows whose subtitle is a real N/A (UFS has no PCIe
 * Link, Adreno has no Slot / Max Power Cap). Values stay truthful.
 *
 * Never hide ResGraphBox. Logical CPU tiles set title_label to "N/A"
 * until the first cpufreq sample. Walking from that label to ResGraphBox
 * and calling gtk_widget_set_visible(false) made Processor → Show usages
 * of logical CPUs a blank page. /proc/stat usage is real; a missing
 * frequency string is not a missing graph.
 *
 * ident: dagu-hide-na:rows-only
 */
static const char dagu_hide_na_ident[] __attribute__((used)) =
	"dagu-hide-na:rows-only";

static int is_na(const char *s)
{
	if (!s)
		return 0;
	while (*s == ' ' || *s == '\t')
		s++;
	if (!*s)
		return 0;
	if (strcmp(s, "N/A") == 0 || strcmp(s, "n/a") == 0)
		return 1;
	if (strcmp(s, "不适用") == 0 || strcmp(s, "不可用") == 0)
		return 1;
	if (strcmp(s, "—") == 0)
		return 1;
	return 0;
}

void adw_action_row_set_subtitle(void *self, const char *subtitle)
{
	static void (*real)(void *, const char *);
	static void (*set_visible)(void *, int);

	if (!real)
		real = dlsym(RTLD_NEXT, "adw_action_row_set_subtitle");
	if (real)
		real(self, subtitle);
	if (!set_visible)
		set_visible = dlsym(RTLD_DEFAULT, "gtk_widget_set_visible");
	if (set_visible && self)
		set_visible(self, !is_na(subtitle));
}
