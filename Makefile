APP    = MiniSwitcher
BUNDLE = $(APP).app
BIN    = $(BUNDLE)/Contents/MacOS/$(APP)

.PHONY: build run clean

build:
	swiftc main.swift -o $(APP)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp $(APP) $(BIN)
	cp Info.plist $(BUNDLE)/Contents/Info.plist

run: build
	open $(BUNDLE)

clean:
	rm -rf $(APP) $(BUNDLE)
