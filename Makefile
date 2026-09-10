# Glisse — build & packaging
#
# The SwiftPM package produces a plain Mach-O executable. macOS needs a real
# .app bundle for: LSUIElement (no Dock icon), a stable bundle identifier for
# Accessibility permission, SMAppService login-item registration, and code
# signing. This Makefile assembles that bundle.
#
# Common targets:
#   make            debug build + bundle  -> build/Glisse.app
#   make release    optimised build       -> dist/Glisse.app
#   make run        build + launch
#   make diagnose   run the trackpad diagnostic in the terminal
#   make test       unit + fuzz tests
#   make dmg        dist/Glisse.dmg (after `make release`)
#   make icon       regenerate Resources/AppIcon.icns
#   make clean

SHELL := /bin/bash

# Executable / SwiftPM product name: ASCII, because it is also the process name.
APP_NAME      := Glisse
# What the bundle is called on disk and in the UI.
APP_BUNDLE    := Glissé
BUNDLE_ID     := xyz.glisse.Glisse
CONFIG        ?= debug
BUILD_DIR     := build
DIST_DIR      := dist
RES_DIR       := Resources

# Code signing identity.
#
# Ad-hoc ("-") gives the app no stable code identity: the designated requirement
# is a cdhash, which changes on every rebuild, so macOS treats each build as a
# different app and the Accessibility grant is silently invalidated.
#
# If a local self-signed identity exists (Scripts/make-signing-identity.sh), use
# it — its certificate hash is stable, so the permission survives rebuilds.
# An explicit CODESIGN_IDENTITY always wins.
# Preference order, best first:
#   1. an Apple Development certificate — real Team ID, stable requirement
#   2. the local self-signed identity from Scripts/make-signing-identity.sh
#   3. ad-hoc, which works but loses the Accessibility grant on every rebuild
#
# Revoked certificates are skipped: codesign refuses them.
LOCAL_SIGNING_NAME := Glisse Local Signing

ifeq ($(origin CODESIGN_IDENTITY), undefined)
  APPLE_DEV_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null \
      | grep 'Apple Development' | grep -v REVOKED | head -1 \
      | sed -E 's/.*"(.*)".*/\1/')
  LOCAL_IDENTITY := $(shell security find-identity -p codesigning 2>/dev/null \
      | grep -o '$(LOCAL_SIGNING_NAME)' | head -1)
  ifneq ($(APPLE_DEV_IDENTITY),)
    CODESIGN_IDENTITY := $(APPLE_DEV_IDENTITY)
  else ifeq ($(LOCAL_IDENTITY),$(LOCAL_SIGNING_NAME))
    CODESIGN_IDENTITY := $(LOCAL_SIGNING_NAME)
  else
    CODESIGN_IDENTITY := -
  endif
endif

SWIFT         := swift
SWIFT_FLAGS   :=

# Use a real Xcode if one is present but not selected; SwiftPM works with the
# Command Line Tools alone, so this is only a convenience.
ifeq ($(origin DEVELOPER_DIR), undefined)
  ifneq ($(wildcard /Applications/Xcode.app/Contents/Developer),)
    export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
  else ifneq ($(wildcard /Applications/Xcode-beta.app/Contents/Developer),)
    export DEVELOPER_DIR := /Applications/Xcode-beta.app/Contents/Developer
  endif
endif

.PHONY: all debug release build bundle run diagnose diagnose-appkit probe selftest haptictest hudtest test clean dmg icon signing-identity print-bin

all: debug

debug: CONFIG := debug
debug: bundle

release: CONFIG := release
release: bundle

build:
	$(SWIFT) build -c $(CONFIG) $(SWIFT_FLAGS)

print-bin:
	@$(SWIFT) build -c $(CONFIG) --show-bin-path

