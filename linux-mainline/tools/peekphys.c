/* Minimal physical MMIO read for rooted Android when /dev/mem exists. */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	unsigned long addr;
	unsigned long page;
	off_t offset;
	void *map;
	volatile uint32_t *p;
	int fd;

	if (argc != 2) {
		fprintf(stderr, "usage: %s <phys_addr_hex>\n", argv[0]);
		return 2;
	}
	addr = strtoul(argv[1], NULL, 0);
	page = addr & ~0xfffUL;
	offset = addr & 0xfffUL;

	fd = open("/dev/mem", O_RDONLY | O_SYNC);
	if (fd < 0) {
		fprintf(stderr, "open /dev/mem: %s\n", strerror(errno));
		return 1;
	}
	map = mmap(NULL, 0x1000, PROT_READ, MAP_SHARED, fd, page);
	if (map == MAP_FAILED) {
		fprintf(stderr, "mmap 0x%lx: %s\n", page, strerror(errno));
		close(fd);
		return 1;
	}
	p = (volatile uint32_t *)((char *)map + offset);
	printf("0x%08lx\n", (unsigned long)*p);
	munmap(map, 0x1000);
	close(fd);
	return 0;
}
