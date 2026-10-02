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
#
# ⚠ THREE PACKAGES SPLIT THEIR SUITE ACROSS TWO PROFILES, and the unit-only half is
# the one named here. `modules-aave-v3` is 6 unit tests; its 56 FORK tests — the
# leverage, swaps, closing, limit-order and TakerModuleAuth suites, i.e. everything
# that exercises the module against a real lender — live under
# `modules-aave-v3-fork` and used to be reachable from no make target at all. Same
# for compound-v3 and morpho-blue. `test-all` therefore reported green while
# skipping the majority of those packages' coverage. FORK_PACKAGES below closes it;
# `test-all` runs both lists. Keep the two in sync when a `-fork` profile is added
# to foundry.toml.
PACKAGES := \
	core \
	periphery \
	validators \
	lib \
	solvers \
	modules-aave-v2 \
	modules-aave-v3 \
	modules-aave-v4 \
	modules-bridge \
	modules-compound-v2 \
	modules-compound-v3 \
	modules-dolomite \
	modules-erc4626 \
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
	modules-teller \
	modules-pricing-chainlink \
	modules-pricing-quotes \
	modules-pricing-range \
	modules-fill \
	modules-nft \
	modules-maker \
	modules-oco

# Fork-only profiles: same sources, the FULL test directory, and an RPC. Listed
# separately because they are additive to the unit profile of the same name, not a
# replacement for it — running both is what covers the package.
FORK_PACKAGES := \
	modules-aave-v3-fork \
	modules-compound-v3-fork \
	modules-morpho-blue-fork

ALL_PACKAGES := $(PACKAGES) $(FORK_PACKAGES)

.PHONY: print-packages test test-sdk test-ts build test-all test-fork test-invariant test-deployed build-all gas gas-check gas-diff size-check docs-check modules-check predict-core deploy-core $(addprefix test-,$(ALL_PACKAGES)) $(addprefix build-,$(ALL_PACKAGES))

# ── CI matrix source ──────────────────────────────────────────────────────────

## Print ALL_PACKAGES as a JSON array. `.github/workflows/test.yml` builds its
## per-package matrix from this, so a package added here is gated in CI with no
## second list to keep in sync (audit 2026-09-30 MISC-MOD-6: `modules-erc4626` sat
## in no target, and CI gated only the core).
print-packages:
	@printf '['; sep=''; for p in $(ALL_PACKAGES); do printf '%s"%s"' "$$sep" "$$p"; sep=','; done; printf ']\n'

# ── Single package ────────────────────────────────────────────────────────────

## Run tests for one package: make test PKG=modules-aave-v3
test:
	@test -n "$(PKG)" || (echo "Usage: make test PKG=<package-name>"; exit 1)
	FOUNDRY_PROFILE=$(PKG) $(FORGE) test -vv

## SDK (vitest). Includes `encodingGolden.test.ts`, which shares
## `packages/sdk/test/fixtures/encoding-vectors.json` with
## `packages/core/test/EncodingGolden.t.sol`: the SDK must REPRODUCE the fixture,
## the core suite must INTERPRET it. Regenerate only with a contract change, via
## `UPDATE_FIXTURES=1 make test-sdk`, and commit both.
test-sdk:
	cd packages/sdk && npx vitest run

## The whole TypeScript side: SDK, orderbook, orderbook-server, auction, app. BUILDS
## THE DISTS FIRST — the orderbook, server, auction and app packages import
## `@1delta-x/sdk` (and the server `@1delta-x/orderbook`) through their compiled
## `dist/`, so a stale build ran the server suite against months-old code and hid a
## broken lens call (F29 P1). The auction and app suites were reachable from no make
## target at all until the 2026-09-30 audit (A-IMMUT-1).
test-ts:
	cd packages/sdk && npx tsc -p tsconfig.json && npx vitest run
	cd packages/orderbook && npx tsc -p tsconfig.json && npx vitest run
	cd packages/orderbook-server && npx tsc --noEmit -p tsconfig.json && npx vitest run
	cd packages/auction && npx tsc --noEmit -p tsconfig.json && npx vitest run
	cd packages/app && npx tsc --noEmit -p tsconfig.json && npx vitest run

## Compile one package: make build PKG=modules-aave-v3
build:
	@test -n "$(PKG)" || (echo "Usage: make build PKG=<package-name>"; exit 1)
	FOUNDRY_PROFILE=$(PKG) $(FORGE) build

# ── Per-package shortcuts ─────────────────────────────────────────────────────

