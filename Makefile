.PHONY: build test

build:
	swift build -c release

test:
	swift test
	./Tests/shell/test-auto-update.sh
