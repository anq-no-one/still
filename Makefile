SHELL := /bin/bash
ROOT := $(CURDIR)
DERIVED_DATA ?= $(HOME)/Library/Developer/Xcode/DerivedData/Still-shared
MAC_APP := $(DERIVED_DATA)/Build/Products/Debug/Still.app
IOS_APP := $(DERIVED_DATA)/Build/Products/Debug-iphonesimulator/Still.app
BUNDLE_ID := com.andrii.still

.PHONY: run-mac run-ios

run-mac:
	pkill -x Still || true
	xcodegen generate --spec "$(ROOT)/project.yml" --project "$(ROOT)" --quiet
	xcodebuild build -project "$(ROOT)/Still.xcodeproj" -scheme Still-macOS -destination 'platform=macOS,arch=arm64' -derivedDataPath "$(DERIVED_DATA)" -skipPackagePluginValidation -skipMacroValidation -allowProvisioningUpdates
	open "$(MAC_APP)"

run-ios:
	xcodegen generate --spec "$(ROOT)/project.yml" --project "$(ROOT)" --quiet
	UDID=$${STILL_SIMULATOR_UDID:-$$(xcrun simctl list devices available | grep -m1 -E 'iPhone.*\(Booted\)' | grep -oE '[0-9A-Fa-f-]{36}')}; \
	if [ -z "$$UDID" ]; then \
		TYPE=$$(xcrun simctl list devicetypes | grep -m1 -E '^iPhone 1[6-9] Pro \(' | sed -E 's/ \(.*//'); \
		UDID=$$(xcrun simctl create still-run "$$TYPE"); \
		xcrun simctl boot "$$UDID"; \
		xcrun simctl bootstatus "$$UDID" >/dev/null; \
	fi; \
	xcodebuild build -project "$(ROOT)/Still.xcodeproj" -scheme Still-iOS -destination "id=$$UDID" -derivedDataPath "$(DERIVED_DATA)" -skipPackagePluginValidation -skipMacroValidation -allowProvisioningUpdates; \
	xcrun simctl install "$$UDID" "$(IOS_APP)"; \
	xcrun simctl launch "$$UDID" "$(BUNDLE_ID)"
