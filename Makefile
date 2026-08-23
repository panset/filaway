.DEFAULT_GOAL := build
.PHONY: setup build test smoke bench app run dmg notarize clean release

## setup: check the toolchain and report optional tools
setup:
	@command -v swift >/dev/null || { echo "ERROR: swift not found. Install the Xcode Command Line Tools: xcode-select --install"; exit 1; }
	@echo "swift:      $$(swift --version 2>&1 | head -1)"
	@echo "developer:  $$(xcode-select -p)"
	@command -v brew       >/dev/null && echo "brew:       $$(brew --version | head -1)" || echo "brew:       not installed (optional)"
	@command -v create-dmg >/dev/null && echo "create-dmg: present" || echo "create-dmg: missing (optional, 'brew install create-dmg'; hdiutil fallback works)"
	@command -v swiftlint  >/dev/null && echo "swiftlint:  present" || echo "swiftlint:  missing (optional, 'brew install swiftlint')"
	@security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" \
		&& echo "signing:    Developer ID present" \
		|| echo "signing:    no Developer ID (notarization blocked; see docs/plan.md §8)"
	@swift package resolve

## build: debug build of every target
build:
	swift build

## test: run the Swift Testing suite
test:
	swift test

## smoke: headless UI smoke test of the shell (builds the app if needed)
smoke: app
	Tools/smoke.sh

## bench: run the benchmark CLI (pass ARGS="...")
bench:
	swift run filaway-bench $(ARGS)

## app: assemble and ad-hoc sign build/Filaway.app
app:
	Tools/make_app.sh

## run: build the app bundle and launch it
run: app
	open build/Filaway.app

## dmg: package build/Filaway.app into build/Filaway.dmg
dmg: app
	Tools/make_dmg.sh

## notarize: Developer ID sign, notarize and staple the DMG
notarize:
	Tools/notarize.sh

## release: app -> dmg -> notarize
release: app dmg notarize

## clean: remove build products
clean:
	swift package clean
	rm -rf .build build
