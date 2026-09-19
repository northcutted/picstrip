FASTLANE ?= bundle exec fastlane
DEVICE ?=
DEVICES ?=
LANGUAGES ?=
MARKETING_VERSION ?=
BUILD_NUMBER ?=
SUBMIT_FOR_REVIEW ?= false
RELEASE_TAG ?=
METADATA_COMMIT ?=

.PHONY: help lint analyze test build metadata-only audit-localization localization-export localization-pseudo localization-validate test-fixture screenshots process-screenshots screenshots-full screenshots-device screenshots-devices clean-screenshots

help:
	@echo "PicStrip helper commands"
	@echo ""
	@echo "  make lint                         Run SwiftLint"
	@echo "  make analyze                      Run xcodebuild static analysis"
	@echo "  make test                         Run PicStripTests on the simulator"
	@echo "  make test-fixture                 Regenerate the OCR test fixture (PicStripUITests/test_list.png)"
	@echo "  make build                        Build and export build/PicStrip.ipa"
	@echo "  make metadata-only RELEASE_TAG=vX.Y.Z METADATA_COMMIT=<sha>  Run the verified metadata workflow"
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

lint:
	$(FASTLANE) lint

analyze:
	$(FASTLANE) analyze

test:
	$(FASTLANE) test

# Regenerates the OCR test fixture (PicStripUITests/test_list.png) from
# scripts/make_fixture.py. The fixture image is committed; this target only
# needs to run when the fixture itself is being changed (e.g. to add a new
# PII type to the OCR-detection scenarios). Requires Pillow:
#   pip3 install --user -r scripts/requirements.txt
test-fixture:
	python3 scripts/make_fixture.py \
		--reference PicStripUITests/test_list.png \
		--out PicStripUITests/test_list.png

build:
	MARKETING_VERSION="$(MARKETING_VERSION)" BUILD_NUMBER="$(BUILD_NUMBER)" $(FASTLANE) build

metadata-only:
	@test -n "$(RELEASE_TAG)" || (echo "Set RELEASE_TAG to an immutable release"; exit 1)
	@test -n "$(METADATA_COMMIT)" || (echo "Set METADATA_COMMIT to the reviewed full commit SHA"; exit 1)
	gh workflow run metadata-only.yml --ref "$(RELEASE_TAG)" \
		-f release_tag="$(RELEASE_TAG)" -f metadata_commit="$(METADATA_COMMIT)" -f submit_for_review="$(SUBMIT_FOR_REVIEW)"

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
	@if [ -n "$(DEVICE)" ]; then \
		$(FASTLANE) screenshots device:"$(DEVICE)"; \
	elif [ -n "$(DEVICES)" ]; then \
		$(FASTLANE) screenshots devices:"$(DEVICES)"; \
	else \
		$(FASTLANE) screenshots; \
	fi

screenshots-full:
	$(FASTLANE) screenshots

screenshots-device:
	@if [ -z "$(DEVICE)" ]; then \
		echo "Set DEVICE, for example: make screenshots-device DEVICE=\"iPhone 18 Pro Max\""; \
		exit 1; \
	fi
	$(FASTLANE) screenshots device:"$(DEVICE)"

screenshots-devices:
	@if [ -z "$(DEVICES)" ]; then \
		echo "Set DEVICES, for example: make screenshots-devices DEVICES=\"iPhone 18 Pro Max,iPad Pro 13-inch (M5)\""; \
		exit 1; \
	fi
	$(FASTLANE) screenshots devices:"$(DEVICES)"

process-screenshots:
	$(FASTLANE) process_screenshots

clean-screenshots:
	rm -rf fastlane/screenshots fastlane/screenshot_logs
