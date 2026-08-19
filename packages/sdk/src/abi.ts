// Minimal ABIs for calldata encoding. Tuple component order matches the
// Solidity structs exactly.

const itemComponents = [
  { name: "op", type: "uint8" },
  { name: "module", type: "address" },
  { name: "amount", type: "uint256" },
  { name: "recipient", type: "address" },
  { name: "data", type: "bytes" },
] as const;

const validatorComponents = [
  { name: "target", type: "address" },
  { name: "data", type: "bytes" },
] as const;

const curvePointComponents = [
  { name: "timeDelta", type: "uint32" },
  { name: "bumpBps", type: "uint32" },
] as const;

const legInComponents = [
  { name: "token", type: "address" },
  { name: "start", type: "uint256" },
  { name: "end", type: "uint256" },
] as const;

const legOutComponents = [
  { name: "token", type: "address" },
  { name: "start", type: "uint256" },
  { name: "end", type: "uint256" },
  { name: "recipient", type: "address" },
] as const;

export const orderComponents = [
  { name: "maker", type: "address" },
  { name: "nonce", type: "uint256" },
  // `expiry` folded into `timing` bits [160:208) — not a tuple member. See packed.ts.
  { name: "legsIn", type: "bytes" },
  { name: "legsOut", type: "bytes" },
  { name: "timing", type: "uint256" },
  { name: "exclusiveFiller", type: "address" },
  { name: "minFillAnchor", type: "uint256" },
  { name: "params", type: "uint256" },
  { name: "curve", type: "bytes" },
  { name: "items", type: "bytes" },
  { name: "validators", type: "bytes" },
  { name: "invariants", type: "bytes" },
  { name: "fillModule", type: "address" },
  { name: "fillTotal", type: "uint256" },
  { name: "pricingModule", type: "address" },
] as const;

const tokenPermitComponents = [
  { name: "spender", type: "address" },
  { name: "token", type: "address" },
  { name: "amount", type: "uint160" },
  { name: "expiration", type: "uint48" },
] as const;

const takerPermitComponents = [
  { name: "spender", type: "address" },
  { name: "module", type: "address" },
  { name: "ref", type: "bytes32" },
  { name: "amount", type: "uint160" },
  { name: "expiration", type: "uint48" },
] as const;

const permitBatchComponents = [
  { name: "tokens", type: "tuple[]", components: tokenPermitComponents },
  { name: "takers", type: "tuple[]", components: takerPermitComponents },
  { name: "nonce", type: "uint256" },
  { name: "deadline", type: "uint256" },
] as const;

const permitTakeComponents = [
  { name: "module", type: "address" },
  { name: "ref", type: "bytes32" },
  { name: "amount", type: "uint160" },
  { name: "nonce", type: "uint256" },
  { name: "deadline", type: "uint256" },
] as const;

const tokenSpenderPairComponents = [
  { name: "token", type: "address" },
  { name: "spender", type: "address" },
] as const;

const spenderRefPairComponents = [
  { name: "spender", type: "address" },
  { name: "module", type: "address" },
  { name: "ref", type: "bytes32" },
] as const;

const outputLegComponents = [
  { name: "token", type: "address" },
  { name: "flashAmount", type: "uint256" },
  { name: "dexFee", type: "uint24" },
  { name: "spendIn", type: "uint256" },
  { name: "minOut", type: "uint256" },
] as const;

const orderArg = { name: "order", type: "tuple", components: orderComponents } as const;

