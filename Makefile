.PHONY: build test
build: lint
	swift build -c release
test: lint
	swift test

include scripts/guardrails.mk
