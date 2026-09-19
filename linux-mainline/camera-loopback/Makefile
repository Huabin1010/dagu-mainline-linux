CXX ?= g++
RUSTC ?= rustc
PREFIX ?= /usr/local
PKG_CFLAGS := $(shell pkg-config --cflags libcamera 2>/dev/null)
PKG_LIBS := $(shell pkg-config --libs libcamera 2>/dev/null)
CXXFLAGS ?= -O2 -std=c++17 -fPIC -pthread $(or $(PKG_CFLAGS),-I/usr/include/libcamera)
LDFLAGS ?= $(or $(PKG_LIBS),-lcamera -lcamera-base) -lstdc++ -pthread

.PHONY: all install clean test

all: dagu-camera-loopback

test: tests/test_app_v4l2
	./tests/test_app_v4l2

tests/test_app_v4l2: tests/test_app_v4l2.c
	$(CC) -O2 -Wall -o $@ $<

dagu_cam.o: cpp/dagu_cam.cpp cpp/dagu_cam.h
	$(CXX) $(CXXFLAGS) -O3 -c cpp/dagu_cam.cpp -o dagu_cam.o

libdagu_cam.a: dagu_cam.o
	ar rcs libdagu_cam.a dagu_cam.o

dagu-camera-loopback: libdagu_cam.a src/main.rs
	$(RUSTC) --edition 2021 -C opt-level=3 -C panic=abort \
		src/main.rs -o dagu-camera-loopback \
		-L native=. -l static=dagu_cam \
		-C link-arg=-lcamera -C link-arg=-lcamera-base \
		-C link-arg=-lstdc++ -C link-arg=-pthread

install: dagu-camera-loopback
	install -d $(DESTDIR)$(PREFIX)/sbin
	install -m755 dagu-camera-loopback $(DESTDIR)$(PREFIX)/sbin/dagu-camera-loopback

clean:
	rm -f dagu_cam.o libdagu_cam.a dagu-camera-loopback
