GO ?= go

.PHONY: build test test-offline lint

build:
	$(GO) build -o bin/routecraft ./cmd/routecraft

test:
	$(GO) test ./...

test-offline:
	GOPROXY=off GOSUMDB=off $(GO) test ./...

lint:
	@test -z "$$(gofmt -l cmd internal tests/fixtures)" || (gofmt -l cmd internal tests/fixtures && exit 1)
	$(GO) vet ./...
