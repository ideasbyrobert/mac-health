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
APP_NAME := Energy Lab
APP_DIR := dist/$(APP_NAME).app

VERSION := $(shell sed -n 's/^public let macHealthVersion = "\(.*\)"$$/\1/p' Sources/MacHealthKit/Core/Version.swift)
APP_IDENTITY ?= Developer ID Application: ROBERT KARAPETYAN (X87D35HM5V)
NOTARY_PROFILE ?= AC_NOTARY
DIST_DMG := dist/mac-health-$(VERSION).dmg

.PHONY: all build release test clean install uninstall app lab notarized

all: build

build:
	swift build

release:
	swift build -c release

test:
	swift test $(TEST_FLAGS)

clean:
	swift package clean

# A locally linked SwiftPM binary carries no signature on Intel, and launchd
# items pointing at it show as "unidentified developer" in System Settings.
# When the Developer ID identity is present, sign the installed copy so the
# background items attribute correctly; elsewhere the plain copy still works.
install: release
	install -d $(PREFIX)/bin
	install -m 0755 .build/release/mac-health $(PREFIX)/bin/mac-health
	@if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$(APP_IDENTITY)"; then \
		codesign --force --options runtime --timestamp --sign "$(APP_IDENTITY)" $(PREFIX)/bin/mac-health; \
		echo "signed with: $(APP_IDENTITY)"; \
	fi
	@echo "installed $(PREFIX)/bin/mac-health"

uninstall:
	rm -f $(PREFIX)/bin/mac-health

# Run every chaos scenario and print its energy signature.
lab: build
	./.build/debug/mac-health energy lab

# SwiftPM emits a bare executable; a SwiftUI app needs a bundle with an
# Info.plist before AppKit will give it a dock icon, a menu bar, or activation.
# chaos-worker ships inside the bundle because the lab spawns it by path.
app: release
	rm -rf "$(APP_DIR)"
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	cp .build/release/EnergyLabApp "$(APP_DIR)/Contents/MacOS/$(APP_NAME)"
	cp .build/release/chaos-worker "$(APP_DIR)/Contents/MacOS/chaos-worker"
	printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '  <key>CFBundleName</key><string>$(APP_NAME)</string>' \
	  '  <key>CFBundleDisplayName</key><string>$(APP_NAME)</string>' \
	  '  <key>CFBundleExecutable</key><string>$(APP_NAME)</string>' \
	  '  <key>CFBundleIdentifier</key><string>com.fundamentalapplications.energy-lab</string>' \
	  '  <key>CFBundlePackageType</key><string>APPL</string>' \
	  '  <key>CFBundleShortVersionString</key><string>1.1.0</string>' \
	  '  <key>LSMinimumSystemVersion</key><string>12.0</string>' \
	  '  <key>NSHighResolutionCapable</key><true/>' \
	  '</dict></plist>' > "$(APP_DIR)/Contents/Info.plist"
	@echo "built $(APP_DIR) — open it with: open \"$(APP_DIR)\""

# ROADMAP §4: Developer ID-signed binary (hardened runtime, timestamped),
# notarized DMG, stapled ticket, and a Gatekeeper verdict before anything
# lands in dist/. The submit status is parsed rather than trusted: notarytool
# can exit 0 for an Invalid submission it merely finished waiting on.
notarized: release
	codesign --force --options runtime --timestamp --sign "$(APP_IDENTITY)" .build/release/mac-health
	codesign --verify --strict --verbose=2 .build/release/mac-health
	rm -rf dist/dmg-stage
	mkdir -p dist/dmg-stage
	cp .build/release/mac-health dist/dmg-stage/mac-health
	hdiutil create -volname mac-health -srcfolder dist/dmg-stage -ov -format UDZO "$(DIST_DMG)" >/dev/null
	codesign --force --timestamp --sign "$(APP_IDENTITY)" "$(DIST_DMG)"
	@status=$$(xcrun notarytool submit "$(DIST_DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait --output-format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])'); \
	echo "notarization: $$status"; [ "$$status" = "Accepted" ]
	xcrun stapler staple "$(DIST_DMG)"
	xcrun stapler validate "$(DIST_DMG)"
	spctl -a -t open --context context:primary-signature -v "$(DIST_DMG)"
	shasum -a 256 "$(DIST_DMG)"
	rm -rf dist/dmg-stage
	@echo "notarized $(DIST_DMG)"