$(addprefix test-,$(ALL_PACKAGES)): test-%:
	FOUNDRY_PROFILE=$* $(FORGE) test -vv

$(addprefix build-,$(ALL_PACKAGES)): build-%:
	FOUNDRY_PROFILE=$* $(FORGE) build

# ── All packages (sequential) ─────────────────────────────────────────────────

## Run ONLY the fork suites (needs an RPC; `ETH_RPC_URL` to pin one).
test-fork:
	@set -e; \
	for pkg in $(FORK_PACKAGES); do \
		printf "\n\033[1;34m══ %-30s ══\033[0m\n" "$$pkg"; \
		FOUNDRY_PROFILE=$$pkg $(FORGE) test -vv; \
	done

## Run the stateful invariant suite under the CORE profile's invariant settings.
# `[profile.core.invariant]` is the `core` profile's `invariant` SECTION, not a
# separate profile — so it activates under `FOUNDRY_PROFILE=core`, NOT
# `core.invariant` (which resolves as a fresh profile inheriting `default`'s
# whole-monorepo `src` and pulls every module in). `fail_on_revert = false` there
# is REQUIRED, not a convenience (foundry.toml): the handler drives every
# lifecycle entry as every actor, so most calls are SUPPOSED to revert — without
# it the walk stops at call 2. Scoped to `--match-path` so the rest of the core
# suite keeps its normal profile; run via `make test-core` / `make gas-check`.
test-invariant:
	FOUNDRY_PROFILE=core $(FORGE) test --match-path "packages/core/test/invariants/*" -vv

## Run the core suite against the DEPLOYED (via-IR) Permit3 + Settlement bytecode.
# Production ships both from `[profile.core-deploy]` (via-IR, runs = 100, cancun),
# but every other target tests the legacy `[profile.core]` build — so hand-written
# assembly whose `memory-safe-assembly` promise only via-IR relies on is otherwise
# never run as shipped (audit 2026-09-29, lens F L-1). Compiling the TEST tree via-IR
# takes 20+ minutes; instead (1) builds just the deployable artifacts via-IR, then
# (2) runs the legacy-compiled suite with `DEPLOYED_BYTECODE=1`, which makes the
# shared bases deploy Permit3/Settlement from that artifact JSON instead of `new`
# (packages/core/test/shared/DeployedBytecode.sol). Tests, helpers and every other
# contract stay legacy; only the two shipped singletons (and the executor Settlement
# creates) swap — same addresses as `new`. Gas numbers under the switch are NOT the
# committed baseline, and the switch leaves the DEFAULT run's gas untouched (verified
# 0 of 804 non-fuzz tests moved — see the file's header for why that took care).
#
# MEASURED 2026-09-29: step (1) ~3 s, step (2) ~10 s of test time on top of the usual
# [profile.core] compile (~3 min cold, reused warm). Not switched, by design: the
# `new Settlement` in ErrorSurfaceTest's body (twin: DeployedBytecodeHarnessTest) and
# DeterministicDeployTest (tests the deploy SCRIPT's own `type(..).creationCode`).
#
#   make test-deployed                                      # full core suite
#   make test-deployed DEPLOYED_TEST_ARGS='--match-path "packages/core/test/permit3/*"'
#
# Step (1) builds into its OWN out/cache pair, not `out/core-deploy` + `cache/`:
#   • a SHARED cache is invalidated by every profile switch — MEASURED: one
#     core-deploy build (3 s) forces the next [profile.core] build to recompile the
#     whole test tree (~3 min), i.e. every run of this target would pay it;
#   • a SEPARATE cache over the SHARED `out/core-deploy` could go stale silently
#     (foundry checks an artifact exists, not which build wrote it), and `size-check`
#     rewrites that dir under other settings' caches.
# Override both to run beside a concurrent `test-deployed` (the dir must stay under
# `./out`, see fs_permissions); export FOUNDRY_OUT/FOUNDRY_CACHE_PATH to privatise
# step (2)'s legacy build as well.
DEPLOYED_ARTIFACTS ?= out/test-deployed
DEPLOYED_CACHE ?= cache/test-deployed
DEPLOYED_TEST_ARGS ?=
test-deployed:
	FOUNDRY_PROFILE=core-deploy FOUNDRY_OUT=$(DEPLOYED_ARTIFACTS) FOUNDRY_CACHE_PATH=$(DEPLOYED_CACHE) \
		$(FORGE) build --skip 'packages/core/test/*' --skip '*.s.sol'
	DEPLOYED_BYTECODE=1 DEPLOYED_ARTIFACTS=$(DEPLOYED_ARTIFACTS) FOUNDRY_PROFILE=core \
		$(FORGE) test -vv $(DEPLOYED_TEST_ARGS)

