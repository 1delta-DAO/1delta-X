// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Item, ItemOp, Order} from "@core/settlement/Settlement.sol";

import {MidnightModulesBase} from "../shared/MidnightModulesBase.t.sol";
import {MorphoBlueMock} from "../shared/MorphoBlueMock.sol";

import {MarketParams} from "../../../morpho-blue/src/interfaces/IMorphoBlue.sol";
import {
    MorphoBlueSupplyCollateralModule,
    MorphoBlueTakerModule
} from "../../../morpho-blue/src/MorphoBlueModules.sol";

/// @dev Migrate a Morpho MIDNIGHT position → Morpho BLUE in ONE settlement order —
/// the "avoid a fixed-maturity liquidation by rolling into a perpetual Blue
/// market" flow. The maker has an open Midnight COLL/LOAN position (collateral +
/// debt); they sign one 4-item order that closes it on Midnight and opens the
/// equivalent position on a Blue COLL/LOAN market. Same assets on both sides.
///
/// Items (strictly ordered):
///   [0] MAKE  MidnightRepayModule                 repay Midnight debt (frees collateral)
///   [1] TAKE  MidnightTakerModule (WithdrawColl)  withdraw COLL from Midnight, recipient = maker
///   [2] MAKE  MorphoBlueSupplyCollateralModule    supply COLL onto Blue
///   [3] TAKE  MorphoBlueTakerModule (Borrow)      borrow LOAN on Blue, recipient = Settlement
///
/// No flash: the solver fronts the buffered repay as `tokenOut`; the Blue borrow
/// proceeds pay it back as `tokenIn`. Because item [0] zeroes the Midnight debt
/// before item [1] withdraws, the whole collateral comes out freely — so this
/// works even on a position that is unhealthy (or at maturity) on Midnight.
///
/// Mock-based (both singletons), matching the Midnight suite; the morpho-blue
/// package's fork suite covers real Morpho economics. Assets: COLL (18d) / LOAN (6d).
contract MigrateMidnightToBlueTest is MidnightModulesBase {
    MorphoBlueMock blue;
    MorphoBlueSupplyCollateralModule blueSupply;
    MorphoBlueTakerModule blueTaker;

    function setUp() public override {
        super.setUp();

        blue = new MorphoBlueMock();
        blueSupply = new MorphoBlueSupplyCollateralModule(address(permit3), address(blue), address(settlement));
        blueTaker = new MorphoBlueTakerModule(address(permit3), address(blue));

        vm.label(address(blue), "MorphoBlueMock");
        vm.label(address(blueSupply), "blueSupplyModule");
        vm.label(address(blueTaker), "blueTakerModule");
    }

    function test_migrate_midnight_to_blue() public {
        uint256 collat = 2e18; //        COLL collateral on Midnight
        uint256 debtUnits = 1_000e6; //  LOAN debt on Midnight
        uint256 buffer = 50e6;
        uint256 bufferedRepay = debtUnits + buffer;

        // ── Seed the source Midnight position + fund the participants ──
        _seedCollateral(maker, collat);
        midnight.seedDebt(_market(), maker, debtUnits);
        LOAN.mint(solver, bufferedRepay); //   solver fronts the repay (delivered as tokenOut)
        LOAN.mint(address(blue), debtUnits); // Blue liquidity for the new borrow proceeds

        bytes memory repayData = _repayData();
        bytes memory wcData = _withdrawCollateralData(0); // Exact
        bytes memory blueSupplyData = _blueSupplyData();
        bytes memory blueBorrowData = _blueBorrowData();

        // ── Authorizations (one-time, maker) ──
        // [0] Midnight repay: repay module pulls LOAN via Permit3.
        _makerApproveToken(address(repayModule), address(LOAN), bufferedRepay);
        // [1] Midnight withdraw-collateral: Permit3 taker cap + Midnight native auth.
        _makerApproveTaker(keccak256(wcData), collat);
        _makerAuthorize(address(takerModule));
        // [2] Blue supply: supply module pulls COLL via Permit3.
        _makerApproveToken(address(blueSupply), address(COLL), collat);
        // [3] Blue borrow: Permit3 taker cap + Morpho native auth.
        _makerApproveTaker(keccak256(blueBorrowData), debtUnits);
        vm.prank(maker);
        blue.setAuthorization(address(blueTaker), true);
        // Solver funds the tokenOut delivery.
        vm.prank(solver);
        permit3.approveToken(address(settlement), address(LOAN), uint160(bufferedRepay), 0);

        // ── Build + fill the migration order ──
        Item[] memory items = new Item[](4);
        items[0] = Item(ItemOp.MAKE, address(repayModule), bufferedRepay, address(0), repayData);
        items[1] = Item(ItemOp.TAKE, address(takerModule), collat, maker, wcData); // withdrawn COLL → maker
        items[2] = Item(ItemOp.MAKE, address(blueSupply), collat, address(0), blueSupplyData);
        items[3] = Item(ItemOp.TAKE, address(blueTaker), debtUnits, address(0), blueBorrowData); // proceeds → Settlement

        Order memory order = _order(maker, 42, address(LOAN), address(LOAN), debtUnits, bufferedRepay, items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, debtUnits);

        // ── Midnight side closed ──
        assertEq(_debtOf(maker), 0, "Midnight debt cleared");
        assertEq(_collateralOf(maker), 0, "Midnight collateral withdrawn");

        // ── Blue side opened (same assets) ──
        MarketParams memory bm = _blueMarket();
        assertEq(blue.collateralOf(bm, maker), collat, "Blue collateral opened exactly");
        assertEq(blue.borrowSharesOf(bm, maker), debtUnits, "Blue debt opened (1:1)");

        // ── Balances net out ──
        assertEq(LOAN.balanceOf(maker), buffer, "maker keeps the repay buffer");
        assertEq(COLL.balanceOf(maker), 0, "maker COLL net-zero (withdrawn = supplied)");
        assertEq(LOAN.balanceOf(solver), debtUnits, "solver recouped from the Blue borrow");
        _assertDrained();
    }

    // ──────────────────── helpers ────────────────────

    function _blueMarket() internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: address(LOAN),
            collateralToken: address(COLL),
            oracle: address(0x0AC1E),
            irm: address(0x121121),
            lltv: 0.8e18
        });
    }

    function _blueSupplyData() internal view returns (bytes memory) {
        return abi.encode(_blueMarket());
    }

    function _blueBorrowData() internal view returns (bytes memory) {
        return abi.encode(uint8(MorphoBlueTakerModule.Op.Borrow), _blueMarket());
    }

    function _seedCollateral(address who, uint256 amount) internal {
        COLL.mint(address(this), amount);
        COLL.approve(address(midnight), amount);
        midnight.seedCollateral(_market(), who, 0, amount);
    }

    function _assertDrained() internal view {
        assertEq(LOAN.balanceOf(address(settlement)), 0, "settlement LOAN drained");
        assertEq(COLL.balanceOf(address(settlement)), 0, "settlement COLL drained");
        assertEq(LOAN.balanceOf(address(repayModule)), 0, "repay module drained");
        assertEq(COLL.balanceOf(address(takerModule)), 0, "midnight taker drained");
        assertEq(COLL.balanceOf(address(blueSupply)), 0, "blue supply module drained");
        assertEq(LOAN.balanceOf(address(blueTaker)), 0, "blue taker module drained");
    }
}
