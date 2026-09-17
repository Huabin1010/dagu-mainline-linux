/*
 * dagu: SLPI SEE (Sensors Execution Environment) client.
 *
 * LSM6DSO / tcs3701 / rohm_bu27030 live on the SLPI I2C, not AP QUP.
 * Talk sns_client QMI (service 400) over AF_QIPCRTR after PAS brings SLPI
 * up. Accel is uinput INPUT_PROP_ACCELEROMETER for iio-sensor-proxy / Mutter.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/qrtr.h>
#include <linux/uinput.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define QMI_SVC_SSC		400
#define QMI_REQ			0x00
#define QMI_RESP		0x02
#define QMI_IND			0x04
#define SSC_CTRL		0x0020
#define SSC_IND_SMALL		0x0021
#define SSC_IND_LARGE		0x0022
#define TLV_DATA		0x01	/* req/resp ARRAY payload; IND client_id */
#define TLV_RESULT		0x02	/* QMI result on SSC_CTRL resp */
#define TLV_IND_PAYLOAD		0x02	/* IND 0x21/0x22 ARRAY protobuf */
#define TLV_REPORT_TYPE		0x10

#define FASTRPC_IOCTL_INIT_ATTACH_SNS	_IO('R', 8)

static int sns_fd = -1;

/*
 * hexagonrpcd owns INIT_ATTACH_SNS + apps_std fopen. A second attach from
 * this process races the 40s sensor_pd USER-PD DOG. Opt-in only for debug.
 */
static int attach_sns_pd(void)
{
	static const char *paths[] = {
		"/dev/fastrpc-sdsp",
		"/dev/fastrpc-sdsp-secure",
		NULL,
	};
	int i, fd;

	if (!getenv("DAGU_SSC_ATTACH_SNS"))
		return -2;
	for (i = 0; paths[i]; i++) {
		fd = open(paths[i], O_RDWR | O_CLOEXEC);
		if (fd < 0)
			continue;
		if (ioctl(fd, FASTRPC_IOCTL_INIT_ATTACH_SNS) < 0) {
			fprintf(stderr, "dagu-ssc: INIT_ATTACH_SNS %s: %s\n",
				paths[i], strerror(errno));
			close(fd);
			continue;
		}
		fprintf(stderr, "dagu-ssc: SLPI sensor PD attached via %s\n", paths[i]);
		return fd;
	}
	return -1;
}

static int wait_sdsp_node(void)
{
	for (;;) {
		if (access("/dev/fastrpc-sdsp", F_OK) == 0 ||
		    access("/dev/fastrpc-sdsp-secure", F_OK) == 0)
			return 0;
		fprintf(stderr, "dagu-ssc: waiting for /dev/fastrpc-sdsp\n");
		sleep(1);
	}
}

#define SUID_LOOKUP_LO		0xababababababababULL
#define SUID_LOOKUP_HI		0xababababababababULL
#define MSG_SUID_REQ		512
#define MSG_SUID_EVENT		768
#define MSG_STD_CONFIG		513
#define MSG_STD_ONCHANGE	514
#define MSG_STD_EVENT		1025

#define ACCEL_RES		256	/* counts per g */

struct qmi_hdr {
	uint8_t type;
	uint16_t txn;
	uint16_t msgid;
	uint16_t len;
} __attribute__((packed));

struct pb {
	uint8_t *p;
	uint8_t *end;
};

static uint8_t txbuf[4096];
static uint8_t rxbuf[65536];
static uint16_t txn_id = 1;
static int uifd = -1;
static int als_fd = -1;
static uint64_t accel_lo, accel_hi;
static uint64_t gyro_lo, gyro_hi;
static uint64_t als_lo, als_hi;
static int have_accel, have_gyro, have_als;

static void pb_init(struct pb *b, uint8_t *p, size_t n)
{
	b->p = p;
	b->end = p + n;
}

static int pb_put(struct pb *b, const void *s, size_t n)
{
	if (b->p + n > b->end)
		return -1;
	memcpy(b->p, s, n);
	b->p += n;
	return 0;
}

static int pb_varint(struct pb *b, uint64_t v)
{
	uint8_t tmp[10];
	int n = 0;

	do {
		tmp[n++] = (uint8_t)((v & 0x7f) | (v > 0x7f ? 0x80 : 0));
		v >>= 7;
	} while (v);
	return pb_put(b, tmp, (size_t)n);
}

