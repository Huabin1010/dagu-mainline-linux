/*
 * dagu: CDSP (Hexagon 698 / HVX) FastRPC client.
 *
 * PAS loads cdsp.mbn; this process is the userspace workload. GET_DSP_INFO
 * invokes FASTRPC_DSP_UTILITIES on the Hexagon, then INIT_ATTACH holds the
 * compute PD. Not WebNN, not TFLite/CPU, not SNPE blobs.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define FASTRPC_IOCTL_INIT_ATTACH	_IO('R', 4)
#define FASTRPC_IOCTL_GET_DSP_INFO	_IOWR('R', 13, struct fastrpc_ioctl_capability)

struct fastrpc_ioctl_capability {
	uint32_t unused;
	uint32_t attribute_id;
	uint32_t capability;
	uint32_t reserved[4];
};

static int open_cdsp(void)
{
	static const char *paths[] = {
		"/dev/fastrpc-cdsp",
		"/dev/fastrpc-cdsp-secure",
		NULL,
	};
	int i, fd;

	for (i = 0; paths[i]; i++) {
		fd = open(paths[i], O_RDWR | O_CLOEXEC);
		if (fd >= 0) {
			fprintf(stderr, "dagu-cdsp-rpc: opened %s\n", paths[i]);
			return fd;
		}
	}
	return -1;
}

int main(int argc, char **argv)
{
	struct fastrpc_ioctl_capability cap;
	int fd, i, hold;
	unsigned int attrs[16];

	hold = 1;
	if (argc > 1 && !strcmp(argv[1], "--once"))
		hold = 0;

	for (;;) {
		fd = open_cdsp();
		if (fd < 0) {
			fprintf(stderr, "dagu-cdsp-rpc: waiting for /dev/fastrpc-cdsp (%s)\n",
				strerror(errno));
			sleep(2);
			continue;
		}

		memset(attrs, 0, sizeof(attrs));
		for (i = 0; i < 16; i++) {
			memset(&cap, 0, sizeof(cap));
			cap.attribute_id = (unsigned int)i;
			if (ioctl(fd, FASTRPC_IOCTL_GET_DSP_INFO, &cap) < 0) {
				fprintf(stderr, "dagu-cdsp-rpc: GET_DSP_INFO[%d] %s\n",
					i, strerror(errno));
				if (i == 0) {
					close(fd);
					sleep(2);
					fd = -1;
					break;
				}
				break;
			}
			attrs[i] = cap.capability;
			fprintf(stderr, "dagu-cdsp-rpc: attr[%d]=%u\n", i, cap.capability);
		}
		if (fd < 0)
			continue;

		if (ioctl(fd, FASTRPC_IOCTL_INIT_ATTACH) < 0) {
			fprintf(stderr, "dagu-cdsp-rpc: INIT_ATTACH %s\n", strerror(errno));
			close(fd);
			sleep(2);
			continue;
		}
		fprintf(stderr, "dagu-cdsp-rpc: Hexagon 698 PD attached attr0=%u\n",
			attrs[0]);
		break;
	}

	if (!hold) {
		close(fd);
		return 0;
	}
	for (;;)
		pause();
}
