CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra
PREFIX ?= /usr/local

.PHONY: all install clean

all: dagu-touch-boost dagu-power-button dagu-fcitx5-shift-tap dagu-ssc dagu-cdsp-rpc

dagu-touch-boost: dagu-touch-boost.c
	$(CC) $(CFLAGS) -o $@ $<

dagu-power-button: dagu-power-button.c
	$(CC) $(CFLAGS) -o $@ $<

dagu-fcitx5-shift-tap: dagu-fcitx5-shift-tap.c
	$(CC) $(CFLAGS) -o $@ $<

dagu-ssc: dagu-ssc.c
	$(CC) $(CFLAGS) -o $@ $<

dagu-cdsp-rpc: dagu-cdsp-rpc.c
	$(CC) $(CFLAGS) -o $@ $<

install: all
	install -d $(DESTDIR)$(PREFIX)/sbin
	install -m755 dagu-touch-boost dagu-power-button dagu-fcitx5-shift-tap \
		dagu-ssc dagu-cdsp-rpc \
		$(DESTDIR)$(PREFIX)/sbin/

clean:
	rm -f dagu-touch-boost dagu-power-button dagu-fcitx5-shift-tap \
		dagu-ssc dagu-cdsp-rpc
