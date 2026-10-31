CONFIG ?= release
INSTALL_DIR ?= /Applications
IDENTITY ?= $(or $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $$2; exit}'),-)
SIGN_FLAGS ?= --timestamp=none

ifeq ($(CONFIG),debug)
APP := KubeConfig Dev
BUNDLE_ID := com.igorv.kubeconfig.dev
OUTPUT_DIR := build/debug
else ifeq ($(CONFIG),release)
APP := KubeConfig
BUNDLE_ID := com.igorv.kubeconfig
OUTPUT_DIR := build
else
$(error CONFIG must be debug or release)
endif

BUNDLE := $(OUTPUT_DIR)/$(APP).app
STAGING_DIR := $(OUTPUT_DIR)/.bundle-$(CONFIG)
STAGING_BUNDLE := $(STAGING_DIR)/$(APP).app
ICON := build/AppIcon.icns

VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
DMG := build/KubeConfig-$(VERSION).dmg

.PHONY: all help build debug dev production bundle run install install-dev install-production install-prod test dmg cask clean

all: bundle

help:
	@printf '%s\n' \
	  'make bundle                 Build and sign the production app' \
	  'make debug                  Build the separate development app' \
	  'make run CONFIG=debug       Build and open the development app' \
	  'make install-dev            Install KubeConfig Dev.app' \
	  'make install-production     Install KubeConfig.app' \
	  'make install CONFIG=debug   Equivalent development install' \
	  'make test                   Run the test suite' \
	  'make dmg                    Build build/KubeConfig-<version>.dmg (release)' \
	  'make cask                   Write build/kubeconfig.rb for the Homebrew tap' \
	  'Override INSTALL_DIR or IDENTITY when needed.'

build:
	swift build -c "$(CONFIG)" --product KubeConfig

debug dev:
	@$(MAKE) bundle CONFIG=debug

production:
	@$(MAKE) bundle CONFIG=release

$(ICON): Assets/AppIcon.png
	@mkdir -p build
	@set -eu; \
	  temporary=$$(mktemp -d build/.icon.XXXXXX); \
	  trap 'rm -rf "$$temporary"' EXIT; \
	  mkdir -p "$$temporary/AppIcon.iconset"; \
	  for dimension in 16 32 128 256 512; do \
	    sips -z "$$dimension" "$$dimension" "$<" --out "$$temporary/AppIcon.iconset/icon_$${dimension}x$${dimension}.png" >/dev/null; \
	    double_dimension=$$((dimension * 2)); \
	    sips -z "$$double_dimension" "$$double_dimension" "$<" --out "$$temporary/AppIcon.iconset/icon_$${dimension}x$${dimension}@2x.png" >/dev/null; \
	  done; \
	  iconutil -c icns "$$temporary/AppIcon.iconset" -o "$$temporary/AppIcon.icns"; \
	  mv "$$temporary/AppIcon.icns" "$@"

bundle: build $(ICON)
	@rm -rf "$(STAGING_DIR)"
	@mkdir -p "$(STAGING_BUNDLE)/Contents/MacOS" "$(STAGING_BUNDLE)/Contents/Resources"
	@install -m 755 "$$(swift build -c "$(CONFIG)" --show-bin-path)/KubeConfig" "$(STAGING_BUNDLE)/Contents/MacOS/KubeConfig"
	@install -m 644 Resources/Info.plist "$(STAGING_BUNDLE)/Contents/Info.plist"
	@install -m 644 Resources/ThirdPartyNotices.txt "$(STAGING_BUNDLE)/Contents/Resources/ThirdPartyNotices.txt"
	@install -m 644 "$(ICON)" "$(STAGING_BUNDLE)/Contents/Resources/AppIcon.icns"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(BUNDLE_ID)" "$(STAGING_BUNDLE)/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleName $(APP)" "$(STAGING_BUNDLE)/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $(APP)" "$(STAGING_BUNDLE)/Contents/Info.plist"
	@codesign --force --sign "$(IDENTITY)" $(SIGN_FLAGS) "$(STAGING_BUNDLE)"
	@codesign --verify --strict "$(STAGING_BUNDLE)"
	@set -eu; \
	  previous=$$(mktemp -d "$(OUTPUT_DIR)/.previous.XXXXXX"); \
	  if [ -e "$(BUNDLE)" ] || [ -L "$(BUNDLE)" ]; then mv "$(BUNDLE)" "$$previous/app"; fi; \
	  if mv "$(STAGING_BUNDLE)" "$(BUNDLE)"; then \
	    rm -rf "$$previous" "$(STAGING_DIR)"; \
	  else \
	    if [ -e "$$previous/app" ] || [ -L "$$previous/app" ]; then mv "$$previous/app" "$(BUNDLE)"; fi; \
	    rmdir "$$previous"; exit 1; \
	  fi
	@printf 'Built %s\n' "$(BUNDLE)"

