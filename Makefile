SWIFT ?= swift
CONFIGURATION ?= Debug

.PHONY: all build vendor app test test-integration lint clean

all: build

build: vendor
	$(SWIFT) build

vendor:
	./scripts/vendor.sh

test:
	$(SWIFT) test

test-integration:
	./scripts/testenv.sh up
	set -a; eval "$$(./scripts/testenv.sh env)"; set +a; \
		HINDSIGHT_ALLOW_DESTRUCTIVE_TESTS=1 HINDSIGHT_REQUIRE_TEST_ENV=1 $(SWIFT) test; \
		status=$$?; ./scripts/testenv.sh down; exit $$status

# Builds Hindsight.app.
#
# Signed ad hoc by default, which needs no Apple Developer account and is what
# building it yourself gets you. To sign with a Developer ID instead — needed
# only for a build that will run on a Mac other than the one that built it:
#
#     make app HINDSIGHT_TEAM_ID=ABCDE12345
#
# `HINDSIGHT_UNSIGNED=1` skips signing altogether. Prefer the ad-hoc default:
# an unsigned bundle cannot register the background agent at all.
app: vendor
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo "xcodegen is needed to generate the app project: brew install xcodegen"; \
		exit 1; \
	}
	cd App && xcodegen generate
	cd App && xcodebuild -project Hindsight.xcodeproj -scheme Hindsight \
		-configuration $(CONFIGURATION) -destination 'platform=macOS' \
		$(if $(HINDSIGHT_UNSIGNED),CODE_SIGNING_ALLOWED=NO,) \
		$(if $(HINDSIGHT_TEAM_ID),DEVELOPMENT_TEAM=$(HINDSIGHT_TEAM_ID) HINDSIGHT_SIGN_IDENTITY="Developer ID Application",) \
		build

# Submits the signed app to Apple, waits for the result, and staples the ticket
# to the bundle so it is accepted without a network round trip.
#
# Only for distributing a build to other people's Macs. Building Hindsight for
# yourself needs none of this: run `make app` and the ad-hoc signature is
# enough.
#
# Needs an Apple Developer account, a Developer ID certificate, and a
# notarytool keychain profile of your own:
#
#     xcrun notarytool store-credentials hindsight \
#       --apple-id <you@example.com> --team-id <YOUR_TEAM_ID> \
#       --password <app-specific-password>
#
# Then: make notarize HINDSIGHT_TEAM_ID=<YOUR_TEAM_ID>
HINDSIGHT_NOTARY_PROFILE ?= hindsight

notarize: app
	@set -eu; \
	[ -n "$(HINDSIGHT_TEAM_ID)" ] || { \
		echo "notarising needs a Developer ID: make notarize HINDSIGHT_TEAM_ID=<YOUR_TEAM_ID>"; \
		exit 1; \
	}; \
	profile="$(HINDSIGHT_NOTARY_PROFILE)"; \
	xcrun notarytool history --keychain-profile "$$profile" >/dev/null 2>&1 || { \
		echo "no notarytool keychain profile named $$profile; see the comment above this target"; \
		exit 1; \
	}; \
	app="$$(cd App && xcodebuild -project Hindsight.xcodeproj -scheme Hindsight \
		-configuration $(CONFIGURATION) -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $$2; exit}')/Hindsight.app"; \
	echo "notarising $$app with profile $$profile"; \
	codesign --verify --deep --strict "$$app"; \
	rm -f build/Hindsight.zip; mkdir -p build; \
	ditto -c -k --keepParent "$$app" build/Hindsight.zip; \
	xcrun notarytool submit build/Hindsight.zip \
		--keychain-profile "$$profile" --wait; \
	xcrun stapler staple "$$app"; \
	spctl --assess --type execute -vvv "$$app"

lint:
	@if command -v swiftformat >/dev/null 2>&1; then \
		swiftformat --lint . ; \
	else \
		echo "swiftformat not installed; skipping (brew install swiftformat)" ; \
	fi

clean:
	$(SWIFT) package clean
	rm -rf .build