## Run every package's tests one at a time.
test-all:
	@set -e; \
	PASS=0; FAIL=0; \
	for pkg in $(ALL_PACKAGES); do \
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

# ── Documentation gate ───────────────────────────────────────────────────────
#
# `docs/edge-case-matrix.md` binds every classified combination to the test that
# pins it, and `docs/reference-audits.md` binds every finding to its regression.
# Those bindings are prose: rename a test and the table still claims the cell is
# covered, which is the same drift-between-doc-and-code that produced F13. This
# gate makes the citations mechanically checkable, like the error sweep in the
# matrix note's Part 3.

## CI gate: fail if any doc cites a test that no longer exists.
docs-check:
	@python3 tools/check-doc-citations.py

# ── Module shape gate ─────────────────────────────────────────────────────────
#
# Permit3's taker book is keyed by `(user, spender, module, ref)` and cannot tell
# `take` from `takeFor`, so a module implementing BOTH dispatches would let one
# `approveTaker` authorise either — with nothing in the grant saying which. Every
# module shipped implements one; this is what makes that a rule rather than a
# habit. See docs/reference-audits.md F23.
## CI gate: fail if any contract implements both taker dispatch shapes.
modules-check:
	@python3 tools/check-module-shapes.py
	@python3 tools/test-module-shapes.py
	@python3 tools/check-ci-packages.py

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
#
# The old `--skip 'src/modules/*'` is gone with the directory: as of 2026-08-24 core
# ships no modules, so there is nothing there to exclude from the via-IR build. The
# `src/validators/*` and `src/dust/*` skips went the same way when those directories
# left core.
#
# `SettlementLensChecks` is CREATEd by the lens constructor (audit 2026-09-30), so it
# is bound by EIP-170 too and is gated here; so is `NativeSettler`.
#
# The lens and the two 7683 settlers now build under `periphery-deploy`, whose
# compiler settings are pinned byte-identical to `core-deploy` — the lens is a CREATE2
# singleton in `Deploy.s.sol`, so a settings drift between the two profiles would move
# its address alone. Verified unchanged across the split.

## CI gate: fail if the deployable Settlement/lens exceed the deploy size limits.
size-check:
	@FOUNDRY_PROFILE=core-deploy $(FORGE) build --quiet \
		--skip 'packages/core/test/*' --skip '*.s.sol'
	@FOUNDRY_PROFILE=periphery-deploy $(FORGE) build --quiet --skip '*.s.sol'
	@fail=0; \
	check() { \
		rt=$$(( ($$(FOUNDRY_PROFILE=$$1 $(FORGE) inspect $$2 deployedBytecode | tr -d '[:space:]' | wc -c) - 2) / 2 )); \
		ic=$$(( ($$(FOUNDRY_PROFILE=$$1 $(FORGE) inspect $$2 bytecode | tr -d '[:space:]' | wc -c) - 2) / 2 )); \
		printf "%-24s (%s) runtime %6d / 24576   initcode %6d / 49152\n" $$2 $$1 $$rt $$ic; \
		if [ $$rt -gt 24576 ]; then echo "FAIL: $$2 runtime exceeds EIP-170"; fail=1; fi; \
		if [ $$ic -gt 49152 ]; then echo "FAIL: $$2 initcode exceeds EIP-3860"; fail=1; fi; \
	}; \
	check core-deploy Settlement; \
	check periphery-deploy SettlementLens; \
	check periphery-deploy SettlementLensChecks; \
	check periphery-deploy NativeSettler; \
	check periphery-deploy OriginSettler7683; \
	check periphery-deploy DestinationSettler7683; \
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
	@echo "  test-deployed         Core suite against the deployed (via-IR) Permit3/Settlement"
	@echo "  build-all             Compile-check all packages"
	@echo "  gas                   Regenerate the committed .gas-snapshot baseline"
	@echo "  gas-check             Fail if any test's gas moved from the baseline"
	@echo "  gas-diff              Show per-test gas deltas vs the baseline"
	@echo "  size-check            Fail if Settlement/facet exceed deploy size limits"
	@echo "  predict-core RPC=..   Print predicted deterministic core addresses"
	@echo "  deploy-core  RPC=..   Deploy core singletons via the CREATE2 factory"
	@echo ""
	@echo "Packages: $(PACKAGES)"
