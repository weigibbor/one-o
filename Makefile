APP      = build/OneO.app
SOURCES  = $(wildcard Sources/*.swift)
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ { print $$2; exit }')

.PHONY: build install clean

build:
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources" build
	xcrun -sdk macosx metal -O3 -c Resources/Fold.metal -o build/Fold.air
	xcrun -sdk macosx metallib build/Fold.air -o "$(APP)/Contents/Resources/default.metallib"
	xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 $(SOURCES) \
		-o "$(APP)/Contents/MacOS/OneO" \
		-framework SwiftUI -framework AppKit -framework IOKit -framework ScreenCaptureKit -framework MetalKit
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
