#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/syscall.h>

int main(void)
{
	if (syscall(SYS_pivot_root, ".", "oldroot") != 0) {
		fprintf(stderr, "pivot_root: %s\n", strerror(errno));
		return 1;
	}
	execl("/grow.sh", "grow.sh", (char *)NULL);
	fprintf(stderr, "exec grow.sh: %s\n", strerror(errno));
	return 2;
}
