// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Permit3} from "@core/permit3/Permit3.sol";
import {Narrow160} from "@lib/Narrow160.sol";
import {RiverOpenModule} from "../../src/RiverModules.sol";
import {RvrToken} from "../unit/RiverProceeds.t.sol";

/// @dev SatoshiXApp stand-in for `openTrove` with the FORK-VALIDATED delivery
///      direction (value-out to `msg.sender`, i.e. the module). It pulls exactly
///      `_collateralAmount` from the caller against the allowance the module
///      just granted — which is precisely what a hostile `xapp` named in `data`
///      would do with an un-narrowed approve.
contract MockOpenXApp {
    RvrToken public debtToken;
    RvrToken public collToken;

    constructor(address _debt, address _coll) {
        debtToken = RvrToken(_debt);
        collToken = RvrToken(_coll);
    }

    function openTrove(address, address, uint256, uint256 collAmount, uint256 debtAmount, address, address) external {
        collToken.transferFrom(msg.sender, address(this), collAmount);
        debtToken.mint(msg.sender, debtAmount);
    }
}

/// @title RiverOpenNarrow160OverflowTest
/// @notice Pins the {Narrow160} guard at {RiverOpenModule.takeOnBehalf}:
///
///             permit3.transferFrom(onBehalfOf, address(this), p.collateralToken,
///                                  Narrow160.to160(p.sideAmount));
///             SafeTransferLib.forceApprove(p.collateralToken, p.xapp, p.sideAmount);
///
///         `sideAmount` is decoded from the maker-signed item `data`, which the core
///         never width-checks (only the taker `amount` goes through the uint160
///         Permit3 book). Before the guard, `sideAmount = 2^160 + 1` pulled ONE WEI
///         (uint160 clip) yet approved ~1.46e48 to the `xapp` the same `data`
///         names — a claim on any collateral stranded on this shared module.
///
///         Entry path: the realistic one — Settlement (pranked) calls
///         `Permit3.take(module, maker, amount, receiver, data)` against the
///         maker's `approveTaker` grant on `keccak256(data)`; Permit3 dispatches
///         `takeOnBehalf`, which reaches the narrowing. Permit3.take does not wrap
///         module reverts, so the raw `AmountOverflow` selector bubbles.
///
///         Mock-based (no fork): reuses {RvrToken} from the unit suite.
contract RiverOpenNarrow160OverflowTest is Test {
    Permit3 permit3;
    RvrToken satUSD;
    RvrToken coll;
    MockOpenXApp xapp;
    RiverOpenModule openModule;

    address settlement = address(0x5E77);
    address maker = address(0xA11CE);
    address solver = address(0x50FE);
    address tm = address(0x7333);

    uint256 constant DEBT = 1_000e18;
    uint256 constant MAKER_COLL = 10 ether;
    /// @dev Collateral left on the shared module by someone else — the drain target.
    uint256 constant STRANDED = 3 ether;

    function setUp() public {
        permit3 = new Permit3();
        satUSD = new RvrToken();
        coll = new RvrToken();
        xapp = new MockOpenXApp(address(satUSD), address(coll));
        openModule = new RiverOpenModule(address(permit3));

        coll.mint(maker, MAKER_COLL);
        coll.mint(address(openModule), STRANDED);

        vm.startPrank(maker);
        coll.approve(address(permit3), type(uint256).max);
        satUSD.approve(address(permit3), type(uint256).max);
        // Standing collateral grant to the module (uint160.max = infinite).
        permit3.approveToken(address(openModule), address(coll), type(uint160).max, 0);
        vm.stopPrank();
    }

    function _openData(uint256 sideAmount) internal view returns (bytes memory) {
        return abi.encode(
            RiverOpenModule.OpenData(
                address(xapp), tm, address(coll), address(satUSD), 1e16, sideAmount, address(0), address(0), DEBT
            )
        );
    }

    struct State {
        uint256 makerColl;
        uint256 moduleColl;
        uint256 xappColl;
        uint256 makerDebt;
        uint256 moduleDebt;
        uint256 solverDebt;
        uint256 moduleToXappAllowance;
        uint160 tokenAllowance;
        uint160 takerAllowance;
    }

    function _state(bytes32 ref) internal view returns (State memory s) {
        s.makerColl = coll.balanceOf(maker);
        s.moduleColl = coll.balanceOf(address(openModule));
        s.xappColl = coll.balanceOf(address(xapp));
        s.makerDebt = satUSD.balanceOf(maker);
        s.moduleDebt = satUSD.balanceOf(address(openModule));
        s.solverDebt = satUSD.balanceOf(solver);
        s.moduleToXappAllowance = coll.allowance(address(openModule), address(xapp));
        (s.tokenAllowance,) = permit3.tokenAllowance(maker, address(openModule), address(coll));
        (s.takerAllowance,) = permit3.takerAllowance(maker, settlement, address(openModule), ref);
    }

    function _assertEq(State memory a, State memory b) internal pure {
        assertEq(a.makerColl, b.makerColl, "maker collateral moved");
        assertEq(a.moduleColl, b.moduleColl, "module collateral moved");
        assertEq(a.xappColl, b.xappColl, "venue collateral moved");
        assertEq(a.makerDebt, b.makerDebt, "maker satUSD moved");
        assertEq(a.moduleDebt, b.moduleDebt, "module satUSD moved");
        assertEq(a.solverDebt, b.solverDebt, "solver satUSD moved");
        assertEq(a.moduleToXappAllowance, b.moduleToXappAllowance, "module->xapp allowance changed");
        assertEq(a.tokenAllowance, b.tokenAllowance, "Permit3 token allowance changed");
        assertEq(a.takerAllowance, b.takerAllowance, "Permit3 taker allowance changed");
    }

    /// `sideAmount = 2^160` would clip to 0, `2^160 + 1` to 1 wei; both used to
    /// pair with a ~1.46e48 approve to `xapp`. Now: AmountOverflow, nothing moves.
    function test_narrow160_openSideAmount_reverts() public {
        uint256 side = uint256(type(uint160).max) + 1;
        bytes memory data = _openData(side);
        bytes32 ref = keccak256(data);

        vm.prank(maker);
        permit3.approveTaker(settlement, address(openModule), ref, uint160(DEBT), 0);

        State memory before = _state(ref);
        assertEq(before.takerAllowance, uint160(DEBT));

        vm.prank(settlement);
        vm.expectRevert(Narrow160.AmountOverflow.selector);
        permit3.take(address(openModule), maker, uint160(DEBT), solver, data);

        _assertEq(_state(ref), before);
        assertEq(coll.balanceOf(address(openModule)), STRANDED, "stranded collateral not drained");
    }

    /// Boundary: `sideAmount == type(uint160).max` fits, passes the narrowing and
    /// the whole open succeeds (maker funded for it) — pull and approve agree.
    function test_narrow160_openSideAmount_atMaxPassesNarrowing() public {
        uint256 side = uint256(type(uint160).max);
        coll.mint(maker, side - MAKER_COLL); // maker now holds exactly uint160.max
        bytes memory data = _openData(side);
        bytes32 ref = keccak256(data);

        vm.prank(maker);
        permit3.approveTaker(settlement, address(openModule), ref, uint160(DEBT), 0);

        vm.prank(settlement);
        permit3.take(address(openModule), maker, uint160(DEBT), solver, data);

        assertEq(coll.balanceOf(maker), 0, "maker paid exactly sideAmount");
        assertEq(coll.balanceOf(address(xapp)), side, "venue received exactly sideAmount");
        assertEq(coll.balanceOf(address(openModule)), STRANDED, "stranded collateral untouched");
        assertEq(coll.allowance(address(openModule), address(xapp)), 0, "no residual approve");
        assertEq(satUSD.balanceOf(solver), DEBT, "solver paid the minted debt");
        (uint160 taker,) = permit3.takerAllowance(maker, settlement, address(openModule), ref);
        assertEq(taker, 0, "taker grant consumed");
    }
}
