#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>

/*
 * Hide Resources rows/graphs whose *value* is N/A.
 * Only intercepts libadwaita / GTK setters — not sysfs. Values stay truthful.
 *
 * ResGraphBox title_label uses CSS class "subtitle". Logical CPU tiles set
 * that title to "N/A" until the first frequency sample. Hiding the whole
 * box made "Show usages of logical CPUs" a blank page. Visibility follows
 * the value label (info_label) only, and is restored when the value is real.
 */

struct gtype_instance {
	void *g_class;
};

struct gtype_class {
	unsigned long g_type;
};

static int is_na(const char *s)
{
	if (!s)
		return 1;
	while (*s == ' ' || *s == '\t')
		s++;
	if (!*s)
		return 1;
	if (strcmp(s, "N/A") == 0 || strcmp(s, "n/a") == 0)
		return 1;
	if (strcmp(s, "不适用") == 0 || strcmp(s, "不可用") == 0)
		return 1;
	if (strcmp(s, "—") == 0 || strcmp(s, "-") == 0)
		return 1;
	return 0;
}

static void set_visible(void *widget, int vis)
{
	static void (*fn)(void *, int);

	if (!fn)
		fn = dlsym(RTLD_DEFAULT, "gtk_widget_set_visible");
	if (fn && widget)
		fn(widget, vis);
}

static void *widget_parent(void *widget)
{
	static void *(*fn)(void *);

	if (!fn)
		fn = dlsym(RTLD_DEFAULT, "gtk_widget_get_parent");
	return fn ? fn(widget) : NULL;
}

static int has_css_class(void *widget, const char *cls)
{
	static int (*fn)(void *, const char *);

	if (!fn)
		fn = dlsym(RTLD_DEFAULT, "gtk_widget_has_css_class");
	return (fn && widget && cls) ? fn(widget, cls) : 0;
}

static const char *type_name(void *obj)
{
	static const char *(*fn)(unsigned long);
	struct gtype_instance *inst;
	struct gtype_class *cls;

	if (!obj)
		return "";
	if (!fn)
		fn = dlsym(RTLD_DEFAULT, "g_type_name");
	if (!fn)
		return "";
	inst = obj;
	if (!inst->g_class)
		return "";
	cls = inst->g_class;
	return fn(cls->g_type) ? fn(cls->g_type) : "";
}

static void hide_graph_if_na(void *label, const char *text)
{
	void *w;
	int i;
	int vis;

	if (has_css_class(label, "subtitle"))
		return;

	vis = !is_na(text);
	w = label;
	for (i = 0; i < 8 && w; i++) {
		const char *n = type_name(w);

		if (strcmp(n, "ResGraphBox") == 0 ||
		    strcmp(n, "ResDoubleGraphBox") == 0) {
			set_visible(w, vis);
			return;
		}
		w = widget_parent(w);
	}
}

void adw_action_row_set_subtitle(void *self, const char *subtitle)
{
	static void (*real)(void *, const char *);

	if (!real)
		real = dlsym(RTLD_NEXT, "adw_action_row_set_subtitle");
	if (real)
		real(self, subtitle);
	set_visible(self, !is_na(subtitle));
}

void gtk_label_set_label(void *self, const char *str)
{
	static void (*real)(void *, const char *);

	if (!real)
		real = dlsym(RTLD_NEXT, "gtk_label_set_label");
	if (real)
		real(self, str);
	hide_graph_if_na(self, str);
}
