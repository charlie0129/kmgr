SHELL := /bin/zsh

.PHONY: all generate test app run clean test-go test-swift

all: test

generate: ## Regenerate checked-in Go and Swift protobuf sources.
	./scripts/generate-proto.sh

test: test-go test-swift

test-go:
	go test ./...

test-swift:
	swift test --package-path macos

app:
	./scripts/build-app.sh

run: app
	open build/Kmgr.app

clean:
	rm -rf build bin macos/.build .build
