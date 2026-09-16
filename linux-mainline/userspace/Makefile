CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra
PREFIX ?= /usr/local

.PHONY: all install clean

all: dagu-touch-boost dagu-power-button

dagu-touch-boost: dagu-touch-boost.c
	$(CC) $(CFLAGS) -o $@ $<

dagu-power-button: dagu-power-button.c
	$(CC) $(CFLAGS) -o $@ $<

install: all
	install -d $(DESTDIR)$(PREFIX)/sbin
	install -m755 dagu-touch-boost dagu-power-button $(DESTDIR)$(PREFIX)/sbin/

clean:
	rm -f dagu-touch-boost dagu-power-button
