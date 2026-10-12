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

# Builds Hindsight.app, signed with the Developer ID identity named in
# App/project.yml. `HINDSIGHT_UNSIGNED=1` builds without signing, which is the
# only option on a machine without the certificate — such a build cannot
# register the LaunchAgent, and says so.
HINDSIGHT_TEAM_ID ?= SM26HBBKRL
app: vendor
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo "xcodegen is needed to generate the app project: brew install xcodegen"; \
		exit 1; \
	}
	cd App && xcodegen generate
	cd App && xcodebuild -project Hindsight.xcodeproj -scheme Hindsight \
		-configuration $(CONFIGURATION) -destination 'platform=macOS' \
		$(if $(HINDSIGHT_UNSIGNED),CODE_SIGNING_ALLOWED=NO,DEVELOPMENT_TEAM=$(HINDSIGHT_TEAM_ID)) \
		build

# Submits the signed app to Apple, waits for the result, and staples the ticket
# to the bundle so it is accepted without a network round trip.
#
# Credentials come from a notarytool keychain profile. Any profile for this
# Apple account works, so an existing one is reused rather than asking for the
# password again; set HINDSIGHT_NOTARY_PROFILE to choose. A new one is made
# with:
#
#     xcrun notarytool store-credentials hindsight \
#       --apple-id <you@example.com> --team-id $(HINDSIGHT_TEAM_ID) \
#       --password <app-specific-password>
NOTARY_PROFILE_CANDIDATES ?= hindsight scribe-notary

notarize: app
	@set -eu; \
	profile="$(HINDSIGHT_NOTARY_PROFILE)"; \
	if [ -z "$$profile" ]; then \
		for candidate in $(NOTARY_PROFILE_CANDIDATES); do \
			if xcrun notarytool history --keychain-profile "$$candidate" \
				>/dev/null 2>&1; then profile="$$candidate"; break; fi; \
		done; \
	fi; \
	[ -n "$$profile" ] || { \
		echo "no notarytool keychain profile found; see the comment above this target"; \
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