run: bundle
	open "$(BUNDLE)"

install: bundle
	@set -eu; \
	  mkdir -p "$(INSTALL_DIR)"; \
	  temporary=$$(mktemp -d "$(INSTALL_DIR)/.kubeconfig-install.XXXXXX"); \
	  trap 'if [ ! -e "$$temporary/previous.app" ] && [ ! -L "$$temporary/previous.app" ]; then rm -rf "$$temporary"; fi' EXIT; \
	  ditto "$(BUNDLE)" "$$temporary/$(APP).app"; \
	  codesign --verify --strict "$$temporary/$(APP).app"; \
	  destination="$(INSTALL_DIR)/$(APP).app"; \
	  if [ -e "$$destination" ] || [ -L "$$destination" ]; then mv "$$destination" "$$temporary/previous.app"; fi; \
	  if mv "$$temporary/$(APP).app" "$$destination"; then \
	    rm -rf "$$temporary/previous.app"; \
	  else \
	    if [ -e "$$temporary/previous.app" ] || [ -L "$$temporary/previous.app" ]; then mv "$$temporary/previous.app" "$$destination"; fi; \
	    exit 1; \
	  fi; \
	  printf 'Installed %s\n' "$$destination"

install-dev:
	@$(MAKE) install CONFIG=debug

install-production install-prod:
	@$(MAKE) install CONFIG=release

test:
	swift test

# A disk image with an Applications link to drag onto, always from the release app.
# Pass IDENTITY and SIGN_FLAGS to sign it for publishing.
dmg:
	@$(MAKE) bundle CONFIG=release
	@rm -rf build/dmg "$(DMG)"
	@mkdir -p build/dmg
	@ditto "build/KubeConfig.app" build/dmg/KubeConfig.app
	@ln -s /Applications build/dmg/Applications
	@# `diskutil image` replaces the deprecated `hdiutil create` but is new in macOS 26.
	@if diskutil image create from --help >/dev/null 2>&1; then \
	  diskutil image create from --format UDZO --volumeName "KubeConfig" build/dmg "$(DMG)" >/dev/null; \
	else \
	  hdiutil create -volname "KubeConfig" -srcfolder build/dmg -format UDZO -ov "$(DMG)" >/dev/null; \
	fi
	@rm -rf build/dmg
	@printf 'Built %s\n' "$(DMG)"

# Fills the cask template with this version and the disk image's checksum.
cask:
	@test -f "$(DMG)" || { echo "$(DMG) not found; run make dmg first"; exit 1; }
	@sed -e '1{/^#/d;}' -e 's/^  version ".*"/  version "$(VERSION)"/' \
	     -e "s/^  sha256 \".*\"/  sha256 \"$$(shasum -a 256 "$(DMG)" | cut -d' ' -f1)\"/" \
	     packaging/kubeconfig.rb > build/kubeconfig.rb
	@echo "wrote build/kubeconfig.rb"

clean:
	swift package clean
	rm -rf build
