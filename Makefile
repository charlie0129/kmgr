SHELL := /bin/zsh

.PHONY: all generate test app app-release run clean test-build test-go test-swift clean-test-preferences clean-app-preferences

all: test

generate: ## Regenerate checked-in Go and Swift protobuf sources.
	./scripts/generate-proto.sh

test: test-build test-go test-swift

test-build:
	./scripts/test-build-app.sh

test-go:
	go test ./...
	go test -tags kmgr_dev ./backend/cmd/kmgr-engine

test-swift:
	./scripts/test-swift.sh

app:
	./scripts/build-app.sh

app-release:
	CONFIGURATION=release ./scripts/build-app.sh

install: app
	rm -rf /Applications/Kmgr.app
	cp -R build/Kmgr.app /Applications/Kmgr.app

run: app
	open build/Kmgr.app

clean:
	rm -rf build bin macos/.build .build

clean-test-preferences:
	./scripts/clean-test-preferences.sh

clean-app-preferences: clean-test-preferences
	rm -rf ~/Library/Application\ Support/kmgr
	rm -f ~/Library/Preferences/cc.chlc.kmgr.plist
