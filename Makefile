APP    = MiniSwitcher
BUNDLE = $(APP).app
BIN    = $(BUNDLE)/Contents/MacOS/$(APP)

.PHONY: build run clean

# Generate once; only reruns if generate_icon.swift is newer than the .icns.
AppIcon.icns: generate_icon.swift
	swiftc generate_icon.swift -o .gen_icon && ./.gen_icon; rm -f .gen_icon

build: AppIcon.icns
	swiftc main.swift -o $(APP)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(APP) $(BIN)
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	cp AppIcon.icns $(BUNDLE)/Contents/Resources/
	codesign --force --deep --sign - $(BUNDLE)

run: build
	open $(BUNDLE)

clean:
	rm -rf $(APP) $(BUNDLE) AppIcon.icns
