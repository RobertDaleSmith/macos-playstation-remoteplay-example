# Builds a real .app bundle. An unbundled binary cannot be granted Local Network
# permission, and without that the console is never discovered.
APP     := PSRemotePlayExample.app
CONFIG  ?= release
BIN     := .build/$(CONFIG)/PSRemotePlayExample

.PHONY: app run clean

app:
	swift build -c $(CONFIG)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/PSRemotePlayExample
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --deep --sign - $(APP)
	@echo "built $(APP)"

run: app
	open $(APP)

clean:
	rm -rf .build $(APP)
