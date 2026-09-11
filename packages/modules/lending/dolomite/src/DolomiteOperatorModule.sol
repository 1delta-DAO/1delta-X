// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {ITakerForModule} from "@core/interfaces/ITakerForModule.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";
import {IProceedsAsset} from "@core/interfaces/IProceedsAsset.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";
import {Narrow160} from "@lib/Narrow160.sol";
import {FundingPreflight} from "@lib/FundingPreflight.sol";

import {
    IDolomiteMargin,
    AccountInfo,
    AssetAmount,
    AssetDenomination,
    AssetReference,
    WeiBalance,
    ActionType,
    ActionArgs
} from "./interfaces/IDolomite.sol";

// ════════════════ Dolomite OPERATOR module — every op the grant covers ════════════════
//
// One contract for every Dolomite op, because on Dolomite there is exactly ONE
// grant and every op needs it.
//
//  WHY ALL FIVE MODULES MERGE HERE, WHERE AAVE'S DID NOT
//  ────────────────────────────────────────────────────
//  Every Dolomite state change flows through `operate(accounts, actions)`, and
//  `operate` requires `msg.sender` to be a LOCAL OPERATOR of each referenced
//  account. That grant is a bare boolean: unscoped by market, by token, by
//  amount, by sub-account, and with no expiry. An operator can do anything the
//  account can do until the maker revokes it.
//
//  Crucially — and unlike every other venue in this tree — Dolomite has no
//  permissionless value-IN path either. A DEPOSIT is an `operate` too, so the
//  deposit and repay makers need the same total-control flag as the borrow and
//  withdraw takers. The five contracts this replaces therefore did not partition
//  the maker's authority five ways; they multiplied one unscoped grant into five
//  independent, permanent copies of itself:
//
//      DolomiteDepositModule   DolomiteRepayModule    (MAKE)
//      DolomiteTakerModule     DolomiteOperateModule  (TAKE)
//      DolomiteTakeForModule                          (TAKE_FOR)
//
//  {AaveV3CreditModule} keeps three addresses because Aave has three genuinely
//  different grants — a scoped credit delegation, an aToken approval, and a
//  wallet allowance — so a redeploy of one class cannot force re-approval of
//  another. That reasoning is what produces ONE address here rather than three:
//  the containment it buys does not exist on Dolomite, because there is no second
//  grant to contain. Splitting bought nothing and cost four extra approvals.
//
//  WHAT THE MERGE DOES NOT WEAKEN
//  ──────────────────────────────
//  Permit3's taker book is keyed `(user, spender, module, ref = keccak256(data))`
//  and the op is the first word of `data`, so it is inside `ref`. A grant signed
//  for `Borrow` cannot be spent on a `Withdraw` or a `BatchClose`, exactly as it
//  could not when they were separate contracts. Only the coarse operator flag is
//  consolidated, and that flag was never per-op.
//
//  ONE OP TABLE, THREE SEAMS — and each blob is accepted by exactly ONE of them.
//  `MAKE` and plain `TAKE` share the `>> 253 == 0` data space, which is safe here
//  and worth stating because it is the one thing that looks like a collision:
//  a `MAKE` item consumes no taker grant at all (Settlement dispatches it
//  directly, against `order.maker`, under that maker's own signature), so there is
//  no allowance for a cross-seam blob to redirect. The op table then closes it
//  outright — each seam rejects every op that is not its own, so a `Deposit` blob
//  handed to `takeOnBehalf` reverts rather than doing anything at all.
//
//    MAKE           word 0 IS the op. `makeOnBehalf` pins `msg.sender == settlement`.
//    plain TAKE     word 0 IS the op — small, so `>> 253 == 0`, which is exactly
//                   what {PreFundGuard.requirePlainTake} demands.
//    TAKE_FOR       word 0 must be the funding descriptor (the core reads it at
//                   `data.offset`), so the op rides bits [244,252) via
//                   {PreFundModuleBase._preFundOp}.
//
//  `Borrow` and `Withdraw` KEEP their pre-merge values 0 and 1, so every blob
//  {DolomiteTakerModule} accepted is still valid byte-for-byte. `Deposit` and
//  `Repay` gain an op word their blobs never had — which also ALIGNS them: all
//  four single-op layouts are now the same five fields, so one decode serves them.
//
//  LAYOUTS
//  ───────
//    Op.Borrow / Withdraw / Deposit / Repay
//      abi.encode(uint8(op), dolomite, marketId, token, accountNumber, …)  base 160
//        — Withdraw: BalanceMode@160; total@192 and MANDATORY when the mode is
//          `Full` (see {FullFillGuard}).
//        — Repay:    DustAction@160.
//    Op.BatchOpen / BatchClose
//      abi.encode(BatchData{op, …})                                — op is word 0
//    Op.Open  (TAKE_FOR)
//      abi.encode(OpenData{forDesc, forCap, …})                    — op in forDesc
//
contract DolomiteOperatorModule is
    PreFundModuleBase,
    IMakerModule,
    ITakerModule,
    ITakerForModule,
    IFundingSource,
    IProceedsAsset
{
    /// @notice Every op the maker's Dolomite operator grant covers.
    /// @dev `Borrow` and `Withdraw` hold their pre-merge wire values on purpose: the
    ///      merge is then byte-compatible for the two ops carrying the most live
    ///      orders, and only the blobs that had to change do.
    enum Op {
        Borrow, //     0 — TAKE      (was DolomiteTakerModule.Op.Borrow)
        Withdraw, //   1 — TAKE      (was DolomiteTakerModule.Op.Withdraw)
        Deposit, //    2 — MAKE      (was DolomiteDepositModule, op-less)
        Repay, //      3 — MAKE      (was DolomiteRepayModule, op-less)
        BatchOpen, //  4 — TAKE      (was DolomiteOperateModule.BatchMode.Open)
        BatchClose, // 5 — TAKE      (was DolomiteOperateModule.BatchMode.Close)
        Open //        6 — TAKE_FOR  (was DolomiteTakeForModule)
    }

    /// @dev The fused plain-`TAKE` shape. Word 0 is the op, which is what makes a
    ///      `BatchData` blob and a single-op blob discriminable by the same read.
    struct BatchData {
        uint256 op;
        address dolomite;
        uint256 collMarketId;
        address collToken;
        uint256 borrowMarketId;
        address borrowToken;
        uint256 accountNumber;
        uint256 sideAmount;
        /// @dev The item's FULL maker-signed amount. Composite ops are full-fill
        ///      only — see {FullFillGuard}.
        uint256 totalAmount;
    }

    /// @dev The `TAKE_FOR` shape. `forDesc` first and `forCap` second: the two words
    ///      {Base._forSlice} reads.
    struct OpenData {
        uint256 forDesc;
        uint256 forCap;
        address dolomite;
        uint256 collMarketId;
        address collToken;
        uint256 borrowMarketId;
        uint256 accountNumber;
    }

    /// @dev The blob named an op this module does not implement ON THIS SEAM. The
    ///      seam check is the point: it is what keeps the shared `>> 253 == 0` data
    ///      space between `MAKE` and plain `TAKE` from meaning anything.
    error BadOp(uint256 op);

    /// @dev `data` is too short to carry an op word. Rejected rather than defaulted:
    ///      classifying a sub-word blob would read the op out of whatever calldata
    ///      FOLLOWS it.
    error MalformedData();

    // ──────────────────── why there is NO reentrancy guard here ────────────────────
    //
    // The `DolomiteRepayModule` this absorbed carried a 1/2-SSTORE `_locked` on its
    // `makeOnBehalf`. The first cut of the merge dropped it by accident; the second
    // restored it on all three entrypoints; the differential review then asked
    // whether it was load-bearing at all. It is not, and the argument is executable.
    //
    // Every entrypoint is reached through a LOCKED dispatcher — Settlement for MAKE,
    // Permit3.take / takeFor for the taker seams — except one window Permit3 leaves
    // open on purpose ({AllowanceTransfer.transferFrom} is "DELIBERATELY NOT
    // nonReentrant"): a MAKE repay's pull hands control to a maker-chosen token, and a
    // hook can call `Permit3.take` from inside it. That call can only land
    // `takeOnBehalf(X, …)` for an X that granted the HOOK CONTRACT a taker bucket —
    // the attacker, never the victim (core
    // `test_reentrancy_transferFrom_cannotReachTheSpendersBucket`). So the only
    // question is whether an interleaved call on ITS OWN account, on THIS shared
    // balance, can disturb what the victim's fill measures.
    //
    // It cannot, because no path here ever pays out a balance it merely READ: repay
    // disposes `bal - floor`, `Full` withdraw pays `min(received - snapshot, amount)`,
    // pre-fund open sweeps `bal - floor`, batch reads no balance at all. A caller
    // that adds to or drains the shared balance mid-flight changes none of those
    // deltas. `test/audit/ReentrancyWindow.t.sol` runs precisely that interleaving —
    // a hook token re-entering `Permit3.take` → `takeOnBehalf(attacker, Withdraw
    // Full)` while a victim's `Recycle` repay is between its pull and its disposal —
    // and asserts the victim's outcome is byte-identical to an un-attacked fill.
    //
    // The invariant that makes this hold — "no raw self-balance is ever paid out" —
    // is now rule 8 of `tools/check-module-shapes.py`, so the property the guard was
    // standing in for is enforced at every module rather than paid for at every
    // call. If a future path here needs a raw balance, it needs the guard back AND a
    // reason the checker should let it through.

    constructor(address _permit3, address _settlement) PreFundModuleBase(_permit3, _settlement) {}

    // ──────────────────── MAKE ────────────────────

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data)
        external
        override
    {
        // MAKE is dispatched Settlement → module DIRECTLY, so the pin is `msg.sender`,
        // asserted by the EVM rather than carried in a parameter. There is no
        // permissionless hub in front of this entrypoint.
        PreFundGuard.requireSettlement(msg.sender, settlement);
        uint256 op = _plainOp(data);
        if (op == uint256(Op.Deposit)) {
            _deposit(onBehalfOf, amount, data);
        } else if (op == uint256(Op.Repay)) {
            _repay(onBehalfOf, amount, data);
        } else {
            revert BadOp(op);
        }
    }

    /// @dev Pull `token` and supply it into the maker's account as a one-action
    ///      `operate`. This module is the Deposit action's funding source
    ///      (`otherAddress`), which is why even the value-IN path needs operator
    ///      status on Dolomite.
    function _deposit(address onBehalfOf, uint256 amount, bytes calldata data) private {
        (, address dolomite, uint256 marketId, address token, uint256 accountNumber) = _single(data);
        permit3.transferFrom(onBehalfOf, address(this), token, uint160(amount));
        _approveAndOperate(dolomite, onBehalfOf, accountNumber, token, _depositAction(marketId, amount, address(this)), amount);
    }

    /// @dev Repay, clamped to the live debt. `SweepToUser` (the default) never pulls
    ///      the over-repay buffer at all, so no dust is created; `Recycle` takes
    ///      custody of the signed ceiling and re-supplies the surplus. Either way
    ///      disposal is locked to `onBehalfOf` / the venue, never a caller-chosen
    ///      address.
    function _repay(address onBehalfOf, uint256 amount, bytes calldata data) private {
        (,,, address token,) = _single(data);
        // The balance this module held BEFORE the pull. Everything below disposes of
        // the delta over it, never the whole balance — another fill's dust may
        // legitimately be sitting here.
        uint256 floor = IERC20(token).balanceOf(address(this));
        // Two frames, each re-decoding `data`. Carrying the five decoded fields plus
        // `action` and `floor` across both calls overflows the stack on the legacy
        // codegen; re-decoding is a few hundred gas against a body that does two
        // external calls.
        _pullAndRepay(onBehalfOf, amount, data);
        _disposeResidual(onBehalfOf, data, floor);
    }

    /// @dev Pull the funding token and repay, clamped to the live debt.
    ///      `SweepToUser` (the default) pulls only what the debt needs, so the
    ///      over-repay buffer never leaves the maker's wallet and no dust is created.
    ///      `Recycle` takes custody of the signed ceiling so the surplus can be
    ///      re-supplied by {_disposeResidual}. Either way disposal is locked to
    ///      `onBehalfOf` / the venue, never a caller-chosen address.
    function _pullAndRepay(address onBehalfOf, uint256 amount, bytes calldata data) private {
        (, address dolomite, uint256 marketId, address token, uint256 accountNumber) = _single(data);
        uint256 toRepay;
        {
            uint256 debt = _debtOf(dolomite, onBehalfOf, accountNumber, marketId);
            toRepay = amount < debt ? amount : debt;
            // `toPull` is `amount` or `min(amount, debt)` — both bounded by the CORE
            // slice, which {Base._runItem} already proved `<= type(uint160).max`, so
            // this cast cannot wrap.
            uint256 toPull =
                DustHandler.readAction(data, 160) == DustHandler.DustAction.Recycle ? amount : toRepay;
            if (toPull > 0) permit3.transferFrom(onBehalfOf, address(this), token, uint160(toPull));
        }
        if (toRepay > 0) {
            _approveAndOperate(
                dolomite, onBehalfOf, accountNumber, token, _depositAction(marketId, toRepay, address(this)), toRepay
            );
        }
    }

    /// @dev Dispose of any residual THIS call produced — measured as the delta over
    ///      `floor`, never the module's whole balance.
    function _disposeResidual(address onBehalfOf, bytes calldata data, uint256 floor) private {
        // ⚠ EVERY LOCAL IS SCOPED, AND THAT IS NOT STYLE. `DustHandler.disposeResidual`
        //   takes seven arguments, so anything still live at the call site sits under
        //   them on the stack; carried flat, this frame overflows the legacy codegen.
        //   `_single` is re-run inside the scope that needs the market fields rather
        //   than destructured once at the top.
        address token;
        address dolomite;
        {
            (, dolomite,, token,) = _single(data);
        }
        uint256 residual;
        {
            uint256 bal = IERC20(token).balanceOf(address(this));
            // The delta THIS call produced, never the module's whole balance — see the
            // floor overload of {DustHandler.disposeResidual} for why "the module ends
            // empty" is the wrong invariant.
            if (bal <= floor) return;
            unchecked {
                residual = bal - floor; // bal > floor
            }
        }
        bytes memory recycleCall;
        {
            (,, uint256 marketId,, uint256 accountNumber) = _single(data);
            AccountInfo[] memory accounts = new AccountInfo[](1);
            accounts[0] = AccountInfo(onBehalfOf, accountNumber);
            ActionArgs[] memory actions = new ActionArgs[](1);
            actions[0] = _depositAction(marketId, residual, address(this));
            recycleCall = abi.encodeCall(IDolomiteMargin.operate, (accounts, actions));
        }
        DustHandler.disposeResidual(
            token, residual, floor, onBehalfOf, DustHandler.readAction(data, 160), dolomite, recycleCall
        );
    }

    // ──────────────────── plain TAKE ────────────────────

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data)
        external
        override
    {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        // Pin the plain half of the data space. Word 0 is the op, a small integer, so
        // `>> 253 == 0` holds by construction — and the funding seam below excludes
        // the LITERAL form, leaving the two provably disjoint. That is what keeps one
        // `ref` from authorising both dispatches now that one contract hosts both.
        PreFundGuard.requirePlainTake(data);

        uint256 op = _plainOp(data);
        if (op == uint256(Op.Borrow)) {
            // EXACT LENGTH, because `Borrow` has no optional tail and `abi.decode`
            // tolerates trailing bytes. `Borrow` kept its pre-merge value 0 for wire
            // compatibility — and 0 was ALSO the old `DolomiteOperateModule`'s
            // `BatchMode.Open`. A stale 9-word `BatchData` blob would otherwise decode
            // here as a clean 5-field Borrow (`collMarketId` as the market,
            // `borrowMarketId` as the sub-account) rather than revert. The merged
            // contract is a NEW address, so no already-signed order can reach it; this
            // is a guard against a stale off-chain encoder, and it costs one compare.
            if (data.length != 160) revert MalformedData();
            // Borrow IS an exact withdraw on Dolomite: one negative delta to `receiver`.
            (, address dolomite, uint256 marketId,, uint256 accountNumber) = _single(data);
            _operate(dolomite, onBehalfOf, accountNumber, _withdrawAction(marketId, amount, receiver));
        } else if (op == uint256(Op.Withdraw)) {
            _withdraw(onBehalfOf, amount, receiver, data);
        } else if (op == uint256(Op.BatchOpen) || op == uint256(Op.BatchClose)) {
            _batch(onBehalfOf, amount, receiver, data, op == uint256(Op.BatchOpen));
        } else {
            revert BadOp(op);
        }
    }

    /// @dev Exact or `Full`. Its own frame: the `Full` branch's locals do not fit
    ///      alongside the dispatcher's.
    function _withdraw(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) private {
        (, address dolomite, uint256 marketId, address token, uint256 accountNumber) = _single(data);
        if (DustHandler.readBalanceMode(data, 160) != DustHandler.BalanceMode.Full) {
            _operate(dolomite, onBehalfOf, accountNumber, _withdrawAction(marketId, amount, receiver));
            return;
        }
        // `Full` liquidates the user's ENTIRE live balance, so it cannot be pro-rated
        // — a sliced fill would unwind the whole position and brick the rest of the
        // order. Require the slice to be the whole item.
        FullFillGuard.requireFullFillFromData(data, 192, amount);
        WeiBalance memory w = IDolomiteMargin(dolomite).getAccountWei(AccountInfo(onBehalfOf, accountNumber), marketId);
        uint256 bal = w.sign ? w.value : 0;

        // MEASURE what the withdraw actually delivered and never forward more than
        // that: the module takes custody between the withdraw and the split, so a
        // short or fake-venue delivery must not be topped up out of a stray balance
        // (the H-3 drain). `snapshot` excludes any balance already sitting here.
        uint256 snapshot = IERC20(token).balanceOf(address(this));
        _operate(dolomite, onBehalfOf, accountNumber, _withdrawAction(marketId, bal, address(this)));
        uint256 received = IERC20(token).balanceOf(address(this)) - snapshot;
        // I-8: the lower bound the venue used to enforce for free. The OLD form called
        // the venue FOR the signed amount, so a short position reverted inside it; the
        // split form calls it for the whole position, so nothing does — and
        // {Core._payInputsToSolver} would then bill the shortfall to the MAKER'S WALLET.
        // Safe here and only here: `Full` is full-fill, so `amount` is the signed TOTAL.
        //
        // ⚠ Every other `Full` leg in the tree carried this since the 2026-09-10
        //   restoration; this one never did — the sibling the patch missed, found by
        //   the differential review of the merge and closed here.
        FullFillGuard.requireDelivered(received, amount);
        SafeTransferLib.safeTransfer(token, receiver, received < amount ? received : amount);
        if (received > amount) SafeTransferLib.safeTransfer(token, onBehalfOf, received - amount);
    }

    /// @dev The fused plain-`TAKE` ops: a value-in and a value-out leg in ONE
    ///      `operate`, so both settle under Dolomite's single end-of-call
    ///      collateralisation check — the architectural payoff, and the reason these
    ///      are not two items.
    function _batch(address onBehalfOf, uint256 amount, address receiver, bytes calldata data, bool open) private {
        BatchData memory p = abi.decode(data, (BatchData));
        // Composite items execute a multi-leg position op whose side leg lives in
        // `data` and does NOT pro-rate. Reject a sliced fill outright.
        FullFillGuard.requireFullFill(amount, p.totalAmount);

        ActionArgs[] memory actions = new ActionArgs[](2);
        address fundedToken; // hoisted so the grant can be cleared after `operate`
        if (open) {
            // {Narrow160}: `sideAmount` is DECODED FROM ORDER DATA, so the core never
            // width-checked it. A truncating `uint160` pull beside an un-truncated
            // `forceApprove` to an order-decoded venue is the F-2 drain.
            permit3.transferFrom(onBehalfOf, address(this), p.collToken, Narrow160.to160(p.sideAmount));
            SafeTransferLib.forceApprove(p.collToken, p.dolomite, p.sideAmount);
            fundedToken = p.collToken;
            actions[0] = _depositAction(p.collMarketId, p.sideAmount, address(this));
            actions[1] = _withdrawAction(p.borrowMarketId, amount, receiver);
        } else {
            uint256 debt = _debtOf(p.dolomite, onBehalfOf, p.accountNumber, p.borrowMarketId);
            uint256 toRepay = p.sideAmount < debt ? p.sideAmount : debt;
            if (toRepay > 0) {
                permit3.transferFrom(onBehalfOf, address(this), p.borrowToken, Narrow160.to160(toRepay));
                SafeTransferLib.forceApprove(p.borrowToken, p.dolomite, toRepay);
                fundedToken = p.borrowToken;
            }
            actions[0] = _depositAction(p.borrowMarketId, toRepay, address(this));
            actions[1] = _withdrawAction(p.collMarketId, amount, receiver);
        }

        AccountInfo[] memory accounts = new AccountInfo[](1);
        accounts[0] = AccountInfo(onBehalfOf, p.accountNumber);
        IDolomiteMargin(p.dolomite).operate(accounts, actions);
        if (fundedToken != address(0)) SafeTransferLib.forceApprove(fundedToken, p.dolomite, 0);
    }

    // ──────────────────── TAKE_FOR ────────────────────

    /// @param forAmount this fill's COLLATERAL, core-sized from the signed descriptor.
    /// @dev BOTH funding shapes, selected by descriptor bit 253.
    function takeForOnBehalf(
        address spender,
        address onBehalfOf,
        uint256 amount,
        uint256 forAmount,
        address receiver,
        bytes calldata data
    ) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        // Pinned for BOTH shapes: Settlement is the sole legitimate spender either
        // way, and one unconditional check beats a branch that has to be right
        // (F27/C-1 — `Permit3.takeFor` is a permissionless entrypoint).
        PreFundGuard.requireSettlement(spender, settlement);
        // Pin the funding half of the data space: leg-reference or balance, never
        // LITERAL. Literal is the one descriptor form that overlaps the plain space,
        // and this contract now hosts all three seams.
        PreFundGuard.requireFundingDescriptor(data);

        uint256 op = _preFundOp(data);
        // The other ops are deliberately unreachable here: none has a funding leg for
        // the core to size, so admitting one would mean accepting a `forAmount` no
        // body spends.
        if (op != uint256(Op.Open)) revert BadOp(op);

        _open(onBehalfOf, amount, forAmount, receiver, data);
    }

    /// @dev The fused open in either funding shape — the two-action `operate` under
    ///      one collateralisation check, with the collateral sized by the core.
    function _open(address onBehalfOf, uint256 amount, uint256 forAmount, address receiver, bytes calldata data)
        private
    {
        OpenData memory p = abi.decode(data, (OpenData));

        bool preFund = _fundingShape(data);
        uint256 floor;
        ActionArgs[] memory actions = new ActionArgs[](forAmount == 0 ? 1 : 2);
        uint256 k;
        address fundedToken;
        if (forAmount != 0) {
            if (preFund) {
                // The delivery must have landed HERE, in THIS token — the core binds
                // the funding leg's RECIPIENT (bit 253) but never its TOKEN. Underflows
                // if it did not (F27/H-1).
                //
                // ⚠ THE FLOOR IS KEPT, NOT DISCARDED. This body used the weaker
                // `requireDelivered`, which proves the same thing and throws the number
                // away; a venue consuming LESS than instructed then left the remainder
                // resident on a SHARED SINGLETON, and residue on a pre-fund singleton is
                // the precondition the unbound-token drain monetised.
                floor = PreFundGuard.floorOf(data, p.collToken, forAmount);
            } else {
                // PULL: drawn back out of the maker's wallet through their Permit3 token
                // allowance. `forAmount` is core-sized, so the cast is a no-op.
                permit3.transferFrom(onBehalfOf, address(this), p.collToken, uint160(forAmount));
            }
            SafeTransferLib.forceApprove(p.collToken, p.dolomite, forAmount);
            fundedToken = p.collToken;
            actions[k++] = _depositAction(p.collMarketId, forAmount, address(this));
        }
        actions[k] = _withdrawAction(p.borrowMarketId, amount, receiver);

        AccountInfo[] memory accounts = new AccountInfo[](1);
        accounts[0] = AccountInfo(onBehalfOf, p.accountNumber);
        IDolomiteMargin(p.dolomite).operate(accounts, actions);
        if (fundedToken != address(0)) {
            SafeTransferLib.forceApprove(fundedToken, p.dolomite, 0);
            // PRE-FUND only: the pull shape drew exactly `forAmount` from the maker's
            // wallet, so there is no pre-existing floor to sweep down to (F27/C-3, M-1).
            if (preFund) PreFundGuard.sweepSurplus(fundedToken, onBehalfOf, floor);
        }
    }

    // ──────────────────── views ────────────────────

    /// @inheritdoc IProceedsAsset
    /// @dev The value-OUT token, where the maker actually SIGNED it:
    ///
    ///        Borrow / Withdraw   `token` — signed beside its market id
    ///        BatchOpen           `borrowToken`
    ///        BatchClose          `collToken`
    ///        Deposit / Repay     none — they deliver nothing
    ///        Open                `address(0)` — HONESTLY UNKNOWN. {OpenData} names
    ///                            the borrow side by `borrowMarketId` alone, and the
    ///                            token behind it lives in a live registry this pure
    ///                            view cannot read and the maker does not sign.
    ///                            Reporting a guess would be worse than nothing: the
    ///                            lens would compare a wrong address against the leg
    ///                            and reject fillable orders. Closing it properly means
    ///                            signing the borrow TOKEN beside its market id, the
    ///                            way `collToken` already sits beside `collMarketId`.
    function proceedsAsset(bytes calldata data) external pure override returns (address) {
        if (!_isPlainLayout(data)) return address(0);
        uint256 op = _plainOp(data);
        if (op == uint256(Op.Borrow) || op == uint256(Op.Withdraw)) {
            (,,, address token,) = _single(data);
            return token;
        }
        if (op == uint256(Op.BatchOpen) || op == uint256(Op.BatchClose)) {
            BatchData memory p = abi.decode(data, (BatchData));
            return op == uint256(Op.BatchOpen) ? p.borrowToken : p.collToken;
        }
        return address(0);
    }

    /// @inheritdoc IFundingSource
    /// @dev The value-IN token — what this module draws from the maker to fund the op.
    ///      `Borrow` and `Withdraw` pull nothing, so `(address(0), 0)`, which is the
    ///      lens's "unknown" and the truthful answer. `Open`'s `available` is
    ///      SHAPE-dependent: a wallet read would preview a self-funding (pre-fund)
    ///      order as short.
    function fundingSource(address onBehalfOf, bytes calldata data)
        external
        view
        override
        returns (address asset, uint256 available)
    {
        if (!_isPlainLayout(data)) {
            asset = abi.decode(data, (OpenData)).collToken;
            available = _fundingShape(data)
                ? type(uint256).max
                : FundingPreflight.pullable(permit3, address(this), onBehalfOf, asset);
            return (asset, available);
        }
        uint256 op = _plainOp(data);
        if (op == uint256(Op.Deposit) || op == uint256(Op.Repay)) {
            (,,, asset,) = _single(data);
        } else if (op == uint256(Op.BatchOpen) || op == uint256(Op.BatchClose)) {
            BatchData memory p = abi.decode(data, (BatchData));
            asset = op == uint256(Op.BatchOpen) ? p.collToken : p.borrowToken;
        } else {
            return (address(0), 0);
        }
        available = FundingPreflight.pullable(permit3, address(this), onBehalfOf, asset);
    }

    // ──────────────────── Dolomite `operate` helpers ────────────────────

    /// @dev A positive (supply) delta in `marketId`, funded from `from`.
    function _depositAction(uint256 marketId, uint256 amount, address from) private pure returns (ActionArgs memory) {
        return ActionArgs({
            actionType: ActionType.Deposit,
            accountId: 0,
            amount: AssetAmount(true, AssetDenomination.Wei, AssetReference.Delta, amount),
            primaryMarketId: marketId,
            secondaryMarketId: 0,
            otherAddress: from,
            otherAccountId: 0,
            data: ""
        });
    }

    /// @dev A negative (withdraw/borrow) delta in `marketId`, sent to `to`.
    function _withdrawAction(uint256 marketId, uint256 amount, address to) private pure returns (ActionArgs memory) {
        return ActionArgs({
            actionType: ActionType.Withdraw,
            accountId: 0,
            amount: AssetAmount(false, AssetDenomination.Wei, AssetReference.Delta, amount),
            primaryMarketId: marketId,
            secondaryMarketId: 0,
            otherAddress: to,
            otherAccountId: 0,
            data: ""
        });
    }

    function _operate(address dolomite, address user, uint256 accountNumber, ActionArgs memory action) private {
        AccountInfo[] memory accounts = new AccountInfo[](1);
        accounts[0] = AccountInfo(user, accountNumber);
        ActionArgs[] memory actions = new ActionArgs[](1);
        actions[0] = action;
        IDolomiteMargin(dolomite).operate(accounts, actions);
    }

    /// @dev Scoped approve + `operate` + CLEAR. `dolomite` is decoded from the order's
    ///      `data` on a SHARED singleton, so it is attacker-choosable — anyone can
    ///      author an order naming themselves as maker. A target consuming less than
    ///      approved would leave a standing third-party claim on any FUTURE balance of
    ///      this module. {SafeTransferLib.ensureApproval} forbids this shape. F26/2c.
    function _approveAndOperate(
        address dolomite,
        address user,
        uint256 accountNumber,
        address token,
        ActionArgs memory action,
        uint256 allowance
    ) private {
        SafeTransferLib.forceApprove(token, dolomite, allowance);
        _operate(dolomite, user, accountNumber, action);
        SafeTransferLib.forceApprove(token, dolomite, 0);
    }

    /// @dev The account's debt in `marketId` (0 if the balance is non-negative).
    function _debtOf(address dolomite, address user, uint256 accountNumber, uint256 marketId)
        private
        view
        returns (uint256)
    {
        WeiBalance memory w = IDolomiteMargin(dolomite).getAccountWei(AccountInfo(user, accountNumber), marketId);
        return w.sign ? 0 : w.value;
    }

    // ──────────────────── discriminators ────────────────────

    /// @dev The five fields every single-op blob carries. Adding the op word to the
    ///      two MAKE layouts is what ALIGNED them with the two TAKE layouts, so all
    ///      four share this one decode instead of two near-identical ones.
    function _single(bytes calldata data)
        private
        pure
        returns (uint8 op, address dolomite, uint256 marketId, address token, uint256 accountNumber)
    {
        return abi.decode(data, (uint8, address, uint256, address, uint256));
    }

    /// @dev WHICH SEAM'S LAYOUT `data` IS IN — the views are reached from
    ///      {SettlementLens} without a seam, and the byte maps are not aligned, so a
    ///      single decode does not revert, it returns the WRONG field silently.
    ///
    ///      ⚠ `calldataload`, NOT a `bytes32(data[0:32])` slice: the slice form is a
    ///      bounds-checked calldata COPY INTO MEMORY, measured at 417 gas — see
    ///      {PreFundGuard._word0} and {Base._isPreFundDesc}.
    function _isPlainLayout(bytes calldata data) private pure returns (bool r) {
        /// @solidity memory-safe-assembly
        assembly {
            r := and(gt(data.length, 31), iszero(shr(253, calldataload(data.offset))))
        }
    }

    /// @dev The op for the `MAKE` / plain-`TAKE` seams: word 0, whole. Length-guarded
    ///      for the reason {PreFundModuleBase._preFundOp} states — `requirePlainTake`
    ///      deliberately passes a sub-word blob, so the test has to live here.
    function _plainOp(bytes calldata data) private pure returns (uint256 op) {
        if (data.length < 32) revert MalformedData();
        /// @solidity memory-safe-assembly
        assembly {
            op := calldataload(data.offset)
        }
    }
}
