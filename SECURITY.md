# Security

This document describes the security model of the 1delta-x intent-settlement
system, the invariants each component upholds, and the findings + fixes from the
internal security audit of 2026-06-18.

- [Architecture & trust model](#architecture--trust-model)
- [Security invariants](#security-invariants)
- [Audit (2026-06-18): findings & fixes](#audit-2026-06-18-findings--fixes)
- [Breaking change for integrators](#breaking-change-for-integrators)
- [Reporting a vulnerability](#reporting-a-vulnerability)

---

## Architecture & trust model

The system has three on-chain layers and no admin role / no module whitelist —
authority comes entirely from a maker's EIP-712 signature plus their Permit3
allowances.

```
   maker (EIP-712 order + permits)
        │
        ▼
   UniversalSettlement ──── the only trusted "spender" ────┐
        │  fill(order, sig, amount)                          │
        │                                                    │
        ├─ MAKE item ─▶ IMakerModule.makeOnBehalf(...)       │  gated: msg.sender == settlement
        │                 └─ permit3.transferFrom(...)  ◀─────┤  token book (spender = module)
        │                                                     │
        └─ TAKE item ─▶ permit3.take(module, maker, ...)  ◀──┘  taker book (spender = settlement)
                          └─ ITakerModule.takeOnBehalf(...)      gated: msg.sender == permit3
                                └─ protocol borrow/withdraw
```

### Permit3 — the allowance hub

Permit3 holds **two allowance books**, both keyed by **spender** (the address
allowed to consume the allowance), exactly like Permit2:

| Book  | Key                       | Consumed by                                   |
|-------|---------------------------|-----------------------------------------------|
| Token | `(user, spender, token)`  | `transferFrom(user, to, token, amount)` — `msg.sender == spender` |
| Taker | `(user, spender, ref)`    | `take(module, user, amount, receiver, data)` — `msg.sender == spender`, `ref = keccak256(data)` |

The taker book lets a module pull *value out of a position* (borrow, withdraw,
unstake, claim) — operations that don't fit the ERC20 `transferFrom` shape.
`take` decrements the `(user, msg.sender, ref)` allowance and then calls
`module.takeOnBehalf(...)`, which performs the protocol-native call.

### Modules — single-operation adapters

Each module performs exactly one operation (one Aave borrow, one Comet
withdraw, …). This keeps blast radius small: approving a borrow module can never
be used to withdraw collateral. Modules come in two shapes:

- **Taker modules** (`ITakerModule.takeOnBehalf`) — borrow/withdraw. Reachable
  **only** through `Permit3.take`; they enforce `msg.sender == permit3`.
- **Maker modules** (`IMakerModule.makeOnBehalf`) — deposit/repay. Called
  **only** by Settlement; they enforce `msg.sender == settlement`.

### Settlement — the only trusted spender

`UniversalSettlement` is the sole address makers approve as their taker/token
spender. It verifies the EIP-712 order, runs pre-execution validators, executes
items pro-rata, runs post-execution invariants, and pays the solver from the
proceeds **produced by that fill only**.

---

## Security invariants

1. **Taker authority is spender-keyed.** A taker allowance can be consumed only
   by the spender the maker approved (Settlement). `Permit3.take` is *not*
   open to arbitrary callers in practice: a caller with no allowance under its
   own address reverts `InsufficientAllowance`. The `receiver` of proceeds is
   chosen by that trusted spender, which enforces the maker-signed `recipient`.
   *(Regression test: `Permit3.t.sol::test_take_revert_unauthorizedSpender_C1`.)*

2. **Taker modules are Permit3-only.** Every `takeOnBehalf` reverts unless
   `msg.sender == permit3`, so the spender gate above cannot be bypassed by
   calling a module directly.

3. **Maker modules are Settlement-only.** Every `makeOnBehalf` reverts unless
   `msg.sender == settlement`, so an attacker cannot force unsolicited
   deposits/repays that consume a victim's standing token allowance.

4. **`ref = keccak256(data)` with no module-side canonicalisation.** The bytes a
   maker authorises are byte-for-byte the bytes the module decodes. The
   dispatched module is bound by the maker's signed order, so it need not enter
   `ref`.

5. **Reentrancy.** `Permit3.take`, `UniversalSettlement.fill`, and the
   repay/operate modules carry `nonReentrant` guards. Flash-solver callbacks are
   authenticated (`msg.sender == provider` + an in-flight flag + Aave
   `initiator == self`).

6. **Token movement is safe-by-default.** All ERC20 `transfer`/`transferFrom`/
   `approve` go through [`SafeTransferLib`](packages/core/src/utils/SafeTransferLib.sol)
   (`safeTransfer`, `safeTransferFrom`, `forceApprove`) — tolerating non-standard
   tokens (USDT-style no-return / approve-race).

7. **Validators are read-only and signer-bound.** They run via `staticcall`
   (no state change, no reentrancy), and their `target` + `data` are in the
   order's EIP-712 typehash, so a solver cannot weaken or swap them.

8. **Oracle freshness is enforced.** Chainlink validators reject
   non-positive prices, incomplete rounds, and prices older than a maker-signed
   `maxStaleness`. The MoC depeg guard rejects zero prices and reversed bands.

9. **Settlement holds no cross-fill funds.** The solver is paid from the TAKE
   proceeds of the current fill (measured as a balance delta), never from any
   pre-existing or donated Settlement balance; surplus is returned to the maker.

---

## Audit (2026-06-18): findings & fixes

Internal audit of `packages/core` + all module packages. All items below are
fixed in the working tree and covered by the test suite (**133/133 passing**,
including fork tests).

| ID  | Severity | Component | Finding | Fix |
|-----|----------|-----------|---------|-----|
| **C-1** | **Critical** | `Permit3.take` | The taker book was keyed by *module* and `take` was callable by anyone with an arbitrary `receiver`. Any standing taker allowance (required by the `fill()` path; left as a residual by partial `fillWithPermit`) could be drained by anyone — borrow/withdraw proceeds redirected to an attacker while the victim kept the debt. | Re-keyed the taker book by **spender** (`_takerAllowance[user][msg.sender][ref]`), mirroring the token book. Only the approved spender (Settlement) can consume an allowance; Settlement enforces the maker-signed `recipient`. |
| H-1 | High | Chainlink / DepegGuard validators | Oracle reads ignored staleness, round completeness, and price sign — a stale/zero price could pass a take-profit/stop-loss gate. | Added `price > 0`, `answeredInRound >= roundId`, and a maker-signed `maxStaleness` heartbeat to the Chainlink validators; DepegGuard now rejects zero price and reversed bands. |
| M-1 | Medium | Maker modules | `makeOnBehalf` was ungated — anyone could force a victim's pre-approved funds into deposits/repays (griefing / order-layer bypass). | Gated every `makeOnBehalf` to `msg.sender == settlement`. |
| M-2 | Medium | All modules + core | Raw ERC20 calls ignored return values (USDT-class break / silent failure). | Introduced `SafeTransferLib` and applied it repo-wide. |
| M-3 | Medium | `RedemptionSettledValidator` | "Settled" was inferred from the FIFO queue head (`firstOperId`), which only proves the op was *dequeued*, not that it cleared. | Now reads the op's final state via `opersInfo(opId)` / `operIdCount()`. |
| M-4 | Medium | Full-mode withdraws | Trusted a stale pre-read balance / static amount; could over-forward or leak a stray balance. | Forward a **measured** balance delta with `require(received >= amount)`; sweep only the real excess to the user. |
| L-1 | Low | `UniversalSettlement` | Solver payout used the whole contract balance (could scoop donated funds). | Pay from the current fill's measured proceeds only; return surplus to the maker. |
| L-2 | Low | DepegGuard | No `minPrice <= maxPrice` validation (self-DoS). | Reverts `InvalidBand` on a reversed band. |

**Confirmed-safe (no change needed):** flash-solver callback authentication;
Morpho `onMorphoRepay` is morpho-gated with a cap check (and supply uses empty
callback data); Fluid never implements `liquidityCallback` and always returns
the position NFT to the owner; token-side `transferFrom` is spender-gated;
EIP-712 domain caching with fork-recompute; Dutch-decay ceil-div (maker never
underpaid).

---

## Breaking change for integrators

The C-1 fix changes the **off-chain signing format**. Relayers / SDKs MUST update:

- **`TakerPermit` struct**: field `module` → **`spender`**. Set it to the
  **Settlement contract address**, not the module.
- **`approveTaker(spender, ref, amount, expiration)`**: the first argument is now
  the spender (Settlement).
- **`ref` is unchanged**: still `keccak256(data)`.
- **`ModuleRefPair` → `SpenderRefPair`** (for `lockdownTakers`).
- **EIP-712 typestrings** changed to
  `TakerPermit(address spender,bytes32 ref,uint160 amount,uint48 expiration)`
  in Permit3's batch/witness typehashes and Settlement's witness typestring.
- **Maker module constructors** now take an extra `address settlement` argument.

---

## Reporting a vulnerability

Report suspected vulnerabilities privately to **security@1delta.io**. Please do
not open public issues for security reports. Include a description, affected
contracts/addresses, and a reproduction (a failing Foundry test is ideal).

### Running the test suite

```bash
forge build --skip '*.s.sol'     # '*.s.sol' skip: boilerplate Deploy script is not part of the system
forge test  --skip '*.s.sol'     # fork tests; set ETH_RPC_URL to pin a fast mainnet RPC
```
