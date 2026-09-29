## Second corpus — v4 / EVK / RFQ (2026-08-27)

The original C1–C15 taxonomy was built from 1inch, 0x, CoW, UniswapX and Velora.
This round adds **Uniswap v4**, **Euler v2 (EVC/EVK)**, **Native** and **Bebop**,
chosen because the first two attack the parts of our design the first corpus never
covered: v4's flash accounting is our netted `matchSettle` credit ledger, and the
EVC's batch-with-deferred-checks is our `MatchPlan` schedule. CoW and Velora were
already in [Sources](sources.md#sources) and are not re-derived here.

**Bebop publishes nine audits**, indexed at
[docs.bebop.xyz/audits](https://docs.bebop.xyz/audits#security-and-audits) — a
correction to an earlier draft of this section, which recorded "no public audit
report" because a keyword search surfaced only their docs. The lesson is worth
keeping: **a search that finds nothing is not evidence of nothing; check the
protocol's own docs for an audit index before recording a negative.** The MixBytes
report is markdown and is summarised as B1–B4 below; the other eight are PDFs that do
not survive automated fetch.

**Native** has one ([Symbolic Software NAT-001](https://symbolic.software/pdf/nat-001.pdf));
its published finding (NAT-001-001, immediately-overwritten variables) is a
code-quality issue with no analogue here, and its architecture (AquaVault treasury +
`NativePool` verifying maker quote signatures) is the same PMM-quote shape our
`CosignedQuotePriceModule` already implements.

| # | Class | Source | Our position |
|---|---|---|---|
| V1 | **Accounting bugs that still satisfy the settlement invariant.** The PoolManager only checks that a session's currency deltas resolve to zero; it never validates a hook's *internal* accounting, so a wrong sign, a rounding step or a mixed balance bucket leaks value while every transaction stays "valid" | [Trail of Bits — v4 hooks](https://blog.trailofbits.com/2026/07/30/building-secure-uniswap-v4-hooks/) #3; Bunni drained through 44 individually-valid txs | **This is precisely [F15](findings-ledger.md#f15--a-duplicate-pull-step-burned-maker-allowance-without-extra-fill-progress).** `BatchNotWhole` proves the POOL nets and `LegUnfunded` proves each leg reached its `owed` — neither says anything about how `owed` was rounded, nor about authority consumed on the way. Rounding direction is now pinned by `RoundingDirection.t.sol`: slicing an order must never favour the solver, fixed inputs are exact under any slicing (cumulative-difference form), outputs round toward the maker. |
| V2 | **Unrestricted hook callbacks / missing caller checks** — the Cork exploit (~$12M) | [ToB](https://blog.trailofbits.com/2026/07/30/building-secure-uniswap-v4-hooks/) #1 | **Clean, and load-bearing.** Every module entrypoint gates on its caller as its first statement: `msg.sender != address(permit3)` for `ITakerModule`, `msg.sender != settlement` for `IMakerModule`. Verified across all ten entrypoints in the aave-v3/v4 and morpho-blue packages during the 2026-08 module audit. |
| V3 | **Untrusted key/route selection** — attacker-created pools let untrusted `PoolKey` data reach logic that treats it as trusted | [ToB](https://blog.trailofbits.com/2026/07/30/building-secure-uniswap-v4-hooks/) #2 | **Structurally absent.** Our equivalent of a `PoolKey` is the maker-SIGNED order: modules, validators and the pricing module are all fields inside the EIP-712 hash, so a filler cannot substitute a route the maker did not sign. The one attacker-supplied channel is `takerData`, which is documented as adversarial and must be verified by whoever reads it. |
| V4 | **Logic in the wrong callback / stale cross-callback state** — values cached before an external call are stale after it | [ToB](https://blog.trailofbits.com/2026/07/30/building-secure-uniswap-v4-hooks/) #4, #7 | **Watch item.** `ctx.bump` is pinned once at `_openFill` and reused for every leg — correct, and deliberately so — but it means any future price input that CAN move mid-fill must not be read through `ctx`. `matchSettle` measures item proceeds as balance deltas around each module call rather than caching, which is the right shape. |
| E1 | **Deferred checks that can be skipped or forgiven.** The EVC lets a batch break invariants mid-flight so long as everything passes at the end; the danger is a path where the end-check does not run | [OpenZeppelin — EVK](https://www.openzeppelin.com/news/euler-vault-kit-evk-audit), [Electisec](https://reports.electisec.com/2024-03-EulerV2) | **Clean by construction.** `_matchFlush` is CONTRACT-owned and loops every order: completeness (`PlanIncomplete`), `_matchReconcileInputs`, then `_runInvariants`. The solver's schedule cannot skip it, reorder it, or address an order out of it — unlike the EVC, where which vaults get checked depends on what the batch touched. |
| E2 | **Reentrancy during an in-batch transfer**, where checks are forgiven before control returns; mitigated in the EVC by making `checkAccountStatus` a STATICCALL so a share transfer cannot execute attacker code | [OpenZeppelin — EVK](https://www.openzeppelin.com/news/euler-vault-kit-evk-audit) (low) | **Same mitigation, independently arrived at.** Validators, invariants and price modules are all `staticcall`-ed with a one-word return cap, so none can reenter or bomb memory; `matchSettle` is additionally `nonReentrant`. |
| E3 | **Rounding in loop/self-referential ops** — "expecting 10 units, receiving 11" | [OpenZeppelin — EVK](https://www.openzeppelin.com/news/euler-vault-kit-evk-audit) (low) | Covered by the V1 row's tests for the fill path. |

### Bebop (MixBytes, Jul 2023) — 1 High, 4 Medium, 1 Low

Their findings land almost entirely on the signature surface we hardened this week,
which is a useful independent check on that work.

Read via local `pdftotext` extraction after WebFetch failed on the binaries — the
same trick works for every PDF in the index, so "PDF" is not a reason to leave a
report unread.

| # | Their finding | Our position |
|---|---|---|
| B1 | **HIGH — EIP-712 `DOMAIN_SEPARATOR` replay.** Chain id cached in an immutable instead of read per call, so signatures stay valid on a forked network | **Clean, and now pinned.** `EIP712.DOMAIN_SEPARATOR()` serves the cached value only while `block.chainid` matches construction and recomputes otherwise — the Permit2 behaviour, inherited deliberately. `test_domainSeparator_followsChainId` asserts it. This is [S3](signature-validation.md#signature-validation--the-published-corpus-vs-our-position) confirmed by an external High. |
| B2 | **MEDIUM — unsafe `ecrecover`: the return value used as a MAPPING INDEX rather than only for comparison** | **Clean, guarded twice.** This is the sharper form of the zero-address class, and it applies to us: `Signatures._verifySignature` indexes `orderSignerExpiry[expected][signer]` for maker-delegated signing. Guarded by `signer != address(0)` *before* the lookup, and independently by `setOrderSigner` refusing a zero delegate so the slot can never be written. Pinned by `test_zeroRecovery_cannotAuthorizeViaDelegateRegistry`, deliberately run with a delegation ACTIVE — with no delegate the branch is unreachable and the test would pass whether the guard existed or not. |
| B3 | **MEDIUM — nonce truncation.** A `uint256` nonce cast to `uint64`, silently discarding high bits and colliding | **Structurally absent.** `NonceManager` splits the full `uint256` as `nonce >> 8` (word) and `nonce & 0xff` (bit); nothing is narrowed, so two distinct nonces cannot collide. |
| B4 | **MEDIUM — excess `msg.value` not refunded**, locking user funds | **Worth a look when native-input lands.** Not applicable to the current core: makers never send native value into a fill (see the native-asset assessment — maker-native-input needs escrow and was kept out of core). Re-check this row if that changes. |

### Bebop (Cyfrin, Router v2.0, Jun 2026) — 1 High, 2 Medium, 18 Low

The richest report in the index, and the one whose High is closest to our own shape.

| # | Their finding | Our position |
|---|---|---|
| C-H1 | **HIGH — the signed order authorises the input pull, but UNSIGNED relayer calldata decides the realised output.** The user's digest covered the order fields, not `bebopPmmCalldata`; validation checked token identity and non-zero amounts but not that the delivered amount matched the quote, that the receiver was the router, or that delivery was ERC-20 rather than native. With `limitAmount == 0` there was no output floor either. Three vectors: dust under-fill, receiver redirect, native-delivery accounting bypass — all total loss of the swap | **Same shape, structurally bounded.** Untrusted input reaches our realised price too: a cosigned-quote module derives its answer from filler-supplied `takerData`. The defence is not a check but a clamp — `DutchAuction.priceBump` forces the answer into `[0, BPS]` and maps it through the maker's OWN signed endpoints, so the worst a hostile module achieves is the maker's floor, a price they already declared acceptable. **Bebop's exploitable case was precisely the one with no floor.** Pinned by `HostilePriceModule.t.sol`, including a fuzz over every `uint256` answer. The redirect half is pinned by `FillUpTo.t.sol` — output-leg recipients live inside the signed `legsOut` blob. |
| C-L02 | **LOW — absolute balances.** `_executeSwapCore` reads the router's whole token balance, so tokens already held from an under-consumed fill, hook overproduction or a direct transfer get folded into the current swap | **Clean — this is [C15](failure-classes.md#c15--the-settlers-balance-treated-as-a-shared-pot).** `matchSettle` measures against `st.beforeBal[t]` snapshots and `_sweepSurplus` floors every touched token at its pre-context balance, so a donated balance is unreachable. `_stepPresend` says so explicitly. |
| C-L05 | **LOW — dust-fill nonce burn.** `exactAmount` is a function argument, not a signed field, so a relayer could partial-fill for dust and permanently consume the user's nonce. *Recommended: include a minimum fill size in the signed order* | **Already implemented, twice.** `Order.minFillAnchor` is exactly that maker-signed floor ({FillTooSmall}), and it gates the CLAMPED delta on `fillUpTo` too. Separately, a fill-once order (`useNonceInvalidator`) rejects partials outright with {FillOnceMustBeFull} — for the identical reason, since there the nonce IS the progress counter. |
| C-M1 / C-M2 | Leg scaling on maker refunds; relayer-supplied values stranding user input | Our refund path is fixed by construction: `_matchReconcileInputs` returns any surplus to the **maker**, never the solver, and the amount is the `owed` resolved at open rather than a recomputation. |

### Bebop — Decurity (JAM, Nov 2023) and Nethermind (Dec 2024)

Decurity's JAM review (their batch settlement, the closest external analogue to
`matchSettle` after the EVC) reports one Medium — a taker-loss path in
`JamBalanceManager` — plus two acknowledged Lows on signing and solver
observability. Nethermind's single point of attention is more interesting to us:

**Nethermind 7.1 — nonces shared between JamSettlement orders and Permit2.** One
nonce field feeds three independent invalidation systems (regular orders, limit
orders, Permit2), so off-chain allocation must satisfy all three at once and an
unrelated protocol consuming a Permit2 nonce can brick an order.

**Our position: the same sharing exists, but scoped and documented.** Permit3 shares
ONE bitmap per owner across both signed flows — deliberately, so
`invalidateUnorderedNonces` is a complete kill switch whichever flow signed, with the
stated cost that allocation is per-owner rather than per-message-type
({UnorderedNonces}). Crucially the ORDER nonce space ({NonceManager}) is **separate**
from the Permit3 space, so we have two clearly-bounded systems rather than three
implicitly coupled ones. Worth re-reading that header if a third signed flow is added.

### Bebop — Offside Labs (RFQ, Dec 2025)

**Solana**, not EVM (PDAs, signer seeds), so most of it does not transfer. The one
portable finding is 4.2 (Low, fixed): `output_amount * filled_taker_amount /
input_amount` overflowed the intermediate product on large quotes, causing a DoS.
Our pro-rata slice math has the same shape (`delta * tick / anchor`), but in checked
Solidity 0.8 an overflow reverts rather than wrapping, and reaching it needs
maker-signed amounts around 1e38 — a self-inflicted DoS on that maker's own order,
not a lever against anyone else. Noted, not actioned.

**The thread joining V1 and E1**, and the question to carry into the next batching
feature: *a wholeness check is not an accounting check.* Ours prove the pool nets and
every leg was funded. They do not prove that the per-order arithmetic was right, that
no authority was over-consumed reaching it, or that rounding went the intended way —
each of those needs its own assertion. F15 slipped through precisely because the
wholeness check passed.

---
