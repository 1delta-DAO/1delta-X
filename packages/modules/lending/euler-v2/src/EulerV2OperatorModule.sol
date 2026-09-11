// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {ITakerForModule} from "@core/interfaces/ITakerForModule.sol";
import {IPositionSource} from "@core/interfaces/IPositionSource.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";
import {IProceedsAsset} from "@core/interfaces/IProceedsAsset.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {DelegationHelper} from "@lib/DelegationHelper.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";
import {Narrow160} from "@lib/Narrow160.sol";
import {FundingPreflight} from "@lib/FundingPreflight.sol";

import {IEulerVault, IEVC} from "./interfaces/IEulerV2.sol";

// ════════════════ Euler V2 OPERATOR module — every op the grant covers ════════════════
//
// One contract for every Euler v2 op that acts as the maker's EVC account, so the
// maker runs `EVC.setAccountOperator(maker, module, true)` ONCE.
//
//  WHY THE GRANT IS THE MERGE BOUNDARY, AND WHY IT BINDS HARDER HERE THAN ON AAVE
//  ──────────────────────────────────────────────────────────────────────────────
//  Euler authenticates value-out through the EVC: `EVC.call(vault, user, …)` is
//  admitted only if `user` has made the caller an ACCOUNT OPERATOR. That grant is
//  a bare boolean. It is not scoped to a vault, not scoped to an asset, not
//  scoped to an amount, and it has no expiry — an operator can do anything the
//  account can do, for as long as the flag is set.
//
//  Aave's `approveDelegation` at least names one debt token and a cap; this names
//  nothing. So splitting Euler's value-out ops across four addresses did not
//  divide the authority four ways — it multiplied it, handing out four
//  independent, permanent, total-control grants over the same account:
//
//      EulerV2TakerModule          borrow / withdraw
//      EulerV2BatchModule          fused deposit+borrow, fused repay+withdraw
//      EulerV2TakeForModule        fused open, collateral PULLED
//      EulerV2PreFundTakeForModule fused open, collateral PUSHED
//
//  All four are folded in here. `EulerV2DepositModule` and `EulerV2RepayModule`
//  are deliberately NOT: value flowing INTO the protocol is authenticated as the
//  module itself, so they need no operator status at all. They are a different
//  grant class (a Permit3 token allowance) and keep their own addresses — the
//  same partition rule {AaveV3CreditModule} states, applied to Euler's grant map
//  rather than copied from Aave's.
//
//  ⚠ THE COST, STATED SO IT IS DESIGNED AROUND. A merged contract redeploys as a
//  unit, so a bugfix in any op here invalidates the operator grant every other op
//  relies on. On Aave that argument is what KEEPS the aToken and wallet-allowance
//  ops at separate addresses. It does not apply between the four ops merged here,
//  because there is no boundary left to preserve: they already required the
//  identical unscoped flag, so splitting them bought no containment and cost
//  three extra grants.
//
//  WHAT THE MERGE DOES NOT WEAKEN
//  ──────────────────────────────
//  Permit3's taker book is keyed `(user, spender, module, ref = keccak256(data))`,
//  and the op is the first word of `data` — so it is inside `ref`. A grant signed
//  for `Borrow` cannot be spent on a `Withdraw`, a `BatchClose`, or an `Open`,
//  exactly as it could not when they were four contracts. The per-leg,
//  amount-gated allowance is untouched; only the coarse operator flag is
//  consolidated, and that flag was never per-op to begin with.
//
//  ONE OP TABLE, TWO SEAMS
//  ───────────────────────
//    plain `TAKE`   word 0 IS the op — a small integer, so `>> 253 == 0`, which is
//                   what {PreFundGuard.requirePlainTake} demands. The
//                   discriminator pays for the data-space pin for free.
//    `TAKE_FOR`     word 0 must be the funding descriptor (the core reads it at
//                   `data.offset`), so the op rides its free bits [244,252) via
//                   {PreFundModuleBase._preFundOp}.
//
//  `Borrow` and `Withdraw` KEEP their pre-merge values 0 and 1, so every blob
//  {EulerV2TakerModule} accepted is still valid here byte-for-byte. The fused ops
//  move: `EulerV2BatchModule`'s `BatchMode.Open`/`Close` (0/1) become 2/3, and the
//  `TAKE_FOR` seam gains an op it never had.
//
//  LAYOUTS
//  ───────
//    Op.Borrow      abi.encode(uint8(0), vault)                       base 64
//    Op.Withdraw    abi.encode(uint8(1), vault[, BalanceMode[, total]])
//                     — BalanceMode@64; total@96 and MANDATORY when the mode is
//                       `Full` (see {FullFillGuard}).
//    Op.BatchOpen   abi.encode(BatchData{op:2, collateralVault, borrowVault,
//    Op.BatchClose                        sideAmount, totalAmount})   — op is word 0
//    Op.Open        abi.encode(OpenData{forDesc, forCap, collateralVault,
//                              borrowVault}) [+ optional EVC-permit tail @128]
//
contract EulerV2OperatorModule is
    PreFundModuleBase,
    ITakerModule,
    ITakerForModule,
    IPositionSource,
    IFundingSource,
    IProceedsAsset
{
    /// @notice Every op this contract's operator grant covers, in one table shared
    ///         by both seams.
    /// @dev `Borrow` and `Withdraw` hold their pre-merge wire values on purpose:
    ///      the merge is then byte-compatible for the two ops that carry the most
    ///      live orders, and only the fused ops re-encode.
    enum Op {
        Borrow, //      0 — plain TAKE  (was EulerV2TakerModule.Op.Borrow)
        Withdraw, //    1 — plain TAKE  (was EulerV2TakerModule.Op.Withdraw)
        BatchOpen, //   2 — plain TAKE  (was EulerV2BatchModule.BatchMode.Open)
        BatchClose, //  3 — plain TAKE  (was EulerV2BatchModule.BatchMode.Close)
        Open //         4 — TAKE_FOR, in BOTH funding shapes
    }

    /// @dev The fused plain-`TAKE` shape. Word 0 is the op, which is what makes a
    ///      `BatchData` blob and a `(op, vault)` blob discriminable by the same read.
    struct BatchData {
        uint256 op;
        address collateralVault;
        address borrowVault;
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
        address collateralVault;
        address borrowVault;
    }

    /// @dev The blob named an op this module does not implement on this seam.
    error BadOp(uint256 op);

    /// @dev `data` is too short to carry an op word. Rejected rather than defaulted:
    ///      classifying a sub-word blob would read the op out of whatever calldata
    ///      FOLLOWS it.
    error MalformedData();

    constructor(address _permit3, address _settlement) PreFundModuleBase(_permit3, _settlement) {}

    // ──────────────────── plain TAKE: the op is word 0 ────────────────────

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
            // EXACT LENGTH — `Borrow` has no optional tail, and its wire value 0 was
            // also the old `EulerV2BatchModule`'s `BatchMode.Open`. Without this, a
            // stale `BatchData` blob decodes here as a clean Borrow from what was its
            // `collateralVault`. The merged contract is a NEW address, so no signed
            // order can reach it; this guards a stale off-chain encoder, for one compare.
            if (data.length != 64) revert MalformedData();
            (, address vault) = abi.decode(data, (uint8, address));
            IEVC(IEulerVault(vault).EVC())
                .call(vault, onBehalfOf, 0, abi.encodeCall(IEulerVault.borrow, (amount, receiver)));
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
        (, address vault) = abi.decode(data, (uint8, address));
        // BalanceMode slot at offset 64 (op@0 + vault@32).
        if (DustHandler.readBalanceMode(data, 64) == DustHandler.BalanceMode.Full) {
            // `Full` liquidates the user's ENTIRE live balance, so it cannot be
            // pro-rated — a sliced fill would unwind the whole position and brick the
            // rest of the order. Require the slice to be the whole item.
            FullFillGuard.requireFullFillFromData(data, 96, amount);
            _withdrawFull(vault, onBehalfOf, amount, receiver);
        } else {
            IEVC(IEulerVault(vault).EVC())
                .call(vault, onBehalfOf, 0, abi.encodeCall(IEulerVault.withdraw, (amount, receiver, onBehalfOf)));
        }
    }

    /// @dev Full mode: ONE venue withdraw, then an ERC-20 SPLIT — the whole position
    ///      lands here and the signed `amount` goes on to `receiver`, the rest back to
    ///      `onBehalfOf`. A second venue withdraw would re-do the burn and accounting;
    ///      a transfer does not.
    ///
    ///      ⚠ THE CAP IS WHAT MAKES THE CUSTODY SAFE, and it is not optional: the
    ///      module holds the asset between the withdraw and the split, so `floor`
    ///      excludes any balance already sitting here and `min(received, amount)`
    ///      makes it structurally impossible for a short or fake-venue delivery to be
    ///      topped up out of it. A nominal `safeTransfer(receiver, amount)` would be
    ///      the H-3 drain.
    function _withdrawFull(address vault, address onBehalfOf, uint256 amount, address receiver) private {
        address evc = IEulerVault(vault).EVC();
        address asset = IEulerVault(vault).asset();
        uint256 floor = IERC20(asset).balanceOf(address(this));
        (, uint256 bal) = _vaultPositionOf(vault, onBehalfOf);
        IEVC(evc).call(vault, onBehalfOf, 0, abi.encodeCall(IEulerVault.withdraw, (bal, address(this), onBehalfOf)));
        uint256 received = IERC20(asset).balanceOf(address(this)) - floor;
        // The lower bound the venue used to enforce. Before the split rewrite the
        // venue call was sized at `amount`, so a short position reverted inside it;
        // now nothing does, and {Core._payInputsToSolver} would bill the shortfall to
        // the MAKER'S WALLET. Safe here and only here: `Full` is full-fill, so
        // `amount` is the signed TOTAL, never a pro-rated slice.
        FullFillGuard.requireDelivered(received, amount);
        SafeTransferLib.safeTransfer(asset, receiver, received < amount ? received : amount);
        if (received > amount) SafeTransferLib.safeTransfer(asset, onBehalfOf, received - amount);
    }

    /// @dev The fused plain-`TAKE` ops, sharing ONE `EVC.batch` so both legs settle
    ///      under a single deferred account/vault status check — the architectural
    ///      payoff of Euler's design, and the reason these are not two items.
    ///
    ///      `open`: deposit `sideAmount` collateral (module-funded via Permit3) then
    ///      borrow `amount` to `receiver`. `close`: repay up to `sideAmount` (capped
    ///      at live debt) then withdraw `amount` collateral to `receiver`.
    function _batch(address onBehalfOf, uint256 amount, address receiver, bytes calldata data, bool open) private {
        BatchData memory p = abi.decode(data, (BatchData));
        // Composite items execute a multi-leg position op whose side leg lives in
        // `data` and does NOT pro-rate. Reject a sliced fill outright.
        FullFillGuard.requireFullFill(amount, p.totalAmount);

        address fundedAsset;
        address fundedVault;
        uint256 funded;
        if (open) {
            fundedVault = p.collateralVault;
            fundedAsset = IEulerVault(fundedVault).asset();
            funded = p.sideAmount;
        } else {
            fundedVault = p.borrowVault;
            fundedAsset = IEulerVault(fundedVault).asset();
            uint256 debt = IEulerVault(p.borrowVault).debtOf(onBehalfOf);
            funded = p.sideAmount < debt ? p.sideAmount : debt;
        }
        if (funded != 0) {
            // {Narrow160}: `sideAmount` is DECODED FROM ORDER DATA, so the core never
            // width-checked it. A truncating `uint160` pull beside an un-truncated
            // `forceApprove` to an order-decoded vault is the F-2 drain.
            permit3.transferFrom(onBehalfOf, address(this), fundedAsset, Narrow160.to160(funded));
            SafeTransferLib.forceApprove(fundedAsset, fundedVault, funded);
        }

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        // Item 0 is authenticated as THIS MODULE — it is the funder, so the value-in
        // leg is drawn from here while crediting the user's position. Item 1 is
        // authenticated as the USER, so the debt (or the collateral withdrawal) and
        // the single liquidity check land on their account.
        items[0] = IEVC.BatchItem({
            targetContract: fundedVault,
            onBehalfOfAccount: address(this),
            value: 0,
            data: open
                ? abi.encodeCall(IEulerVault.deposit, (funded, onBehalfOf))
                : abi.encodeCall(IEulerVault.repay, (funded, onBehalfOf))
        });
        items[1] = IEVC.BatchItem({
            targetContract: open ? p.borrowVault : p.collateralVault,
            onBehalfOfAccount: onBehalfOf,
            value: 0,
            data: open
                ? abi.encodeCall(IEulerVault.borrow, (amount, receiver))
                : abi.encodeCall(IEulerVault.withdraw, (amount, receiver, onBehalfOf))
        });
        IEVC(IEulerVault(p.borrowVault).EVC()).batch(items);

        // Clear the scoped grant. The vault is decoded from the order's `data` on a
        // SHARED singleton, so it is attacker-choosable — anyone can author an order
        // naming themselves as maker. A target consuming less than approved would
        // leave a standing third-party claim on any FUTURE balance of this module.
        // {SafeTransferLib.ensureApproval} forbids this shape. F26/2c.
        if (funded != 0) SafeTransferLib.forceApprove(fundedAsset, fundedVault, 0);
    }

    // ──────────────────── TAKE_FOR: the op rides the descriptor ────────────────────

    /// @param amount    this fill's slice of the BORROW leg (taker-allowance gated).
    /// @param forAmount this fill's COLLATERAL, core-sized from the signed descriptor.
    /// @dev BOTH FUNDING SHAPES, selected by descriptor bit 253. The two used to be
    ///      separate contracts differing by ONE line in the collateral leg —
    ///      `transferFrom` out of the maker's wallet (PULL) versus a balance floor
    ///      over a delivery already addressed here (PRE-FUND) — while each carried its
    ///      own copy of the EVC batch, the scoped approve and its clear.
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
        // LITERAL. Literal is the one descriptor form that overlaps the plain-take
        // space, and this contract now hosts both entrypoints. The cost is that this
        // seam can no longer be signed with an absolute funding amount — which it
        // never wanted: its whole point is a core-sized funding leg.
        PreFundGuard.requireFundingDescriptor(data);

        uint256 op = _preFundOp(data);
        // The plain ops are deliberately NOT reachable here. `Borrow` and `Withdraw`
        // have no funding leg for the core to size, and the fused plain ops pin their
        // side leg in `data` instead. Admitting any of them would mean accepting a
        // `forAmount` no body spends.
        if (op != uint256(Op.Open)) revert BadOp(op);

        _open(onBehalfOf, amount, forAmount, receiver, data);
    }

    /// @dev The fused open, in either funding shape. Its own frame: the shape branch
    ///      plus the batch construction overflows the dispatcher's stack.
    function _open(address onBehalfOf, uint256 amount, uint256 forAmount, address receiver, bytes calldata data)
        private
    {
        OpenData memory p = abi.decode(data, (OpenData));
        address evc = IEulerVault(p.borrowVault).EVC();

        // OPTIONAL EVC-PERMIT TAIL at 128 — the maker's entire Euler auth surface,
        // signature-only: a permit whose self-call grants this module operator rights
        // and enables the controller / collateral, replayed BEFORE the batch that
        // needs them. Best-effort (a front-runner landing the lifted permit leaves
        // exactly the grants the fill wanted — see {DelegationHelper}). No tail ⇒
        // no-op, so the pre-granted path is untouched.
        //
        // ⚠ NOW ON BOTH SHAPES. It was on the pre-fund contract only, for no reason
        // beyond which file it was added to: the grants it installs are the EVC
        // operator/controller/collateral set, which the PULL shape needs just as much.
        // Merging the two bodies is what made the asymmetry visible.
        DelegationHelper.replayEvcPermit(data, 128, evc, onBehalfOf);

        bool preFund = _fundingShape(data);
        uint256 floor;
        address fundedAsset;
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](forAmount == 0 ? 1 : 2);
        uint256 k;
        if (forAmount != 0) {
            fundedAsset = IEulerVault(p.collateralVault).asset();
            if (preFund) {
                // The delivery must have landed HERE, in THIS token — the core binds
                // the funding leg's RECIPIENT (bit 253) but never its TOKEN. Underflows
                // if it did not (F27/C-1, B).
                //
                // ⚠ THE FLOOR IS KEPT, NOT DISCARDED. This body used the weaker
                // `requireDelivered`, which proves the same thing and throws the number
                // away; a vault consuming LESS than instructed then left the remainder
                // resident on a SHARED SINGLETON, and residue on a pre-fund singleton is
                // the precondition the unbound-token drain monetised. Same correction
                // {AaveV3CreditModule} carries.
                floor = PreFundGuard.floorOf(data, fundedAsset, forAmount);
            } else {
                // PULL: the leg was delivered to the maker's wallet and is drawn back
                // through their Permit3 token allowance. `forAmount` is core-sized, so
                // it is already proven `<= type(uint160).max` and the cast is a no-op.
                permit3.transferFrom(onBehalfOf, address(this), fundedAsset, uint160(forAmount));
            }
            SafeTransferLib.forceApprove(fundedAsset, p.collateralVault, forAmount);
            items[k++] = IEVC.BatchItem({
                targetContract: p.collateralVault,
                onBehalfOfAccount: address(this),
                value: 0,
                data: abi.encodeCall(IEulerVault.deposit, (forAmount, onBehalfOf))
            });
        }
        items[k] = IEVC.BatchItem({
            targetContract: p.borrowVault,
            onBehalfOfAccount: onBehalfOf,
            value: 0,
            data: abi.encodeCall(IEulerVault.borrow, (amount, receiver))
        });
        IEVC(evc).batch(items);

        if (fundedAsset != address(0)) {
            // Clear the scoped grant — see {_batch}. F26/2c.
            SafeTransferLib.forceApprove(fundedAsset, p.collateralVault, 0);
            // PRE-FUND only: the pull shape drew exactly `forAmount` from the maker's
            // wallet, so there is no pre-existing floor to sweep down to. Anything the
            // vault did not take is MEASURED against the pre-delivery floor, never
            // sized from the pre-call clamp (F27/C-3, M-1).
            if (preFund) PreFundGuard.sweepSurplus(fundedAsset, onBehalfOf, floor);
        }
    }

    // ──────────────────── views ────────────────────

    /// @inheritdoc IPositionSource
    /// @dev `Withdraw` only — it is the one op whose fill can be SIZED from the live
    ///      position. Every other op here is sized by the taker allowance.
    function positionOf(address user, bytes calldata data)
        public
        view
        override
        returns (address asset, uint256 amount)
    {
        if (!_isPlainLayout(data)) revert BadOp(_preFundOp(data));
        uint256 op = _plainOp(data);
        if (op != uint256(Op.Withdraw)) revert BadOp(op);
        (, address vault) = abi.decode(data, (uint8, address));
        return _vaultPositionOf(vault, user);
    }

    /// @dev The vault read itself, taking the vault address so the internal `Full`
    ///      path can share it — that path has already decoded the blob and cannot hand
    ///      a calldata slice back.
    ///
    ///      `asset` comes from the VAULT, never from `data`: it is the token the
    ///      withdraw actually pays out, so it is the only honest answer to the
    ///      caller's units check.
    function _vaultPositionOf(address vault, address user) private view returns (address asset, uint256 amount) {
        return (IEulerVault(vault).asset(), IEulerVault(vault).convertToAssets(IEulerVault(vault).balanceOf(user)));
    }

    /// @inheritdoc IProceedsAsset
    /// @dev The value-OUT asset per op, DERIVED from the vault rather than decoded —
    ///      Euler names vaults, not assets, so the answer cannot disagree with the
    ///      vault the value actually leaves:
    ///
    ///        Borrow / Withdraw   the named vault's asset
    ///        BatchOpen           the BORROW vault's asset  (the borrow is the payout)
    ///        BatchClose          the COLLATERAL vault's asset (the withdraw is)
    ///        Open                the BORROW vault's asset
    function proceedsAsset(bytes calldata data) external view override returns (address) {
        if (!_isPlainLayout(data)) {
            return IEulerVault(abi.decode(data, (OpenData)).borrowVault).asset();
        }
        uint256 op = _plainOp(data);
        if (op == uint256(Op.Borrow) || op == uint256(Op.Withdraw)) {
            (, address vault) = abi.decode(data, (uint8, address));
            return IEulerVault(vault).asset();
        }
        BatchData memory p = abi.decode(data, (BatchData));
        return IEulerVault(op == uint256(Op.BatchOpen) ? p.borrowVault : p.collateralVault).asset();
    }

    /// @inheritdoc IFundingSource
    /// @dev The value-IN asset — what this module draws from the maker to fund the op:
    ///
    ///        Borrow / Withdraw   NONE. They pull nothing; `(address(0), 0)` is the
    ///                            lens's "unknown", and the truthful answer.
    ///        BatchOpen           the COLLATERAL vault's asset (deposited)
    ///        BatchClose          the BORROW vault's asset (repaid)
    ///        Open                the COLLATERAL vault's asset; `available` is
    ///                            SHAPE-dependent, because a wallet/allowance read
    ///                            would preview a self-funding (pre-fund) order as
    ///                            short.
    function fundingSource(address onBehalfOf, bytes calldata data)
        external
        view
        override
        returns (address asset, uint256 available)
    {
        if (!_isPlainLayout(data)) {
            asset = IEulerVault(abi.decode(data, (OpenData)).collateralVault).asset();
            available = _fundingShape(data)
                ? type(uint256).max
                : FundingPreflight.pullable(permit3, address(this), onBehalfOf, asset);
            return (asset, available);
        }
        uint256 op = _plainOp(data);
        if (op == uint256(Op.Borrow) || op == uint256(Op.Withdraw)) return (address(0), 0);
        BatchData memory p = abi.decode(data, (BatchData));
        asset = IEulerVault(op == uint256(Op.BatchOpen) ? p.collateralVault : p.borrowVault).asset();
        available = FundingPreflight.pullable(permit3, address(this), onBehalfOf, asset);
    }

    // ──────────────────── discriminators ────────────────────

    /// @dev WHICH SEAM'S LAYOUT `data` IS IN. The views are reached from
    ///      {SettlementLens} without a seam, and the two byte maps are not aligned, so
    ///      a single decode does not revert — it returns the WRONG vault, silently.
    ///
    ///      The discriminator is the one the ENTRYPOINTS already enforce, so the views
    ///      and the dispatch cannot disagree: {takeOnBehalf} pins `requirePlainTake`
    ///      (`>> 253 == 0`, word 0 being the op) and {takeForOnBehalf} pins
    ///      `requireFundingDescriptor` (bit 255 set, i.e. `>> 253` in 4..7).
    ///
    ///      ⚠ `calldataload`, NOT a `bytes32(data[0:32])` slice: the slice form is a
    ///      bounds-checked calldata COPY INTO MEMORY, measured at 417 gas — see
    ///      {PreFundGuard._word0} and {Base._isPreFundDesc}, which read the same word
    ///      the same way for the same reason.
    function _isPlainLayout(bytes calldata data) private pure returns (bool r) {
        /// @solidity memory-safe-assembly
        assembly {
            r := and(gt(data.length, 31), iszero(shr(253, calldataload(data.offset))))
        }
    }

    /// @dev The plain seam's op: word 0, whole. Length-guarded for the reason
    ///      {PreFundModuleBase._preFundOp} states — `requirePlainTake` deliberately
    ///      passes a sub-word blob (there is no descriptor to reject), so the length
    ///      test has to live here.
    function _plainOp(bytes calldata data) private pure returns (uint256 op) {
        if (data.length < 32) revert MalformedData();
        /// @solidity memory-safe-assembly
        assembly {
            op := calldataload(data.offset)
        }
    }
}
