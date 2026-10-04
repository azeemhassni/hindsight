SWIFT ?= swift

.PHONY: all build vendor test test-integration test-coolify lint clean

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
		HINDSIGHT_ALLOW_DESTRUCTIVE_TESTS=1 $(SWIFT) test; \
		status=$$?; ./scripts/testenv.sh down; exit $$status

test-coolify:
	./scripts/coolify-testenv.sh up
	set -a; eval "$$(./scripts/testenv.sh env)"; eval "$$(./scripts/coolify-testenv.sh env)"; set +a; \
		HINDSIGHT_TEST_COOLIFY=1 $(SWIFT) test --filter CoolifyIntegrationTests

lint:
	@if command -v swiftformat >/dev/null 2>&1; then \
		swiftformat --lint . ; \
	else \
		echo "swiftformat not installed; skipping (brew install swiftformat)" ; \
	fi

clean:
	$(SWIFT) package clean
	rm -rf .build