export const SETTLEMENT_ABI = [
  {
    type: "function",
    name: "fill",
    stateMutability: "nonpayable",
    inputs: [orderArg, { name: "sig", type: "bytes" }, { name: "fillAmountIn", type: "uint256" }],
    outputs: [{ name: "fillAmountsOut", type: "uint256[]" }],
  },
  // Overload carrying a filler-supplied `takerData` blob (unsigned, adversarial —
  // a validator must independently verify it). Distinct selector; the 3-arg form
  // above stays for callers that don't use it.
  {
    type: "function",
    name: "fill",
    stateMutability: "nonpayable",
    inputs: [
      orderArg,
      { name: "sig", type: "bytes" },
      { name: "fillAmountIn", type: "uint256" },
      { name: "takerData", type: "bytes" },
    ],
    outputs: [{ name: "fillAmountsOut", type: "uint256[]" }],
  },
  {
    type: "function",
    name: "fillWithPermit",
    stateMutability: "nonpayable",
    inputs: [
      orderArg,
      { name: "batch", type: "tuple", components: permitBatchComponents },
      { name: "sig", type: "bytes" },
      { name: "fillAmountIn", type: "uint256" },
    ],
    outputs: [{ name: "fillAmountsOut", type: "uint256[]" }],
  },
  // fillWithPermit overload with a trailing `takerData` blob (see the fill overload).
  {
    type: "function",
    name: "fillWithPermit",
    stateMutability: "nonpayable",
    inputs: [
      orderArg,
      { name: "batch", type: "tuple", components: permitBatchComponents },
      { name: "sig", type: "bytes" },
      { name: "fillAmountIn", type: "uint256" },
      { name: "takerData", type: "bytes" },
    ],
    outputs: [{ name: "fillAmountsOut", type: "uint256[]" }],
  },
  // The aggregator entry: clamps to the order's remaining size instead of the
  // OverFill race revert, optionally redirects proceeds, and returns full
  // both-sides accounting — (delta, received per legsIn, paid per legsOut).
  {
    type: "function",
    name: "fillUpTo",
    stateMutability: "nonpayable",
    inputs: [
      orderArg,
      { name: "sig", type: "bytes" },
      { name: "fillAmount", type: "uint256" },
      { name: "recipient", type: "address" },
      { name: "minBumpBps", type: "uint256" },
      { name: "takerData", type: "bytes" },
    ],
    outputs: [
      { name: "delta", type: "uint256" },
      { name: "received", type: "uint256[]" },
      { name: "paid", type: "uint256[]" },
    ],
  },
  // ──────────────────── Cancellation ────────────────────
  //
  // Three on-chain granularities, plus the free off-chain one:
  //   cancelOrder(order)         ONE order, by hash. Siblings sharing its nonce
  //                              stay fillable. Parks `filled` at the max
  //                              sentinel, so it costs the hot path nothing.
  //   cancelOrders(nonces[])     every order carrying any of those nonces.
  //   invalidateNonceWord(word)  256 nonces in one SSTORE.
  //   rollbackNonces(minValid)   every nonce below a watermark, in one SSTORE.
  //   (off-chain)                a signed `SoftCancel` — see `softcancel.ts`.
  //                              Free, but advisory: it evicts from books, it
  //                              does not bind a filler.
  {
    type: "function",
    name: "cancelOrder",
    stateMutability: "nonpayable",
    inputs: [orderArg],
    outputs: [{ name: "orderHash", type: "bytes32" }],
  },
  {
    type: "function",
    name: "cancelOrders",
    stateMutability: "nonpayable",
    inputs: [{ name: "noncesToCancel", type: "uint256[]" }],
    outputs: [],
  },
  {
    type: "function",
    name: "invalidateNonceWord",
    stateMutability: "nonpayable",
    inputs: [{ name: "wordIndex", type: "uint256" }],
    outputs: [],
  },
  {
    type: "function",
    name: "rollbackNonces",
    stateMutability: "nonpayable",
    inputs: [{ name: "newMinValidNonce", type: "uint256" }],
    outputs: [],
  },
  {
    type: "function",
    name: "isNonceCancelled",
    stateMutability: "view",
    inputs: [
      { name: "maker", type: "address" },
      { name: "nonce", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
  // ──────────────────── Authorization ────────────────────
  {
    type: "function",
    name: "approveOrder",
    stateMutability: "nonpayable",
    inputs: [orderArg],
    outputs: [{ name: "orderHash", type: "bytes32" }],
  },
  // Batch approveOrder — one transaction (one multisig action) authorizing a
  // whole ladder. All-or-nothing on the maker check; same per-order events.
  {
    type: "function",
    name: "approveOrders",
    stateMutability: "nonpayable",
    inputs: [{ ...orderArg, name: "orders", type: "tuple[]" }],
    outputs: [{ name: "orderHashes", type: "bytes32[]" }],
  },
  {
    type: "function",
    name: "revokeOrderApproval",
    stateMutability: "nonpayable",
    inputs: [{ name: "orderHash", type: "bytes32" }],
    outputs: [],
  },
  {
    type: "function",
    name: "setOrderSigner",
    stateMutability: "nonpayable",
    inputs: [
      { name: "signer", type: "address" },
      { name: "expiry", type: "uint256" },
    ],
    outputs: [],
  },
  // `0` = not a signer. Read by the off-chain cancel verifier to accept a
  // delegate's signature over a `SoftCancel` on exactly the terms the settlement
  // accepts one over an `Order`.
  {
    type: "function",
    name: "orderSignerExpiry",
    stateMutability: "view",
    inputs: [
      { name: "maker", type: "address" },
      { name: "signer", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "filled",
    stateMutability: "view",
    inputs: [{ name: "orderHash", type: "bytes32" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  // ──────────────────── Events ────────────────────
  //
  // The chain announcing what an off-chain book would otherwise have to poll
  // for. Four of the five below are ENOUGH ON THEIR OWN to evict — a watcher
  // learns maker + which nonces/hash died and needs no follow-up call. Only
  // `OrderFilled` needs one, because it says an order moved but not how far.
  {
    type: "event",
    name: "OrderFilled",
    inputs: [
      { name: "orderHash", type: "bytes32", indexed: true },
      { name: "maker", type: "address", indexed: true },
      { name: "solver", type: "address", indexed: true },
    ],
  },
  {
    type: "event",
    name: "OrderCancelledByHash",
    inputs: [
      { name: "maker", type: "address", indexed: true },
      { name: "orderHash", type: "bytes32", indexed: true },
    ],
  },
  {
    type: "event",
    name: "OrdersCancelled",
    inputs: [
      { name: "maker", type: "address", indexed: true },
      { name: "nonces", type: "uint256[]", indexed: false },
    ],
  },
  {
    type: "event",
    name: "NoncesRolledBack",
    inputs: [
      { name: "maker", type: "address", indexed: true },
      { name: "minValidNonce", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "NonceWordInvalidated",
    inputs: [
      { name: "maker", type: "address", indexed: true },
      { name: "wordIndex", type: "uint256", indexed: false },
    ],
  },
] as const;

/// The Permit3 allowance hub — the external surface an integrator calls directly
/// (the SDK's order helpers only ever touch `permitBatchWithWitness` via the
/// settlement's `fillWithPermit`, so this is the rest: on-chain grants, the taker
/// book, the one-shot `permitTake`, strict mode and combined revocation). Tuple
/// component order matches `IPermit3.sol` exactly.
export const PERMIT3_ABI = [
  // ── Token book ──
  {
    type: "function",
    name: "approveToken",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "token", type: "address" },
      { name: "amount", type: "uint160" },
      { name: "expiration", type: "uint48" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "transferFrom",
    stateMutability: "nonpayable",
    inputs: [
      { name: "user", type: "address" },
      { name: "to", type: "address" },
      { name: "token", type: "address" },
      { name: "amount", type: "uint160" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "tokenAllowance",
    stateMutability: "view",
    inputs: [
      { name: "user", type: "address" },
      { name: "spender", type: "address" },
      { name: "token", type: "address" },
    ],
    outputs: [
      { name: "amount", type: "uint160" },
      { name: "expiration", type: "uint48" },
    ],
  },
  { type: "function", name: "revokeToken", stateMutability: "nonpayable", inputs: [{ name: "spender", type: "address" }, { name: "token", type: "address" }], outputs: [] },
  { type: "function", name: "lockdown", stateMutability: "nonpayable", inputs: [{ name: "approvals", type: "tuple[]", components: tokenSpenderPairComponents }], outputs: [] },
  // ── Taker book (module is part of the key — audit fix S-2) ──
  {
    type: "function",
    name: "approveTaker",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "module", type: "address" },
      { name: "ref", type: "bytes32" },
      { name: "amount", type: "uint160" },
      { name: "expiration", type: "uint48" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "take",
    stateMutability: "nonpayable",
    inputs: [
      { name: "module", type: "address" },
      { name: "user", type: "address" },
      { name: "amount", type: "uint160" },
      { name: "receiver", type: "address" },
      { name: "data", type: "bytes" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "takerAllowance",
    stateMutability: "view",
    inputs: [
      { name: "user", type: "address" },
      { name: "spender", type: "address" },
      { name: "module", type: "address" },
      { name: "ref", type: "bytes32" },
    ],
    outputs: [
      { name: "amount", type: "uint160" },
      { name: "expiration", type: "uint48" },
    ],
  },
  { type: "function", name: "refFor", stateMutability: "pure", inputs: [{ name: "data", type: "bytes" }], outputs: [{ name: "ref", type: "bytes32" }] },
  { type: "function", name: "revokeTaker", stateMutability: "nonpayable", inputs: [{ name: "spender", type: "address" }, { name: "module", type: "address" }, { name: "ref", type: "bytes32" }], outputs: [] },
  { type: "function", name: "lockdownTakers", stateMutability: "nonpayable", inputs: [{ name: "approvals", type: "tuple[]", components: spenderRefPairComponents }], outputs: [] },
  // ── Combined revocation (audit fix U-4) ──
  {
    type: "function",
    name: "lockdownAll",
    stateMutability: "nonpayable",
    inputs: [
      { name: "tokens", type: "tuple[]", components: tokenSpenderPairComponents },
      { name: "takers", type: "tuple[]", components: spenderRefPairComponents },
      { name: "nonceWords", type: "uint256[]" },
      { name: "nonceMasks", type: "uint256[]" },
    ],
    outputs: [],
  },
  // ── Strict mode (audit fix U-6) ──
  { type: "function", name: "setStrictMode", stateMutability: "nonpayable", inputs: [{ name: "enabled", type: "bool" }], outputs: [] },
  { type: "function", name: "strictMode", stateMutability: "view", inputs: [{ name: "user", type: "address" }], outputs: [{ name: "", type: "bool" }] },
  // ── Signed grants ──
  {
    type: "function",
    name: "permitBatch",
    stateMutability: "nonpayable",
    inputs: [{ name: "owner", type: "address" }, { name: "batch", type: "tuple", components: permitBatchComponents }, { name: "sig", type: "bytes" }],
    outputs: [],
  },
  {
    type: "function",
    name: "permitBatchWithWitness",
    stateMutability: "nonpayable",
    inputs: [
      { name: "owner", type: "address" },
      { name: "batch", type: "tuple", components: permitBatchComponents },
      { name: "witness", type: "bytes32" },
      { name: "witnessTypeString", type: "string" },
      { name: "sig", type: "bytes" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "permitBatchWithWitnessIfNeeded",
    stateMutability: "nonpayable",
    inputs: [
      { name: "owner", type: "address" },
      { name: "batch", type: "tuple", components: permitBatchComponents },
      { name: "witness", type: "bytes32" },
      { name: "witnessTypeString", type: "string" },
      { name: "sig", type: "bytes" },
    ],
    outputs: [],
  },
  // ── One-shot signed take (audit fix U-2) ──
  {
    type: "function",
    name: "permitTake",
    stateMutability: "nonpayable",
    inputs: [
      { name: "permit", type: "tuple", components: permitTakeComponents },
      { name: "owner", type: "address" },
      { name: "receiver", type: "address" },
      { name: "data", type: "bytes" },
      { name: "sig", type: "bytes" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "permitTakeWithWitness",
    stateMutability: "nonpayable",
    inputs: [
      { name: "permit", type: "tuple", components: permitTakeComponents },
      { name: "owner", type: "address" },
      { name: "receiver", type: "address" },
      { name: "data", type: "bytes" },
      { name: "witness", type: "bytes32" },
      { name: "witnessTypeString", type: "string" },
      { name: "sig", type: "bytes" },
    ],
    outputs: [],
  },
  // ── Nonces & domain ──
  { type: "function", name: "invalidateUnorderedNonces", stateMutability: "nonpayable", inputs: [{ name: "wordPos", type: "uint256" }, { name: "mask", type: "uint256" }], outputs: [] },
  { type: "function", name: "isPermitNonceUsed", stateMutability: "view", inputs: [{ name: "owner", type: "address" }, { name: "nonce", type: "uint256" }], outputs: [{ name: "", type: "bool" }] },
  { type: "function", name: "DOMAIN_SEPARATOR", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "bytes32" }] },
  {
    type: "function",
    name: "eip712Domain",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "fields", type: "bytes1" },
      { name: "name", type: "string" },
      { name: "version", type: "string" },
      { name: "chainId", type: "uint256" },
      { name: "verifyingContract", type: "address" },
      { name: "salt", type: "bytes32" },
      { name: "extensions", type: "uint256[]" },
    ],
  },
] as const;

/// Optional per-module view a taker module MAY implement so a wallet can render a
/// taker approval in words — "Borrow 1,000 USDC from Aave v3" instead of an opaque
/// `ref`. Off-chain only; Permit3 never calls it. A frontend that holds a TAKE
/// item's `data` reads it directly (with its own graceful fallback for modules that
/// do not implement it). See `readTakerDescription` in `permit3.ts`.
export const TAKER_MODULE_DESCRIBE_ABI = [
  {
    type: "function",
    name: "describe",
    stateMutability: "view",
    inputs: [{ name: "data", type: "bytes" }],
    outputs: [{ name: "", type: "string" }],
  },
] as const;

/// {OcoGroupModule} — the bracket registry. `GroupClaimed` is the one event that
/// retires N−1 orders at once, so a book watching it drops every sibling of a
/// bracket the moment the winner lands, instead of serving them until a solver
/// wastes gas discovering they are dead. See `docs/oco.md`.
export const OCO_GROUP_MODULE_ABI = [
  {
    type: "event",
    name: "GroupClaimed",
    inputs: [
      { name: "maker", type: "address", indexed: true },
      { name: "groupId", type: "uint256", indexed: true },
      { name: "nonce", type: "uint256", indexed: false },
    ],
  },
  {
    type: "function",
    name: "claim",
    stateMutability: "view",
    inputs: [
      { name: "maker", type: "address" },
      { name: "groupId", type: "uint256" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "isRetiredFor",
    stateMutability: "view",
    inputs: [
      { name: "maker", type: "address" },
      { name: "groupId", type: "uint256" },
      { name: "nonce", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
] as const;

/// Read-only preflight/preview surface. These live on {SettlementLens}, a
/// separate view contract, NOT on the settlement — calling them against the
/// settlement address reverts. Point these at the deployed lens address.
export const SETTLEMENT_LENS_ABI = [
  {
    type: "function",
    name: "hashOrder",
    stateMutability: "pure",
    inputs: [orderArg],
    outputs: [{ name: "", type: "bytes32" }],
  },
  {
    type: "function",
    name: "previewAmountOut",
    stateMutability: "view",
    inputs: [orderArg],
    outputs: [{ name: "", type: "uint256[]" }],
  },
  {
    type: "function",
    name: "previewAmountIn",
    stateMutability: "view",
    inputs: [orderArg],
    outputs: [{ name: "", type: "uint256[]" }],
  },
  {
    type: "function",
    name: "remaining",
    stateMutability: "view",
    inputs: [orderArg],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "validateOrder",
    stateMutability: "view",
    inputs: [orderArg],
    outputs: [
      { name: "ok", type: "bool" },
      { name: "reason", type: "string" },
    ],
  },
  {
    type: "function",
    name: "getOrderRelevantState",
    stateMutability: "view",
    // `takerData`: the filler-supplied blob the filler intends to submit with the
    // fill, previewed through the validators exactly as the settlement passes it.
    inputs: [
      orderArg,
      { name: "sig", type: "bytes" },
      { name: "filler", type: "address" },
      { name: "takerData", type: "bytes" },
    ],
    outputs: [
      { name: "status", type: "uint8" },
      { name: "fillableAmount", type: "uint256" },
      { name: "isSignatureValid", type: "bool" },
      { name: "validatorsPass", type: "bool" },
    ],
  },
  // Exact-execution quote for `fillUpTo`: same clamp, same exclusivity, same
  // per-leg pricing — an eth_call at block N equals a fill executed at block N.
  {
    type: "function",
    name: "previewFill",
    stateMutability: "view",
    inputs: [
      orderArg,
      { name: "fillAmount", type: "uint256" },
      { name: "filler", type: "address" },
      { name: "takerData", type: "bytes" },
    ],
    outputs: [
      { name: "delta", type: "uint256" },
      { name: "received", type: "uint256[]" },
      { name: "paid", type: "uint256[]" },
    ],
  },
  // The quote side of `fillUpTo`'s `minBumpBps` floor: the resolved decay bump
  // a fill by `filler` would price at right now. Pass the result as the floor
  // and the fill executes at this quote or better, or reverts BumpTooLow.
  {
    type: "function",
    name: "previewBump",
    stateMutability: "view",
    inputs: [orderArg, { name: "filler", type: "address" }, { name: "takerData", type: "bytes" }],
    outputs: [{ name: "bump", type: "uint256" }],
  },
  {
    type: "function",
    name: "getOrderRelevantStates",
    stateMutability: "view",
    // `takerDatas`: per-order filler blobs, aligned 1:1 with `orders`.
    inputs: [
      { name: "orders", type: "tuple[]", components: orderComponents },
      { name: "sigs", type: "bytes[]" },
      { name: "filler", type: "address" },
      { name: "takerDatas", type: "bytes[]" },
    ],
    outputs: [
      { name: "statuses", type: "uint8[]" },
      { name: "fillableAmounts", type: "uint256[]" },
      { name: "sigValids", type: "bool[]" },
      { name: "validatorsPass", type: "bool[]" },
    ],
  },
] as const;

/// Single-input flash solvers (LimitOrderLeverageSolver, AaveV3/Euler/Morpho).
export const FLASH_SOLVER_ABI = [
  {
    type: "function",
    name: "executeFill",
    stateMutability: "nonpayable",
    inputs: [
      { name: "flashSource", type: "address" },
      { name: "flashAmount", type: "uint256" },
      orderArg,
      { name: "sig", type: "bytes" },
      { name: "fillAmountIn", type: "uint256" },
      { name: "dexFee", type: "uint24" },
      { name: "minSwapOut", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "setupTokenApproval",
    stateMutability: "nonpayable",
    inputs: [{ name: "token", type: "address" }],
    outputs: [],
  },
] as const;

/// Multi-input flash solvers (borrow proceeds + equity → collateral).
export const MULTI_INPUT_SOLVER_ABI = [
  {
    type: "function",
    name: "executeFill",
    stateMutability: "nonpayable",
    inputs: [
      { name: "flashSource", type: "address" },
      { name: "flashAmount", type: "uint256" },
      orderArg,
      { name: "sig", type: "bytes" },
      { name: "fillAmountIn", type: "uint256" },
      { name: "dexFees", type: "uint24[]" },
      { name: "minSwapOuts", type: "uint256[]" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "setupTokenApproval",
    stateMutability: "nonpayable",
    inputs: [{ name: "token", type: "address" }],
    outputs: [],
  },
] as const;

/// MultiOutputFlashSolver — flashes the whole output basket.
export const MULTI_OUTPUT_SOLVER_ABI = [
  {
    type: "function",
    name: "executeFill",
    stateMutability: "nonpayable",
    inputs: [
      orderArg,
      { name: "sig", type: "bytes" },
      { name: "fillAmountIn", type: "uint256" },
      { name: "legs", type: "tuple[]", components: outputLegComponents },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "setupTokenApproval",
    stateMutability: "nonpayable",
    inputs: [{ name: "token", type: "address" }],
    outputs: [],
  },
] as const;