static int pb_key(struct pb *b, int field, int wt)
{
	return pb_varint(b, ((uint64_t)field << 3) | (unsigned)wt);
}

static int pb_fixed64(struct pb *b, int field, uint64_t v)
{
	if (pb_key(b, field, 1) < 0)
		return -1;
	return pb_put(b, &v, 8);
}

static int pb_fixed32(struct pb *b, int field, uint32_t v)
{
	if (pb_key(b, field, 5) < 0)
		return -1;
	return pb_put(b, &v, 4);
}

static int pb_bytes(struct pb *b, int field, const void *s, size_t n)
{
	if (pb_key(b, field, 2) < 0 || pb_varint(b, n) < 0)
		return -1;
	return pb_put(b, s, n);
}

static int pb_string(struct pb *b, int field, const char *s)
{
	return pb_bytes(b, field, s, strlen(s));
}

static int pb_bool(struct pb *b, int field, int v)
{
	if (pb_key(b, field, 0) < 0)
		return -1;
	return pb_varint(b, v ? 1 : 0);
}

static int pb_float(struct pb *b, int field, float f)
{
	uint32_t u;

	memcpy(&u, &f, 4);
	if (pb_key(b, field, 5) < 0)
		return -1;
	return pb_put(b, &u, 4);
}

static int pb_u32(struct pb *b, int field, uint32_t v)
{
	if (pb_key(b, field, 0) < 0)
		return -1;
	return pb_varint(b, v);
}

static int encode_suid(struct pb *b, int field, uint64_t lo, uint64_t hi)
{
	uint8_t inner[32];
	struct pb s;

	pb_init(&s, inner, sizeof(inner));
	if (pb_fixed64(&s, 1, lo) < 0 || pb_fixed64(&s, 2, hi) < 0)
		return -1;
	return pb_bytes(b, field, inner, (size_t)(s.p - inner));
}

static size_t encode_suid_req(uint8_t *out, size_t n, const char *dtype)
{
	uint8_t inner[128], susp[32], stdreq[160];
	struct pb b, s, c, r;

	/*
	 * CAF sns_suid_req: register_updates=true so instances that probe
	 * after the first empty list still arrive. default_only=false.
	 */
	pb_init(&s, inner, sizeof(inner));
	if (pb_string(&s, 1, dtype) < 0 || pb_bool(&s, 2, 1) < 0 ||
	    pb_bool(&s, 3, 0) < 0)
		return 0;

	pb_init(&c, susp, sizeof(susp));
	if (pb_u32(&c, 1, 1) < 0 || pb_u32(&c, 2, 0) < 0)
		return 0;

	pb_init(&r, stdreq, sizeof(stdreq));
	if (pb_bytes(&r, 2, inner, (size_t)(s.p - inner)) < 0)
		return 0;

	pb_init(&b, out, n);
	if (encode_suid(&b, 1, SUID_LOOKUP_LO, SUID_LOOKUP_HI) < 0)
		return 0;
	if (pb_fixed32(&b, 2, MSG_SUID_REQ) < 0)
		return 0;
	if (pb_bytes(&b, 3, susp, (size_t)(c.p - susp)) < 0)
		return 0;
	if (pb_bytes(&b, 4, stdreq, (size_t)(r.p - stdreq)) < 0)
		return 0;
	return (size_t)(b.p - out);
}

static size_t encode_stream_req(uint8_t *out, size_t n, uint64_t lo, uint64_t hi,
				uint32_t msgid, const uint8_t *pay, size_t paylen)
{
	uint8_t susp[32], stdreq[64];
	struct pb b, c, r;

	pb_init(&c, susp, sizeof(susp));
	if (pb_u32(&c, 1, 1) < 0 || pb_u32(&c, 2, 0) < 0)
		return 0;

	pb_init(&r, stdreq, sizeof(stdreq));
	if (pay && paylen) {
		if (pb_bytes(&r, 2, pay, paylen) < 0)
			return 0;
	}

	pb_init(&b, out, n);
	if (encode_suid(&b, 1, lo, hi) < 0)
		return 0;
	if (pb_fixed32(&b, 2, msgid) < 0)
		return 0;
	if (pb_bytes(&b, 3, susp, (size_t)(c.p - susp)) < 0)
		return 0;
	if (pb_bytes(&b, 4, stdreq, (size_t)(r.p - stdreq)) < 0)
		return 0;
	return (size_t)(b.p - out);
}

