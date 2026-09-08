// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, LegOut} from "@core/settlement/Settlement.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {MorphoBluePreFundModule} from "../../src/MorphoBluePreFundModules.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {MorphoModulesBase} from "../shared/MorphoModulesBase.t.sol";

/// @dev The ONE-SIDED pre-fund composites on Morpho Blue: "deposit whatever the
/// conversion delivered" / "repay whatever the conversion delivered", with ZERO
/// receive-side approvals. The converted output leg is delivered straight to the
/// module (`recipient = module`), the core sizes `forAmount` to exactly that
/// delivery, and the maker's only grants are the input-leg approval they had
/// anyway plus a signable taker allowance. The received asset — the collateral on
/// a swap-and-lever entry, the loan token on a swap-and-repay — is never approved
/// to anything, anywhere, and (Morpho's supply/supplyCollateral/repay being
/// permissionless on behalf) needs no `setAuthorization` either.
contract MorphoPreFundOneSidedTest is MorphoModulesBase {
    MorphoBluePreFundModule preFund;

    uint256 constant USDC_IN = 5_000e6;
    uint256 constant WSTETH_OUT = 1 ether;

    function setUp() public override {
        super.setUp();
        preFund = new MorphoBluePreFundModule(address(permit3), address(settlement));
        vm.label(address(preFund), "morphoBluePreFundModule");
    }

    /// @dev `(1 << 255) | index` — fund from `legsOut[index]`.
    function _forLeg(uint256 index, address token) internal pure returns (uint256) {
        // bit 255 = leg reference; bit 253 = the PRE-FUND shape, which makes the core
        // require `legsOut[index].recipient == module` (F27/H-1).
        return (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(token)) << 16) | index;
    }

    /// @dev The shared 224-byte pre-fund blob: descriptor word FIRST, then the Morpho
    ///      singleton, then the market. All three ops share this layout — only the
    ///      op in descriptor bits [244,252) differs, which is exactly why one
    ///      contract can serve them and why a grant for one cannot be replayed as
    ///      another (`ref = keccak256(data)` covers the op).
    function _preFundData(MorphoBluePreFundModule.Op op) internal view returns (bytes memory) {
        address token =
            op == MorphoBluePreFundModule.Op.SupplyCollateral ? marketParams.collateralToken : marketParams.loanToken;
        return abi.encode(_forLeg(0, token) | (uint256(op) << 244), address(MORPHO), marketParams);
    }

    /// @dev Address one output leg to `to` (the pre-fund shape).
    function _routeLegOut(Order memory o, address token, uint256 start, uint256 end, address to) internal pure {
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(token, start, end, to);
        o.legsOut = PackedEncode.legsOut(legsOut);
    }

    // ── SWAP & SUPPLY-COLLATERAL. The maker converts USDC (the one asset they
    //    hold and had approved anyway) into wstETH collateral on their Morpho
    //    position. wstETH — the asset they RECEIVE — has its ERC20 approval to
    //    Permit3 revoked outright (the harness grants one in setUp; we strip it)
    //    and no Permit3 book entry to anything: the receive side is strictly
    //    empty, and `supplyCollateral` needs no Morpho authorization either. ──
    function test_preFundSupplyCollateral_swapAndDeposit_zeroReceiveSideApprovals() public {
        deal(USDC, maker, USDC_IN);
        _approveMakerToSettlement(USDC, USDC_IN); //  the input leg — the ONE approval
        deal(WSTETH, solver, WSTETH_OUT);
        _approveSolverSide(WSTETH_OUT, WSTETH);

        bytes memory data = _preFundData(MorphoBluePreFundModule.Op.SupplyCollateral);
        vm.startPrank(maker);
        IERC20(WSTETH).approve(address(permit3), 0); //  receive side stripped bare
        vm.stopPrank();

        // Prove the receive side is empty BEFORE the fill, not just unused.
        assertEq(IERC20(WSTETH).allowance(maker, address(permit3)), 0, "wstETH has no ERC20 approval to Permit3");
        (uint160 amt,) = permit3.tokenAllowance(maker, address(preFund), WSTETH);
        assertEq(amt, 0, "wstETH has no Permit3 book entry either");

        Item[] memory items = new Item[](1);
        // `amount` is the PACING total (the anchor) — this module moves nothing out.
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data);
        Order memory o = _order(maker, 401, USDC, WSTETH, USDC_IN, WSTETH_OUT, items);
        _routeLegOut(o, WSTETH, WSTETH_OUT, 0, address(preFund));
        bytes memory sig = _sign(o);

        // The preflight accepts the module-addressed leg (and cross-checks the
        // fundingSource asset against it).
        (bool ok, string memory why) = lens.validateOrder(o);
        assertTrue(ok, why);

        uint256 collBefore = _collateral(maker);
        uint256 makerWsteth = IERC20(WSTETH).balanceOf(maker);
        uint256 solverUsdc = IERC20(USDC).balanceOf(solver);

        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN);

        // `supplyCollateral` never accrues — the delivered amount maps 1:1.
        assertEq(_collateral(maker) - collBefore, WSTETH_OUT, "the delivered leg became collateral, exactly");
        assertEq(IERC20(WSTETH).balanceOf(maker), makerWsteth, "the maker's wallet never saw the wstETH");
        assertEq(IERC20(WSTETH).balanceOf(address(preFund)), 0, "module drained");
        assertEq(IERC20(USDC).balanceOf(solver) - solverUsdc, USDC_IN, "solver received the input leg");
    }

    // ── SWAP & SUPPLY (earn). The lend-balance sibling: the converted USDC lands
    //    as a supply position. Same empty receive side — the maker's USDC ERC20
    //    approval to Permit3 is revoked outright before the fill. ──
    function test_preFundSupply_earnDeposit_zeroReceiveSideApprovals() public {
        uint256 wstethIn = 1 ether;
        uint256 usdcOut = 2_000e6;
        deal(WSTETH, maker, wstethIn);
        _approveMakerToSettlement(WSTETH, wstethIn);
        deal(USDC, solver, usdcOut);
        _approveSolverSide(usdcOut, USDC);

        bytes memory data = _preFundData(MorphoBluePreFundModule.Op.Supply);
        vm.startPrank(maker);
        IERC20(USDC).approve(address(permit3), 0); //  receive side stripped bare
        vm.stopPrank();
        assertEq(IERC20(USDC).allowance(maker, address(permit3)), 0, "USDC has no ERC20 approval to Permit3");

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data);
        Order memory o = _order(maker, 402, WSTETH, USDC, wstethIn, usdcOut, items);
        _routeLegOut(o, USDC, usdcOut, 0, address(preFund));
        bytes memory sig = _sign(o);

        uint256 supplyBefore = _supplyAssets(maker);
        uint256 makerUsdc = IERC20(USDC).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, wstethIn);

        // `_supplyAssets` values shares round-down, so allow the share-math wei.
        assertApproxEqAbs(_supplyAssets(maker) - supplyBefore, usdcOut, 2, "the delivered leg became a lend balance");
        assertEq(IERC20(USDC).balanceOf(maker), makerUsdc, "the maker's wallet never saw the USDC");
        assertEq(IERC20(USDC).balanceOf(address(preFund)), 0, "module drained");
    }

    // ── SWAP & REPAY, with overshoot. The maker converts wstETH into retiring
    //    their USDC debt. The loan token is the canonical never-approved asset:
    //    the maker's USDC ERC20 approval to Permit3 is revoked to prove the point
    //    and asserted zero before AND after. The solver delivers MORE than the
    //    debt (1500 vs 1000 owed); the module repays the full borrow by SHARES
    //    (the exact close) and sweeps the surplus to the maker — it is theirs. ──
    function test_preFundRepay_capsAtDebt_andSweepsSurplusToMaker() public {
        uint256 debt = 1_000e6;
        uint256 wstethIn = 1 ether;
        uint256 usdcOut = 1_500e6; //  delivered conversion output — overshoots the debt
        _openPosition(10 ether, debt); //  10 wstETH collateral, 1000 USDC borrowed

        deal(WSTETH, maker, wstethIn);
        _approveMakerToSettlement(WSTETH, wstethIn); //  the input leg — already-held asset

        deal(USDC, solver, usdcOut);
        _approveSolverSide(usdcOut, USDC);

        bytes memory data = _preFundData(MorphoBluePreFundModule.Op.Repay);
        vm.startPrank(maker);
        IERC20(USDC).approve(address(permit3), 0); //  receive side stripped bare
        vm.stopPrank();
        assertEq(IERC20(USDC).allowance(maker, address(permit3)), 0, "the loan token is approved nowhere");

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data); //  pacing amount
        Order memory o = _order(maker, 403, WSTETH, USDC, wstethIn, usdcOut, items);
        _routeLegOut(o, USDC, usdcOut, 0, address(preFund));
        bytes memory sig = _sign(o);

        // The round-up live debt — exactly what the shares repay will pull. No
        // time passes between here and the fill, so no further accrual.
        uint256 debtUp = _borrowAssets(maker);
        uint256 makerUsdc = IERC20(USDC).balanceOf(maker);
        uint256 solverWsteth = IERC20(WSTETH).balanceOf(solver);

        vm.prank(solver);
        settlement.fill(o, sig, wstethIn);

        assertEq(_position(maker).borrowShares, 0, "the debt is retired in full");
        assertEq(IERC20(USDC).balanceOf(maker), makerUsdc + (usdcOut - debtUp), "the surplus was swept to the maker");
        assertEq(IERC20(USDC).balanceOf(address(preFund)), 0, "module drained");
        assertEq(IERC20(WSTETH).balanceOf(solver) - solverWsteth, wstethIn, "solver received the input leg");
        assertEq(IERC20(USDC).allowance(maker, address(permit3)), 0, "the loan-token approval stayed zero throughout");
    }
}
