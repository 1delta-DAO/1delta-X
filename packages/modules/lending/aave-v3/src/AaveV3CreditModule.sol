// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {ITakerForModule} from "@core/interfaces/ITakerForModule.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";
import {IProceedsAsset} from "@core/interfaces/IProceedsAsset.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {DelegationHelper} from "@lib/DelegationHelper.sol";
import {FundingPreflight} from "@lib/FundingPreflight.sol";
import {Narrow160} from "@lib/Narrow160.sol";

import {IAaveV3Pool} from "./interfaces/IAaveV3.sol";

// ──────────────── Aave v3 CREDIT module — every op that draws debt ────────────────
//
// One contract for every Aave v3 op that incurs debt on the maker's behalf, so the
// maker delegates their credit line to ONE address.
//
//  WHY THE GRANT IS THE MERGE BOUNDARY
//  ───────────────────────────────────
//  Aave's credit delegation is a STANDING, protocol-native authorisation: the maker
//  calls `approveDelegation(module, amount)` on the variable/stable debt token and
//  that module can incur debt for them until they revoke it. It is not scoped by
//  Permit3, not scoped by an order, and — in practice — approved at `max`, because
//  the Permit3 taker allowance is what actually caps a fill.
//
//  So every borrow-shaped module is a separate, permanent liability the maker has to
//  understand, monitor and eventually revoke. Shipping a fused leverage op used to
//  mean asking the entire user base for a SECOND delegation over the same credit
//  line, and every future borrow-shaped op would have meant a third. That is a
//  growth tax on the module surface paid in user-facing approval prompts, and the
//  usual outcome is not that users revoke the old grant — it is that they keep both.
//
//  The total authority is unchanged by merging: it is the same credit line either
//  way. What changes is how many addresses hold it, how many a maker must audit, and
//  how many they must revoke to actually stop. One is the right number.
//
//  ⚠ THE COST, STATED SO IT IS DESIGNED AROUND RATHER THAN DISCOVERED. A merged
//  contract redeploys as a UNIT: a bugfix in the leverage op invalidates the
//  delegation that the bare-borrow op was relying on, and every maker has to
//  re-delegate. That is the reason this module is scoped to ops that consume the
//  CREDIT LINE and nothing else — the aToken-spending ops (withdraw) and the
//  wallet-allowance ops (deposit/repay) keep their own addresses, so churn in one
//  grant class cannot force a re-approval in another. Widening this contract past
//  its grant class would trade four one-time approvals for N re-approval campaigns.
//
//  A maker who does not want a standing delegation at all does not need one: every
//  op here accepts an optional EIP-712 `delegationWithSig` block appended to `data`
//  ({DelegationHelper.replayAaveDelegation}), which grants per-order and leaves
//  nothing behind.
//
//  THE OP DISCRIMINATOR, AND WHY IT IS SAFE
//  ────────────────────────────────────────
//  Permit3's taker book is keyed `(user, spender, module, keccak256(data))` and
//  records nothing about WHICH op a grant authorised. Merging ops onto one contract
//  is therefore safe exactly when the op is INSIDE `data` — then it is inside `ref`,
//  and a grant signed for `Borrow` cannot be replayed as `Leverage`. This is the
//  same argument {AaveV3PreFundModule} makes for its own two ops; it is repeated
//  here because it is the whole basis of the merge, not a detail of it.
//
//  ONE OP TABLE, TWO SEAMS. The op rides in a different slot per seam, because the
//  two seams disagree about what word 0 is for — but it is the same {Op} numbering
//  on both, so a future op needs one entry, not two:
//
//    plain `TAKE`   word 0 IS the op (a small integer, so `>> 253 == 0`, which is
//                   exactly what {PreFundGuard.requirePlainTake} demands — the
//                   discriminator pays for the data-space pin for free).
//    `TAKE_FOR`     word 0 must be the funding descriptor (the core reads it at
//                   `data.offset`), so the op rides its free bits [244,252) via
//                   {PreFundModuleBase._preFundOp}.
//
//  The two spaces stay disjoint — `>> 253` is 0 for plain take and 4..7 for a
//  funding descriptor — which is what keeps one `ref` from authorising both
//  dispatches. Each entrypoint pins its own half, and `tools/check-module-shapes.py`
//  enforces that both pins are present.
//
//  LAYOUTS
//  ───────
//    Op.Borrow   (plain TAKE)
//      abi.encode(op, pool, asset, rateMode [, debtToken, deadline, v, r, s])
//      base = 128; delegation block at 128.
//
//    Op.Leverage (plain TAKE — collateral sized by a maker-signed RATIO)
//      abi.encode(op, pool, borrowAsset, rateMode, collateralAsset,
//                 collateralTotal, borrowTotal [, debtToken, deadline, v, r, s])
//      base = 224; delegation block at 224.
//
//    Op.Leverage (TAKE_FOR — collateral sized by the CORE from the descriptor)
//      abi.encode(forDesc, forCap, pool, borrowAsset, rateMode, collateralAsset
//                 [, debtToken, deadline, v, r, s])
//      base = 192; delegation block at 192.
//
//  All three carry `(pool, borrowAsset, rateMode)` as three consecutive words — at
//  offset 32 on the plain seam, 64 on the funding seam — which is what lets the
//  borrow leg be ONE function instead of the three verbatim copies it was.
//
contract AaveV3CreditModule is
    PreFundModuleBase,
    ITakerModule,
    ITakerForModule,
    IFundingSource,
    IProceedsAsset
{
    /// @notice Every op on this contract, in one table shared by both seams.
    /// @dev `Borrow` is 0 and `Leverage` is 1 on the plain seam AND in the funding
    ///      descriptor's op bits. A single numbering is the point: an op added here
    ///      gets one number, and the views below need one branch rather than a
    ///      per-seam translation table.
    enum Op {
        Borrow,
        Leverage
    }

    /// @dev The blob named an op this module does not implement on this seam.
    error BadOp(uint256 op);

    /// @dev `data` is too short to carry an op word. Rejected rather than defaulted:
    ///      classifying a sub-word blob would read the op out of whatever calldata
    ///      FOLLOWS it, which is the failure {PreFundModuleBase._preFundOp} folds its
    ///      own length test in to avoid.
    error MalformedData();

    /// @dev The RATIO-sized seam was handed a zero borrow total, so the collateral
    ///      figure it derives is undefined.
    error InvalidRatio();

    constructor(address _permit3, address _settlement) PreFundModuleBase(_permit3, _settlement) {}

    // ──────────────────── plain TAKE: the op is word 0 ────────────────────

    /// @param amount   this fill's slice of the BORROW leg — what the taker
    ///                 allowance gates, in every op here.
    /// @param receiver where the borrow proceeds land; Settlement on the netted path,
    ///                 so they fund the rest of the match.
    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data)
        external
        override
    {
        // ⚠ ORDER IS LOAD-BEARING: hub pin first, then the data-space pin.
        //   `msg.sender == permit3` authorises NOTHING on its own; it establishes
        //   only that the taker book was consulted. The spender pin the funding seam
        //   adds after it is absent here because plain `take` carries no `spender`
        //   — the classic seam has always been reached through Permit3's own gate.
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        // Pin the plain half of the data space. Word 0 is the op, a small integer, so
        // `>> 253 == 0` holds by construction — and the funding seam below excludes
        // the LITERAL form, leaving the two spaces provably disjoint. That is what
        // makes one `ref` mean exactly one dispatch.
        PreFundGuard.requirePlainTake(data);

        uint256 op = _plainOp(data);
        if (op == uint256(Op.Borrow)) {
            // No collateral leg at all: a bare borrow pulls nothing from the maker,
            // it only issues debt. Delegation block at 128.
            DelegationHelper.replayAaveDelegation(data, 128, onBehalfOf, address(this), amount);
            _borrowLeg(onBehalfOf, amount, receiver, data);
        } else if (op == uint256(Op.Leverage)) {
            // Its own frame: the ratio decode plus the borrow leg's locals overflow
            // the stack when inlined together.
            _ratioSupplyLeg(onBehalfOf, amount, data);
            DelegationHelper.replayAaveDelegation(data, 224, onBehalfOf, address(this), amount);
            _borrowLeg(onBehalfOf, amount, receiver, data);
        } else {
            revert BadOp(op);
        }
    }

    // ──────────────────── TAKE_FOR: the op rides the descriptor ────────────────────

    /// @param spender   the `Permit3.takeFor` caller, pinned to Settlement.
    /// @param amount    this fill's slice of the BORROW leg (taker-allowance gated).
    /// @param forAmount this fill's COLLATERAL, computed by the core from the signed
    ///                  descriptor — no ratio, no second signed total.
    /// @dev BOTH FUNDING SHAPES, selected by descriptor bit 253: `transferFrom` out of
    ///      the maker's wallet (PULL) versus a balance floor over a delivery already
    ///      addressed here (PRE-FUND). See {PreFundModuleBase._fundingShape}.
    function takeForOnBehalf(
        address spender,
        address onBehalfOf,
        uint256 amount,
        uint256 forAmount,
        address receiver,
        bytes calldata data
    ) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        // Pinned for BOTH shapes. The pull shape does not strictly need it — there the
        // value comes out of `onBehalfOf`'s own wallet, so a self-granting caller only
        // robs themselves — but Settlement is the sole legitimate spender either way,
        // and one unconditional check beats a branch that has to be right (F27/C-1).
        PreFundGuard.requireSettlement(spender, settlement);
        // Pin the funding half of the data space: leg-reference or balance, never
        // LITERAL. Literal is the one form that overlaps the plain-take space
        // (`>> 253` of 0..3 versus 0), and this contract hosts both entrypoints.
        // Costs this seam the literal descriptor — which it never wanted: its whole
        // point is a core-sized funding leg.
        PreFundGuard.requireFundingDescriptor(data);

        uint256 op = _preFundOp(data);
        // `Borrow` is deliberately NOT reachable here. A bare borrow has no funding
        // leg, so there is nothing for the core to size and nothing the descriptor
        // could reference; admitting it would mean accepting a `forAmount` no body
        // spends. Rejected explicitly rather than left to a decode that happens to
        // fail.
        if (op != uint256(Op.Leverage)) revert BadOp(op);

        // Leg 1 in its own frame: the shape branch plus its decode overflows the
        // stack alongside the borrow leg.
        _fundedSupplyLeg(onBehalfOf, forAmount, data);
        DelegationHelper.replayAaveDelegation(data, 192, onBehalfOf, address(this), amount);
        _borrowLeg(onBehalfOf, amount, receiver, data);
    }

    // ──────────────────── the legs ────────────────────

    /// @notice Draw the debt and deliver the proceeds. THE op every module here
    ///         shares, and the reason they share an address.
    /// @dev This was three verbatim copies — `AaveV3BorrowModule.takeOnBehalf` and
    ///      both seams of `AaveV3LeverageModule` — differing only in where they
    ///      decoded `(pool, borrowAsset, rateMode)` from. Three copies of a
    ///      delta-measured payout is three chances for a fix to land on two of them,
    ///      which is the failure mode the 2026-09-08 audit found six times over. One
    ///      copy cannot diverge.
    /// @dev THE OPTIONAL DELEGATION BLOCK IS REPLAYED BY THE CALLER, not here. Its
    ///      offset is the one thing that genuinely differs per layout (128 / 224 /
    ///      192), and carrying it as a parameter kept `data`, the offset and the three
    ///      decoded fields all live across the venue call — which overflows the stack
    ///      on the legacy codegen. Replaying it at the three call sites costs one line
    ///      each and puts the offset next to the layout comment that defines it.
    function _borrowLeg(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) private {
        // `(pool, borrowAsset, rateMode)` are three consecutive words on BOTH seams —
        // after the op word on the plain seam, after the descriptor and its cap on the
        // funding seam. Derived from the same predicate the entrypoints pin, so the
        // decode and the dispatch cannot disagree about which layout this is.
        (address pool, address borrowAsset, uint256 rateMode) =
            abi.decode(data[_isPlainLayout(data) ? 32 : 64:], (address, address, uint256));

        // Measure the borrow's delta (`balBefore` excludes any residue) and deliver
        // that measured amount, capped at `amount` — never a nominal top-up from a
        // stray balance. A short/fake-pool borrow therefore delivers less and fails
        // the fill's output check downstream rather than socialising residue (the H-3
        // River shape). No FoT/rebasing borrow reserves by policy; see
        // module-security-model.
        uint256 balBefore = IERC20(borrowAsset).balanceOf(address(this));
        IAaveV3Pool(pool).borrow(borrowAsset, amount, rateMode, 0, onBehalfOf);
        uint256 received = IERC20(borrowAsset).balanceOf(address(this)) - balBefore;
        SafeTransferLib.safeTransfer(borrowAsset, receiver, received < amount ? received : amount);
        // Excess over the signed amount is the maker's — the solver already paid it.
        if (received > amount) SafeTransferLib.safeTransfer(borrowAsset, onBehalfOf, received - amount);
    }

    /// @notice The RATIO-sized collateral leg: `ceil(amount · collTotal / borrowTotal)`
    ///         pulled from the maker's wallet.
    /// @dev Settlement pro-rates `item.amount` but never tells a module the fill
    ///      fraction, so a fused item cannot carry two independent amounts. It carries
    ///      the maker's intended TOTALS instead and re-derives. At a full fill
    ///      `amount == borrowTotal`, so the collateral is exactly `collateralTotal` —
    ///      no drift on the common case. Across partial fills the rounding is per-fill
    ///      and rounds UP, i.e. always toward MORE collateral, so a partially-filled
    ///      position is never under-collateralised by the arithmetic.
    function _ratioSupplyLeg(address onBehalfOf, uint256 amount, bytes calldata data) private {
        (, address pool,,, address collateralAsset, uint256 collateralTotal, uint256 borrowTotal) =
            abi.decode(data, (uint256, address, address, uint256, address, uint256, uint256));
        if (borrowTotal == 0) revert InvalidRatio();

        uint256 collateral = _ceilDiv(amount * collateralTotal, borrowTotal);
        if (collateral == 0) return;
        // {Narrow160}, not a bare `uint160` cast: `collateral` is DERIVED FROM ORDER
        // DATA, so it is not width-checked by the core the way `amount` and
        // `forAmount` are. A truncating pull beside an un-truncated `forceApprove` to
        // an order-decoded, attacker-choosable `pool` is the F-2 drain.
        permit3.transferFrom(onBehalfOf, address(this), collateralAsset, Narrow160.to160(collateral));
        _supply(collateralAsset, pool, onBehalfOf, collateral);
    }

    /// @notice The CORE-SIZED collateral leg, in either funding shape.
    /// @dev The one place the two shapes differ is which line puts `forAmount` on this
    ///      contract's balance. Everything after it is identical, which is why they
    ///      are one function.
    function _fundedSupplyLeg(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (,, address pool,,, address collateralAsset) =
            abi.decode(data, (uint256, uint256, address, address, uint256, address));
        // A dust slice can floor the funding leg to zero while the borrow leg still
        // rounds up. Skip rather than revert: it accumulates exactly across fills, the
        // same posture {Base._runItem} takes on a zero slice.
        if (forAmount == 0) return;

        uint256 floor;
        bool preFund = _fundingShape(data);
        if (preFund) {
            // PRE-FUND: the delivery must have landed HERE, in THIS token — the core
            // binds the leg's recipient (bit 253) but not its token (F27/H-1).
            // Underflows if it did not.
            //
            // ⚠ THE FLOOR IS KEPT, NOT DISCARDED. The weaker `requireDelivered` proves
            // the same thing and throws the number away; a venue consuming LESS than
            // instructed then left the remainder resident on a SHARED SINGLETON, and
            // residue on a pre-fund singleton is the precondition the unbound-token
            // drain monetised. `AaveV3FusedModules` was the last body in the package
            // still on the old form when it was folded in here.
            floor = PreFundGuard.floorOf(data, collateralAsset, forAmount);
        } else {
            // PULL: the classic shape — the leg was delivered to the maker's wallet
            // and is drawn back through their Permit3 token allowance. `forAmount` is
            // core-sized, so it is already proven `<= type(uint160).max` by
            // {Base._dispatchTake} and the cast is a no-op.
            permit3.transferFrom(onBehalfOf, address(this), collateralAsset, uint160(forAmount));
        }

        _supply(collateralAsset, pool, onBehalfOf, forAmount);

        // PRE-FUND only: the pull shape drew exactly `forAmount` from the maker's
        // wallet, so there is no pre-existing floor to sweep down to. Anything the
        // venue did not take is MEASURED against the pre-delivery floor, never sized
        // from the pre-call clamp (F27/C-3, M-1).
        if (preFund) PreFundGuard.sweepSurplus(collateralAsset, onBehalfOf, floor);
    }

    /// @dev Scoped approve + supply + CLEAR. `pool` is decoded from the order's `data`
    ///      on a SHARED singleton, so it is attacker-choosable — anyone can author an
    ///      order naming themselves as maker. A target that consumes less than
    ///      approved would leave this module holding a permanent third-party claim on
    ///      any FUTURE balance of `asset`, which is what turns a later
    ///      residual-stranding bug into a theft. F25 / lead A-3.
    function _supply(address asset, address pool, address onBehalfOf, uint256 amount) private {
        SafeTransferLib.forceApprove(asset, pool, amount);
        IAaveV3Pool(pool).supply(asset, amount, onBehalfOf, 0);
        SafeTransferLib.forceApprove(asset, pool, 0);
    }

    // ──────────────────── views ────────────────────

    /// @inheritdoc IProceedsAsset
    /// @dev The BORROW asset — what lands on `receiver`, and the same field on every
    ///      op: word 2 on the plain seam, word 3 on the funding seam.
    function proceedsAsset(bytes calldata data) external pure override returns (address asset) {
        if (_isPlainLayout(data)) {
            (,, asset) = abi.decode(data, (uint256, address, address));
        } else {
            (,,, asset) = abi.decode(data, (uint256, uint256, address, address));
        }
    }

    /// @inheritdoc IFundingSource
    /// @dev The COLLATERAL asset, and `available` is SHAPE-dependent: a
    ///      wallet/allowance read would preview a PRE-FUND (self-funding) order as
    ///      short.
    ///
    ///      `Op.Borrow` reports `(address(0), 0)` — "unknown" in the lens's posture,
    ///      which is the truthful answer: a bare borrow pulls nothing from the maker,
    ///      so it has no funding source to preflight. That is also exactly what the
    ///      lens saw before the merge, when `AaveV3BorrowModule` did not implement
    ///      this interface at all, so the preflight is unchanged for that op.
    function fundingSource(address onBehalfOf, bytes calldata data)
        external
        view
        override
        returns (address asset, uint256 available)
    {
        if (_isPlainLayout(data)) {
            if (_plainOp(data) != uint256(Op.Leverage)) return (address(0), 0);
            (,,,, asset) = abi.decode(data, (uint256, address, address, uint256, address));
            available = FundingPreflight.pullable(permit3, address(this), onBehalfOf, asset);
        } else {
            (,,,,, asset) = abi.decode(data, (uint256, uint256, address, address, uint256, address));
            available = _fundingShape(data)
                ? type(uint256).max
                : FundingPreflight.pullable(permit3, address(this), onBehalfOf, asset);
        }
    }

    // ──────────────────── discriminators ────────────────────

    /// @dev WHICH SEAM'S LAYOUT `data` IS IN. The views are reached from
    ///      {SettlementLens} without a seam, and the two byte maps are not aligned —
    ///      field 2 is the borrow asset on one and the pool on the other — so a single
    ///      decode does not revert, it returns the WRONG token, silently.
    ///
    ///      The discriminator is the one the ENTRYPOINTS already enforce, so the views
    ///      and the dispatch cannot disagree: {takeOnBehalf} pins
    ///      `PreFundGuard.requirePlainTake` (`>> 253 == 0`, word 0 being the op, a
    ///      small integer) and {takeForOnBehalf} pins `requireFundingDescriptor`
    ///      (bit 255 set, i.e. `>> 253` in 4..7).
    ///
    ///      ⚠ `calldataload`, NOT a `bytes32(data[0:32])` slice. The slice form is a
    ///      bounds-checked calldata COPY INTO MEMORY, measured at **417 gas** on this
    ///      very path — see {PreFundGuard._word0} and {Base._isPreFundDesc}, which
    ///      read the same word the same way for the same reason. It was a slice while
    ///      this predicate served only the lens views; {_borrowLeg} now calls it on
    ///      every fill, so the copy would have been a per-fill regression on the
    ///      hottest path in the package.
    ///
    ///      Length is folded in, like every other reader of this word: under 32 bytes
    ///      it answers "funding seam", the branch whose decode then reverts, rather
    ///      than classifying from whatever calldata FOLLOWS the blob.
    function _isPlainLayout(bytes calldata data) private pure returns (bool r) {
        /// @solidity memory-safe-assembly
        assembly {
            r := and(gt(data.length, 31), iszero(shr(253, calldataload(data.offset))))
        }
    }

    /// @dev The plain seam's op: word 0, whole. Length-guarded for the reason
    ///      {PreFundModuleBase._preFundOp} states — without it a blob shorter than one
    ///      word is classified from whatever calldata FOLLOWS it. `requirePlainTake`
    ///      does NOT cover this: it deliberately passes a sub-word blob (there is no
    ///      descriptor to reject), so the length test has to live here.
    function _plainOp(bytes calldata data) private pure returns (uint256 op) {
        if (data.length < 32) revert MalformedData();
        /// @solidity memory-safe-assembly
        assembly {
            op := calldataload(data.offset)
        }
    }

    /// @dev ceil(a / b), b > 0 — mirrors {Pricing.ceilDiv}.
    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
