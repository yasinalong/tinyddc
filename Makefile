CC = clang
CFLAGS ?= -Os -Wall -Wextra -Werror
OBJCFLAGS = -fobjc-arc -mmacosx-version-min=12.0 -arch arm64
FRAMEWORKS = -framework Foundation -framework CoreGraphics -framework IOKit
PREFIX ?= /usr/local

.PHONY: all test clean install
all: tinyddc

tinyddc: src/tinyddc.m src/ddc_packet.h
	$(CC) $(CFLAGS) $(OBJCFLAGS) src/tinyddc.m $(FRAMEWORKS) -o $@

build/packet_test: tests/packet_test.c src/ddc_packet.h
	mkdir -p build
	$(CC) $(CFLAGS) -std=c11 tests/packet_test.c -o $@

test: tinyddc build/packet_test
	./build/packet_test
	sh tests/cli_test.sh ./tinyddc

install: tinyddc
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 755 tinyddc "$(DESTDIR)$(PREFIX)/bin/tinyddc"

clean:
	rm -f tinyddc
	rm -rf build
