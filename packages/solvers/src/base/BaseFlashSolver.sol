// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedArraysMem} from "@core/settlement/PackedArraysMem.sol";
import {PackedArrays} from "@core/settlement/PackedArrays.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {Settlement, Order, ItemOp} from "@core/settlement/Settlement.sol";

/// @notice Uniswap v3 `exactInputSingle` shape — used to swap the borrow proceeds
///         back to the collateral asset that sources the flash repayment.
interface IUniV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256);
}

/// @notice Uniswap `SwapRouter02` `exactInputSingle` shape — the same call WITHOUT
///         the `deadline` field (SwapRouter02 moved it to `multicall`). Deployed on
///         most L2s and on Rootstock (Oku); the v1 selector reverts there. Which
///         shape a solver speaks is detected once at construction — see
///         {BaseFlashSolver.ROUTER02}.
interface IUniV3Router02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256);
}

/// @notice Optional per-call settings for a flash fill — the trailing argument of
///         every solver's `executeFill` overload (audit 2026-09-30 FLASH-7). The
///         overload without it behaves exactly as `FlashOpts(address(0), "")`.
/// @param recipient where the fill's profit is swept; `address(0)` = `msg.sender`.
///        Name it explicitly when the solver is driven by a contract that must not
///        keep it — in particular from Settlement's EXECUTOR (a `matchSettle` CALL
///        step or a `fillWithCallback` target), which is refused as a recipient:
///        anything parked on that shared trampoline is takeable by the next caller.
/// @param takerData forwarded to `settlement.fill` — the order's validators,
///        invariants, price module and fill module read it (a filler attestation, a
///        cosigned quote, a fill-module proposal). `""` for plain orders.
struct FlashOpts {
    address recipient;
    bytes takerData;
}

