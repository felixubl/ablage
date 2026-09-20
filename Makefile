APP = Ablage
BIN = .build/release/$(APP)
BUNDLE = dist/$(APP).app
# A real signing identity keeps the same designated requirement across builds, so macOS keeps
# folder and notification permissions. Ad hoc signatures change with every build and lose them.
SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development: [^"]*"' | head -1)
ifeq ($(SIGN_ID),)
SIGN_ID = -
endif

.PHONY: build app icons install run clean

build:
	swift build -c release

icons:
	mkdir -p dist/AppIcon.iconset
	cat Sources/Ablage/AppMark.swift Resources/make-icon.swift | swift - dist/AppIcon.iconset
	iconutil -c icns dist/AppIcon.iconset -o Resources/AppIcon.icns

app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	cp LICENSE $(BUNDLE)/Contents/Resources/LICENSE
	codesign --force --timestamp=none --sign $(SIGN_ID) $(BUNDLE)

install: app
	pkill -x $(APP) || true
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/$(APP).app
	open -n /Applications/$(APP).app

run: app
	open $(BUNDLE)

clean:
	rm -rf .build dist
