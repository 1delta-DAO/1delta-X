// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";

import {ListaPreFundModule} from "../../src/ListaPreFundModules.sol";
import {MarketParams} from "../../src/interfaces/ILista.sol";
import {ListaNettedSmartProvider} from "./NettedPreFund.t.sol";

/// @title Review 2026-10-18 — SmartSupplyCollateral with an out-of-range `coinIndex`
/// @notice Probe, not a finding: `_smartSupplyCollateral` maps `coinIndex` to
///         `(amount0, amount1)` with `== 0 ? : 0` / `== 1 ? : 0`, so any index ≥ 2 hands
///         the provider a ZERO zap. With a non-zero `minLpRate` the provider's slippage
///         floor rejects it (fail closed); with `minLpRate == 0` the op is a silent
///         no-op and the whole delivery is swept back to the maker's WALLET instead of
///         becoming LP collateral. Maker-signed misconfiguration either way, no value
///         lost or stranded; pinned here so the number is on record.
contract Review20261018_SmartCoinIndexTest is Test {
    ListaPreFundModule preFund;
    ListaNettedSmartProvider provider;
    MockERC20 coin0;
    MockERC20 coin1;
    address maker = address(0xA11CE);
    uint256 constant RESIDUE = 3e18;
    uint256 constant DELIVERY = 7e18;

    function setUp() public {
        coin0 = new MockERC20("c0");
        coin1 = new MockERC20("c1");
        provider = new ListaNettedSmartProvider(address(coin0), address(coin1));
        // settlement = this test, so `makeOnBehalf` can be driven directly.
        preFund = new ListaPreFundModule(address(0xBEEF), address(this));
        coin0.mint(address(preFund), RESIDUE);
    }

    function _desc(uint256 op, address token) internal pure returns (uint256) {
        return (uint256(5) << 253) | (op << 244) | (uint256(uint160(token)) << 16);
    }

    function _data(uint256 coinIndex, uint256 minLpRate) internal view returns (bytes memory) {
        return abi.encode(
            _desc(uint256(ListaPreFundModule.Op.SmartSupplyCollateral), address(coin0)),
            address(provider),
            address(coin0),
            coinIndex,
            minLpRate,
            MarketParams({
                loanToken: address(coin1),
                collateralToken: address(provider),
                oracle: address(0),
                irm: address(0),
                lltv: 0
            })
        );
    }

    /// coinIndex = 2, minLpRate = 0: zero zap, nothing credited, the entire delivery is
    /// returned to the maker's wallet; the singleton's residue is untouched.
    function test_coinIndexOutOfRange_rateZero_isASilentNoOp_deliveryBackToWallet() public {
        coin0.mint(address(preFund), DELIVERY); // the core's delivery of legsOut[j]
        preFund.makeOnBehalf(maker, DELIVERY, _data(2, 0));

        assertEq(provider.collateral(maker), 0, "no LP minted");
        assertEq(coin0.balanceOf(address(provider)), 0, "provider pulled nothing");
        assertEq(coin0.balanceOf(maker), DELIVERY, "whole delivery swept back to the wallet");
        assertEq(coin0.balanceOf(address(preFund)), RESIDUE, "residue below the floor untouched");
    }

    /// coinIndex = 2 with any positive LP floor: the provider's slippage check fails
    /// the zero zap and the fill reverts — fail closed.
    function test_coinIndexOutOfRange_withRate_failsClosed() public {
        coin0.mint(address(preFund), DELIVERY);
        vm.expectRevert(bytes("slippage"));
        preFund.makeOnBehalf(maker, DELIVERY, _data(2, 0.99e18));
    }

    /// Control: coinIndex = 0 zaps exactly the delivery (1:1 mock), sweeps nothing.
    function test_control_coinIndex0_zapsExactlyTheDelivery() public {
        coin0.mint(address(preFund), DELIVERY);
        preFund.makeOnBehalf(maker, DELIVERY, _data(0, 0.99e18));

        assertEq(provider.collateral(maker), DELIVERY, "LP = delivery");
        assertEq(coin0.balanceOf(maker), 0, "nothing swept");
        assertEq(coin0.balanceOf(address(preFund)), RESIDUE, "residue untouched");
    }
}
