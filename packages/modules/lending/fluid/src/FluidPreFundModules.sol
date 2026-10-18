// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";

import {IFluidVault, IFluidVaultFactory} from "./interfaces/IFluid.sol";

// ──────────────── Fluid PRE-FUNDED one-sided modules ────────────────
//
// "Deposit whatever the conversion delivered" and "repay whatever the conversion
// delivered" into the maker's EXISTING Fluid position, with ZERO receive-side
// approvals: the maker signs the converted output leg with `recipient = module`
// and a pre-funded `MAKE` item whose leg-reference descriptor points at it. The
// core sizes `forAmount` to exactly what the fill delivered here
// ({Base._forSlice} → {Pricing.outputAt}), auction decay included, and this module
// supplies / pays back from its own balance. The maker's only grant is the one they
// had anyway — the ERC20+Permit3 approval on the asset they are CONVERTING FROM —
// and NO taker allowance: Settlement dispatches a `MAKE` directly.
//
// Closes review 2026-10-18 M-1 for Fluid (the venue shipped only PULL makers, so a
// zero-capital `matchSettle` fill needed a Permit3 allowance to the module for a
// token the maker never held) and M-3 (the fused `FluidOperateModule` Close was the
// only zero-wallet repay-all, and a fused item is a cycle by construction).
//
//  Why Fluid fits the pre-fund seam cleanly
//  ────────────────────────────────────────
//  Supply and payback are PERMISSIONLESS on Fluid — `operate` checks
//  `VAULT_FACTORY.ownerOf(nftId) == msg.sender` only on the value-OUT legs — so a
//  value-in leg needs NO NFT custody and no `setApprovalForAll`. The strict-ownerOf /
//  just-in-time custody rule that shapes {FluidTakerModule} does not arise here,
//  and this module never holds, pulls or transfers a position NFT. Funding still
//  goes through the vault's `liquidityCallback`, which runs
//  `transferFrom(operateCaller → Liquidity)` FROM THE VAULT, so the scoped approval
//  goes to the VAULT (never the Liquidity layer) — the same spender as the pull
//  siblings.
//
//  Three ops — the repay-all one is the point
//  ──────────────────────────────────────────
//    • Deposit  `operate(nftId, +forAmount, 0)` — the vault takes the whole delivery.
//    • Repay    `operate(nftId, 0, −forAmount)` — EXACT. Fluid reverts a literal
//               payback above the live debt, so this is for partial deleverage where
//               the delivery is bounded below the debt by construction (a fixed
//               output leg, or a delivery far below the debt).
//    • RepayAll `operate(nftId, 0, type(int256).min)` — the LIVE-DEBT CLAMP. Fluid's
//               repay-all sentinel makes the vault consume exactly the live debt
//               (accrued interest included), and the scoped `forAmount` approval
//               is the ceiling: a debt above the delivery fails closed inside the
//               callback's `transferFrom`, so it can never reach a sibling order's
//               delivery parked on this singleton. The unconsumed remainder is
//               swept to the maker. This is what makes a Fluid FULL close acyclic:
//               `withdraw` TAKE early (the position's LTV headroom carries the debt
//               for one step), convert, deliver the debt token here, `RepayAll`
//               late — no flash, no fused item, no wallet.
//               The sentinel is resolved against the POSITION named in the same
//               call, never against this module's balance (checker rule 6), and the
//               approval bounds what the vault may draw.
//               ⚠ ONE-SHOT. Once the debt is zero, Fluid resolves the sentinel to
//               its 1-wei rounding payback, which the Liquidity layer rejects
//               (`UserModule__OperateAmountInsufficient`, fork-pinned) — so sign a
//               RepayAll order full-fill (a partial fill whose slice does not cover
//               the live debt also fails closed, on the ceiling).
//
//  ⚠ Fluid rejects any literal |amount| below 10,000 wei (`Vault__InvalidOperateAmount`),
//  so a Deposit / Repay slice that small reverts rather than skipping — fail closed,
//  dust-only. RepayAll passes the sentinel and is not affected.
//
//  Bindings, all cheap insurance against the maker's own typos
//  ───────────────────────────────────────────────────────────
//    • `nftId != 0` — Fluid mints a FRESH position to `msg.sender` (this module) on
//      id 0, and this module has no hand-off step: the supplied collateral would be
//      stranded forever (same rule as {FluidBase._requireExistingPosition}).
//    • the position is the MAKER's — payback/supply are permissionless, so a signed
//      stranger's id would spend the maker's delivery on someone else's position
//      (2026-09-30 audit L-CENSUS-8 (3); same read as the pull siblings: the
//      factory named by the vault's own `constantsView`).
//    • the spent token IS the vault's supply token (Deposit) / borrow token
//      (Repay, RepayAll) — otherwise the vault would pull a token this module never
//      approved and the fill reverts deep in the callback; this names the reason.
//      A NATIVE side (`0xEeee…`) can never match an ERC-20 leg, so native funding
//      fails closed here, as everywhere in the package.
//
//  `vault` is maker-signed and NOT bound to the VaultFactory, unlike the custody
//  modules ({FluidCustodyBase._bindVault}). That pin exists because a module that
//  ever OWNS an NFT is the authority over it whoever signed; this module never owns
//  one, and it only ever spends its own maker's delivery (the balance floor) under
//  a scoped, cleared approval — so a lying vault can misdirect only its own signer's
//  funds, the posture of every pre-fund sibling whose venue is maker-named.
//
//  LEG-REFERENCE ONLY, enforced ({_gatePreFundMake}). A LITERAL descriptor would
//  instruct an amount this module has no delivery for, and a BALANCE one reads the
//  MAKER's wallet while this module funds from its own.
//
// `data = abi.encode(forDesc, vault, token, nftId)` — forDesc@0 (op in bits
// [244,252)), vault@32, token@64, nftId@96; 128 bytes, the same map for all ops.
contract FluidPreFundModule is PreFundModuleBase, IMakerModule, IFundingSource {
    enum Op {
        Deposit, // 0 — supply the delivered collateral
        Repay, //   1 — pay back exactly the delivered debt token
        RepayAll // 2 — pay back ALL live debt, the delivery as the ceiling
    }

    /// @dev Fluid's native-token sentinel in `constantsView`.
    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @dev The descriptor named an op this module does not implement.
    error BadOp(uint256 op);
    /// @dev Same selector as {FluidBase.FreshPositionUnsupported}.
    error FreshPositionUnsupported();
    /// @dev Same selector as {FluidBase.NotPositionOwner}.
    error NotPositionOwner(uint256 nftId, address owner);
    /// @dev The signed token is not the vault's side token this op spends.
    error WrongVaultToken(address token, address vaultToken);

    constructor(address _permit3, address _settlement) PreFundModuleBase(_permit3, _settlement) {}

    /// @param onBehalfOf the maker — whose position is supplied into or paid back.
    /// @param forAmount  this fill's delivered output leg, core-sized from the
    ///                   pre-fund descriptor; spent from this module's own balance.
    ///                   It is the item's ONLY amount — `item.amount` is not read on
    ///                   this seam.
    function makeOnBehalf(address onBehalfOf, uint256 forAmount, bytes calldata data) external override {
        _gatePreFundMake(data);
        uint256 op = _preFundOp(data);
        if (op > uint256(Op.RepayAll)) revert BadOp(op);
        // A dust slice can floor the funding leg to zero; skip, as every pre-fund
        // module does — it accumulates exactly across fills.
        if (forAmount == 0) return;

        (, address vault, address token, uint256 nftId) = abi.decode(data, (uint256, address, address, uint256));
        if (nftId == 0) revert FreshPositionUnsupported();
        // The delivery must have landed HERE, in THIS token — the core binds the
        // funding leg's recipient (descriptor bit 253) and consumes it
        // ({Base.ForLegInvalid}); {PreFundGuard.floorOf} binds `token` to the
        // descriptor's token field and underflows on a mis-pairing. Sound because
        // `msg.sender == settlement` pins `forAmount` to the core. KEPT, not
        // discarded: everything above it after the venue call is this fill's own
        // unconsumed remainder and nothing else — on the netted path that is what
        // keeps another order's delivery, parked here between its DELIVER and its
        // ITEM, out of this maker's sweep.
        uint256 floor = PreFundGuard.floorOf(data, token, forAmount);
        _bindPosition(vault, token, nftId, onBehalfOf, op != uint256(Op.Deposit));

        int256 amt = _signed(forAmount);
        // Scoped approve + CLEAR: `vault` is decoded from order data on a shared
        // singleton, so it is attacker-choosable (F25 / lead A-3). The approval is
        // also the RepayAll ceiling — the vault cannot draw past this fill's delivery.
        SafeTransferLib.forceApprove(token, vault, forAmount);
        if (op == uint256(Op.Deposit)) {
            IFluidVault(vault).operate(nftId, amt, 0, address(0));
        } else if (op == uint256(Op.Repay)) {
            IFluidVault(vault).operate(nftId, 0, -amt, address(0));
        } else {
            IFluidVault(vault).operate(nftId, 0, type(int256).min, address(0));
        }
        SafeTransferLib.forceApprove(token, vault, 0);
        // Anything the vault did not take belongs to the maker — MEASURED against the
        // pre-delivery floor, never sized from `operate`'s return value (F27/C-3, M-1).
        PreFundGuard.sweepSurplus(token, onBehalfOf, floor);
    }

    /// @dev The position is the maker's (L-CENSUS-8 (3)), and `token` is the vault
    ///      side this op spends. Both read from the vault itself (`constantsView`).
    function _bindPosition(address vault, address token, uint256 nftId, address user, bool debtSide) private view {
        (, address factory,,, address supplyToken, address borrowToken) = IFluidVault(vault).constantsView();
        address owner = IFluidVaultFactory(factory).ownerOf(nftId);
        if (owner != user) revert NotPositionOwner(nftId, owner);
        address side = debtSide ? borrowToken : supplyToken;
        if (token != side || side == NATIVE) revert WrongVaultToken(token, side);
    }

    /// @dev `uint256 → int256` guarding the high bit. `forAmount` is core-sized and
    ///      far below it on every real leg; the check keeps the negation exact.
    function _signed(uint256 x) private pure returns (int256) {
        require(x <= uint256(type(int256).max), "amount overflow");
        return int256(x);
    }

    /// @inheritdoc IFundingSource
    /// @dev Funded by the fill's OWN delivery — a wallet/allowance read would
    ///      preview a self-funding order as short. Same slot for every op.
    function fundingSource(address, bytes calldata data)
        external
        pure
        override
        returns (address asset, uint256 available)
    {
        (,, asset) = abi.decode(data, (uint256, address, address));
        available = type(uint256).max;
    }
}
