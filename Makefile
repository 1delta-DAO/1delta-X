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
	solvers \
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

.PHONY: test build test-all build-all gas gas-check gas-diff $(addprefix test-,$(PACKAGES)) $(addprefix build-,$(PACKAGES))

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

# ── Gas snapshot (core package) ───────────────────────────────────────────────
#
# Records per-test gas into `.gas-snapshot` (committed) for the CORE package — where
# all the settlement / Permit3 / hashing / transfer-lib logic (and every gas
# optimization) lives. Scoped to `core` on purpose: `forge snapshot` keys entries by
# `Contract::test` WITHOUT the file path, and several module packages reuse test
# contract names (InvariantsTest, WithdrawAndSwapTest, …), which collide in a
# whole-monorepo snapshot. Core's 25 test contracts are all uniquely named, so this
# baseline is deterministic and `--check`-safe.
#
# Fork tests are block-pinned (deterministic gas); the few fuzz tests are pinned to a
# fixed `--fuzz-seed` here ONLY — the global config stays seedless so normal
# `forge test` keeps exploring.
#
#   make gas         # regenerate the committed baseline after an intended change
#   make gas-check   # CI gate: fail if any core test's gas moved from the baseline
#   make gas-diff    # show per-test gas deltas vs the baseline (no fail)
#
# Per-module gas gates, if ever needed, follow the same pattern:
#   FOUNDRY_PROFILE=modules-aave-v3-fork forge snapshot --snap gas/aave-v3.gas-snapshot

GAS_SEED ?= 0x1de17a

## Regenerate the committed gas baseline (.gas-snapshot) for the core package.
gas:
	FOUNDRY_PROFILE=core $(FORGE) snapshot --fuzz-seed $(GAS_SEED)

## Fail if any core test's gas moved from the committed baseline.
gas-check:
	FOUNDRY_PROFILE=core $(FORGE) snapshot --check --fuzz-seed $(GAS_SEED)

## Show per-test gas deltas vs the committed baseline.
gas-diff:
	FOUNDRY_PROFILE=core $(FORGE) snapshot --diff --fuzz-seed $(GAS_SEED)

# ── Help ──────────────────────────────────────────────────────────────────────

help:
	@echo "Targets:"
	@echo "  test PKG=<name>       Test one package"
	@echo "  build PKG=<name>      Build one package"
	@echo "  test-<name>           Shorthand (e.g. make test-modules-aave-v3)"
	@echo "  build-<name>          Shorthand"
	@echo "  test-all              All packages sequentially"
	@echo "  build-all             Compile-check all packages"
	@echo "  gas                   Regenerate the committed .gas-snapshot baseline"
	@echo "  gas-check             Fail if any test's gas moved from the baseline"
	@echo "  gas-diff              Show per-test gas deltas vs the baseline"
	@echo ""
	@echo "Packages: $(PACKAGES)"