/// @title BaseFlashSolver
/// @notice Shared machinery for the leverage-fill solver family. Each concrete
///         solver sources the collateral inventory from a DIFFERENT flash-loan
///         provider — Balancer v2, Aave v3, Euler EVK, Morpho Blue — but the
///         fill→swap→repay core is identical and lives here.
///
///  Every solver exposes the SAME entrypoint:
///
///    executeFill(flashSource, flashAmount, order, sig, fillAmountIn, dexFee, minSwapOut)
///
///  where `flashSource` is the provider-specific handle (the asset to borrow for
///  the singleton providers, or the EVK vault for Euler). The body always:
///
///    1. flash-loan `flashAmount` of the collateral asset (`PackedArraysMem.legOutToken(order.legsOut, 0)`),
///    2. inside the provider callback, run `_fillAndSwap`:
///         a. `settlement.fill` — Settlement pulls the collateral from this solver
///            via Permit3, supplies it on the maker's behalf, borrows
///            `PackedArraysMem.legInToken(order.legsIn, 0)` and routes the proceeds back here,
///         b. swap the borrow proceeds → collateral on Uniswap v3,
///    3. repay the flash per the provider's convention (transfer-back or approve-pull).
///
///  `fillAmountIn` may be `type(uint256).max` — "whatever remains" — which the
///  settler resolves on every entry (needed for a {Proportional} balance-anchored
///  order, whose live anchor a stranger's 1-wei transfer can move before inclusion).
///
///  SUPPORTED ORDER SHAPES (audit 2026-09-30 FLASH-1/FLASH-7/PERIPH-4.v1): MAKE and
///  TAKE items (the leverage shapes); NO `SETTLE` items — a SETTLE module pays
///  `ctx.filler`, i.e. this contract, in any token it likes, and nothing here would
///  forward it, so the receipt would be left for the next caller to claim. Refused
///  up front, before the flash ({SettleItemsUnsupported}). Single-input solvers take
///  one input leg, {MultiOutputFlashSolver} one input leg too; the multi-input
///  family swaps every input leg back. The repayment swap is a single-hop Uniswap v3
///  `exactInputSingle` (v1 `SwapRouter` or `SwapRouter02`, detected at
///  construction); multi-hop routes need a different solver.
///
///  Trust model: these contracts hold no funds between fills and are callable by
///  anyone — the security boundary is the maker's signed order + their Permit3
///  allowances. The `initiatesFlash` guard makes `executeFill` non-reentrant, and the
///  callback gate is OPEN ONLY WHILE THE PROVIDER CALL IS IN FLIGHT: it is closed the
///  moment the provider returns ({_providerReturned}), so the profit sweep — which
///  hands control to token code — cannot host a callback (audit 2026-09-30 FLASH-2).
///
///  What the gate does and does not stop, per provider (audit 2026-09-30 FLASH-2 /
///  CENSUS-A-5). It stops a THIRD PARTY injecting a callback into a flash an honest
///  caller started:
///    • Aave v3     — `initiator == this` (the Pool passes the flash's initiator);
///    • Midnight    — `caller == this` (same, Midnight's own field);
///    • Morpho Blue / Euler EVK — the provider calls back ITS OWN `msg.sender` only,
///      so a foreign flash cannot target this contract; Euler's per-call vault is
///      additionally pinned in storage before the call ({_requireInFlashFromArmed});
///    • Balancer v2 — supplies NO initiator and accepts any recipient, so the
///      callback is bound to the exact payload `executeFill` sent instead
///      ({_commitFlash} / {_consumeFlashCommit}).
///  It does NOT stop a caller's OWN fake provider (an attacker-written "Euler vault"
///  passed as `flashVault`): that callback runs as designed, with this contract as
///  the filler of whatever order the attacker supplies. That is harmless only
///  because these contracts hold nothing between fills — every sweep below empties
///  what a fill produced — so the operating rule "hold no balance here" IS the
///  security property: any residue (a donation, a stranded token) is claimable by
///  anyone through such a provider.
///
///  ⚠ NOT A FILLER IDENTITY (audit 2026-09-30 FLASH-6). Settlement keys every
///  filler-conditional gate — `exclusiveFiller`, a FILLER_SET, a filler-aware
///  validator or price module — on its `msg.sender`, which is THIS contract
///  whoever called it. An order naming a deployed flash solver in any of them has
///  named everyone. A solver that needs an identity runs its own operator-gated
///  contract.
abstract contract BaseFlashSolver {
    IPermit3 public immutable permit3;
    Settlement public immutable settlement;
    IUniV3Router public immutable router;

    /// @notice Whether `router` speaks the `SwapRouter02` shape (no `deadline`).
    ///         Detected at construction: SwapRouter02 exposes `factoryV2()`, the v1
    ///         `SwapRouter` does not. No constructor argument, so every existing
    ///         deployment script keeps compiling.
    bool public immutable ROUTER02;

    /// @notice Settlement's callback trampoline, refused as a profit recipient.
    ///         `address(0)` if the settlement exposes none.
    address public immutable EXECUTOR;

    /// @dev 1 = idle, 2 = inside a flash this solver initiated, provider call in
    ///      flight (callbacks accepted), 3 = still inside `executeFill` but the
    ///      provider has returned (callbacks refused, re-entry still refused).
    uint256 private _flashActive = 1;

    /// @dev Balancer-only payload commitment — see {_commitFlash}.
    bytes32 private _flashCommit;

    /// @dev The provider `executeFill` actually called, recorded when the flash is
    ///      armed. Callbacks whose provider address is not an immutable MUST
    ///      authenticate against THIS, never against a value decoded from the
    ///      callback payload — see {_requireInFlashFrom}.
    address private _armedProvider;

    /// @dev Set by the callback, asserted after the provider call — see
    ///      {_requireCallbackRan}.
    bool private _callbackRan;

    error FlashLoanNotRepaid();
    error NotInFlash();
    /// @dev A callback arrived from an address that is not the provider this
    ///      solver actually called.
    error UnexpectedFlashProvider();
    /// @dev The provider returned without invoking the callback, so the order was
    ///      never validated and no flash actually happened.
    error FlashCallbackMissing();
    /// @dev This solver only routes a single debt leg (`legsIn[0]`); a
    ///      multi-input order would strand legs [1..] as maker shortfalls.
    error MultiInputUnsupported();
    /// @dev The order carries a `SETTLE` item, which pays this contract (the
    ///      filler) in a token nothing here forwards — see the contract note.
    error SettleItemsUnsupported();
    /// @dev A Balancer callback whose payload is not the one `executeFill` sent.
    error UnexpectedFlashPayload();
    /// @dev The profit would be swept to Settlement's EXECUTOR or to this contract,
    ///      where the next caller could take it. Name `FlashOpts.recipient`.
    error BadProfitRecipient();

    constructor(address _permit3, address _settlement, address _router) {
        permit3 = IPermit3(_permit3);
        settlement = Settlement(_settlement);
        router = IUniV3Router(_router);
        ROUTER02 = _hasWord(_router, abi.encodeWithSignature("factoryV2()"));
        (bool ok, bytes memory ret) = _settlement.staticcall(abi.encodeWithSignature("EXECUTOR()"));
        EXECUTOR = ok && ret.length >= 32 ? abi.decode(ret, (address)) : address(0);
    }

    /// @dev Whether `target` answers `data` with at least one word — a tolerant probe
    ///      (an EOA or a contract without the function reads `false`).
    function _hasWord(address target, bytes memory data) private view returns (bool) {
        if (target.code.length == 0) return false;
        (bool ok, bytes memory ret) = target.staticcall(data);
        return ok && ret.length >= 32;
    }

    /// @dev Wrap `executeFill`: non-reentrant + arms the callback guard for the
    ///      duration of the provider's flash callback. The body MUST call
    ///      {_providerReturned} right after the provider call.
    modifier initiatesFlash() {
        if (_flashActive != 1) revert NotInFlash();
        _flashActive = 2;
        _;
        _flashActive = 1;
    }

    /// @dev Close the callback gate the moment the provider returns, while keeping
    ///      the re-entry lock (state 3 is neither "idle" nor "in flash"). Everything
    ///      after this — the profit sweep, which transfers tokens whose code runs —
    ///      can no longer host a provider callback. Before this existed the gate
    ///      stayed armed through the sweep, and Balancer, which names no initiator,
    ///      let a hostile swept token start its own flash naming this solver and run
    ///      a fill as it over the surpluses still waiting to be swept (audit
    ///      2026-09-30 FLASH-2).
    function _providerReturned() internal {
        _flashActive = 3;
    }

    /// @dev Bind the next Balancer callback to the exact payload about to be sent.
    ///      Balancer v2 passes no initiator and accepts any recipient, so
    ///      `msg.sender == vault` plus the in-flight flag cannot tell this solver's
    ///      own flash from one a hostile token starts while ours is in flight (inside
    ///      the repayment swap). The commitment can: it is consumed by the first
    ///      matching callback, so any later or foreign one fails (audit 2026-09-30
    ///      FLASH-2).
    function _commitFlash(bytes32 payloadHash) internal {
        _flashCommit = payloadHash;
    }

    /// @dev See {_commitFlash}. Single-use.
    function _consumeFlashCommit(bytes32 payloadHash) internal {
        if (payloadHash != _flashCommit || payloadHash == bytes32(0)) revert UnexpectedFlashPayload();
        _flashCommit = bytes32(0);
    }

    /// @dev Refuse `SETTLE` items before the flash (audit 2026-09-30 PERIPH-4.v1).
    ///      MAKE / TAKE / TAKE_FOR stay allowed — the leverage shapes need them.
    ///      Refused rather than swept: a custom SETTLE module can pay ANY token, so
    ///      no fixed sweep set could be exhaustive.
    function _requireNoSettleItems(Order calldata order) internal pure {
        bytes calldata items = order.items;
        uint256 n = PackedArrays.validateRecords(items, PackedArrays.ITEM_HEAD);
        uint256 cursor = PackedArrays.recordsStart();
        for (uint256 i; i < n; ++i) {
            uint256 op;
            (op,,,,, cursor) = PackedArrays.itemAt(items, cursor);
            if (op == uint256(ItemOp.SETTLE)) revert SettleItemsUnsupported();
        }
    }

    /// @dev Resolve `FlashOpts.recipient` (`0` = the caller) and refuse the two
    ///      destinations where a swept profit would be claimable by the next caller.
    function _profitRecipient(address requested) internal view returns (address to) {
        to = requested == address(0) ? msg.sender : requested;
        if (to == address(this) || (to == EXECUTOR && EXECUTOR != address(0))) revert BadProfitRecipient();
    }

    /// @dev Sweep the fill's profit: the asset the flash was taken and repaid in —
    ///      the surplus lives THERE — plus `legsOut[0]`'s token when it differs (a
    ///      caller who named a flash asset other than leg 0's token). Previously only
    ///      the unvalidated `legsOut[0]` token was swept, which stranded the whole
    ///      surplus as public residue whenever the two differed (audit 2026-09-30
    ///      FLASH-3).
    function _sweepProfit(address flashAsset, Order calldata order, address to) internal {
        _sweep(flashAsset, to);
        bytes memory legsOut = order.legsOut;
        if (PackedArraysMem.validateLegsOut(legsOut) != 0) {
            address leg0 = PackedArraysMem.legOutToken(legsOut, 0);
            if (leg0 != flashAsset) _sweep(leg0, to);
        }
    }

    /// @dev A provider callback MUST call this first — it only passes while a flash
    ///      initiated by this solver is in flight, so a stray external call to the
    ///      callback (with attacker-crafted data) reverts.
    function _requireInFlash() internal view {
        if (_flashActive != 2) revert NotInFlash();
    }

    /// @dev Record the provider this fill is about to call. Only needed where the
    ///      provider is chosen per call rather than pinned as an immutable.
    function _armProvider(address provider) internal {
        _armedProvider = provider;
    }

    /// @dev Callback authentication for a per-call provider: in-flash AND from the
    ///      exact address `executeFill` called.
    ///
    ///      This exists because deriving the expected provider from the callback's
    ///      own payload is circular and therefore no check at all. When both the
    ///      provider argument and the callback data are attacker-supplied — as they
    ///      are for a per-call flash source — `msg.sender == decoded.provider` is
    ///      trivially satisfied by a contract the attacker wrote, which then drives
    ///      an arbitrary `settlement.fill` with THIS SOLVER as the filler and no
    ///      repayment floor. Comparing against storage written before the external
    ///      call closes that for a flash an HONEST caller started: a third party can
    ///      no longer inject a callback into it, because its provider is the one
    ///      that was armed.
    ///
    ///      ⚠ IT DOES NOT STOP A CALLER'S OWN FAKE PROVIDER (corrected in audit
    ///      2026-09-30 CENSUS-A-5; this note used to claim "no reach into this
    ///      solver's identity"). `executeFill(flashVault = attackerContract, …)` arms
    ///      the attacker's contract, which then calls back with arbitrary data: this
    ///      solver runs `settlement.fill` AS THE FILLER of the attacker's order and
    ///      repays "the vault" in whatever `asset()` it names. Nothing is lost only
    ///      because this contract holds nothing between fills — any residue here is
    ///      claimable by anyone this way. Keep the zero-balance rule.
    function _requireInFlashFromArmed() internal {
        if (_flashActive != 2) revert NotInFlash();
        if (msg.sender != _armedProvider) revert UnexpectedFlashProvider();
        _callbackRan = true;
    }

    /// @dev Assert the provider actually called back, then reset. Required after a
    ///      per-call provider, because a "provider" that simply returns without
    ///      invoking the callback would otherwise fall straight through to the
    ///      profit sweep — and the sweep names a token from an `order` that, on
    ///      that path, was NEVER signature-checked (the order is only validated
    ///      inside the callback). That made the tail sweep a signature-free
    ///      "send me your balance of any token I name" primitive.
    function _requireCallbackRan() internal {
        if (!_callbackRan) revert FlashCallbackMissing();
        _callbackRan = false;
    }

    /// @notice Grant this contract's ERC20 + Permit3 allowances for `token` so
    ///         Settlement can pull the flash-loaned collateral during `fill`.
    ///         Permissionless — only this contract's own (transient) funds are at risk.
    function setupTokenApproval(address token) external {
        SafeTransferLib.forceApprove(token, address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, type(uint160).max, 0);
    }

    /// @dev The leverage core: run the maker fill, then swap the borrow proceeds
    ///      (`PackedArraysMem.legInToken(order.legsIn, 0)`) back to `tokenOut` (the flash-loaned collateral) so the
    ///      caller can repay. Leaves all proceeds in `tokenOut` denomination here.
    function _fillAndSwap(
        Order memory order,
        bytes memory sig,
        uint256 fillAmountIn,
        address tokenOut,
        uint24 dexFee,
        uint256 minSwapOut,
        bytes memory takerData
    ) internal {
        // Single-debt core: the borrow proceeds are the first (and only) input
        // leg. A multi-input order would collect only legsIn[0] here and turn
        // legs [1..] into maker shortfalls, so reject it (see _fillAndSwapAll for
        // the multi-input variant).
        if (PackedArraysMem.validateLegsIn(order.legsIn) != 1) revert MultiInputUnsupported();

        settlement.fill(order, sig, fillAmountIn, takerData);

        address tokenIn = PackedArraysMem.legInToken(order.legsIn, 0);
        // An input already in the collateral asset needs no swap — and the router
        // reverts on a same-token pool (audit 2026-09-30 FLASH-7e).
        if (tokenIn == tokenOut) return;
        _swapExactIn(tokenIn, tokenOut, IERC20(tokenIn).balanceOf(address(this)), dexFee, minSwapOut);
    }

    /// @dev {_fillAndSwap} over a payload laid out as `abi.encode(order, sig,
    ///      fillAmountIn, dexFee, minSwapOut, takerData)` — decoded in its own frame
    ///      so a provider callback with many parameters stays inside the legacy
    ///      profile's stack limit.
    function _fillAndSwapEncoded(bytes memory payload, address tokenOut) internal {
        (
            Order memory order,
            bytes memory sig,
            uint256 fillAmountIn,
            uint24 dexFee,
            uint256 minSwapOut,
            bytes memory takerData
        ) = abi.decode(payload, (Order, bytes, uint256, uint24, uint256, bytes));
        _fillAndSwap(order, sig, fillAmountIn, tokenOut, dexFee, minSwapOut, takerData);
    }

    /// @dev {_fillAndSwapAll} over `abi.encode(order, sig, fillAmountIn, dexFees,
    ///      minSwapOuts, takerData)` — see {_fillAndSwapEncoded}.
    function _fillAndSwapAllEncoded(bytes memory payload, address tokenOut) internal {
        (
            Order memory order,
            bytes memory sig,
            uint256 fillAmountIn,
            uint24[] memory dexFees,
            uint256[] memory minSwapOuts,
            bytes memory takerData
        ) = abi.decode(payload, (Order, bytes, uint256, uint24[], uint256[], bytes));
        _fillAndSwapAll(order, sig, fillAmountIn, tokenOut, dexFees, minSwapOuts, takerData);
    }

    /// @dev Multi-input leverage core: run the maker fill, then swap EVERY
    ///      received input leg back to `tokenOut` (the flash-loaned collateral)
    ///      so the caller can repay. Input legs already denominated in `tokenOut`
    ///      are left as-is. `dexFees`/`minSwapOuts` are aligned with
    ///      `PackedArraysMem.legInToken(order.legsIn, 0)`; entries for a skipped leg are ignored.
    function _fillAndSwapAll(
        Order memory order,
        bytes memory sig,
        uint256 fillAmountIn,
        address tokenOut,
        uint24[] memory dexFees,
        uint256[] memory minSwapOuts,
        bytes memory takerData
    ) internal {
        settlement.fill(order, sig, fillAmountIn, takerData);

        uint256 n = PackedArraysMem.validateLegsIn(order.legsIn);
        for (uint256 i; i < n; i++) {
            address tokenIn = PackedArraysMem.legInToken(order.legsIn, i);
            if (tokenIn == tokenOut) continue; // already the collateral asset
            uint256 bal = IERC20(tokenIn).balanceOf(address(this));
            if (bal == 0) continue;
            _swapExactIn(tokenIn, tokenOut, bal, dexFees[i], minSwapOuts[i]);
        }
    }

    /// @dev Swap `amountIn` of `tokenIn` → `tokenOut` on Uniswap v3 (single hop).
    function _swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint24 dexFee, uint256 minOut) internal {
        SafeTransferLib.forceApprove(tokenIn, address(router), amountIn);
        if (ROUTER02) {
            IUniV3Router02(address(router)).exactInputSingle(
                IUniV3Router02.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: dexFee,
                    recipient: address(this),
                    amountIn: amountIn,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );
            return;
        }
        router.exactInputSingle(
            IUniV3Router.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: dexFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @dev Revert unless this solver holds at least `owed` of `token` post fill+swap.
    function _ensureRepayable(address token, uint256 owed) internal view {
        if (IERC20(token).balanceOf(address(this)) < owed) revert FlashLoanNotRepaid();
    }

    /// @dev Sweep the solver's ENTIRE residual balance of `token` to `to` (no-op
    ///      if zero). Run at the end of every `executeFill` so this contract never
    ///      carries a balance between fills. `executeFill` is permissionless and
    ///      `setupTokenApproval` leaves Settlement a standing max Permit3 allowance,
    ///      so any surplus left parked here could be drained by a later attacker-
    ///      crafted order routed through the same permissionless entrypoint. Sending
    ///      the fill's profit out (to the caller or `FlashOpts.recipient`) closes that
    ///      window — the `initiatesFlash` guard blocks a transfer-hook reentry into
    ///      `executeFill` during the sweep, and {_providerReturned} has already
    ///      closed the provider-callback gate.
    function _sweep(address token, address to) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal != 0) SafeTransferLib.safeTransfer(token, to, bal);
    }
}
