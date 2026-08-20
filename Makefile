# Swift Testing ships inside the Command Line Tools at a path SwiftPM only
# discovers through an Xcode platform directory. On a machine with no Xcode,
# `xcrun --show-sdk-platform-path` is empty and `import Testing` fails, so the
# flags below hand SwiftPM the framework and its interop dylib directly. With a
# full Xcode install these resolve to nothing and plain `swift test` is used.

CLT_FRAMEWORKS := $(shell [ -d "$$(xcode-select -p)/Library/Developer/Frameworks" ] && echo "$$(xcode-select -p)/Library/Developer/Frameworks")
CLT_LIB := $(shell [ -d "$$(xcode-select -p)/Library/Developer/usr/lib" ] && echo "$$(xcode-select -p)/Library/Developer/usr/lib")
HAS_XCODE := $(shell xcrun --show-sdk-platform-path 2>/dev/null)

ifeq ($(strip $(HAS_XCODE)),)
TEST_FLAGS := --disable-xctest \
	-Xswiftc -F -Xswiftc $(CLT_FRAMEWORKS) \
	-Xlinker -F -Xlinker $(CLT_FRAMEWORKS) \
	-Xlinker -rpath -Xlinker $(CLT_FRAMEWORKS) \
	-Xlinker -rpath -Xlinker $(CLT_LIB)
else
TEST_FLAGS :=
endif

PREFIX ?= $(HOME)/.local

.PHONY: all build release test clean install uninstall

all: build

build:
	swift build

release:
	swift build -c release

test:
	swift test $(TEST_FLAGS)

clean:
	swift package clean

install: release
	install -d $(PREFIX)/bin
	install -m 0755 .build/release/mac-health $(PREFIX)/bin/mac-health
	@echo "installed $(PREFIX)/bin/mac-health"

uninstall:
	rm -f $(PREFIX)/bin/mac-health
