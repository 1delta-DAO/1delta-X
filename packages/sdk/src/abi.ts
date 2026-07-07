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

export const orderComponents = [
  { name: "maker", type: "address" },
  { name: "side", type: "uint8" },
  { name: "nonce", type: "uint256" },
  { name: "deadline", type: "uint256" },
  { name: "tokenIn", type: "address[]" },
  { name: "startAmountIn", type: "uint256[]" },
  { name: "endAmountIn", type: "uint256[]" },
  { name: "decayStartTime", type: "uint32" },
  { name: "decayDuration", type: "uint32" },
  { name: "tokenOut", type: "address[]" },
  { name: "startAmountOut", type: "uint256[]" },
  { name: "endAmountOut", type: "uint256[]" },
  { name: "exclusiveFiller", type: "address" },
  { name: "exclusivityEndTime", type: "uint32" },
  { name: "minFillAnchor", type: "uint256" },
  { name: "exclusivityOverrideBps", type: "uint256" },
  { name: "curve", type: "tuple[]", components: curvePointComponents },
  { name: "gasBumpBps", type: "uint256" },
  { name: "gasPriceRef", type: "uint256" },
  { name: "items", type: "tuple[]", components: itemComponents },
  { name: "validators", type: "tuple[]", components: validatorComponents },
  { name: "invariants", type: "tuple[]", components: validatorComponents },
] as const;

const tokenPermitComponents = [
  { name: "spender", type: "address" },
  { name: "token", type: "address" },
  { name: "amount", type: "uint160" },
  { name: "expiration", type: "uint48" },
] as const;

const takerPermitComponents = [
  { name: "spender", type: "address" },
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
    name: "filledAmountIn",
    stateMutability: "view",
    inputs: [{ name: "orderHash", type: "bytes32" }],
    outputs: [{ name: "", type: "uint256" }],
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
