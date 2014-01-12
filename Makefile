CFLAGS = -g -O2 -Wall -Wunused
DBUS_FLAGS = $(shell pkg-config --cflags --libs dbus-1)
GIO_FLAGS := $(shell pkg-config --cflags --libs 'glib-2.0 >= 2.26' gio-2.0 gio-unix-2.0)
PCAP_FLAGS := $(shell pcap-config --cflags pcap-config --libs)
DESTDIR =
PREFIX = /usr/local
BINDIR = $(DESTDIR)$(PREFIX)/bin
DATADIR = $(DESTDIR)$(PREFIX)/share
MAN1DIR = $(DATADIR)/man/man1

BINARIES = \
	dist/build/bustle-pcap \
	$(NULL)

MANPAGE = bustle-pcap.1
DESKTOP_FILE = bustle.desktop
APPDATA_FILE = bustle.appdata.xml

all: $(BINARIES) $(MANPAGE) $(DESKTOP_FILE) $(APPDATA_FILE)

BUSTLE_PCAP_SOURCES = c-sources/pcap-monitor.c c-sources/bustle-pcap.c
BUSTLE_PCAP_GENERATED_HEADERS = dist/build/autogen/version.h
BUSTLE_PCAP_HEADERS = c-sources/pcap-monitor.h $(BUSTLE_PCAP_GENERATED_HEADERS)

bustle-pcap.1: dist/build/bustle-pcap
	-help2man --output=$@ --no-info --name='Generate D-Bus logs for bustle' $<

bustle.desktop: data/bustle.desktop.in
	LC_ALL=C intltool-merge -d -u po $< $@

bustle.appdata.xml: data/bustle.appdata.xml.in
	LC_ALL=C intltool-merge -x -u po $< $@

dist/build/bustle-pcap: $(BUSTLE_PCAP_SOURCES) $(BUSTLE_PCAP_HEADERS)
	@mkdir -p dist/build
	$(CC) -Idist/build/autogen $(CFLAGS) $(CPPFLAGS) $(LDFLAGS) \
		-o $@ $(BUSTLE_PCAP_SOURCES) \
		$(GIO_FLAGS) $(PCAP_FLAGS)

dist/build/autogen/version.h: bustle.cabal
	@mkdir -p `dirname $@`
	perl -nle 'm/^Version:\s+(.*)$$/ and print qq(#define BUSTLE_VERSION "$$1")' \
		$< > $@

install: all
	mkdir -p $(BINDIR)
	cp $(BINARIES) $(BINDIR)
	-mkdir -p $(MAN1DIR)
	-cp $(MANPAGE) $(MAN1DIR)
	mkdir -p $(DATADIR)/applications
	cp $(DESKTOP_FILE) $(DATADIR)/applications
	mkdir -p $(DATADIR)/appdata
	cp $(APPDATA_FILE) $(DATADIR)/appdata

uninstall:
	rm -f $(BINDIR)/$(notdir $(BINARIES))
	rm -f $(MAN1DIR)/$(MANPAGE)
	rm -f $(DATADIR)/applications/$(DESKTOP_FILE)
	rm -f $(DATADIR)/appdata/$(APPDATA_FILE)

clean:
	rm -f $(BINARIES) $(MANPAGE) $(BUSTLE_PCAP_GENERATED_HEADERS) $(DESKTOP_FILE) $(APPDATA_FILE)
	if test -d ./$(TARBALL_DIR); then rm -r ./$(TARBALL_DIR); fi
	rm -f ./$(TARBALL)

# Binary tarball stuff. Please ignore this unless you're making a release.
TOP := $(shell pwd)
TARBALL_PARENT_DIR := dist
TARBALL_DIR := $(shell git describe --tags)-$(shell gcc -dumpmachine | perl -pe 's/-.*//')
TARBALL_FULL_DIR := $(TARBALL_PARENT_DIR)/$(TARBALL_DIR)
TARBALL := $(TARBALL_DIR).tar.bz2
maintainer-binary-tarball: all
	mkdir -p $(TARBALL_FULL_DIR)
	cabal-dev configure --prefix=$(TOP)/$(TARBALL_FULL_DIR) \
		--datadir=$(TOP)/$(TARBALL_FULL_DIR) --datasubdir=.
	cabal-dev build
	cabal-dev copy
	cp bustle.sh README $(TARBALL_FULL_DIR)
	perl -pi -e 's{^    bustle-pcap}{    ./bustle-pcap};' \
		-e  's{^    bustle}     {    ./bustle.sh};' \
		$(TARBALL_FULL_DIR)/README
	cp $(BINARIES) $(MANPAGE) $(DESKTOP_FILE) $(APPDATA_FILE) $(TARBALL_FULL_DIR)
	mkdir -p $(TARBALL_FULL_DIR)/lib
	cp LICENSE.bundled-libraries $(TARBALL_FULL_DIR)/lib
	./ldd-me-up.sh $(TARBALL_FULL_DIR)/bin/bustle \
		| xargs -I XXX cp XXX $(TARBALL_FULL_DIR)/lib
	cd $(TARBALL_PARENT_DIR) && tar cjf $(TARBALL) $(TARBALL_DIR)

maintainer-update-messages-pot:
	hgettext -k __ -o po/messages.pot **/*.hs