static int qmi_put_tlv(uint8_t *p, size_t room, uint8_t type, const void *v, uint16_t vn)
{
	if (room < (size_t)3 + vn)
		return -1;
	p[0] = type;
	p[1] = vn & 0xff;
	p[2] = vn >> 8;
	memcpy(p + 3, v, vn);
	return 3 + vn;
}

static int qmi_put_array(uint8_t *p, size_t room, uint8_t type, const void *v, uint16_t vn)
{
	uint16_t inner = vn;
	uint16_t outer = (uint16_t)(vn + 2);

	if (room < (size_t)5 + vn)
		return -1;
	p[0] = type;
	p[1] = outer & 0xff;
	p[2] = outer >> 8;
	p[3] = inner & 0xff;
	p[4] = inner >> 8;
	memcpy(p + 5, v, vn);
	return 5 + vn;
}

static int qmi_send(int fd, const struct sockaddr_qrtr *dst, uint16_t msgid,
		    const uint8_t *pb, size_t pblen)
{
	struct qmi_hdr *h;
	uint8_t *p;
	int n, m;
	uint8_t rpt = 1; /* libqmi guint8 jumbo/large report; 4-byte INT is MALFORMED */

	h = (struct qmi_hdr *)txbuf;
	h->type = QMI_REQ;
	h->txn = txn_id++;
	h->msgid = msgid;
	p = txbuf + sizeof(*h);
	/* libssc order: report type then ARRAY payload */
	n = qmi_put_tlv(p, sizeof(txbuf) - sizeof(*h), TLV_REPORT_TYPE, &rpt, 1);
	if (n < 0)
		return -1;
	p += n;
	m = qmi_put_array(p, (size_t)(txbuf + sizeof(txbuf) - p), TLV_DATA, pb,
			  (uint16_t)pblen);
	if (m < 0)
		return -1;
	h->len = (uint16_t)(n + m);
	if (h->txn <= 4) {
		size_t i, total = sizeof(*h) + h->len;

		fprintf(stderr, "dagu-ssc: tx msgid=0x%04x n=%zu:", h->msgid, total);
		for (i = 0; i < total && i < 64; i++)
			fprintf(stderr, " %02x", txbuf[i]);
		fprintf(stderr, "%s\n", total > 64 ? " ..." : "");
	}
	return (int)sendto(fd, txbuf, sizeof(*h) + h->len, 0,
			   (const struct sockaddr *)dst, sizeof(*dst));
}

static const uint8_t *qmi_tlv(const uint8_t *p, size_t n, uint8_t want, uint16_t *outlen)
{
	while (n >= 3) {
		uint8_t t = p[0];
		uint16_t ln = (uint16_t)(p[1] | (p[2] << 8));

		p += 3;
		n -= 3;
		if (ln > n)
			return NULL;
		if (t == want) {
			*outlen = ln;
			return p;
		}
		p += ln;
		n -= ln;
	}
	return NULL;
}

static int pb_skip(const uint8_t **pp, size_t *n, int wt);

static int pb_uvar(const uint8_t **pp, size_t *n, uint64_t *v)
{
	int shift = 0;
	uint64_t x = 0;

	while (*n) {
		uint8_t b = *(*pp)++;
		(*n)--;
		x |= (uint64_t)(b & 0x7f) << shift;
		if (!(b & 0x80)) {
			*v = x;
			return 0;
		}
		shift += 7;
		if (shift > 63)
			return -1;
	}
	return -1;
}

static int pb_skip(const uint8_t **pp, size_t *n, int wt)
{
	uint64_t v;

	switch (wt) {
	case 0:
		return pb_uvar(pp, n, &v);
	case 1:
		if (*n < 8)
			return -1;
		*pp += 8;
		*n -= 8;
		return 0;
	case 2:
		if (pb_uvar(pp, n, &v) < 0 || v > *n)
			return -1;
		*pp += (size_t)v;
		*n -= (size_t)v;
		return 0;
	case 5:
		if (*n < 4)
			return -1;
		*pp += 4;
		*n -= 4;
		return 0;
	default:
		return -1;
	}
}

