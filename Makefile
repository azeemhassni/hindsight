SWIFT ?= swift
CONFIGURATION ?= Debug

.PHONY: all build vendor app test test-integration test-coolify lint clean

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

test-coolify:
	./scripts/coolify-testenv.sh up
	@set -a; eval "$$(./scripts/testenv.sh env)"; eval "$$(./scripts/coolify-testenv.sh env)"; set +a; \
		HINDSIGHT_TEST_COOLIFY=1 HINDSIGHT_REQUIRE_COOLIFY_ENV=1 \
			$(SWIFT) test --filter "CoolifyIntegrationTests|EnvironmentPresenceTests"; \
		status=$$?; \
		if [ $$status -ne 0 ]; then \
			echo ""; \
			echo "If these were skipped, the virtual machine was unreachable."; \
			echo "OrbStack machine networking sometimes drops; restarting OrbStack restores it."; \
		fi; \
		exit $$status

# Builds Hindsight.app. Signs with HINDSIGHT_SIGNING_IDENTITY when it is set;
# without it the build is unsigned, which cannot register a LaunchAgent.
app: vendor
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo "xcodegen is needed to generate the app project: brew install xcodegen"; \
		exit 1; \
	}
	cd App && xcodegen generate
	cd App && xcodebuild -project Hindsight.xcodeproj -scheme Hindsight \
		-configuration $(CONFIGURATION) -destination 'platform=macOS' \
		$(if $(HINDSIGHT_SIGNING_IDENTITY),CODE_SIGN_IDENTITY="$(HINDSIGHT_SIGNING_IDENTITY)",CODE_SIGNING_ALLOWED=NO) \
		build

lint:
	@if command -v swiftformat >/dev/null 2>&1; then \
		swiftformat --lint . ; \
	else \
		echo "swiftformat not installed; skipping (brew install swiftformat)" ; \
	fi

clean:
	$(SWIFT) package clean
	rm -rf .build
