// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, LegOut} from "@core/settlement/Settlement.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {VenusPreFundModule} from "../../src/VenusPreFundModules.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {VenusModulesBase} from "../shared/VenusModulesBase.t.sol";

/// @dev The ONE-SIDED pre-fund composites over Venus: "deposit whatever the
/// conversion delivered" / "repay whatever the conversion delivered", with ZERO
/// receive-side approvals. The converted output leg is delivered straight to the
/// module (`recipient = module`), the core sizes `forAmount` to exactly that
/// delivery, and the maker's only grants are the input-leg approval they had
/// anyway plus a signable taker allowance. Both venue ops are permissionless
/// value-in (`mintBehalf` / `repayBorrowBehalf`), so unlike the borrow/withdraw
/// legs no `comptroller.updateDelegate` is needed either — the receive side is
/// empty end to end.
contract VenusPreFundOneSidedTest is VenusModulesBase {
    VenusPreFundModule preFund;

    uint256 constant USDC_IN = 1_500e6;
    uint256 constant WETH_OUT = 1 ether;

    function setUp() public override {
        super.setUp();
        preFund = new VenusPreFundModule(address(permit3), address(settlement));
        }

    /// @dev `(1 << 255) | index` — fund from `legsOut[index]`.
    function _forLeg(uint256 index, address token) internal pure returns (uint256) {
        // bit 255 = leg reference; bit 253 = the PRE-FUND shape, which makes the core
        // require `legsOut[index].recipient == module` (F27/H-1).
        return (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(token)) << 16) | index;
    }

    /// @dev The repay op, in descriptor bits [244,252) — see {PreFundModuleBase._preFundOp}.
    function _forLegRepay(uint256 index, address token) internal pure returns (uint256) {
        return _forLeg(index, token) | (uint256(VenusPreFundModule.Op.Repay) << 244);
    }

    /// @dev Address one output leg to `to` (the pre-fund shape).
    function _routeLegOut(Order memory o, address token, uint256 start, uint256 end, address to) internal pure {
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(token, start, end, to);
        o.legsOut = PackedEncode.legsOut(legsOut);
    }

    // ── SWAP & DEPOSIT. The maker converts USDC (the one asset they hold and had
    //    approved anyway) into a vWETH deposit. WETH — the asset they RECEIVE —
    //    has its ERC20 approval to Permit3 revoked outright and no Permit3 token
    //    allowance to anything: the receive side is strictly empty. `mintBehalf`
    //    credits the maker directly — no receipt forwarding needed. ──
    function test_preFundDeposit_swapAndDeposit_zeroReceiveSideApprovals() public {
        deal(USDC, maker, USDC_IN);
        _approveMakerToSettlement(USDC, USDC_IN); //  the input leg — the ONE approval
        deal(WETH, solver, WETH_OUT);
        _approveSolverSide(WETH_OUT, WETH);

        bytes memory data = abi.encode(_forLeg(0, WETH), address(VWETH), WETH);
        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), 0); //  receive side stripped bare
        vm.stopPrank();

        // Prove the receive side is empty BEFORE the fill, not just unused.
        assertEq(IERC20(WETH).allowance(maker, address(permit3)), 0, "WETH has no ERC20 approval to Permit3");

        Item[] memory items = new Item[](1);
        // `amount` is the PACING total (the anchor) — this module moves nothing out.
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data);
        Order memory o = _order(maker, 601, USDC, WETH, USDC_IN, WETH_OUT, items);
        _routeLegOut(o, WETH, WETH_OUT, 0, address(preFund));
        bytes memory sig = _sign(o);

        // The preflight accepts the module-addressed leg.
        (bool ok, string memory why) = lens.validateOrder(o);
        assertTrue(ok, why);

        uint256 collBefore = _wethCollateral(maker);
        uint256 makerWeth = IERC20(WETH).balanceOf(maker);
        uint256 solverUsdcBefore = IERC20(USDC).balanceOf(solver);

        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN);

        // vToken rounding is coarser than Aave/Comet's; allow a small relative band.
        assertApproxEqRel(_wethCollateral(maker) - collBefore, WETH_OUT, 1e15, "the delivered leg became collateral");
        assertEq(IERC20(WETH).balanceOf(maker), makerWeth, "the maker's wallet never saw the WETH");
        assertEq(IERC20(WETH).balanceOf(address(preFund)), 0, "module WETH drained");
        assertEq(VWETH.balanceOf(address(preFund)), 0, "no vTokens stranded at the module");
        assertEq(IERC20(USDC).balanceOf(solver) - solverUsdcBefore, USDC_IN, "solver received the input leg");
    }

    // ── SWAP & REPAY. The maker converts WETH into retiring their USDC debt. The
    //    debt asset is the canonical never-approved token: the maker's USDC ERC20
    //    approval to Permit3 is revoked to prove the point. Over-delivery (1100
    //    delivered vs 1000 owed) is swept to the maker — the surplus is theirs. ──
    function test_preFundRepay_capsAtDebt_andSweepsSurplusToMaker() public {
        uint256 debt = 1_000e6; //    USDC owed
        uint256 usdcIn = 1_100e6; //  delivered conversion output — overshoots the debt

        _openVenusPosition(10 ether, debt); // 10 WETH collateral, 1000 USDC debt

        deal(WETH, maker, 1 ether);
        _approveMakerToSettlement(WETH, 1 ether); //  the input leg — already-held asset
        deal(USDC, solver, usdcIn);
        _approveSolverSide(usdcIn, USDC);

        bytes memory data = abi.encode(_forLegRepay(0, USDC), address(VUSDC), USDC);
        vm.startPrank(maker);
        IERC20(USDC).approve(address(permit3), 0); //  receive side stripped bare
        vm.stopPrank();

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data); //  pacing amount
        Order memory o = _order(maker, 602, WETH, USDC, 1 ether, usdcIn, items);
        _routeLegOut(o, USDC, usdcIn, 0, address(preFund));
        bytes memory sig = _sign(o);

        uint256 makerUsdc = IERC20(USDC).balanceOf(maker);
        uint256 debtBefore = _usdcDebt(maker);
        uint256 solverWethBefore = IERC20(WETH).balanceOf(solver);
        assertGt(debtBefore, 0, "pre: maker should have debt");

        vm.prank(solver);
        settlement.fill(o, sig, 1 ether);

        assertApproxEqAbs(_usdcDebt(maker), 0, 2, "the debt is retired in full");
        // Surplus = delivered − actual (accrued) debt repaid; small band for accrual.
        assertApproxEqAbs(
            IERC20(USDC).balanceOf(maker) - makerUsdc, usdcIn - debtBefore, 1e4, "the surplus was swept to the maker"
        );
        assertGt(IERC20(USDC).balanceOf(maker), makerUsdc, "some surplus exists given the overshoot");
        assertEq(IERC20(USDC).balanceOf(address(preFund)), 0, "module drained");
        assertEq(IERC20(WETH).balanceOf(solver) - solverWethBefore, 1 ether, "solver received the input leg");
    }

    // ── The dispatch gate: only Permit3 may enter. ──
    function test_preFundModules_rejectNonPermit3() public {
        bytes memory data = abi.encode(_forLeg(0, WETH), address(VWETH), WETH);
        vm.prank(address(0xBAD));
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        preFund.makeOnBehalf(maker, 1, data);
        vm.prank(address(0xBAD));
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        preFund.makeOnBehalf(maker, 1, data);
    }

    // ── The descriptor gate: only a `legsOut` REFERENCE — the one form whose
    //    amount the core sized to a delivery this module actually received. ──
    function test_preFundModules_rejectNonLegRefDescriptors() public {
        bytes memory literal = abi.encode(uint256(0), address(VWETH), WETH);
        bytes memory balance = abi.encode((uint256(3) << 254) | uint160(WETH), address(VWETH), WETH);

        vm.startPrank(address(settlement));
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1, literal);
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1, balance);
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1, literal);
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1, balance);
        vm.stopPrank();
    }
}
