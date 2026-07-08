# Foundry monorepo build helpers.
#
# Each package is compiled in isolation (only that package + its @core/
# dependencies), keeping peak RAM well below the full-monorepo build.
#
# Common usage:
#   make test PKG=modules-aave-v3   # one package
#   make test-modules-aave-v3       # shorthand
#   make test-all                   # all packages sequentially
#   make build-all                  # compile-check only (no tests)

FORGE ?= $(shell command -v forge 2>/dev/null || echo $(HOME)/.foundry/bin/forge)

# All packages that have at least one test file.
# Add modules-erc4626 once that branch is merged to main.
PACKAGES := \
	core \
	modules-aave-v2 \
	modules-aave-v3 \
	modules-aave-v4 \
	modules-compound-v2 \
	modules-compound-v3 \
	modules-dolomite \
	modules-euler-v2 \
	modules-fluid \
	modules-morpho \
	modules-transfer \
	modules-usdrif \
	modules-venus

.PHONY: test build test-all build-all $(addprefix test-,$(PACKAGES)) $(addprefix build-,$(PACKAGES))

# ── Single package ────────────────────────────────────────────────────────────

## Run tests for one package: make test PKG=modules-aave-v3
test:
	@test -n "$(PKG)" || (echo "Usage: make test PKG=<package-name>"; exit 1)
	FOUNDRY_PROFILE=$(PKG) $(FORGE) test -vv

## Compile one package: make build PKG=modules-aave-v3
build:
	@test -n "$(PKG)" || (echo "Usage: make build PKG=<package-name>"; exit 1)
	FOUNDRY_PROFILE=$(PKG) $(FORGE) build

# ── Per-package shortcuts ─────────────────────────────────────────────────────

$(addprefix test-,$(PACKAGES)): test-%:
	FOUNDRY_PROFILE=$* $(FORGE) test -vv

$(addprefix build-,$(PACKAGES)): build-%:
	FOUNDRY_PROFILE=$* $(FORGE) build

# ── All packages (sequential) ─────────────────────────────────────────────────

## Run every package's tests one at a time.
test-all:
	@set -e; \
	PASS=0; FAIL=0; \
	for pkg in $(PACKAGES); do \
		printf "\n\033[1;34m══ %-30s ══\033[0m\n" "$$pkg"; \
		if FOUNDRY_PROFILE=$$pkg $(FORGE) test -vv; then \
			PASS=$$((PASS+1)); \
		else \
			FAIL=$$((FAIL+1)); \
		fi; \
	done; \
	echo ""; \
	if [ $$FAIL -eq 0 ]; then \
		printf "\033[1;32m✓ All $$PASS packages passed\033[0m\n"; \
	else \
		printf "\033[1;31m✗ $$FAIL package(s) failed, $$PASS passed\033[0m\n"; \
		exit 1; \
	fi

## Compile-check every package without running tests.
build-all:
	@set -e; \
	for pkg in $(PACKAGES); do \
		printf "\n\033[1;34m══ Building %-26s ══\033[0m\n" "$$pkg"; \
		FOUNDRY_PROFILE=$$pkg $(FORGE) build; \
	done; \
	printf "\n\033[1;32m✓ All packages built\033[0m\n"

# ── Help ──────────────────────────────────────────────────────────────────────

help:
	@echo "Targets:"
	@echo "  test PKG=<name>       Test one package"
	@echo "  build PKG=<name>      Build one package"
	@echo "  test-<name>           Shorthand (e.g. make test-modules-aave-v3)"
	@echo "  build-<name>          Shorthand"
	@echo "  test-all              All packages sequentially"
	@echo "  build-all             Compile-check all packages"
	@echo ""
	@echo "Packages: $(PACKAGES)"
