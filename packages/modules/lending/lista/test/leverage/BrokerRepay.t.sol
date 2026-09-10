// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {ListaBrokerModule} from "../../src/ListaBrokerModule.sol";
import {IListaBroker} from "../../src/interfaces/ILista.sol";
import {ListaModulesBase, IListaBrokerViews} from "../shared/ListaModulesBase.t.sol";

/// @dev Direct (msg.sender-only) broker entrypoints — out of module scope but
///      exactly right for SEEDING debt on the fork, plus the position view the
///      assertions need. `userFixedPositions` returns `FixedLoanPosition[]`
///      (8 static uint256 fields), which ABI-decodes as `uint256[8][]` —
///      field 0 is the `posId` a fixed repay targets.
interface IListaBrokerSeed {
    function borrow(uint256 amount) external; //  flex
    function borrow(uint256 amount, uint256 termId) external; //  fixed-term
    function userFixedPositions(address user) external view returns (uint256[8][] memory);
}

/// @dev {ListaBrokerModule}'s PULL-funded repay against the LIVE broker on a
///      BSC fork. (The same contract's pre-funded repay — the other half of the
///      merged body — is covered in `leverage/PreFundOneSided.t.sol`, and its
///      borrow in `leverage/DepositBorrow.t.sol`.) This coverage exists because the module shipped encoding
///      `repay(0, …)` — a convention the deployed broker does not have: every
///      broker `transferFrom`s the LITERAL amount and reverts `ZeroAmount()` on
///      zero (source-verified on the chain-1 impl, pinned here against the
///      forked one). The module now passes the maker-signed ceiling; the broker
///      consumes exactly the live debt and refunds the surplus to the module,
///      which sweeps it to the maker.
contract ListaBrokerRepayTest is ListaModulesBase {
    uint256 constant DYNAMIC_LOAN = type(uint128).max;
    uint256 constant REPAY_ALL = type(uint256).max;

    /// @dev The merged broker module, built by {ListaModulesBase}.
    ListaBrokerModule repayModule;

    function setUp() public override {
        super.setUp();
        repayModule = brokerModule;
    }

    /// @dev Pull-funded repay blob (base = 128: op, broker, loanToken, loanId —
    ///      no tail). Word 0 is the `uint8` op, which is what keeps this blob out
    ///      of the pre-fund descriptor space AND out of the borrow op.
    function _repayData(uint256 loanId) internal pure returns (bytes memory) {
        return abi.encode(uint8(ListaBrokerModule.Op.Repay), BROKER, USD1, loanId);
    }

    /// @dev The maker's grants for the pull-funded repay: the ERC20 approval to
    ///      Permit3 plus the module-scoped Permit3 token allowance — the module
    ///      pulls the signed ceiling via `permit3.transferFrom`.
    function _approveRepay(uint256 ceiling) internal {
        vm.startPrank(maker);
        IERC20(USD1).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), USD1, uint160(ceiling), 0);
        vm.stopPrank();
    }

    // ── FLEX close with overshoot. The maker owes ~1000 USD1 on the dynamic
    //    position and signs a 1500 ceiling; the broker pulls the literal 1500,
    //    retires the debt, refunds ~500 to the module, and the module sweeps it
    //    to the maker. Before the fix this call could not execute at all. ──
    function test_brokerRepay_flex_overshootCapsAtDebt_refundsMaker() public {
        uint256 borrow = 1_000e18;
        uint256 ceiling = 1_500e18;

        _seedCollateral(0.1e18);
        vm.startPrank(maker);
        IListaBrokerSeed(BROKER).borrow(borrow); //  flex debt, proceeds parked away
        IERC20(USD1).transfer(address(0xD1ED), IERC20(USD1).balanceOf(maker));
        vm.stopPrank();

        deal(USD1, maker, ceiling);
        _approveRepay(ceiling);

        uint256 debt = IListaBrokerViews(BROKER).getUserTotalDebt(maker);
        assertGe(debt, borrow, "flex debt seeded");
        uint256 moduleFloor = IERC20(USD1).balanceOf(address(repayModule));

        vm.prank(address(settlement));
        repayModule.makeOnBehalf(maker, ceiling, _repayData(DYNAMIC_LOAN));

        assertEq(IListaBrokerViews(BROKER).getUserTotalDebt(maker), 0, "the flex debt is retired in full");
        // Broker rounding on the normalize/denormalize round-trip can move a wei.
        assertApproxEqAbs(IERC20(USD1).balanceOf(maker), ceiling - debt, 2, "the surplus was swept to the maker");
        assertEq(IERC20(USD1).balanceOf(address(repayModule)), moduleFloor, "module ends where it started");
        assertEq(IERC20(USD1).allowance(address(repayModule), BROKER), 0, "broker approval cleared");
    }

    // ── FIXED close with overshoot. Same shape targeting a fixed posId, closed
    //    same-block (accrued interest 0, early-repay penalty ≈ half the full
    //    7-day term interest — a few tenths of a USD1 on 1000). The position is
    //    removed outright, so the `minLoan` remainder floor cannot trip. ──
    function test_brokerRepay_fixed_closesPosition_sweepsSurplus() public {
        uint256 borrow = 1_000e18;
        uint256 ceiling = 1_100e18;

        _seedCollateral(0.1e18);
        vm.startPrank(maker);
        IListaBrokerSeed(BROKER).borrow(borrow, TERM_7D);
        IERC20(USD1).transfer(address(0xD1ED), IERC20(USD1).balanceOf(maker));
        vm.stopPrank();

        uint256[8][] memory positions = IListaBrokerSeed(BROKER).userFixedPositions(maker);
        assertEq(positions.length, 1, "one fixed position seeded");
        uint256 posId = positions[0][0];

        deal(USD1, maker, ceiling);
        _approveRepay(ceiling);

        vm.prank(address(settlement));
        repayModule.makeOnBehalf(maker, ceiling, _repayData(posId));

        assertEq(IListaBrokerViews(BROKER).getUserTotalDebt(maker), 0, "the fixed debt is retired in full");
        assertEq(IListaBrokerSeed(BROKER).userFixedPositions(maker).length, 0, "the position is removed");
        uint256 consumed = ceiling - IERC20(USD1).balanceOf(maker);
        assertGe(consumed, borrow, "at least the principal was consumed");
        assertLe(consumed, borrow + 2e18, "penalty-only overhead (no interest same-block)");
        assertEq(IERC20(USD1).balanceOf(address(repayModule)), 0, "module drained");
    }

    // ── FULL close via the `repayAll` sentinel. The maker holds BOTH buckets —
    //    a flex position and a fixed position — and one item retires everything:
    //    `repayAll` pulls exactly the live total debt (+ the fixed leg's
    //    early-repay penalty), refunds nothing, and the module sweeps the
    //    un-pulled remainder of the ceiling back to the maker. ──
    function test_brokerRepay_repayAll_closesBothBuckets_sweepsRemainder() public {
        uint256 flexBorrow = 1_000e18;
        uint256 fixedBorrow = 1_000e18;
        uint256 ceiling = 2_500e18;

        _seedCollateral(0.1e18);
        vm.startPrank(maker);
        IListaBrokerSeed(BROKER).borrow(flexBorrow); //          flex bucket
        IListaBrokerSeed(BROKER).borrow(fixedBorrow, TERM_7D); //  fixed bucket
        IERC20(USD1).transfer(address(0xD1ED), IERC20(USD1).balanceOf(maker));
        vm.stopPrank();

        deal(USD1, maker, ceiling);
        _approveRepay(ceiling);

        uint256 debt = IListaBrokerViews(BROKER).getUserTotalDebt(maker);
        assertGe(debt, flexBorrow + fixedBorrow, "both buckets seeded");
        uint256 moduleFloor = IERC20(USD1).balanceOf(address(repayModule));

        vm.prank(address(settlement));
        repayModule.makeOnBehalf(maker, ceiling, _repayData(REPAY_ALL));

        assertEq(IListaBrokerViews(BROKER).getUserTotalDebt(maker), 0, "ALL debt retired in one call");
        assertEq(IListaBrokerSeed(BROKER).userFixedPositions(maker).length, 0, "fixed position removed");
        // `repayAll` pulls debt + the fixed leg's early-repay penalty (same-block:
        // no accrued interest, penalty ≈ half the 7-day term interest).
        uint256 consumed = ceiling - IERC20(USD1).balanceOf(maker);
        assertGe(consumed, debt, "at least the live debt was consumed");
        assertLe(consumed, debt + 5e18, "penalty-only overhead beyond the debt");
        assertEq(IERC20(USD1).balanceOf(address(repayModule)), moduleFloor, "module ends where it started");
        assertEq(IERC20(USD1).allowance(address(repayModule), BROKER), 0, "broker approval cleared");
    }

    // ── The fail-closed cap: `repayAll` takes no amount, so the module's scoped
    //    approval IS the ceiling — a ceiling short of the live debt makes the
    //    broker's exact-`totalDebt` pull revert instead of part-closing. ──
    function test_brokerRepay_repayAll_ceilingBelowDebt_failsClosed() public {
        uint256 borrow = 1_000e18;
        uint256 ceiling = 500e18;

        _seedCollateral(0.1e18);
        vm.startPrank(maker);
        IListaBrokerSeed(BROKER).borrow(borrow);
        IERC20(USD1).transfer(address(0xD1ED), IERC20(USD1).balanceOf(maker));
        vm.stopPrank();

        deal(USD1, maker, ceiling);
        _approveRepay(ceiling);

        // The cap is the module's scoped ERC20 approval, so the failure surfaces
        // as the broker's own `transferFrom` running out of allowance — not as a
        // check in our code. Pinned to that message: if a broker upgrade ever made
        // `repayAll` part-close instead, the maker would be charged the ceiling for
        // a position that stayed open, and this is the line that would notice.
        vm.prank(address(settlement));
        vm.expectRevert(bytes("ERC20: insufficient allowance"));
        repayModule.makeOnBehalf(maker, ceiling, _repayData(REPAY_ALL));
    }

    // ── The venue fact that motivated the fix, pinned against the LIVE broker:
    //    `repay(0, …)` is not a repay-from-balance convention, it is a revert.
    //    If a broker upgrade ever changes this, this pin — not a production
    //    incident — is what says so. ──
    function test_brokerRepay_zeroAmount_revertsOnLiveBroker() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        IListaBroker(BROKER).repay(0, maker);
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        IListaBroker(BROKER).repay(0, uint256(1), maker);
    }
}