static int parse_suid_event(const uint8_t *p, size_t n, const char *want,
			    uint64_t *lo, uint64_t *hi)
{
	char dtype[64];
	int got_type = 0, got_suid = 0;

	dtype[0] = 0;
	while (n) {
		uint64_t key, ln;
		int field, wt;
		const uint8_t *sub;
		size_t sn;

		if (pb_uvar(&p, &n, &key) < 0)
			break;
		field = (int)(key >> 3);
		wt = (int)(key & 7);
		if (field == 1 && wt == 2) {
			if (pb_uvar(&p, &n, &ln) < 0 || ln > n || ln >= sizeof(dtype))
				return -1;
			memcpy(dtype, p, (size_t)ln);
			dtype[ln] = 0;
			p += (size_t)ln;
			n -= (size_t)ln;
			got_type = 1;
		} else if (field == 2 && wt == 2) {
			if (pb_uvar(&p, &n, &ln) < 0 || ln > n)
				return -1;
			sub = p;
			sn = (size_t)ln;
			p += (size_t)ln;
			n -= (size_t)ln;
			while (sn) {
				uint64_t k2;
				int f2, w2;

				if (pb_uvar(&sub, &sn, &k2) < 0)
					break;
				f2 = (int)(k2 >> 3);
				w2 = (int)(k2 & 7);
				if (f2 == 1 && w2 == 1 && sn >= 8) {
					memcpy(lo, sub, 8);
					sub += 8;
					sn -= 8;
				} else if (f2 == 2 && w2 == 1 && sn >= 8) {
					memcpy(hi, sub, 8);
					sub += 8;
					sn -= 8;
					got_suid = 1;
				} else if (pb_skip(&sub, &sn, w2) < 0) {
					break;
				}
			}
		} else if (pb_skip(&p, &n, wt) < 0) {
			break;
		}
	}
	if (!got_type || strcmp(dtype, want) != 0)
		return 0;
	return got_suid ? 1 : -2;
}

static int parse_float3(const uint8_t *p, size_t n, float *out, int maxn)
{
	int c = 0;

	while (n && c < maxn) {
		uint64_t key;
		int field, wt;

		if (pb_uvar(&p, &n, &key) < 0)
			break;
		field = (int)(key >> 3);
		wt = (int)(key & 7);
		if (field == 1 && wt == 5 && n >= 4) {
			memcpy(&out[c++], p, 4);
			p += 4;
			n -= 4;
		} else if (field == 1 && wt == 2) {
			uint64_t ln;
			const uint8_t *fp;
			size_t fn;

			/* sns_std_sensor_event.data is packed repeated float */
			if (pb_uvar(&p, &n, &ln) < 0 || ln > n)
				return c;
			fp = p;
			fn = (size_t)ln;
			p += (size_t)ln;
			n -= (size_t)ln;
			while (fn >= 4 && c < maxn) {
				memcpy(&out[c++], fp, 4);
				fp += 4;
				fn -= 4;
			}
		} else if (pb_skip(&p, &n, wt) < 0) {
			break;
		}
	}
	return c;
}

static int open_uinput(void)
{
	struct uinput_setup setup;
	struct uinput_abs_setup abs;
	int fd, i;

	fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
	if (fd < 0)
		return -1;
	ioctl(fd, UI_SET_EVBIT, EV_ABS);
	ioctl(fd, UI_SET_EVBIT, EV_SYN);
	ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_ACCELEROMETER);
	ioctl(fd, UI_SET_ABSBIT, ABS_X);
	ioctl(fd, UI_SET_ABSBIT, ABS_Y);
	ioctl(fd, UI_SET_ABSBIT, ABS_Z);
	memset(&setup, 0, sizeof(setup));
	snprintf(setup.name, sizeof(setup.name), "dagu-lsm6dso-accel");
	setup.id.bustype = BUS_HOST;
	setup.id.vendor = 0x18d1;
	setup.id.product = 0x6d50;
	if (ioctl(fd, UI_DEV_SETUP, &setup) < 0) {
		close(fd);
		return -1;
	}
	for (i = ABS_X; i <= ABS_Z; i++) {
		memset(&abs, 0, sizeof(abs));
		abs.code = (unsigned)i;
		abs.absinfo.minimum = -32768;
		abs.absinfo.maximum = 32767;
		abs.absinfo.resolution = ACCEL_RES;
		ioctl(fd, UI_ABS_SETUP, &abs);
	}
	if (ioctl(fd, UI_DEV_CREATE) < 0) {
		close(fd);
		return -1;
	}
	return fd;
}

