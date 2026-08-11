// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {ISettlementModule} from "@core/interfaces/ISettlementModule.sol";
import {Proportional} from "@core/settlement/Proportional.sol";

/// @title ProportionalSweepModule
/// @notice The MULTI-TOKEN half of {Proportional}: "…and take all my USDT too".
///
///  Why this is a module and not a leg
///  ──────────────────────────────────
///  The settler resolves a balance-relative marker on `legsIn[0]` only — the
///  anchor — and that restriction is about COST, not soundness. Resolving markers
///  on `legsIn[1..n]` inside {Pricing.inputOwed} was implemented and tested and
///  works; it costs +2,106 bytes, because `Proportional.resolve` carries a
///  `balanceOf` staticcall and inlines at every `inputOwed` site, which puts
///  Settlement over EIP-170. It can be bought back by lowering `optimizer_runs`
///  to 2,000, but that setting lives in `[profile.default]` and would charge
///  **+4,307 gas to every fill of every order, forever** — including the
///  single-token orders that are the overwhelming majority.
///
///  Here the same capability costs the settler NOTHING, and costs gas only on the
///  orders that actually use it: one `SETTLE` item, one CALL.
///
///  Shape of the order
///  ──────────────────
///      legsIn[0]  = { USDC, start: Proportional.encode(10_000), end: usdcCap }
///      legsOut[0] = { WETH, start: minOut, … }
///      items      = [{ SETTLE, this, amount: usdtCap, recipient: 0,
///                      data: abi.encode(USDT, Proportional.encode(10_000)) }]
///
///  `SETTLE` rather than `MAKE` because only `settle` is FILLER-AWARE: the swept
///  tokens must reach whoever fills, and a maker cannot know that address at
///  signing time. See {ISettlementModule}.
///
///  The item's signed `amount` IS the cap, exactly as `end` is the cap on a
///  proportional leg — reusing a field the maker already signs rather than
///  inventing a second place to put it. It is mandatory: {Proportional.resolve}
///  rejects a zero cap, and the settler's own {Base.SettleSliceZero} rejects a
///  zero slice before this contract is ever reached.
///
///  ⚠ WHY A STANDING PERMIT3 ALLOWANCE TO THIS SHARED MODULE IS SAFE
///  ────────────────────────────────────────────────────────────────
///  This is the question that sank `GenericCallModule` (2026-08 audit, CRITICAL-1),
///  so it deserves an explicit answer rather than an assumption.
///
///  That module took an arbitrary `(target, callData)` out of maker-signed item
///  data and executed it FROM ITS OWN IDENTITY. Since anyone may sign an order
///  naming THEMSELVES as maker, an attacker could point it at Permit3 and drain
///  every user who had approved it.
///
///  This module executes exactly one operation, and its payer is not
///  attacker-controlled:
///
///      permit3.transferFrom(maker, filler, token, amount)
///
///  `maker` is supplied by SETTLEMENT as `order.maker`, and the order hash is
///  maker-bound and signature-verified before any item runs — so an attacker
///  cannot name a victim as the payer. An attacker signing their own order can
///  only ever sweep their OWN balance. Nothing in `data` can redirect the source.
///
///  The destination is the `filler`, which is deliberately open — that is the
///  whole point of a SETTLE item — and a filler who receives the sweep must still
///  deliver every `legsOut` leg or the entire fill reverts.
///
///  The guard against regression is the absence of any spec-supplied address on
///  the `from` side of a transfer. Do not add one.
contract ProportionalSweepModule is ISettlementModule {
    /// @notice The Settlement allowed to invoke this module.
    address public immutable SETTLEMENT;
    /// @notice The Permit3 hub this module spends the maker's allowance on.
    IPermit3 public immutable PERMIT3;

    /// @dev Called by anything other than the Settlement this module was
    ///      deployed for. The maker's order signature is the sole authority over
    ///      `(module, amount, data)`; letting an arbitrary caller in would drop
    ///      that binding entirely.
    error OnlySettlement();
    /// @dev `data`'s second word is not a {Proportional} marker. Almost always a
    ///      caller that encoded raw bps (`10000`) instead of
    ///      `Proportional.encode(10000)`. Caught explicitly because raw bps is a
    ///      perfectly ordinary small integer and would otherwise resolve as a
    ///      nonsense absolute amount.
    error NotAProportionalMarker(uint256 value);
    /// @dev The resolved sweep exceeds Permit3's `uint160` book width. Not
    ///      reachable with any real token, but this is a value path.
    error AmountOverflow();

    constructor(address settlement, address permit3) {
        SETTLEMENT = settlement;
        PERMIT3 = IPermit3(permit3);
    }

    /// @inheritdoc ISettlementModule
    /// @param maker  the order maker — the ONLY address this module ever pulls
    ///        from, supplied by Settlement, never by `data`.
    /// @param filler where the swept tokens land.
    /// @param amount this fill's slice of the signed item amount, used as the
    ///        absolute CAP on the sweep (see the contract note).
    /// @param data   `abi.encode(address token, uint256 marker)`, where `marker`
    ///        is {Proportional.encode}(bps).
    function settle(address maker, address filler, uint256 amount, bytes calldata data) external override {
        if (msg.sender != SETTLEMENT) revert OnlySettlement();

        (address token, uint256 marker) = abi.decode(data, (address, uint256));
        if (!Proportional.isProportional(marker)) revert NotAProportionalMarker(marker);

        // Same arithmetic, same mandatory-cap rule, same library the settler uses
        // for `legsIn[0]` — so a sweep leg and a sweep item can never disagree
        // about what "100% of my balance, capped at N" means.
        uint256 pull = Proportional.resolve(token, maker, marker, amount);

        // A maker holding none of this token sweeps nothing. Not an error: it
        // leaves them strictly better off (they part with less for the same signed
        // output), and reverting would make an otherwise-fillable multi-token
        // order unfillable the moment one of its balances hit zero.
        if (pull == 0) return;
        if (pull > type(uint160).max) revert AmountOverflow();

        PERMIT3.transferFrom(maker, filler, token, uint160(pull));
    }
}
