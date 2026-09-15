CXX ?= g++
RUSTC ?= rustc
PREFIX ?= /usr/local
CXXFLAGS ?= -O2 -std=c++17 -fPIC -pthread -I/usr/include/libcamera
LDFLAGS ?= -lcamera -lcamera-base -lstdc++ -pthread

.PHONY: all install clean

all: dagu-camera-loopback

dagu_cam.o: cpp/dagu_cam.cpp cpp/dagu_cam.h
	$(CXX) $(CXXFLAGS) -c cpp/dagu_cam.cpp -o dagu_cam.o

libdagu_cam.a: dagu_cam.o
	ar rcs libdagu_cam.a dagu_cam.o

dagu-camera-loopback: libdagu_cam.a src/main.rs
	$(RUSTC) --edition 2021 -C opt-level=3 -C panic=abort \
		src/main.rs -o dagu-camera-loopback \
		-L native=. -l static=dagu_cam \
		-C link-arg=-lcamera -C link-arg=-lcamera-base \
		-C link-arg=-lstdc++ -C link-arg=-pthread

install: dagu-camera-loopback
	install -m755 dagu-camera-loopback $(PREFIX)/sbin/dagu-camera-loopback

clean:
	rm -f dagu_cam.o libdagu_cam.a dagu-camera-loopback