static void emit_accel(float x, float y, float z)
{
	struct input_event ev[4];
	int i;

	if (uifd < 0)
		return;
	memset(ev, 0, sizeof(ev));
	for (i = 0; i < 3; i++) {
		float v = (i == 0) ? x : (i == 1) ? y : z;
		int32_t raw = (int32_t)(v / 9.80665f * (float)ACCEL_RES);

		if (raw > 32767)
			raw = 32767;
		if (raw < -32768)
			raw = -32768;
		ev[i].type = EV_ABS;
		ev[i].code = (unsigned)(ABS_X + i);
		ev[i].value = raw;
	}
	ev[3].type = EV_SYN;
	ev[3].code = SYN_REPORT;
	if (write(uifd, ev, sizeof(ev)) < 0) {
		/* keep streaming */
	}
}

static void emit_als(float lux)
{
	char buf[64];
	int n;

	if (als_fd < 0)
		return;
	n = snprintf(buf, sizeof(buf), "%.3f\n", lux);
	if (n < 0)
		return;
	lseek(als_fd, 0, SEEK_SET);
	if (ftruncate(als_fd, 0) < 0)
		return;
	if (write(als_fd, buf, (size_t)n) < 0)
		return;
}

static int qrtr_lookup(int fd, struct sockaddr_qrtr *svc)
{
	struct sockaddr_qrtr sq = {
		.sq_family = AF_QIPCRTR,
		.sq_node = QRTR_NODE_BCAST,
		.sq_port = QRTR_PORT_CTRL,
	};
	struct qrtr_ctrl_pkt pkt;
	struct sockaddr_qrtr from;
	socklen_t flen;
	ssize_t n;
	int tries;

	memset(&pkt, 0, sizeof(pkt));
	pkt.cmd = QRTR_TYPE_NEW_LOOKUP;
	pkt.server.service = QMI_SVC_SSC;
	pkt.server.instance = 0;
	if (sendto(fd, &pkt, sizeof(pkt), 0, (struct sockaddr *)&sq, sizeof(sq)) < 0)
		return -1;

	for (tries = 0; tries < 50; tries++) {
		struct pollfd p = { .fd = fd, .events = POLLIN };

		if (poll(&p, 1, 1000) <= 0)
			continue;
		flen = sizeof(from);
		n = recvfrom(fd, rxbuf, sizeof(rxbuf), 0, (struct sockaddr *)&from, &flen);
		if (n < (ssize_t)sizeof(pkt))
			continue;
		memcpy(&pkt, rxbuf, sizeof(pkt));
		if (pkt.cmd == QRTR_TYPE_NEW_SERVER &&
		    pkt.server.service == QMI_SVC_SSC) {
			svc->sq_family = AF_QIPCRTR;
			svc->sq_node = pkt.server.node;
			svc->sq_port = pkt.server.port;
			fprintf(stderr, "dagu-ssc: SEE node=%u port=%u\n",
				svc->sq_node, svc->sq_port);
			return 0;
		}
	}
	return -1;
}

static int send_suid(int fd, const struct sockaddr_qrtr *dst, const char *dtype)
{
	uint8_t pb[256];
	size_t n = encode_suid_req(pb, sizeof(pb), dtype);

	if (!n)
		return -1;
	return qmi_send(fd, dst, SSC_CTRL, pb, n) < 0 ? -1 : 0;
}

