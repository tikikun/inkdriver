# Native arm64 driver + menu-bar app for the XP-Pen Deco 01 V3.
#
# Requires only the Xcode command line tools. No Rosetta, no .NET, no vendor code.

# Rename the app by changing these two lines.
APP_NAME := InkDriver
BUNDLE_ID := com.local.inkdriver

# Stable self-signed identity (Support/make-signing-identity.sh). Signing with a
# fixed certificate keeps the TCC grants across rebuilds; ad-hoc signing does not,
# because the grant is keyed on the code hash.
SIGN_ID  := InkDriver Dev

BIN      := .build/release
# Build the bundle inside .build/ on purpose. If a copy of the app also sits in
# the repo, both bundles carry the same bundle identifier and LaunchServices will
# happily launch the wrong one (and TCC gets confused). Only the installed copy
# in ~/Applications should ever be launchable.
APP      := .build/$(APP_NAME).app
APPBIN   := $(APP)/Contents/MacOS/$(APP_NAME)
PREFIX   := $(HOME)/.local/bin
AGENT    := $(HOME)/Library/LaunchAgents/$(BUNDLE_ID).plist
LABEL    := $(BUNDLE_ID)
LOGPATH  := $(HOME)/Library/Logs/inkdriver.log

.PHONY: build debug app run-app probe watch descriptor dry-run run \
        install install-agent install-app uninstall-agent clean

build:
	swift build -c release

debug:
	swift build

# Assemble the menu-bar application bundle.
app: build
	rm -rf $(APP) $(APP_NAME).app
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN)/xppen-menu $(APPBIN)
	@test -f Support/AppIcon.icns || python3 Support/make-icon.py
	cp Support/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	sed -e "s|@APP_NAME@|$(APP_NAME)|g" \
	    -e "s|@EXECUTABLE@|$(APP_NAME)|g" \
	    -e "s|@BUNDLE_ID@|$(BUNDLE_ID)|g" \
	    Support/Info.plist.in > $(APP)/Contents/Info.plist
	printf 'APPL????' > $(APP)/Contents/PkgInfo
	plutil -lint $(APP)/Contents/Info.plist
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q "$(SIGN_ID)"; then \
	    codesign --force --sign "$(SIGN_ID)" --identifier "$(BUNDLE_ID)" $(APP) && \
	    echo "signed with '$(SIGN_ID)' (permissions persist across rebuilds)"; \
	else \
	    codesign --force --sign - $(APP) 2>/dev/null || true; \
	    echo "WARNING: signed ad-hoc — macOS will forget the permissions on each rebuild."; \
	    echo "         run Support/make-signing-identity.sh once to fix this."; \
	fi
	@echo "built $(APP)"

run-app: app
	open $(APP)

# --- CLI tools -------------------------------------------------------------

probe: build
	$(BIN)/xppen-probe

watch: build
	$(BIN)/xppen-probe --watch --init

descriptor: build
	$(BIN)/xppen-probe --descriptor

tapcheck: build
	$(BIN)/xppen-tapcheck

dry-run: build
	$(BIN)/xpdriverd --dry-run

run: build
	$(BIN)/xpdriverd

# --- Installation ----------------------------------------------------------

install: build
	mkdir -p $(PREFIX)
	cp $(BIN)/xpdriverd $(PREFIX)/xpdriverd
	cp $(BIN)/xppen-probe $(PREFIX)/xppen-probe
	cp $(BIN)/xppen-tapcheck $(PREFIX)/xppen-tapcheck
	@echo "installed CLI tools to $(PREFIX)"

# Install the menu-bar app into ~/Applications and start it at login.
install-app: app
	mkdir -p $(HOME)/Applications
	rm -rf $(HOME)/Applications/$(APP)
	cp -R $(APP) $(HOME)/Applications/$(APP)
	mkdir -p $(HOME)/Library/LaunchAgents
	@sed -e "s|@BINARY@|$(HOME)/Applications/$(APP)/Contents/MacOS/$(APP_NAME)|g" \
	     -e "s|@LOGPATH@|$(LOGPATH)|g" \
	     -e "s|@LABEL@|$(LABEL)|g" \
	     Support/launch-agent.plist.in > $(AGENT)
	plutil -lint $(AGENT)
	-launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	launchctl bootstrap gui/$$(id -u) $(AGENT)
	@echo "installed $(HOME)/Applications/$(APP) and registered login agent"

uninstall-agent:
	-launchctl bootout gui/$$(id -u)/$(LABEL)
	rm -f $(AGENT)
	rm -rf $(HOME)/Applications/$(APP)
	@echo "removed app and login agent"

clean:
	swift package clean
	rm -rf $(APP)
