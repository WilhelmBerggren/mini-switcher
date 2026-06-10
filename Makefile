APP       = MiniSwitcher
BUNDLE    = $(APP).app
BIN       = $(BUNDLE)/Contents/MacOS/$(APP)
BUNDLE_ID = com.local.miniswitcher

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
	# Override the designated requirement to use the bundle identifier rather than
	# the binary hash, so TCC persists the accessibility grant across rebuilds.
	codesign --force --deep --sign - \
		--identifier "$(BUNDLE_ID)" \
		--requirements '=designated => identifier "$(BUNDLE_ID)"' \
		$(BUNDLE)

run: build
	open $(BUNDLE)

clean:
	rm -rf $(APP) $(BUNDLE) AppIcon.icns