static int send_enable(int fd, const struct sockaddr_qrtr *dst, uint64_t lo, uint64_t hi,
		       int onchange, float hz)
{
	uint8_t pay[16], pb[256];
	struct pb s;
	size_t n, pn = 0;
	uint32_t msgid = onchange ? MSG_STD_ONCHANGE : MSG_STD_CONFIG;

	if (!onchange) {
		pb_init(&s, pay, sizeof(pay));
		if (pb_float(&s, 1, hz) < 0)
			return -1;
		pn = (size_t)(s.p - pay);
	}
	n = encode_stream_req(pb, sizeof(pb), lo, hi, msgid, pn ? pay : NULL, pn);
	if (!n)
		return -1;
	return qmi_send(fd, dst, SSC_CTRL, pb, n) < 0 ? -1 : 0;
}

static void handle_one_event(uint64_t slo, uint64_t shi, uint32_t msgid,
			     const uint8_t *payload, size_t plen)
{
	uint64_t lo, hi;
	float v[4];
	int nv;

	if (msgid == MSG_SUID_EVENT) {
		int i, na, ng, nl;
		static unsigned suid_log;

		if (suid_log < 24) {
			fprintf(stderr, "dagu-ssc: suid-event plen=%zu envelope=%016llx:%016llx pb:",
				plen, (unsigned long long)shi, (unsigned long long)slo);
			for (i = 0; i < (int)plen && i < 48; i++)
				fprintf(stderr, " %02x", payload ? payload[i] : 0);
			fprintf(stderr, "%s\n", plen > 48 ? " ..." : "");
			suid_log++;
		}
		na = parse_suid_event(payload, plen, "accel", &lo, &hi);
		if (na == 1) {
			accel_lo = lo;
			accel_hi = hi;
			have_accel = 1;
			fprintf(stderr, "dagu-ssc: accel suid %016llx:%016llx\n",
				(unsigned long long)hi, (unsigned long long)lo);
		} else if (na == -2)
			fprintf(stderr, "dagu-ssc: suid-event accel listed without instance\n");
		ng = parse_suid_event(payload, plen, "gyro", &lo, &hi);
		if (ng == 1) {
			gyro_lo = lo;
			gyro_hi = hi;
			have_gyro = 1;
			fprintf(stderr, "dagu-ssc: gyro suid %016llx:%016llx\n",
				(unsigned long long)hi, (unsigned long long)lo);
		}
		nl = parse_suid_event(payload, plen, "ambient_light", &lo, &hi);
		if (nl == 1) {
			als_lo = lo;
			als_hi = hi;
			have_als = 1;
			fprintf(stderr, "dagu-ssc: als suid %016llx:%016llx\n",
				(unsigned long long)hi, (unsigned long long)lo);
		}
		return;
	}
	if (msgid != MSG_STD_EVENT) {
		static unsigned other;

		if (other < 16) {
			fprintf(stderr, "dagu-ssc: event msgid=%u plen=%zu envelope=%016llx:%016llx\n",
				msgid, plen, (unsigned long long)shi, (unsigned long long)slo);
			other++;
		}
		return;
	}
	if (!payload)
		return;
	nv = parse_float3(payload, plen, v, 4);
	if (have_accel && slo == accel_lo && shi == accel_hi && nv >= 3) {
		static unsigned accel_log;

		if (accel_log < 3) {
			fprintf(stderr, "dagu-ssc: accel sample %.3f %.3f %.3f m/s^2\n",
				v[0], v[1], v[2]);
			accel_log++;
		}
		emit_accel(v[0], v[1], v[2]);
	}
	if (have_als && slo == als_lo && shi == als_hi && nv >= 1)
		emit_als(v[0]);
}

