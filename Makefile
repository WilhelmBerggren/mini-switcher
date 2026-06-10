APP    = MiniSwitcher
BUNDLE = $(APP).app
BIN    = $(BUNDLE)/Contents/MacOS/$(APP)

.PHONY: build run clean

build:
	swiftc main.swift -o $(APP)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp $(APP) $(BIN)
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	# Ad-hoc sign so macOS TCC tracks permissions by bundle ID rather than raw binary hash.
	# After the very first build+permission grant you should only need to re-grant if you
	# explicitly clean and rebuild (binary content changes → signature changes).
	codesign --force --deep --sign - $(BUNDLE)

run: build
	open $(BUNDLE)

clean:
	rm -rf $(APP) $(BUNDLE)
