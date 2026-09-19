/*
 * In-process IFE CDM dump for HyperOS cameraserver.
 * Read-only. Do not flash 53dcc70.
 *
 * LD_PRELOAD this .so into android.hardware.camera.provider@2.4-service_64.
 * A thread waits for the 1MB CDM dmabuf / AHB packs, then writes:
 *   /data/vendor/camera/dagu-ife-cdm.bin
 *   /data/vendor/camera/dagu-ife-cdm.txt
 */
#define _GNU_SOURCE
#include <android/log.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "dagu-cdm", __VA_ARGS__)
#define DEST_BIN "/data/vendor/camera/dagu-ife-cdm.bin"
#define DEST_TXT "/data/vendor/camera/dagu-ife-cdm.txt"
#define DEST_DIR "/data/vendor/camera"

static int try_dump(void);

static int g_packs;
static int g_bins;

static int looks_cdm(const uint32_t *w, size_t nw)
{
	unsigned hits = 0;
	size_t lim = nw < 8192 ? nw : 8192;
	for (size_t i = 0; i + 2 < lim; i++) {
		uint32_t op = (w[i] >> 24) & 0xff;
		if (op == 0x3 && w[i + 1] < 0x20000)
			hits++;
		if (op == 0x4 && (w[i] & 0xff) >= 1)
			hits++;
	}
	return hits >= 4;
}

static int has_word(const uint32_t *w, size_t nw, uint32_t needle)
{
	for (size_t i = 0; i < nw; i++) {
		if (w[i] == needle)
			return 1;
	}
	return 0;
}

static int write_bin(const char *path, const void *va, size_t len)
{
	FILE *bin = fopen(path, "wb");
	if (!bin)
		return -1;
	size_t n = fwrite(va, 1, len, bin);
	fclose(bin);
	return n == len ? 0 : -1;
}

static void emit_packs(FILE *txt, const uint32_t *w, size_t nw, const char *tag)
{
	static const uint32_t addrs[] = {
		0x4460, 0x4660, 0x4c60, 0x4e60, 0x4868, 0x4a68,
		0x5068, 0x5268, 0x4400, 0x4600, 0x4c00, 0x4e00,
	};
	for (size_t i = 0; i + 10 < nw; i++) {
		if ((w[i] & 0xff000000) != 0x03000000)
			continue;
		uint32_t n = w[i] & 0xff;
		uint32_t addr = w[i + 1];
		int want = 0;
		for (size_t k = 0; k < sizeof addrs / sizeof addrs[0]; k++) {
			if (addr == addrs[k]) {
				want = 1;
				break;
			}
		}
		if (!want && n == 9)
			want = 1;
		if (!want)
			continue;
		g_packs++;
		fprintf(txt, "%s cmd=0x%08x addr=0x%x n=%u", tag, w[i], addr, n);
		if (n > 16)
			n = 16;
		for (uint32_t k = 0; k < n && i + 2 + k < nw; k++)
			fprintf(txt, " %08x", w[i + 2 + k]);
		fprintf(txt, "\n");
	}
	/* Opcode 4 REG_RANDOM: live WM IMAGE_CFG lives here, not opcode 3. */
	for (size_t i = 0; i + 2 < nw; i++) {
		if ((w[i] >> 24) != 0x4)
			continue;
		uint32_t n = w[i] & 0xff;
		if (n < 1 || n > 64)
			continue;
		if (i + 1 + 2 * n > nw)
			continue;
		for (uint32_t k = 0; k < n; k++) {
			uint32_t addr = w[i + 1 + 2 * k];
			uint32_t val = w[i + 2 + 2 * k];
			if (addr == 0xb00c || addr == 0xb10c ||
			    addr == 0xb014 || addr == 0xb114 ||
			    addr == 0xb018 || addr == 0xb118 ||
			    addr == 0xb01c || addr == 0xb11c ||
			    addr == 0xb020 || addr == 0xb120) {
				fprintf(txt, "%s op4 addr=0x%x val=0x%08x\n",
					tag, addr, val);
				g_packs++;
			}
		}
	}
}

/* Patched provider dlopen()s this name and dlsym()s this symbol. */
void dagu_ife_cdm_dump_stub(void)
{
	LOGI("stub called pid=%d", getpid());
	try_dump();
}

