# Interfaces

Shared interfaces used across the settlement system. Modules are **not**
whitelisted or registered — a maker authorizes each module by committing its
address (and its `bytes data`) inside the EIP-712 order hash they sign, and
Permit3 allowances bound what any module can pull. There is no admin, no
`setModule`, and no module registry.

## Module interfaces

An order's `Item[]` dispatches to one of three module shapes, selected by the
item's `op` (`MAKE` / `TAKE` / `SETTLE`). All three touch funds only through
Permit3, keyed by the maker's signed allowances.

### IMakerModule.sol — `MAKE` items
```solidity
function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external;
```
Spends the maker's own assets (deposit / supply collateral / repay debt). Only
touches `onBehalfOf`'s position.

### ITakerModule.sol — `TAKE` items
```solidity
function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external;
```
Draws proceeds on the maker's behalf (borrow / withdraw) and routes `amount` to
`receiver` (`address(0)` → Settlement, which nets it into the fill).

### ISettlementModule.sol — `SETTLE` items
```solidity
function settle(address maker, address filler, uint256 amount, bytes calldata data) external;
```
The **filler-aware** generic exchange (e.g. an NFT sale to an open solver set):
the module receives `filler`, so the maker's asset can be routed to whoever
fills. Used when the typed `legsIn`/`legsOut` fast path can't express the trade.

In every case the `bytes data` blob carries the protocol-specific configuration
(pool address, Morpho `MarketParams`, interest-rate mode, cToken address, …),
committed in the order signature so a solver cannot alter it. Each module defines
its own `data` encoding.

## IFillModule.sol

Optional fill-denominator module (`Order.fillModule`). Decouples "how much does
this fill advance?" from a fungible leg, for any↔any intents (NFTs, auction lots).
```solidity
function resolveFill(Order order, uint256 prevFilled, uint256 fillAmount, bytes takerData)
    external returns (uint256 delta);
```
The core keeps the over-fill cap and the single-fraction per-leg scaling; the
module only picks the accepted `delta` (and may gate the counterparty match via
`takerData`).

## IOrderValidator.sol

Read-only pre-execution trigger (`Order.validators`) or post-execution invariant
(`Order.invariants`).
```solidity
function validate(Order order, address filler, bytes data, bytes takerData)
    external view returns (bool ok);
```
Used for filler gating (whitelist / attestation), min-balance invariants (FoT
protection), and similar policy checks — all maker-signed.

## Ambient interfaces

`IPermit3` (allowance book + witness permits), `IERC1271` / `IERC2612`
(contract-signer + EIP-2612 permit), `IAggregatorV3` (Chainlink-style price feed
for depeg guards), and the protocol-auth shims `ICometAllow` /
`ICreditDelegationToken` / `IMorphoAuth` used by the lending modules to arrange
on-behalf authority.
