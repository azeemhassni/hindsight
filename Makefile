SWIFT ?= swift

.PHONY: all build vendor test test-integration lint clean

all: build

build: vendor
	$(SWIFT) build

vendor:
	./scripts/vendor.sh

test:
	$(SWIFT) test

test-integration:
	@echo "The integration environment arrives with the SSH transport in M2."
	@exit 1

lint:
	@if command -v swiftformat >/dev/null 2>&1; then \
		swiftformat --lint . ; \
	else \
		echo "swiftformat not installed; skipping (brew install swiftformat)" ; \
	fi

clean:
	$(SWIFT) package clean
	rm -rf .build
