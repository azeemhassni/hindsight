SWIFT ?= swift

.PHONY: all build test test-integration lint clean

all: build

build:
	$(SWIFT) build

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