# ---------------------------------------------------------------------------
# Bundle assembly
# ---------------------------------------------------------------------------
bundle: build
	@set -euo pipefail; \
	BIN_PATH="$$($(SWIFT) build -c $(CONFIG) --show-bin-path)"; \
	if [ "$(CONFIG)" = "release" ]; then OUT_DIR="$(DIST_DIR)"; else OUT_DIR="$(BUILD_DIR)"; fi; \
	APP="$$OUT_DIR/$(APP_BUNDLE).app"; \
	rm -rf "$$APP"; \
	mkdir -p "$$APP/Contents/MacOS" "$$APP/Contents/Resources"; \
	cp "$$BIN_PATH/$(APP_NAME)" "$$APP/Contents/MacOS/$(APP_NAME)"; \
	cp "$(RES_DIR)/Info.plist" "$$APP/Contents/Info.plist"; \
	printf 'APPL????' > "$$APP/Contents/PkgInfo"; \
	if [ -f "$(RES_DIR)/AppIcon.icns" ]; then cp "$(RES_DIR)/AppIcon.icns" "$$APP/Contents/Resources/AppIcon.icns"; fi; \
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(BUNDLE_ID)" "$$APP/Contents/Info.plist" >/dev/null; \
	echo "--> codesign ($(CODESIGN_IDENTITY))"; \
	codesign --force --deep --options runtime --timestamp=none \
	         --sign "$(CODESIGN_IDENTITY)" "$$APP" 2>&1 | sed 's/^/    /' || \
	codesign --force --deep --sign "$(CODESIGN_IDENTITY)" "$$APP" 2>&1 | sed 's/^/    /'; \
	echo ""; \
	echo "Built $$APP"; \
	du -sh "$$APP" | sed 's/^/    size: /'

run: bundle
	@set -euo pipefail; \
	if [ "$(CONFIG)" = "release" ]; then OUT_DIR="$(DIST_DIR)"; else OUT_DIR="$(BUILD_DIR)"; fi; \
	pkill -x $(APP_NAME) 2>/dev/null || true; \
	sleep 0.3; \
	open "$$OUT_DIR/$(APP_BUNDLE).app"; \
	echo "Launched. Look for the hand glyph in the menu bar."

# Terminal diagnostic: prints live normalised trackpad touch frames.
diagnose: build
	@set -euo pipefail; \
	BIN_PATH="$$($(SWIFT) build -c $(CONFIG) --show-bin-path)"; \
	"$$BIN_PATH/$(APP_NAME)" --diagnose

# Same, but forced onto the public NSTouch fallback source.
diagnose-appkit: build
	@set -euo pipefail; \
	BIN_PATH="$$($(SWIFT) build -c $(CONFIG) --show-bin-path)"; \
	"$$BIN_PATH/$(APP_NAME)" --diagnose --source appkit

probe: build
	@set -euo pipefail; \
	BIN_PATH="$$($(SWIFT) build -c $(CONFIG) --show-bin-path)"; \
	"$$BIN_PATH/$(APP_NAME)" --probe

# Exercises the real volume/brightness/HUD paths and restores what it changed.
selftest: build
	@set -euo pipefail; \
	BIN_PATH="$$($(SWIFT) build -c $(CONFIG) --show-bin-path)"; \
	"$$BIN_PATH/$(APP_NAME)" --selftest

# Fires every trackpad actuation pattern in turn so the strength mapping can be
# calibrated by feel. Rest a finger on the trackpad while it runs.
haptictest: build
	@set -euo pipefail; \
	BIN_PATH="$$($(SWIFT) build -c $(CONFIG) --show-bin-path)"; \
	"$$BIN_PATH/$(APP_NAME)" --haptictest

# Tries each route to the system HUD, then shows Glisse's own panel.
hudtest: build
	@set -euo pipefail; \
	BIN_PATH="$$($(SWIFT) build -c $(CONFIG) --show-bin-path)"; \
	"$$BIN_PATH/$(APP_NAME)" --hudtest

test:
	$(SWIFT) test

# ---------------------------------------------------------------------------
# Icon: generated from code (no third-party artwork).
# ---------------------------------------------------------------------------
icon:
	@$(SHELL) Scripts/make-icon.sh

# ---------------------------------------------------------------------------
# Disk image
# ---------------------------------------------------------------------------
dmg:
	@set -euo pipefail; \
	test -d "$(DIST_DIR)/$(APP_BUNDLE).app" || { echo "run 'make release' first"; exit 1; }; \
	rm -f "$(DIST_DIR)/$(APP_BUNDLE).dmg"; \
	STAGE="$$(mktemp -d)"; \
	cp -R "$(DIST_DIR)/$(APP_BUNDLE).app" "$$STAGE/"; \
	ln -s /Applications "$$STAGE/Applications"; \
	hdiutil create -volname "$(APP_BUNDLE)" -srcfolder "$$STAGE" -ov -format UDZO \
	    "$(DIST_DIR)/$(APP_BUNDLE).dmg" >/dev/null; \
	rm -rf "$$STAGE"; \
	echo "Built $(DIST_DIR)/$(APP_BUNDLE).dmg"

clean:
	rm -rf .build $(BUILD_DIR) $(DIST_DIR)

# Creates a stable self-signed identity so Accessibility survives rebuilds.
# Touches only the login keychain; see the script header.
signing-identity:
	@$(SHELL) Scripts/make-signing-identity.sh
