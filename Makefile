BINARY = upderive
PREFIX = /usr/local
BINDIR = $(PREFIX)/bin
INITDIR = /etc/init.d
CRONDIR = /etc/cron.d

.PHONY: all build run clean install uninstall install-service remove-service install-cron remove-cron

all: build

build:
	zig build -Doptimize=ReleaseFast

run:
	zig build run

clean:
	rm -rf zig-cache zig-out

install: build
	install -Dm755 zig-out/bin/$(BINARY) $(DESTDIR)$(BINDIR)/$(BINARY)

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(BINARY)

install-service:
	cp init.d/upderive $(INITDIR)/upderive
	rc-update add upderive default

remove-service:
	rc-service upderive stop 2>/dev/null || true
	rc-update del upderive default 2>/dev/null || true
	rm -f $(INITDIR)/upderive

install-cron:
	install -Dm755 cron/cleanup-uploads.sh $(DESTDIR)$(PREFIX)/bin/cleanup-uploads.sh
	cp cron/upderive-cleanup $(CRONDIR)/upderive-cleanup

remove-cron:
	rm -f $(CRONDIR)/upderive-cleanup
	rm -f $(DESTDIR)$(PREFIX)/bin/cleanup-uploads.sh
