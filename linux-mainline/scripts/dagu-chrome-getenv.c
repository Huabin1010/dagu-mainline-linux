/* LD_PRELOAD for Chromium only. official-152 clearenv()s /proc/environ,
 * so DAGU_CHROME_PANEL_ROTATE never reaches DaguPanelRotateDegrees().
 * Do not load this into gnome-shell.
 *
 *   aarch64-linux-gnu-gcc -shared -fPIC -O2 -Wall -ldl \
 *     -o linux-mainline/scripts/libdagu-chrome-getenv.so \
 *     linux-mainline/scripts/dagu-chrome-getenv.c
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char *(*real_getenv)(const char *);
static char *(*real_secure_getenv)(const char *);

static int want_rotate(void)
{
	return access("/run/user/1001/dagu-identity", F_OK) == 0;
}

static char *dagu_getenv(const char *name, char *(*next)(const char *))
{
	if (name && strcmp(name, "DAGU_CHROME_PANEL_ROTATE") == 0 &&
	    want_rotate())
		return "270";
	return next ? next(name) : NULL;
}

char *getenv(const char *name)
{
	if (!real_getenv)
		real_getenv = dlsym(RTLD_NEXT, "getenv");
	return dagu_getenv(name, real_getenv);
}

char *secure_getenv(const char *name)
{
	if (!real_secure_getenv)
		real_secure_getenv = dlsym(RTLD_NEXT, "secure_getenv");
	return dagu_getenv(name, real_secure_getenv);
}
