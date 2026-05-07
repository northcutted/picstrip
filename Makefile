FASTLANE ?= bundle exec fastlane
DEVICE ?=
DEVICES ?=
ALLOW_PARTIAL ?= false

.PHONY: help lint analyze test build screenshots upload-screenshots screenshots-full screenshots-device screenshots-devices frame-screenshots clean-screenshots

help:
	@echo "PicStrip helper commands"
	@echo ""
	@echo "  make lint                         Run SwiftLint"
	@echo "  make analyze                      Run xcodebuild static analysis"
	@echo "  make test                         Run PicStripTests on the simulator"
	@echo "  make build                        Build and export build/PicStrip.ipa"
	@echo "  make screenshots                  Generate screenshots from fastlane/Snapfile"
	@echo "  make screenshots DEVICE=\"iPhone 17 Pro Max\""
	@echo "                                    Generate one-device screenshots"
	@echo "  make screenshots DEVICES=\"iPhone 17 Pro Max,iPhone Air\""
	@echo "                                    Generate a comma-separated device subset"
	@echo "  make frame-screenshots            Add device frames (for GitHub/marketing use)"
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
		echo "Set DEVICES, for example: make screenshots-devices DEVICES=\"iPhone 17 Pro Max,iPhone Air\""; \
		exit 1; \
	fi
	$(FASTLANE) screenshots devices:"$(DEVICES)"

upload-screenshots:
	@if [ "$(ALLOW_PARTIAL)" = "true" ]; then \
		$(FASTLANE) upload_screenshots allow_partial:true; \
	else \
		$(FASTLANE) upload_screenshots; \
	fi

frame-screenshots:
	$(FASTLANE) apply_frames

clean-screenshots:
	rm -rf fastlane/screenshots fastlane/screenshot_logs
