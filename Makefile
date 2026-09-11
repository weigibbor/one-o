APP      = build/OneO.app
SOURCES  = $(wildcard Sources/*.swift)
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ { print $$2; exit }')
VERSION  = $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)

.PHONY: build install clean dmg release check-updater

build:
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources" build
	xcrun -sdk macosx metal -O3 -c Resources/Fold.metal -o build/Fold.air
	xcrun -sdk macosx metallib build/Fold.air -o "$(APP)/Contents/Resources/default.metallib"
	xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 $(SOURCES) \
		-o "$(APP)/Contents/MacOS/OneO" \
		-framework SwiftUI -framework AppKit -framework IOKit -framework ScreenCaptureKit -framework MetalKit -framework MetalPerformanceShaders
	cp Info.plist "$(APP)/Contents/Info.plist"
	codesign --force --options runtime --sign "$(if $(SIGN_IDENTITY),$(SIGN_IDENTITY),-)" "$(APP)"

install: build
	rm -rf /Applications/OneO.app
	ditto "$(APP)" /Applications/OneO.app

clean:
	rm -rf build

dmg: build
	rm -rf dist && mkdir -p dist/stage && ditto "$(APP)" dist/stage/One-O.app && ln -s /Applications dist/stage/Applications
	hdiutil create -quiet -ov -volname "One-O" -srcfolder dist/stage -format UDZO dist/One-O.dmg && rm -rf dist/stage
	shasum -a 256 dist/One-O.dmg

release: dmg
	ditto -c -k --keepParent "$(APP)" dist/One-O.zip
	shasum -a 256 dist/One-O.zip
	@echo 'Publish with:'
	@echo '  gh release create v$(VERSION) dist/One-O.zip dist/One-O.dmg --title "One-O $(VERSION)" --generate-notes'

check-updater:
	mkdir -p build
	xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 Sources/Updater.swift Tests/UpdaterCheck.swift \
		-o build/check-updater -framework AppKit -framework SwiftUI
	build/check-updater
