# ScreenBuffer — build / bundle / install
#
#   make build      compile the release binary
#   make bundle     assemble ScreenBuffer.app (+ ad-hoc codesign)
#   make run        bundle then launch it in the foreground
#   make install    copy app to /Applications and load the always-on LaunchAgent
#   make uninstall  unload the LaunchAgent and remove the installed app
#   make clean      remove build artifacts

APP_NAME    := ScreenBuffer
BUNDLE_ID   := com.bdavey.screenbuffer
APP_DIR     := $(APP_NAME).app
CONTENTS    := $(APP_DIR)/Contents
BIN         := .build/release/$(APP_NAME)
INSTALL_DIR := /Applications
AGENT_LABEL := $(BUNDLE_ID)
AGENT_PLIST := $(HOME)/Library/LaunchAgents/$(AGENT_LABEL).plist

.PHONY: build bundle run install uninstall clean

build:
	swift build -c release

bundle: build
	rm -rf "$(APP_DIR)"
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	cp "$(BIN)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	# Ad-hoc signature so the TCC Screen Recording grant binds to a stable identity.
	codesign --force --deep --sign - "$(APP_DIR)"
	@echo "Built $(APP_DIR)"

run: bundle
	"$(CONTENTS)/MacOS/$(APP_NAME)"

install: bundle
	rm -rf "$(INSTALL_DIR)/$(APP_DIR)"
	cp -R "$(APP_DIR)" "$(INSTALL_DIR)/"
	mkdir -p "$(HOME)/Library/LaunchAgents"
	sed "s|__EXEC__|$(INSTALL_DIR)/$(APP_DIR)/Contents/MacOS/$(APP_NAME)|g" \
		com.bdavey.screenbuffer.plist > "$(AGENT_PLIST)"
	-launchctl bootout gui/$(shell id -u)/$(AGENT_LABEL) 2>/dev/null || true
	launchctl bootstrap gui/$(shell id -u) "$(AGENT_PLIST)"
	@echo "Installed and loaded. Grant Screen Recording to $(INSTALL_DIR)/$(APP_DIR) if prompted."

uninstall:
	-launchctl bootout gui/$(shell id -u)/$(AGENT_LABEL) 2>/dev/null || true
	rm -f "$(AGENT_PLIST)"
	rm -rf "$(INSTALL_DIR)/$(APP_DIR)"
	@echo "Uninstalled."

clean:
	rm -rf .build "$(APP_DIR)"
