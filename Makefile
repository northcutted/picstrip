FASTLANE ?= bundle exec fastlane
DEVICE ?=
DEVICES ?=
ALLOW_PARTIAL ?= false
LANGUAGES ?=
LOCALIZATION_PROVIDER ?= pseudo
OPENAI_TRANSLATION_MODEL ?= gpt-4.1-mini
LOCALIZATION_CONCURRENCY ?= 5
# Canonical language list for localization-translate-all.
# Ordered by iOS market priority; add new codes here to grow coverage.
LOCALIZATION_LANGUAGES ?= es fr de ja zh-Hans pt-BR ko it nl pl sv tr ar zh-Hant pt-PT

.PHONY: help lint analyze test build audit-localization localization-export localization-translate localization-translate-all localization-validate screenshots process-screenshots upload-screenshots screenshots-full screenshots-device screenshots-devices clean-screenshots

help:
	@echo "PicStrip helper commands"
	@echo ""
	@echo "  make lint                         Run SwiftLint"
	@echo "  make analyze                      Run xcodebuild static analysis"
	@echo "  make test                         Run PicStripTests on the simulator"
	@echo "  make build                        Build and export build/PicStrip.ipa"
	@echo "  make audit-localization           Check core/extension string-returning literals"
	@echo "  make localization-export          Export Xcode localization packages to build/localization-export"
	@echo "  make localization-translate LANGUAGES=\"es fr\""
	@echo "                                    Fill missing .xcstrings localizations (default provider: pseudo)"
	@echo "  make localization-translate LOCALIZATION_PROVIDER=openai LANGUAGES=\"es fr\""
	@echo "                                    Translate via OpenAI Responses API (requires OPENAI_API_KEY)"
	@echo "  make localization-translate-all LOCALIZATION_PROVIDER=openai"
	@echo "                                    Translate all 15 supported languages via OpenAI (requires OPENAI_API_KEY)"
	@echo "  make localization-validate        Validate catalogs, localization audit, and SwiftLint"
	@echo "  make screenshots                  Generate screenshots from fastlane/Snapfile"
	@echo "  make screenshots DEVICE=\"iPhone 17 Pro Max\""
	@echo "                                    Generate one-device screenshots"
	@echo "  make screenshots DEVICES=\"iPhone 17 Pro Max,iPad Pro 13-inch (M5)\""
	@echo "                                    Generate a comma-separated device subset"
	@echo "  make process-screenshots          Frame + compose marketing PNGs from existing captures"
	@echo "  make upload-screenshots           Upload full screenshot set to App Store Connect"
	@echo "  make upload-screenshots ALLOW_PARTIAL=true"
	@echo "                                    Force upload of an incomplete screenshot set"
	@echo "  make clean-screenshots            Remove generated screenshots and logs"

lint:
	$(FASTLANE) lint

analyze:
	$(FASTLANE) analyze

test:
	$(FASTLANE) test

build:
	$(FASTLANE) build

audit-localization:
	scripts/audit_localization_strings.sh

localization-export:
	rm -rf build/localization-export
	xcodebuild -exportLocalizations \
		-project PicStrip.xcodeproj \
		-localizationPath build/localization-export

localization-translate:
	@if [ -z "$(LANGUAGES)" ]; then \
		echo "Set LANGUAGES, for example: make localization-translate LANGUAGES=\"es fr de\""; \
		exit 1; \
	fi
	LOCALIZATION_PROVIDER="$(LOCALIZATION_PROVIDER)" \
	OPENAI_TRANSLATION_MODEL="$(OPENAI_TRANSLATION_MODEL)" \
	LOCALIZATION_CONCURRENCY="$(LOCALIZATION_CONCURRENCY)" \
		scripts/translate_xcstrings.js --languages $(LANGUAGES)

localization-translate-all:
	LOCALIZATION_PROVIDER="$(LOCALIZATION_PROVIDER)" \
	OPENAI_TRANSLATION_MODEL="$(OPENAI_TRANSLATION_MODEL)" \
	LOCALIZATION_CONCURRENCY="$(LOCALIZATION_CONCURRENCY)" \
		scripts/translate_xcstrings.js --languages $(LOCALIZATION_LANGUAGES)

localization-validate:
	jq empty PicStrip/Localizable.xcstrings PicStrip/AppShortcuts.xcstrings
	scripts/audit_localization_strings.sh
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
		echo "Set DEVICE, for example: make screenshots-device DEVICE=\"iPhone 17 Pro Max\""; \
		exit 1; \
	fi
	$(FASTLANE) screenshots device:"$(DEVICE)"

screenshots-devices:
	@if [ -z "$(DEVICES)" ]; then \
		echo "Set DEVICES, for example: make screenshots-devices DEVICES=\"iPhone 17 Pro Max,iPad Pro 13-inch (M5)\""; \
		exit 1; \
	fi
	$(FASTLANE) screenshots devices:"$(DEVICES)"

process-screenshots:
	$(FASTLANE) process_screenshots

# Chains process-screenshots first so a local one-shot regenerates the
# marketing PNGs from raw captures before uploading. CI uploads what's
# already in fastlane/screenshots/processed/ (committed via Git LFS) and
# calls upload_screenshots directly without going through this target.
upload-screenshots: process-screenshots
	@if [ "$(ALLOW_PARTIAL)" = "true" ]; then \
		$(FASTLANE) upload_screenshots allow_partial:true; \
	else \
		$(FASTLANE) upload_screenshots; \
	fi

clean-screenshots:
	rm -rf fastlane/screenshots fastlane/screenshot_logs