static void handle_pb(const uint8_t *p, size_t n)
{
	uint64_t slo = 0, shi = 0;
	static unsigned nopb;

	while (n) {
		uint64_t key, ln;
		int field, wt;

		if (pb_uvar(&p, &n, &key) < 0)
			break;
		field = (int)(key >> 3);
		wt = (int)(key & 7);
		if (field == 1 && wt == 2) {
			const uint8_t *sub;
			size_t sn;

			if (pb_uvar(&p, &n, &ln) < 0 || ln > n)
				return;
			sub = p;
			sn = (size_t)ln;
			p += (size_t)ln;
			n -= (size_t)ln;
			while (sn) {
				uint64_t k2;
				int f2, w2;

				if (pb_uvar(&sub, &sn, &k2) < 0)
					break;
				f2 = (int)(k2 >> 3);
				w2 = (int)(k2 & 7);
				if (f2 == 1 && w2 == 1 && sn >= 8) {
					memcpy(&slo, sub, 8);
					sub += 8;
					sn -= 8;
				} else if (f2 == 2 && w2 == 1 && sn >= 8) {
					memcpy(&shi, sub, 8);
					sub += 8;
					sn -= 8;
				} else if (pb_skip(&sub, &sn, w2) < 0) {
					break;
				}
			}
		} else if (field == 2 && wt == 2) {
			const uint8_t *sub, *payload = NULL;
			size_t sn, plen = 0;
			uint32_t msgid = 0;

			if (pb_uvar(&p, &n, &ln) < 0 || ln > n)
				return;
			sub = p;
			sn = (size_t)ln;
			p += (size_t)ln;
			n -= (size_t)ln;
			while (sn) {
				uint64_t k2, ln2;
				int f2, w2;

				if (pb_uvar(&sub, &sn, &k2) < 0)
					break;
				f2 = (int)(k2 >> 3);
				w2 = (int)(k2 & 7);
				if (f2 == 1 && w2 == 5 && sn >= 4) {
					memcpy(&msgid, sub, 4);
					sub += 4;
					sn -= 4;
				} else if (f2 == 3 && w2 == 2) {
					if (pb_uvar(&sub, &sn, &ln2) < 0 || ln2 > sn)
						return;
					payload = sub;
					plen = (size_t)ln2;
					sub += (size_t)ln2;
					sn -= (size_t)ln2;
				} else if (pb_skip(&sub, &sn, w2) < 0) {
					break;
				}
			}
			if (msgid)
				handle_one_event(slo, shi, msgid, payload, plen);
			else if (nopb < 8) {
				fprintf(stderr, "dagu-ssc: pb event no msgid plen=%zu\n", plen);
				nopb++;
			}
		} else if (pb_skip(&p, &n, wt) < 0) {
			break;
		}
	}
}

static const uint8_t *qmi_array_payload(const uint8_t *p, uint16_t ln, uint16_t *pblen)
{
	if (ln >= 2) {
		uint16_t inner = (uint16_t)(p[0] | (p[1] << 8));

		/* Exact ARRAY wrapper only. Protobuf often starts 0a 12; inner+2<=ln
		 * would truncate jumbo SUID lists (6648) and skip two real bytes. */
		if ((uint32_t)inner + 2u == ln) {
			*pblen = inner;
			return p + 2;
		}
	}
	*pblen = ln;
	return p;
}

static void handle_qmi(const uint8_t *buf, ssize_t n)
{
	const struct qmi_hdr *h;
	const uint8_t *tlv, *pb, *walk;
	uint16_t ln = 0, pblen, left;
	static unsigned dumps;
	int i;

	if (n < (ssize_t)sizeof(*h))
		return;
	h = (const struct qmi_hdr *)buf;
	fprintf(stderr, "dagu-ssc: qmi type=%u msgid=0x%04x len=%u n=%zd",
		h->type, h->msgid, h->len, n);
	if (dumps < 12 || n <= 40 || h->type == QMI_IND) {
		ssize_t show = n < 96 ? n : 96;

		if (dumps < 16 || (h->type == QMI_IND && dumps < 24)) {
			for (i = 0; i < (int)show; i++)
				fprintf(stderr, " %02x", buf[i]);
			if (n > show)
				fprintf(stderr, " ...");
			dumps++;
		}
	}
	fprintf(stderr, "\n");
	if ((size_t)n < sizeof(*h) + h->len)
		return;
	tlv = buf + sizeof(*h);
	if (h->type != QMI_IND && h->type != QMI_RESP)
		return;
	if (dumps <= 16) {
		walk = tlv;
		left = h->len;
		fprintf(stderr, "dagu-ssc: tlvs");
		while (left >= 3) {
			uint8_t t = walk[0];
			uint16_t tl = (uint16_t)(walk[1] | (walk[2] << 8));

			fprintf(stderr, " t=0x%02x ln=%u", t, tl);
			if (h->type == QMI_RESP && t == TLV_RESULT && tl >= 4 && left >= 7)
				fprintf(stderr, "(res=%u err=%u)",
					walk[3] | (walk[4] << 8),
					walk[5] | (walk[6] << 8));
			walk += 3;
			left -= 3;
			if (tl > left)
				break;
			walk += tl;
			left -= tl;
		}
		fprintf(stderr, "\n");
	}
	pb = NULL;
	ln = 0;
	if (h->type == QMI_IND &&
	    (h->msgid == SSC_IND_SMALL || h->msgid == SSC_IND_LARGE)) {
		/* IND: 0x01 = client_id, 0x02 = ARRAY protobuf. */
		pb = qmi_tlv(tlv, h->len, TLV_IND_PAYLOAD, &ln);
	} else if (h->type == QMI_RESP) {
		pb = qmi_tlv(tlv, h->len, TLV_DATA, &ln);
		if (!pb)
			return;
	} else {
		return;
	}
	if (!pb)
		return;
	pb = qmi_array_payload(pb, ln, &pblen);
	handle_pb(pb, pblen);
}

