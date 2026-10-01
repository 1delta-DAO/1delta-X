// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {DustHandler} from "@lib/DustHandler.sol";

import {MorphoModulesBase} from "../shared/MorphoModulesBase.t.sol";
import {MarketParams, Id} from "../../src/interfaces/IMorphoBlue.sol";

/// Morpho's permissionless market creation (not in the module's interface).
interface IMorphoCreateMarket {
    function createMarket(MarketParams memory marketParams) external;
}

/// ATTACKER-CONTROLLED: worthless collateral token for the attacker's own market.
contract AuditJunkToken20260930 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// ATTACKER-CONTROLLED: oracle that prices the worthless collateral sky-high.
contract AuditRiggedOracle20260930 {
    function price() external pure returns (uint256) {
        return 1e40;
    }
}

/// @notice 2026-09-30 audit regressions for {MorphoBlueRepayModule}.
///
///  L-LIB-1 — the Recycle branch repaid the maker's WHOLE debt by shares under a
///  standing max approval, so the real Morpho Blue drew everything above the
///  signed `amount` out of loan token already resting on the module singleton.
///  These tests start from the audit PoC and assert the SAFE end state: the
///  module's resident balance is untouched and Morpho draws at most `amount`.
///
///  L-CENSUS-8 (4) — the default (callback) path could not repay partially: a
///  ceiling short of the live debt reverted `BufferTooSmall`. It now repays
///  exactly `amount` by assets, like the pre-fund sibling.
///
///  Real mainnet Morpho Blue / USDC / wstETH on the package fork; only the
///  attacker's own market collateral + oracle are mocks.
contract MorphoBlueRepayAudit20260930Test is MorphoModulesBase {
    address victim = makeAddr("victim");

    uint256 constant RESIDUE = 10_000e6; // victim's USDC resting on the module
    uint256 constant EPS = 1; //             the ONLY USDC the attacker signs for

    function _victimMisSends() internal {
        deal(USDC, victim, RESIDUE);
        vm.prank(victim);
        IERC20(USDC).transfer(address(repayModule), RESIDUE);
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), RESIDUE, "pre: residue on module");
    }

    function _repayOrder(MarketParams memory mp, uint256 nonce, uint256 amount, bool recycle)
        internal
        view
        returns (Order memory)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item(
            ItemOp.MAKE,
            address(repayModule),
            amount,
            address(0),
            recycle ? abi.encode(mp, uint8(DustHandler.DustAction.Recycle)) : abi.encode(mp)
        );
        return _order(maker, nonce, WSTETH, USDC, 1, 1, items);
    }

    function _makerApprovals(uint256 repayCap) internal {
        vm.startPrank(maker);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), USDC, uint160(repayCap), 0);
        // 1-wei legs for the self-fill (maker leg + filler leg).
        permit3.approveToken(address(settlement), USDC, 1, 0);
        permit3.approveToken(address(settlement), WSTETH, 1, 0);
        vm.stopPrank();
    }

    /// @dev Attacker opens a real borrow of `d` USDC in the wstETH/USDC market and keeps it.
    function _attackerBorrows(uint256 d) internal {
        uint256 collateral = 5 ether;
        deal(WSTETH, maker, collateral + 1); // +1 wei for the tokenIn leg
        vm.startPrank(maker);
        IERC20(WSTETH).approve(address(MORPHO), collateral);
        MORPHO.supplyCollateral(marketParams, collateral, maker, "");
        MORPHO.borrow(marketParams, d, 0, maker, maker);
        vm.stopPrank();
    }

    // ──────────────────── L-LIB-1 ────────────────────

    /// PoC variant A: debt D >> signed EPS, Recycle mode, residue on the module.
    /// Before the fix Morpho pulled the whole D from the module (victim lost ~D).
    function test_audit_L_LIB_1_recycleRepayCannotDrawModuleResidue() public {
        _victimMisSends();
        uint256 d = 8_000e6;
        _attackerBorrows(d);
        uint256 debtBefore = _borrowAssets(maker);
        uint256 sharesBefore = _position(maker).borrowShares;
        _makerApprovals(EPS);

        Order memory order = _repayOrder(marketParams, 777, EPS, true);
        bytes memory sig = _sign(order);
        vm.prank(maker); // self-fill
        settlement.fill(order, sig, 1);

        // SAFE: the resident balance is untouched, to the wei.
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), RESIDUE, "module residue untouched");
        // Only a partial repay of the signed EPS happened; the debt is still there.
        assertGt(_position(maker).borrowShares, 0, "debt NOT retired by residue");
        assertLe(_position(maker).borrowShares, sharesBefore, "shares never grow");
        assertGe(_borrowAssets(maker) + EPS, debtBefore, "at most EPS of debt repaid");
        // No approval to Morpho survives the call.
        assertEq(IERC20(USDC).allowance(address(repayModule), address(MORPHO)), 0, "approval cleared");
    }

    /// PoC variant B (the finding's exact scenario): attacker's own permissionless
    /// market, D = whole residue. Before the fix the attacker netted ~RESIDUE.
    function test_audit_L_LIB_1_ownMarketCannotDrainResidue() public {
        _victimMisSends();

        AuditJunkToken20260930 junk = new AuditJunkToken20260930();
        AuditRiggedOracle20260930 oracle = new AuditRiggedOracle20260930();
        MarketParams memory mp = MarketParams({
            loanToken: USDC,
            collateralToken: address(junk),
            oracle: address(oracle),
            irm: marketParams.irm,
            lltv: marketParams.lltv
        });
        IMorphoCreateMarket(address(MORPHO)).createMarket(mp);

        uint256 d = RESIDUE;
        deal(USDC, maker, d);
        deal(WSTETH, maker, 1);
        junk.mint(maker, 1e18);
        vm.startPrank(maker);
        IERC20(USDC).approve(address(MORPHO), d);
        MORPHO.supply(mp, d, 0, maker, "");
        junk.approve(address(MORPHO), 1e18);
        MORPHO.supplyCollateral(mp, 1e18, maker, "");
        MORPHO.borrow(mp, d, 0, maker, maker);
        vm.stopPrank();

        _makerApprovals(EPS);
        Order memory order = _repayOrder(mp, 778, EPS, true);
        bytes memory sig = _sign(order);
        vm.prank(maker);
        settlement.fill(order, sig, 1);

        Id id = Id.wrap(keccak256(abi.encode(mp)));
        assertGt(MORPHO.position(id, maker).borrowShares, 0, "attacker debt still owed");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), RESIDUE, "victim residue intact");
    }

    /// Recycle with a ceiling short of the debt pulls EXACTLY the ceiling from the
    /// maker and repays exactly that — the residue never funds the shortfall.
    function test_audit_L_LIB_1_recyclePartialRepaysExactlyAmount() public {
        _victimMisSends();
        uint256 d = 8_000e6;
        uint256 amount = 3_000e6;
        _attackerBorrows(d);
        uint256 debtBefore = _borrowAssets(maker);
        _makerApprovals(amount);
        uint256 walletBefore = IERC20(USDC).balanceOf(maker);

        Order memory order = _repayOrder(marketParams, 779, amount, true);
        bytes memory sig = _sign(order);
        vm.prank(maker);
        settlement.fill(order, sig, 1);

        // 1 wei of the wallet delta is the self-fill's tokenOut leg round-trip (net 0).
        assertEq(walletBefore - IERC20(USDC).balanceOf(maker), amount, "maker paid exactly the ceiling");
        assertApproxEqAbs(debtBefore - _borrowAssets(maker), amount, 1, "debt down by the ceiling");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), RESIDUE, "module residue untouched");
    }

    /// Recycle full close still works (amount >= debt) with residue present: the
    /// surplus is recycled and the module ends exactly at its floor.
    function test_audit_L_LIB_1_recycleFullCloseKeepsFloor() public {
        _victimMisSends();
        uint256 d = 3_000e6;
        uint256 amount = d + 50e6;
        _attackerBorrows(d);
        deal(USDC, maker, amount); // the buffer on top of the borrowed USDC
        _makerApprovals(amount);

        Order memory order = _repayOrder(marketParams, 780, amount, true);
        bytes memory sig = _sign(order);
        vm.prank(maker);
        settlement.fill(order, sig, 1);

        assertEq(_position(maker).borrowShares, 0, "full close by shares");
        assertGt(_position(maker).supplyShares, 0, "surplus recycled as supply");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), RESIDUE, "module ends at its floor");
        assertEq(IERC20(USDC).allowance(address(repayModule), address(MORPHO)), 0, "approval cleared");
    }

    // ──────────────────── L-CENSUS-8 (4) ────────────────────

    /// Default (callback) path with a ceiling short of the live debt: used to revert
    /// `BufferTooSmall`; now repays exactly `amount` and leaves the rest owed.
    function test_audit_L_CENSUS_8_sweepModePartialRepay() public {
        _victimMisSends();
        uint256 d = 8_000e6;
        uint256 amount = 3_000e6;
        _attackerBorrows(d);
        uint256 debtBefore = _borrowAssets(maker);
        _makerApprovals(amount);
        uint256 walletBefore = IERC20(USDC).balanceOf(maker);

        Order memory order = _repayOrder(marketParams, 781, amount, false);
        bytes memory sig = _sign(order);
        vm.prank(maker);
        settlement.fill(order, sig, 1);

        assertEq(walletBefore - IERC20(USDC).balanceOf(maker), amount, "pulled exactly the ceiling");
        assertApproxEqAbs(debtBefore - _borrowAssets(maker), amount, 1, "partial repay of the ceiling");
        assertGt(_position(maker).borrowShares, 0, "remainder still owed");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), RESIDUE, "module residue untouched");
        assertEq(IERC20(USDC).allowance(address(repayModule), address(MORPHO)), 0, "no standing approval");
    }
}
