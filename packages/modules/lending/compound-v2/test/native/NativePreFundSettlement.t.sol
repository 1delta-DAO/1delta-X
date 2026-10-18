// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {ICEther} from "../../src/interfaces/ICompoundV2.sol";
import {CompoundV2NativePreFundModule} from "../../src/CompoundV2PreFundModules.sol";
import {CompoundV2ModulesBase} from "../shared/CompoundV2ModulesBase.t.sol";

/// @dev {CompoundV2NativePreFundModule} against the LIVE mainnet cETH market and
/// WETH9, driven through `settlement.fill` (review 2026-10-18 M-5). The pull-funded
/// twins ({CompoundV2NativeDepositModule} / {CompoundV2NativeRepayModule}, see
/// NativeSettlement.t.sol) need the maker to approve the module for WETH — a token a
/// "sell USDC, deposit/repay ETH" maker never holds. Here the WETH leg is delivered
/// straight to the module and unwrapped inside the item: the maker's only grant is
/// the USDC input-leg approval, asserted below. Native boundaries are asserted as
/// DELTAS (fork dust on the deterministic deploy addresses — see the package memo).
contract CompoundV2NativePreFundSettlementTest is CompoundV2ModulesBase {
    ICEther constant CETH = ICEther(0x4Ddc2D193948926D02f9B1fE9e1daa0718270ED5);

    CompoundV2NativePreFundModule nPreFund;

    function setUp() public override {
        super.setUp();
        nPreFund = new CompoundV2NativePreFundModule(address(permit3), address(settlement), WETH);
        vm.label(address(nPreFund), "compoundV2NativePreFundModule");
        vm.label(address(CETH), "cETH");
        // The base grants the maker a standing WETH approval; revoke it outright, so
        // the fills below prove the receive side needs none.
        vm.prank(maker);
        IERC20(WETH).approve(address(permit3), 0);
    }

    function _desc(CompoundV2NativePreFundModule.Op op) internal view returns (uint256) {
        return (uint256(5) << 253) | (uint256(op) << 244) | (uint256(uint160(WETH)) << 16);
    }

    function _order1(uint256 usdcIn, uint256 wethOut, CompoundV2NativePreFundModule.Op op)
        internal
        view
        returns (Order memory o)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.MAKE, address(nPreFund), 0, address(0), abi.encode(_desc(op), address(CETH)));
        o = _order(maker, 1, USDC, WETH, usdcIn, wethOut, items);
        o.legsOut = PackedEncode.oneLegOut(WETH, wethOut, 0, address(nPreFund));
    }

    function _assertNoWethGrant() internal view {
        assertEq(IERC20(WETH).allowance(maker, address(permit3)), 0, "no WETH approval to Permit3");
        (uint160 amt,) = permit3.tokenAllowance(maker, address(nPreFund), WETH);
        assertEq(amt, 0, "no WETH book entry to the module");
    }

    /// SELL USDC → DEPOSIT ETH. The solver delivers WETH to the module, which unwraps
    /// exactly that delivery, mints cETH, and forwards the receipt to the maker.
    function test_preFundNative_sellUsdc_depositEth() public {
        uint256 usdcIn = 3_000e6;
        uint256 wethOut = 1 ether;
        deal(USDC, maker, usdcIn);
        _approveMakerToSettlement(USDC, usdcIn);
        deal(WETH, solver, wethOut);
        _approveSolverSide(wethOut, WETH);
        _assertNoWethGrant();

        Order memory o = _order1(usdcIn, wethOut, CompoundV2NativePreFundModule.Op.Deposit);
        bytes memory sig = _sign(o);
        uint256 cethEthBefore = address(CETH).balance;
        uint256 modEth = address(nPreFund).balance;
        uint256 sEth = address(settlement).balance;

        vm.prank(solver);
        settlement.fill(o, sig, usdcIn);

        assertEq(address(CETH).balance - cethEthBefore, wethOut, "cETH received exactly the delivery, natively");
        assertGt(IERC20(address(CETH)).balanceOf(maker), 0, "maker holds the cETH receipt");
        assertEq(IERC20(address(CETH)).balanceOf(address(nPreFund)), 0, "receipt forwarded");
        assertEq(IERC20(WETH).balanceOf(address(nPreFund)), 0, "module WETH drained");
        assertEq(address(nPreFund).balance, modEth, "module retained no native");
        assertEq(address(settlement).balance, sEth, "settlement gained no native");
        assertEq(maker.balance, 0, "maker got no raw ETH");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver paid");
    }

    /// SELL USDC → REPAY an ETH debt. The delivery overshoots the live debt (an
    /// accrual buffer); the module repays the debt exactly and returns the rest,
    /// still WRAPPED, to the maker.
    function test_preFundNative_sellUsdc_repayEthDebt_surplusBackAsWeth() public {
        _seedUsdcCollateral(4_000e6);
        vm.startPrank(maker);
        require(CETH.borrow(1 ether) == 0, "seed eth borrow");
        (bool dumped,) = address(0xdead).call{value: 1 ether}("");
        require(dumped, "dump");
        vm.stopPrank();
        uint256 debt = CETH.borrowBalanceCurrent(maker);
        uint256 wethOut = debt + 0.05 ether;
        uint256 usdcIn = 2_000e6;

        deal(USDC, maker, usdcIn);
        _approveMakerToSettlement(USDC, usdcIn);
        deal(WETH, solver, wethOut);
        _approveSolverSide(wethOut, WETH);
        _assertNoWethGrant();

        Order memory o = _order1(usdcIn, wethOut, CompoundV2NativePreFundModule.Op.Repay);
        bytes memory sig = _sign(o);
        uint256 modEth = address(nPreFund).balance;

        vm.prank(solver);
        settlement.fill(o, sig, usdcIn);

        assertEq(CETH.borrowBalanceStored(maker), 0, "ETH debt closed");
        assertApproxEqAbs(IERC20(WETH).balanceOf(maker), wethOut - debt, 1e12, "buffer back to the maker as WETH");
        assertEq(IERC20(WETH).balanceOf(address(nPreFund)), 0, "module WETH drained");
        assertEq(address(nPreFund).balance, modEth, "module retained no native");
        assertEq(maker.balance, 0, "maker got no raw ETH");
    }
}