int main(void)
{
	struct sockaddr_qrtr local = { .sq_family = AF_QIPCRTR };
	struct sockaddr_qrtr svc;
	socklen_t slen = sizeof(local);
	int fd;

	if (mkdir("/run/dagu-ssc", 0755) < 0 && errno != EEXIST)
		perror("dagu-ssc: mkdir");
	als_fd = open("/run/dagu-ssc/lux", O_WRONLY | O_CREAT | O_CLOEXEC, 0644);

	wait_sdsp_node();
	sns_fd = attach_sns_pd();
	if (sns_fd == -2)
		fprintf(stderr, "dagu-ssc: SNS PD via hexagonrpcd, SEE over QRTR\n");
	else if (sns_fd < 0)
		fprintf(stderr, "dagu-ssc: INIT_ATTACH_SNS skipped/failed, SEE anyway\n");

	fd = socket(AF_QIPCRTR, SOCK_DGRAM, 0);
	if (fd < 0) {
		perror("dagu-ssc: socket AF_QIPCRTR");
		return 1;
	}
	slen = sizeof(local);
	if (getsockname(fd, (struct sockaddr *)&local, &slen) < 0) {
		perror("dagu-ssc: getsockname");
		return 1;
	}
	local.sq_port = 0;
	if (bind(fd, (struct sockaddr *)&local, sizeof(local)) < 0) {
		perror("dagu-ssc: bind");
		return 1;
	}
	slen = sizeof(local);
	getsockname(fd, (struct sockaddr *)&local, &slen);

	for (;;) {
		if (qrtr_lookup(fd, &svc) < 0) {
			fprintf(stderr, "dagu-ssc: waiting for SLPI SEE (svc 400)\n");
			sleep(2);
			continue;
		}
		break;
	}

	/* sensor_process fopen JSON + persist rename takes ~20s after SEE 400. */
	fprintf(stderr, "dagu-ssc: wait 25s for SLPI sensor probe\n");
	sleep(25);

	uifd = open_uinput();
	if (uifd < 0)
		perror("dagu-ssc: uinput");

	for (;;) {
		struct pollfd p = { .fd = fd, .events = POLLIN };
		struct sockaddr_qrtr from;
		socklen_t flen = sizeof(from);
		ssize_t n;
		static int accel_on, als_on, suid_tries;
		static time_t last_suid;
		time_t now;

		if (poll(&p, 1, 1000) > 0) {
			n = recvfrom(fd, rxbuf, sizeof(rxbuf), 0,
				     (struct sockaddr *)&from, &flen);
			if (n > 0)
				handle_qmi(rxbuf, n);
		}
		now = time(NULL);
		if (!have_accel && suid_tries < 24 &&
		    (last_suid == 0 || now - last_suid >= 5)) {
			send_suid(fd, &svc, "accel");
			send_suid(fd, &svc, "gyro");
			send_suid(fd, &svc, "ambient_light");
			suid_tries++;
			last_suid = now;
		}
		if (!accel_on && have_accel) {
			if (send_enable(fd, &svc, accel_lo, accel_hi, 0, 25.0f) == 0)
				fprintf(stderr, "dagu-ssc: accel 25 Hz\n");
			accel_on = 1;
		}
		if (!als_on && have_als) {
			if (send_enable(fd, &svc, als_lo, als_hi, 1, 0) == 0)
				fprintf(stderr, "dagu-ssc: als on-change\n");
			als_on = 1;
		}
	}
}
