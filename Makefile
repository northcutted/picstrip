PLATFORM = python3 scripts/ios_release.py
DEVICE ?=
DEVICES ?=
LANGUAGES ?=
MARKETING_VERSION ?=
BUILD_NUMBER ?=
SUBMIT_FOR_REVIEW ?= false
RELEASE_TAG ?=
METADATA_COMMIT ?=

.PHONY: help platform-sync platform-gems docs check-docs lint analyze test build metadata-only audit-localization localization-export localization-pseudo localization-validate test-fixture screenshots process-screenshots clean-screenshots

help:
	@echo "PicStrip helper commands"
	@echo ""
	@echo "  make platform-sync                Fetch the reviewed platform pin (once per upgrade)"
	@echo "  make platform-gems                Install Ruby tools for screenshots/local archives"
	@echo "  make docs                         Regenerate the CI/CD reference (offline after sync)"
	@echo "  make check-docs                   Check reference drift and CI/CD documentation links"
	@echo "  make lint                         Run SwiftLint"
	@echo "  make analyze                      Run xcodebuild static analysis"
	@echo "  make test                         Run PicStripTests on the simulator"
	@echo "  make test-fixture                 Regenerate the OCR test fixture (Tests/Fixtures/test_list.png)"
	@echo "  make build                        Build and export build/application.ipa"
	@echo "  make metadata-only RELEASE_TAG=vX.Y.Z METADATA_COMMIT=<sha>  Stage metadata through Release"
	@echo "  make audit-localization           Check for unlocalized literals and string catalog gaps"
	@echo "  make localization-export          Export Xcode localization packages to build/localization-export"
	@echo "  make localization-pseudo LANGUAGES=\"es fr\""
	@echo "                                    Pseudo-localize a catalog for layout smoke testing"
	@echo "                                    (production translations are hand-written and committed directly)"
	@echo "  make localization-validate        Validate catalogs, localization audit, and SwiftLint"
	@echo "  make screenshots                  Generate screenshots from fastlane/Snapfile"
	@echo "  make screenshots DEVICE=\"iPhone 18 Pro Max\""
	@echo "                                    Generate one-device screenshots"
	@echo "  make screenshots DEVICES=\"iPhone 18 Pro Max,iPad Pro 13-inch (M5)\""
	@echo "                                    Generate a comma-separated device subset"
	@echo "  make process-screenshots          Frame + compose marketing PNGs from existing captures"
	@echo "  make clean-screenshots            Remove generated screenshots and logs"

platform-sync:
	$(PLATFORM) sync

platform-gems:
	$(PLATFORM) gems-install

docs:
	npm run docs

check-docs:
	npm run check:docs

lint:
	$(PLATFORM) qa lint

analyze:
	$(PLATFORM) qa analyze

test:
	$(PLATFORM) qa test

# Regenerates the OCR test fixture (Tests/Fixtures/test_list.png) from
# scripts/make_fixture.py. The fixture image is committed; this target only
# needs to run when the fixture itself is being changed (e.g. to add a new
# PII type to the OCR-detection scenarios). Requires Pillow:
#   pip3 install --user -r scripts/requirements.txt
test-fixture:
	python3 scripts/make_fixture.py \
		--reference Tests/Fixtures/test_list.png \
		--out Tests/Fixtures/test_list.png

build:
	$(PLATFORM) archive --version "$(MARKETING_VERSION)" --build-number "$(BUILD_NUMBER)"

metadata-only:
	@test -n "$(RELEASE_TAG)" || (echo "Set RELEASE_TAG to an immutable release"; exit 1)
	@test -n "$(METADATA_COMMIT)" || (echo "Set METADATA_COMMIT to the reviewed full commit SHA"; exit 1)
	@case "$(SUBMIT_FOR_REVIEW)" in \
		false) release_action='Update store metadata' ;; \
		true) release_action='Update metadata and request review' ;; \
		*) echo "SUBMIT_FOR_REVIEW must be true or false"; exit 1 ;; \
	esac; \
	gh workflow run promote.yml --ref main \
		-f action="$$release_action" -f source="$(RELEASE_TAG)" -f metadata_commit="$(METADATA_COMMIT)"

audit-localization:
	scripts/audit_localization_strings.sh
	scripts/audit_xcstrings.py

localization-export:
	rm -rf build/localization-export
	xcodebuild -exportLocalizations \
		-project PicStrip.xcodeproj \
		-localizationPath build/localization-export

localization-pseudo:
	@if [ -z "$(LANGUAGES)" ]; then \
		echo "Set LANGUAGES, for example: make localization-pseudo LANGUAGES=\"es fr de\""; \
		exit 1; \
	fi
	scripts/translate_xcstrings.js --languages $(LANGUAGES)

localization-validate:
	jq empty PicStrip/Localizable.xcstrings PicStrip/AppShortcuts.xcstrings \
		PicStrip/InfoPlist.xcstrings PicStripShareExtension/InfoPlist.xcstrings
	scripts/audit_localization_strings.sh
	scripts/audit_xcstrings.py
	swiftlint lint

screenshots:
	$(PLATFORM) screenshots-capture --devices "$(if $(DEVICE),$(DEVICE),$(DEVICES))" --languages "$(LANGUAGES)"

process-screenshots:
	python3 scripts/compose_screenshots.py

clean-screenshots:
	rm -rf fastlane/screenshots fastlane/screenshot_logs
