// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, LegOut} from "@core/settlement/Settlement.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {CompoundV2PreFundModule} from "../../src/CompoundV2PreFundModules.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {CompoundV2ModulesBase} from "../shared/CompoundV2ModulesBase.t.sol";

/// @dev The ONE-SIDED pre-fund composites over vanilla Compound v2: "deposit whatever
/// the conversion delivered" / "repay whatever the conversion delivered", with
/// ZERO receive-side approvals. The converted output leg is delivered straight to
/// the module (`recipient = module`), the core sizes `forAmount` to exactly that
/// delivery, and the maker's only grants are the input-leg approval they had
/// anyway plus a signable taker allowance. The received asset — DAI on both
/// flows here — is never approved to anything, anywhere.
///
/// Venue specifics under test: `mint` credits the CALLER, so the pre-fund-deposit
/// module must forward the measured mint receipt (cTokens) to the maker; repay
/// caps at `borrowBalanceCurrent` and sweeps the delivered surplus to the maker.
contract CompoundV2PreFundOneSidedTest is CompoundV2ModulesBase {
    CompoundV2PreFundModule preFund;

    uint256 constant USDC_IN = 1_500e6;
    uint256 constant DAI_OUT = 1_000e18;

    function setUp() public override {
        super.setUp();
        preFund = new CompoundV2PreFundModule(address(permit3), address(settlement));
        }

    /// @dev `(1 << 255) | index` — fund from `legsOut[index]`.
    function _forLeg(uint256 index, address token) internal pure returns (uint256) {
        // bit 255 = leg reference; bit 253 = the PRE-FUND shape, which makes the core
        // require `legsOut[index].recipient == module` (F27/H-1).
        return (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(token)) << 16) | index;
    }

    /// @dev Same leg reference, with the op in descriptor bits [244,252).
    function _forLegOp(uint256 index, address token, CompoundV2PreFundModule.Op op) internal pure returns (uint256) {
        return _forLeg(index, token) | (uint256(op) << 244);
    }

    /// @dev Address one output leg to `to` (the pre-fund shape).
    function _routeLegOut(Order memory o, address token, uint256 start, uint256 end, address to) internal pure {
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(token, start, end, to);
        o.legsOut = PackedEncode.legsOut(legsOut);
    }

    // ── SWAP & DEPOSIT. The maker converts USDC (the one asset they hold and had
    //    approved anyway) into a cDAI deposit. DAI — the asset they RECEIVE — has
    //    its ERC20 approval to Permit3 revoked outright and no Permit3 token
    //    allowance to anything: the receive side is strictly empty. The mint
    //    credits the MODULE, which must forward the measured cToken receipt. ──
    function test_preFundDeposit_swapAndDeposit_zeroReceiveSideApprovals() public {
        deal(USDC, maker, USDC_IN);
        _approveMakerToSettlement(USDC, USDC_IN); //  the input leg — the ONE approval
        deal(DAI, solver, DAI_OUT);
        _approveSolverSide(DAI_OUT, DAI);

        bytes memory data = abi.encode(_forLeg(0, DAI), address(CDAI), DAI);
        vm.startPrank(maker);
        IERC20(DAI).approve(address(permit3), 0); //  receive side stripped bare
        vm.stopPrank();

        // Prove the receive side is empty BEFORE the fill, not just unused.
        assertEq(IERC20(DAI).allowance(maker, address(permit3)), 0, "DAI has no ERC20 approval to Permit3");

        Item[] memory items = new Item[](1);
        // `amount` is the PACING total (the anchor) — this module moves nothing out.
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data);
        Order memory o = _order(maker, 501, USDC, DAI, USDC_IN, DAI_OUT, items);
        _routeLegOut(o, DAI, DAI_OUT, 0, address(preFund));
        bytes memory sig = _sign(o);

        // The preflight accepts the module-addressed leg.
        (bool ok, string memory why) = lens.validateOrder(o);
        assertTrue(ok, why);

        uint256 collBefore = _daiCollateral(maker);
        uint256 cDaiBefore = CDAI.balanceOf(maker);
        uint256 makerDai = IERC20(DAI).balanceOf(maker);
        uint256 solverUsdcBefore = IERC20(USDC).balanceOf(solver);

        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN);

        // cToken rounding is coarser than Aave/Comet's; allow a small relative band.
        assertApproxEqRel(_daiCollateral(maker) - collBefore, DAI_OUT, 1e15, "the delivered leg became collateral");
        assertGt(CDAI.balanceOf(maker), cDaiBefore, "the mint receipt was forwarded to the maker");
        assertEq(IERC20(DAI).balanceOf(maker), makerDai, "the maker's wallet never saw the DAI");
        assertEq(IERC20(DAI).balanceOf(address(preFund)), 0, "module DAI drained");
        assertEq(CDAI.balanceOf(address(preFund)), 0, "module cDAI drained");
        assertEq(IERC20(USDC).balanceOf(solver) - solverUsdcBefore, USDC_IN, "solver received the input leg");
    }

    // ── SWAP & REPAY. The maker converts wallet USDC into retiring their DAI
    //    debt. The debt asset is the canonical never-approved token: the maker's
    //    DAI ERC20 approval to Permit3 is revoked to prove the point.
    //    Over-delivery (1100 delivered vs 1000 owed) is swept to the maker — the
    //    surplus is theirs. ──
    function test_preFundRepay_capsAtDebt_andSweepsSurplusToMaker() public {
        uint256 debt = 1_000e18; //   DAI owed
        uint256 daiIn = 1_100e18; //  delivered conversion output — overshoots the debt
        uint256 usdcSold = 500e6; //  the input leg — an asset the maker holds

        _openDaiDebt(5_000e6, debt); // 5000 USDC collateral, 1000 DAI debt

        deal(USDC, maker, usdcSold);
        _approveMakerToSettlement(USDC, usdcSold);
        deal(DAI, solver, daiIn);
        _approveSolverSide(daiIn, DAI);

        bytes memory data = abi.encode(_forLegOp(0, DAI, CompoundV2PreFundModule.Op.Repay), address(CDAI), DAI);
        vm.startPrank(maker);
        IERC20(DAI).approve(address(permit3), 0); //  receive side stripped bare
        vm.stopPrank();

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data); //  pacing amount
        Order memory o = _order(maker, 502, USDC, DAI, usdcSold, daiIn, items);
        _routeLegOut(o, DAI, daiIn, 0, address(preFund));
        bytes memory sig = _sign(o);

        uint256 makerDai = IERC20(DAI).balanceOf(maker);
        uint256 debtBefore = _daiDebt(maker);
        uint256 solverUsdcBefore = IERC20(USDC).balanceOf(solver);
        assertGt(debtBefore, 0, "pre: maker should have debt");

        vm.prank(solver);
        settlement.fill(o, sig, usdcSold);

        assertApproxEqAbs(_daiDebt(maker), 0, 1e12, "the debt is retired in full");
        // Surplus = delivered − actual (accrued) debt repaid; wide-ish band for accrual.
        assertApproxEqAbs(
            IERC20(DAI).balanceOf(maker) - makerDai, daiIn - debtBefore, 1e16, "the surplus was swept to the maker"
        );
        assertGt(IERC20(DAI).balanceOf(maker), makerDai, "some surplus exists given the overshoot");
        assertEq(IERC20(DAI).balanceOf(address(preFund)), 0, "module drained");
        assertEq(IERC20(USDC).balanceOf(solver) - solverUsdcBefore, usdcSold, "solver received the input leg");
    }

    // ── The dispatch gate: only Permit3 may enter. ──
    function test_preFundModules_rejectNonPermit3() public {
        bytes memory data = abi.encode(_forLeg(0, DAI), address(CDAI), DAI);
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
        bytes memory literal = abi.encode(uint256(0), address(CDAI), DAI);
        bytes memory balance = abi.encode((uint256(3) << 254) | uint160(DAI), address(CDAI), DAI);

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
