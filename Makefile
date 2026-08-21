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
	modules-bridge \
	modules-compound-v2 \
	modules-compound-v3 \
	modules-dolomite \
	modules-euler-v2 \
	modules-fluid \
	modules-morpho-blue \
	modules-morpho-midnight \
	modules-transfer \
	modules-usdrif \
	modules-venus \
	modules-silo \
	modules-exactly \
	modules-lista \
	modules-river \
	modules-liquity-v2 \
	modules-gearbox-v3 \
	modules-teller

.PHONY: test build test-all build-all gas gas-check gas-diff size-check predict-core deploy-core $(addprefix test-,$(PACKAGES)) $(addprefix build-,$(PACKAGES))

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

# ── Deploy-size gate ─────────────────────────────────────────────────────────
#
# Settlement exceeds the EIP-170 runtime cap under legacy codegen; the
# DEPLOYMENT profile (`core-deploy`, via-IR — see foundry.toml) fits with
# margin. Settlement is the ONLY contract that needs via-IR, so the deploy
# build skips every non-settlement source dir (they still compile if imported)
# — via-IR on the full package takes the better part of an hour, this scope
# takes minutes. Everything else (lens, validators, modules) ships from the
# legacy profile and is measured there. `forge build --sizes` can't be the
# gate directly — the test-data LenderRegistry (never deployed) trips it — so
# this measures just the production contracts via `forge inspect`.

## CI gate: fail if the deployable Settlement/lens exceed the deploy size limits.
size-check:
	@FOUNDRY_PROFILE=core-deploy $(FORGE) build --quiet \
		--skip 'packages/core/test/*' --skip '*.s.sol' \
		--skip 'src/validators/*' --skip 'src/dust/*' --skip 'src/modules/*'
	@fail=0; \
	check() { \
		rt=$$(( ($$(FOUNDRY_PROFILE=$$1 $(FORGE) inspect $$2 deployedBytecode | tr -d '[:space:]' | wc -c) - 2) / 2 )); \
		ic=$$(( ($$(FOUNDRY_PROFILE=$$1 $(FORGE) inspect $$2 bytecode | tr -d '[:space:]' | wc -c) - 2) / 2 )); \
		printf "%-24s (%s) runtime %6d / 24576   initcode %6d / 49152\n" $$2 $$1 $$rt $$ic; \
		if [ $$rt -gt 24576 ]; then echo "FAIL: $$2 runtime exceeds EIP-170"; fail=1; fi; \
		if [ $$ic -gt 49152 ]; then echo "FAIL: $$2 initcode exceeds EIP-3860"; fail=1; fi; \
	}; \
	check core-deploy Settlement; \
	check core-deploy SettlementLens; \
	check core-deploy OriginSettler7683; \
	check core-deploy DestinationSettler7683; \
	exit $$fail

# ── Deterministic deployment ─────────────────────────────────────────────────
#
# The core singletons (Permit3 -> Settlement -> SettlementLens) go out through the
# shared CREATE2 DeployFactory so they land on IDENTICAL addresses on every chain.
# See docs/deterministic-deployment.md.
#
# THESE TARGETS EXIST TO PIN THE PROFILE. A CREATE2 address is a hash of init code,
# so `via_ir`, `optimizer_runs`, `bytecode_hash`, `cbor_metadata` and `evm_version`
# are all inputs to it -- and every one of them differs between `core-deploy` and
# the default profile. A hand-run `forge script` under the wrong profile produces a
# silently WRONG address family that nothing downstream would catch, and a
# Settlement that exceeds EIP-170 besides. A script cannot detect its own compiler
# settings, so the guard has to live here.
#
#   make predict-core RPC=https://...              # no key, no broadcast
#   make deploy-core  RPC=https://... CORE_SALT=0x...
#
# CORE_SALT is REQUIRED for a real rollout; without it the script falls back to a
# committed PLACEHOLDER salt and says so loudly. Once a rollout begins the salt
# must never change -- it is an input to every address ever predicted for it.

DEPLOY_SCRIPT := packages/core/script/Deploy.s.sol:DeployCore

## Print the predicted core addresses for a chain. Read-only.
predict-core:
	@test -n "$(RPC)" || { echo "RPC is required: make predict-core RPC=https://..."; exit 1; }
	FOUNDRY_PROFILE=core-deploy $(FORGE) script $(DEPLOY_SCRIPT) \
		--sig 'predict()' --rpc-url $(RPC)

## Deploy the core singletons, asserting each lands on its predicted address.
deploy-core:
	@test -n "$(RPC)" || { echo "RPC is required: make deploy-core RPC=https://..."; exit 1; }
	@test -n "$(CORE_SALT)" || echo ">> WARNING: CORE_SALT unset - using the PLACEHOLDER salt."
	FOUNDRY_PROFILE=core-deploy $(FORGE) script $(DEPLOY_SCRIPT) \
		--rpc-url $(RPC) --broadcast --verify

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
	@echo "  size-check            Fail if Settlement/facet exceed deploy size limits"
	@echo "  predict-core RPC=..   Print predicted deterministic core addresses"
	@echo "  deploy-core  RPC=..   Deploy core singletons via the CREATE2 factory"
	@echo ""
	@echo "Packages: $(PACKAGES)"
