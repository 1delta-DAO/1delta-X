// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Item, ItemOp, Order, Settlement} from "@core/settlement/Settlement.sol";
import {Permit3} from "@core/permit3/Permit3.sol";
import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

import {Market, CollateralParams, Offer} from "../../src/interfaces/IMidnight.sol";
import {
    MidnightSupplyCollateralModule,
    MidnightRepayModule,
    MidnightLendModule,
    MidnightTakerModule,
    MidnightBorrowModule
} from "../../src/MidnightModules.sol";
import {MidnightMock, MockERC20} from "./MidnightMock.sol";

/// @dev Morpho Midnight settlement-module harness. Midnight is a fixed-rate,
/// fixed-maturity, ORDER-BOOK primitive whose positions are opened by signed
/// maker offers + ratifiers — impractical to seed on a live fork — so, like the
/// composer's Midnight suite, this drives a faithful `MidnightMock` (real
/// selectors, real token flows, real `setIsAuthorized` gating, positions keyed
/// by the same `MidnightIdLib.toId` the modules compute) with mock ERC20s. No
/// fork: `setUp` is overridden to deploy Permit3 + Settlement directly.
///
///   collateral token = COLL
///   loan token       = LOAN
abstract contract MidnightModulesBase is CoreSettlementBase {
    MidnightMock midnight;
    MockERC20 COLL;
    MockERC20 LOAN;

    MidnightSupplyCollateralModule supplyModule;
    MidnightRepayModule repayModule;
    MidnightLendModule lendModule;
    MidnightTakerModule takerModule;
    MidnightBorrowModule borrowModule;

    address offerMaker = address(0x0FFE7);

    function setUp() public virtual override {
        // No fork: deploy the protocol core directly (base setUp forks mainnet).
        _deployCore();

        COLL = new MockERC20("Collateral", "COLL", 18);
        LOAN = new MockERC20("Loan", "LOAN", 6);
        midnight = new MidnightMock();

        supplyModule = new MidnightSupplyCollateralModule(address(permit3), address(midnight), address(settlement));
        repayModule = new MidnightRepayModule(address(permit3), address(midnight), address(settlement));
        lendModule = new MidnightLendModule(address(permit3), address(midnight), address(settlement));
        takerModule = new MidnightTakerModule(address(permit3), address(midnight));
        borrowModule = new MidnightBorrowModule(address(permit3), address(midnight));

        vm.label(address(midnight), "MidnightMock");
        vm.label(address(COLL), "COLL");
        vm.label(address(LOAN), "LOAN");
        vm.label(address(supplyModule), "supplyModule");
        vm.label(address(repayModule), "repayModule");
        vm.label(address(lendModule), "lendModule");
        vm.label(address(takerModule), "takerModule");
        vm.label(address(borrowModule), "borrowModule");

        // Maker + solver bare ERC20 approvals to Permit3.
        vm.startPrank(maker);
        COLL.approve(address(permit3), type(uint256).max);
        LOAN.approve(address(permit3), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(solver);
        COLL.approve(address(permit3), type(uint256).max);
        LOAN.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(COLL), type(uint160).max, 0);
        permit3.approveToken(address(settlement), address(LOAN), type(uint160).max, 0);
        vm.stopPrank();
    }

    /// @dev Replicates CoreSettlementBase's core deploy without the fork.
    function _deployCore() internal {
        permit3 = new Permit3();
        settlement = new Settlement(address(permit3));
        vm.label(maker, "maker");
        vm.label(solver, "solver");
    }

    // ──────────────────── Market / offer builders ────────────────────

    /// @dev A fixed single-collateral market. Field values are arbitrary but must
    ///      be stable across a test so the derived `id` is stable.
    function _market() internal view returns (Market memory m) {
        CollateralParams[] memory cp = new CollateralParams[](1);
        cp[0] = CollateralParams({
            token: address(COLL), lltv: 0.8e18, liquidationCursor: 0.05e18, oracle: address(0x0AC1E)
        });
        m = Market({
            chainId: 1,
            midnight: address(midnight),
            loanToken: address(LOAN),
            collateralParams: cp,
            maturity: 1_900_000_000,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    function _offer(bool buy) internal view returns (Offer memory o) {
        o = Offer({
            market: _market(),
            buy: buy,
            maker: offerMaker,
            start: 0,
            expiry: 1_900_000_000,
            tick: 0,
            group: bytes32(0),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: offerMaker,
            ratifier: address(0),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: type(uint128).max,
            continuousFeeCap: 0
        });
    }

    // ──────────────────── data encoders ────────────────────

    function _supplyData() internal view returns (bytes memory) {
        return abi.encode(_market(), uint256(0));
    }

    function _repayData() internal view returns (bytes memory) {
        return abi.encode(_market());
    }

    function _withdrawCollateralData(uint8 mode) internal view returns (bytes memory) {
        return abi.encode(uint8(MidnightTakerModule.Op.WithdrawCollateral), _market(), uint256(0), mode);
    }

    function _withdrawCreditData(uint8 mode) internal view returns (bytes memory) {
        return abi.encode(uint8(MidnightTakerModule.Op.Withdraw), _market(), uint256(0), mode);
    }

    function _borrowData(uint256 units) internal view returns (bytes memory) {
        return abi.encode(_offer(true), bytes(""), units);
    }

    function _lendData(uint256 units) internal view returns (bytes memory) {
        return abi.encode(_offer(false), bytes(""), units);
    }

    // ──────────────────── maker-side authorization helpers ────────────────────

    function _makerApproveToken(address module, address token, uint256 cap) internal {
        vm.prank(maker);
        permit3.approveToken(module, token, uint160(cap), 0);
    }

    function _makerApproveTaker(bytes32 ref, uint256 cap) internal {
        vm.prank(maker);
        permit3.approveTaker(address(settlement), ref, uint160(cap), 0);
    }

    function _makerAuthorize(address module) internal {
        vm.prank(maker);
        midnight.setIsAuthorized(module, true, maker);
    }

    // ──────────────────── position reads ────────────────────

    function _collateralOf(address who) internal view returns (uint256) {
        return midnight.collateral(_id(), who, 0);
    }

    function _debtOf(address who) internal view returns (uint256) {
        return midnight.debt(_id(), who);
    }

    function _creditOf(address who) internal view returns (uint256) {
        return midnight.credit(_id(), who);
    }

    function _id() internal view returns (bytes32) {
        // Mirror MidnightIdLib.toId(_market()).
        Market memory m = _market();
        return keccak256(
            abi.encodePacked(
                uint8(0xff),
                m.midnight,
                uint256(0),
                keccak256(abi.encodePacked(hex"600b380380600b5f395ff3", abi.encode(m)))
            )
        );
    }

    // ──────────────────── item helper ────────────────────

    function _item(ItemOp op, address module, uint256 amount, bytes memory data) internal pure returns (Item memory) {
        return Item(op, module, amount, address(0), data);
    }
}
