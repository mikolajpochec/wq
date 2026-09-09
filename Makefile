# Prefer a real code-signing identity: an ad-hoc signature changes on every rebuild, which makes
# macOS revoke the Accessibility grant. Falls back to ad-hoc when no identity is available.
SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -m1 -oE '"[^"]+"' | tr -d '"')
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif

APP     := WindowQueue
BUNDLE  := $(APP).app
CONF    := release
BIN     := .build/$(CONF)/$(APP)

.PHONY: all build bundle run install clean debug cert

all: bundle

build:
	swift build -c $(CONF)

debug:
	swift build -c debug

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	printf 'APPL????' > $(BUNDLE)/Contents/PkgInfo
	codesign --force --sign "$(SIGN_ID)" --identifier com.mpochec.windowqueue $(BUNDLE)
	echo "built $(BUNDLE)"

run: bundle
	-pkill -x $(APP) || true
	open $(BUNDLE)

install: bundle
	rm -rf /Applications/$(BUNDLE)
	cp -R $(BUNDLE) /Applications/
	echo "installed to /Applications/$(BUNDLE)"

cert:
	./Scripts/make-signing-cert.sh

clean:
	rm -rf .build $(BUNDLE)
