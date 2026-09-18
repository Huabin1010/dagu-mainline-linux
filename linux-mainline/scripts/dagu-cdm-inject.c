/*
 * Magisk ptrace: call dagu_ife_cdm_dump_stub() in a live cameraserver.
 * Read-only. Do not flash 53dcc70.
 */
#define _GNU_SOURCE
#include <elf.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>
#include <asm/ptrace.h>
#include <linux/elf.h>

#ifndef NT_PRSTATUS
#define NT_PRSTATUS 1
#endif

static unsigned long lib_base(int pid)
{
	char path[64], line[768];
	snprintf(path, sizeof path, "/proc/%d/maps", pid);
	FILE *f = fopen(path, "r");
	if (!f)
		return 0;
	unsigned long base = 0;
	while (fgets(line, sizeof line, f)) {
		if (!strstr(line, "libdagu-ife-cdm-dump.so"))
			continue;
		unsigned long s = 0;
		sscanf(line, "%lx-", &s);
		base = s;
		break;
	}
	fclose(f);
	return base;
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: %s <pid> <stub_offset_hex>\n", argv[0]);
		return 1;
	}
	int pid = atoi(argv[1]);
	unsigned long off = strtoul(argv[2], NULL, 16);
	unsigned long base = lib_base(pid);
	if (!base) {
		fprintf(stderr, "lib not mapped\n");
		return 2;
	}
	unsigned long stub = base + off;
	printf("base=0x%lx stub=0x%lx\n", base, stub);

	if (ptrace(PTRACE_ATTACH, pid, 0, 0) < 0) {
		perror("attach");
		return 3;
	}
	int st = 0;
	if (waitpid(pid, &st, 0) < 0) {
		perror("wait");
		ptrace(PTRACE_DETACH, pid, 0, 0);
		return 4;
	}

	struct user_pt_regs save, wrk;
	struct iovec iov = { .iov_base = &save, .iov_len = sizeof save };
	if (ptrace(PTRACE_GETREGSET, pid, NT_PRSTATUS, &iov) < 0) {
		perror("getregs");
		ptrace(PTRACE_DETACH, pid, 0, 0);
		return 5;
	}
	wrk = save;
	wrk.pc = stub;
	wrk.regs[30] = 0; /* LR: SIGSEGV on return */
	iov.iov_base = &wrk;
	if (ptrace(PTRACE_SETREGSET, pid, NT_PRSTATUS, &iov) < 0) {
		perror("setregs");
		ptrace(PTRACE_DETACH, pid, 0, 0);
		return 6;
	}
	if (ptrace(PTRACE_CONT, pid, 0, 0) < 0) {
		perror("cont");
		ptrace(PTRACE_DETACH, pid, 0, 0);
		return 7;
	}
	if (waitpid(pid, &st, 0) < 0) {
		perror("wait2");
		ptrace(PTRACE_DETACH, pid, 0, 0);
		return 8;
	}
	printf("stop sig=%d exited=%d\n",
	       WIFSTOPPED(st) ? WSTOPSIG(st) : -1, WIFEXITED(st));

	iov.iov_base = &save;
	iov.iov_len = sizeof save;
	if (ptrace(PTRACE_SETREGSET, pid, NT_PRSTATUS, &iov) < 0)
		perror("restore");
	ptrace(PTRACE_DETACH, pid, 0, 0);
	return 0;
}
