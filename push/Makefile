VERSION ?= dev
BIN     := rootshell-notify
PKG     := ./cmd/rootshell-notify
DIST    := dist/$(VERSION)
LDFLAGS := -s -w -X main.version=$(VERSION)
TARGETS := linux/amd64 linux/arm64 linux/arm darwin/amd64 darwin/arm64

.PHONY: build release test test-extensions vet clean

build:
	go build -trimpath -ldflags "$(LDFLAGS)" -o $(BIN) $(PKG)

test:
	go vet ./...
	go test ./...
	$(MAKE) test-extensions
	python3 installer/hermes_test.py

test-extensions:
	node --test installer/adapter.test.mjs

release:
	@test "$(VERSION)" != "dev" || { echo "set VERSION=x.y.z"; exit 1; }
	rm -rf $(DIST) && mkdir -p $(DIST)
	@for t in $(TARGETS); do \
		os=$${t%/*}; arch=$${t#*/}; \
		echo "building $$os/$$arch"; \
		CGO_ENABLED=0 GOOS=$$os GOARCH=$$arch GOARM=7 \
			go build -trimpath -ldflags "$(LDFLAGS)" -o $(DIST)/$(BIN)_$${os}_$${arch} $(PKG) || exit 1; \
	done
	cd $(DIST) && shasum -a 256 $(BIN)_* > SHA256SUMS
	@awk -v version="$(VERSION)" -v sums="$(DIST)/SHA256SUMS" ' \
		BEGIN { while ((getline line < sums) > 0) { split(line, f, / +\*?/); table = table "  " f[2] " " f[1] "\n" } } \
		/^@@CHECKSUMS@@$$/ { printf "%s", table; next } \
		{ gsub(/@@VERSION@@/, version); print } \
	' install.sh.tmpl > $(DIST)/install.sh
	chmod 755 $(DIST)/install.sh
	cp $(DIST)/install.sh install.sh
	@echo "release $(VERSION) in $(DIST)"

clean:
	rm -rf dist $(BIN) install.sh