static int dump_range(FILE *txt, const char *tag, void *va, size_t len)
{
	if (!va || len < 48)
		return 0;
	uint32_t *w = va;
	size_t nw = len / 4;
	int interesting = looks_cdm(w, nw) || len == 1056768;
	for (size_t i = 0; i < nw; i++) {
		if (w[i] == 0x0a1f079f || w[i] == 0x0a1f05bf ||
		    w[i] == 0xc081999a || w[i] == 0xc023d82c ||
		    w[i] == 0xc0200000 || w[i] == 0x05100900 ||
		    w[i] == 0x0522090a || w[i] == 0x05280910 ||
		    w[i] == 0x02880900 || w[i] == 0x02940910)
			interesting = 1;
	}
	if (!interesting)
		return 0;
	int disp = has_word(w, nw, 0x0a1f05bf);
	int ident = has_word(w, nw, 0x0a1f079f);
	int disp_wm = has_word(w, nw, 0x05100900) || /* 2304×1296 */
		      has_word(w, nw, 0x0522090a) || /* 2314×1314 */
		      has_word(w, nw, 0x05280910) || /* 2320×1320 */
		      has_word(w, nw, 0x02880900) || /* 2304×648 chroma */
		      has_word(w, nw, 0x02940910);   /* 2320×660 chroma */
	fprintf(txt, "MAP %s va=%p len=%zu cdm=%d disp=%d ident=%d disp_wm=%d\n",
		tag, va, len, looks_cdm(w, nw), disp, ident, disp_wm);
	emit_packs(txt, w, nw, tag);
	if (len == 1056768) {
		if (write_bin(DEST_BIN, va, len) == 0) {
			LOGI("wrote %s %zu", DEST_BIN, len);
			fprintf(txt, "WROTE_BIN %s %zu\n", DEST_BIN, len);
		} else {
			fprintf(txt, "WROTE_BIN_FAIL errno=%d\n", errno);
		}
	}
	/* Display Full Crop last lives in malloc, not the 1MB first-list. */
	if ((disp || disp_wm) && g_bins < 8 && len <= 8u * 1024u * 1024u) {
		char path[192];
		snprintf(path, sizeof path, DEST_DIR "/dagu-ife-cdm-disp-%d-%zu.bin",
			 g_bins, len);
		if (write_bin(path, va, len) == 0) {
			g_bins++;
			LOGI("wrote %s %zu", path, len);
			fprintf(txt, "WROTE_DISP %s %zu\n", path, len);
		} else {
			fprintf(txt, "WROTE_DISP_FAIL %s errno=%d\n", path, errno);
		}
	}
	return 1;
}

static int try_dump(void)
{
	FILE *maps = fopen("/proc/self/maps", "r");
	if (!maps)
		return 0;
	FILE *txt = fopen(DEST_TXT, "w");
	if (!txt) {
		txt = fopen("/data/local/tmp/dagu-ife-cdm.txt", "w");
		if (!txt) {
			fclose(maps);
			return 0;
		}
	}
	char line[768];
	int found = 0;
	g_packs = 0;
	g_bins = 0;
	while (fgets(line, sizeof line, maps)) {
		unsigned long s, e;
		char perm[8];
		if (sscanf(line, "%lx-%lx %7s", &s, &e, perm) != 3)
			continue;
		if (perm[0] != 'r')
			continue;
		size_t len = e - s;
		if (len < 48 || len > 96u * 1024u * 1024u)
			continue;
		if (!strstr(line, "dmabuf") && !strstr(line, "libc_malloc") &&
		    len != 1056768)
			continue;
		found += dump_range(txt, line, (void *)s, len);
	}
	fclose(maps);
	fprintf(txt, "found=%d packs=%d pid=%d\n", found, g_packs, getpid());
	fclose(txt);
	LOGI("dump found=%d packs=%d", found, g_packs);
	return g_packs > 0;
}

static void *dagu_cdm_thread(void *arg)
{
	(void)arg;
	LOGI("cdm dump thread start pid=%d", getpid());
	for (int i = 0; i < 90; i++) {
		usleep(500 * 1000);
		if (try_dump()) {
			LOGI("cdm dump ok at i=%d", i);
			return NULL;
		}
	}
	LOGI("cdm dump timeout");
	return NULL;
}

__attribute__((constructor)) static void dagu_cdm_init(void)
{
	pthread_t t;
	pthread_create(&t, NULL, dagu_cdm_thread, NULL);
	pthread_detach(t);
}
