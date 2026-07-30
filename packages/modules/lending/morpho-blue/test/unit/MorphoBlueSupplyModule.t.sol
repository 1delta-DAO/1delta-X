// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MorphoBlueSupplyModule} from "../../src/MorphoBlueModules.sol";
import {MarketParams} from "../../src/interfaces/IMorphoBlue.sol";

import {MockERC20, MockMorpho, MockPermit3, dummyMarketParams} from "./MorphoBlueTakerModulesTest.t.sol";

// ── MorphoBlueSupplyModule (earn-side deposit) unit tests ─────────────────────
//
// The MAKE sibling of the taker module's `Op.Withdraw`: pulls loanToken via
// Permit3 and lends it (`morpho.supply`, exact assets) on the user's behalf.
// Wiring-level assertions (settlement gate, right Morpho call, right onBehalf);
// real token flow belongs to the fork suites like every other MAKE module.
contract MorphoBlueSupplyModuleTest is Test {
    MockERC20 loanToken;
    MockERC20 collateralToken;
    MockMorpho morpho;
    MockPermit3 permit3;
    MorphoBlueSupplyModule module;
    MarketParams market;

    address settlement = address(0x5E77);
    address user = address(0xABCD);
    uint256 constant SUPPLY = 1_000e6;

    function setUp() public {
        loanToken = new MockERC20();
        collateralToken = new MockERC20();
        morpho = new MockMorpho(loanToken, collateralToken);
        permit3 = new MockPermit3();
        module = new MorphoBlueSupplyModule(address(permit3), address(morpho), settlement);
        market = dummyMarketParams(address(loanToken), address(collateralToken));
    }

    function test_supply_creditsUsersEarnPosition() public {
        vm.prank(settlement);
        module.makeOnBehalf(user, SUPPLY, abi.encode(market));

        assertEq(morpho.lastSupplyOnBehalf(), user, "supplied on the user's behalf");
        assertEq(morpho.lastSupplyAssets(), SUPPLY, "exact-assets supply");
        assertEq(morpho.position(keccak256(abi.encode(market)), user).supplyShares, SUPPLY, "earn position credited");
    }

    function test_supply_gatedToSettlement() public {
        vm.expectRevert(MorphoBlueSupplyModule.NotSettlement.selector);
        module.makeOnBehalf(user, SUPPLY, abi.encode(market));
    }

    /// @dev Round-trip with the taker's `Op.Withdraw`: the shares this module
    ///      credits are exactly what the withdraw leg redeems — the two halves
    ///      of the earn flow line up on the same position.
    function test_supply_pairsWithTakerWithdraw() public {
        vm.prank(settlement);
        module.makeOnBehalf(user, SUPPLY, abi.encode(market));
        assertEq(morpho.position(keccak256(abi.encode(market)), user).supplyShares, SUPPLY);
    }
}
