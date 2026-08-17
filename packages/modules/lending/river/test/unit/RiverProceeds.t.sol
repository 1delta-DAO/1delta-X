// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Permit3} from "@core/permit3/Permit3.sol";
import {RiverTakerModule, RiverProceeds} from "../../src/RiverModules.sol";

contract RvrToken {
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

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

/// @dev SatoshiXApp stand-in whose delivery behaviour is configurable, because the
///      real fund-flow direction is exactly what the package header flags as
///      unverified. `deliveryBps` models: 10000 = mints the full amount to the
///      account (the assumed Liquity-V1 lineage behaviour), <10000 = a fork that
///      nets a borrow fee out of the mint, 0 = a fork that routes proceeds
///      elsewhere or where the delegate grant silently no-ops.
contract MockXApp {
    RvrToken public debtToken;
    RvrToken public collToken;
    uint256 public deliveryBps = 10_000;
    /// @dev false = deliver to `account` (Prisma lineage); true = deliver to
    ///      `msg.sender` (the FORK-VALIDATED Hemi diamond behaviour).
    bool public mintToCaller;

    constructor(address _debt, address _coll) {
        debtToken = RvrToken(_debt);
        collToken = RvrToken(_coll);
    }

    function setDeliveryBps(uint256 bps) external {
        deliveryBps = bps;
    }

    function setMintToCaller(bool v) external {
        mintToCaller = v;
    }

    function withdrawDebt(address, address account, uint256, uint256 amount, address, address) external {
        debtToken.mint(mintToCaller ? msg.sender : account, (amount * deliveryBps) / 10_000);
    }

    function withdrawColl(address, address account, uint256 amount, address, address) external {
        collToken.mint(mintToCaller ? msg.sender : account, (amount * deliveryBps) / 10_000);
    }
}

/// @title RiverProceedsTest
/// @notice Regression tests for the River value-out legs.
///
///         River's CDP ops carry no `receiver` — they mint/return to `account` —
///         so the taker module pulls the payout out of the MAKER'S WALLET. Before
///         the fix it pulled a fixed `amount` with no check that the op delivered
///         anything, so any shortfall was silently covered by the maker's
///         PRE-EXISTING balance and handed to the solver. The bound was the maker's
///         Permit3 token allowance, which for this flow is realistically large.
///
///         These tests pin the two failure shapes the package header calls out as
///         unverified: a fork that nets a fee out of the mint, and one where the
///         proceeds never reach the account at all.
contract RiverProceedsTest is Test {
    Permit3 permit3;
    RvrToken satUSD;
    RvrToken coll;
    MockXApp xapp;
    RiverTakerModule takerModule;

    address settlement = address(0x5E77);
    address maker = address(0xA11CE);
    address solver = address(0x50FE);
    address tm = address(0x7333);

    uint256 constant BORROW = 1_000e18;
    uint256 constant MAKER_SAVINGS = 5_000e18; // the maker's own satUSD, not part of the order

    function setUp() public {
        permit3 = new Permit3();
        satUSD = new RvrToken();
        coll = new RvrToken();
        xapp = new MockXApp(address(satUSD), address(coll));
        takerModule = new RiverTakerModule(address(permit3));

        // The maker holds an unrelated satUSD balance and has granted the module the
        // standing token allowance the flow requires.
        satUSD.mint(maker, MAKER_SAVINGS);
        vm.startPrank(maker);
        satUSD.approve(address(permit3), type(uint256).max);
        coll.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(takerModule), address(satUSD), type(uint160).max, 0);
        permit3.approveToken(address(takerModule), address(coll), type(uint160).max, 0);
        vm.stopPrank();
    }

    function _borrowData() internal view returns (bytes memory) {
        return abi.encode(uint8(0), address(xapp), tm, address(satUSD), uint256(0), address(0), address(0));
    }

    function _collData() internal view returns (bytes memory) {
        return abi.encode(uint8(1), address(xapp), tm, address(coll), address(0), address(0));
    }

    function _take(bytes memory data, uint256 amount) internal {
        vm.prank(maker);
        permit3.approveTaker(settlement, address(takerModule), keccak256(data), uint160(amount), 0);
        vm.prank(settlement);
        permit3.take(address(takerModule), maker, uint160(amount), solver, data);
    }

    // ──────────────── Happy path ────────────────

    function test_borrow_forwardsWhatTheCdpMinted() public {
        _take(_borrowData(), BORROW);

        assertEq(satUSD.balanceOf(solver), BORROW, "solver paid from the mint");
        assertEq(satUSD.balanceOf(maker), MAKER_SAVINGS, "maker's own balance untouched");
    }

    // ──────────────── The raid, blocked ────────────────

    /// A fork that nets a borrow fee out of the mint. The maker receives 990 but
    /// the module owes the solver 1000 — the 10 difference used to come out of the
    /// maker's savings, silently.
    function test_shortDelivery_doesNotRaidTheMakersBalance() public {
        xapp.setDeliveryBps(9_900); // 1% fee netted out of the mint

        bytes memory data = _borrowData();
        vm.prank(maker);
        permit3.approveTaker(settlement, address(takerModule), keccak256(data), uint160(BORROW), 0);

        vm.prank(settlement);
        vm.expectRevert(
            abi.encodeWithSelector(RiverProceeds.InsufficientProceeds.selector, (BORROW * 9_900) / 10_000, BORROW)
        );
        permit3.take(address(takerModule), maker, uint160(BORROW), solver, data);

        assertEq(satUSD.balanceOf(solver), 0, "solver got nothing");
        assertEq(satUSD.balanceOf(maker), MAKER_SAVINGS, "maker's savings intact");
    }

    /// The worst shape: the CDP call succeeds but delivers nothing to the account —
    /// a fork whose proceeds land elsewhere, or a delegate grant that no-ops. This
    /// used to transfer a clean `BORROW` of the maker's OWN satUSD to the solver.
    function test_zeroDelivery_doesNotRaidTheMakersBalance() public {
        xapp.setDeliveryBps(0);

        bytes memory data = _borrowData();
        vm.prank(maker);
        permit3.approveTaker(settlement, address(takerModule), keccak256(data), uint160(BORROW), 0);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(RiverProceeds.InsufficientProceeds.selector, 0, BORROW));
        permit3.take(address(takerModule), maker, uint160(BORROW), solver, data);

        assertEq(satUSD.balanceOf(maker), MAKER_SAVINGS, "not a single wei of the maker's own funds moved");
    }

    /// Same guard on the collateral leg.
    function test_collateralLeg_isAlsoMeasured() public {
        coll.mint(maker, 10 ether); // maker's own collateral, unrelated to the order
        xapp.setDeliveryBps(0);

        bytes memory data = _collData();
        vm.prank(maker);
        permit3.approveTaker(settlement, address(takerModule), keccak256(data), uint160(1 ether), 0);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(RiverProceeds.InsufficientProceeds.selector, 0, 1 ether));
        permit3.take(address(takerModule), maker, uint160(1 ether), solver, data);

        assertEq(coll.balanceOf(maker), 10 ether, "maker's own collateral intact");
    }

    /// Over-delivery (fee added to debt rather than netted from the mint) is fine:
    /// the solver gets exactly the signed amount and the surplus stays with the maker.
    function test_overDelivery_surplusStaysWithMaker() public {
        xapp.setDeliveryBps(10_500);

        _take(_borrowData(), BORROW);

        assertEq(satUSD.balanceOf(solver), BORROW, "solver paid exactly the signed amount");
        assertEq(satUSD.balanceOf(maker), MAKER_SAVINGS + (BORROW * 500) / 10_000, "surplus kept by the maker");
    }

    // ──────────────── The Hemi direction (fork-validated) ────────────────

    /// The deployed Hemi diamond delivers value-out to msg.sender — the MODULE —
    /// not to `account`. The direction-agnostic settle pays the solver from the
    /// module's own delta; the maker's wallet is never touched.
    function test_borrow_hemiDirection_paysFromModuleDelta() public {
        xapp.setMintToCaller(true);

        _take(_borrowData(), BORROW);

        assertEq(satUSD.balanceOf(solver), BORROW, "solver paid from the module-held mint");
        assertEq(satUSD.balanceOf(maker), MAKER_SAVINGS, "maker wallet untouched");
        assertEq(satUSD.balanceOf(address(takerModule)), 0, "module ends empty");
    }

    /// Hemi direction with over-delivery: the module-held surplus is the maker's
    /// and is swept there, never left on the shared module.
    function test_hemiDirection_moduleSurplusSweptToMaker() public {
        xapp.setMintToCaller(true);
        xapp.setDeliveryBps(10_500);

        _take(_borrowData(), BORROW);

        assertEq(satUSD.balanceOf(solver), BORROW, "solver paid exactly the signed amount");
        assertEq(satUSD.balanceOf(maker), MAKER_SAVINGS + (BORROW * 500) / 10_000, "module surplus swept to maker");
        assertEq(satUSD.balanceOf(address(takerModule)), 0, "module ends empty");
    }
}
