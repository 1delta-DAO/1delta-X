// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {Market, CollateralParams, Offer} from "../src/interfaces/IMidnight.sol";
import {MidnightLoopCallback, IUniV3Router} from "../src/MidnightLoopCallback.sol";
import {MidnightMock, MockERC20, MockRatifier} from "./shared/MidnightMock.sol";

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @dev Uniswap-v3-shaped mock swapper. Pulls `amountIn` of `tokenIn` from the
///      caller and pays out `amountIn * rateNum / rateDen` of `tokenOut` from its
///      own (pre-funded) inventory. Selector matches
///      {IUniV3Router.exactInputSingle} so {MidnightLoopCallback} can call it.
contract MockSwapRouter {
    uint256 public rateNum = 1;
    uint256 public rateDen = 1;

    function setRate(uint256 n, uint256 d) external {
        rateNum = n;
        rateDen = d;
    }

    function exactInputSingle(IUniV3Router.ExactInputSingleParams calldata p) external returns (uint256 amountOut) {
        IERC20Like(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        amountOut = (p.amountIn * rateNum) / rateDen;
        require(amountOut >= p.amountOutMinimum, "slippage");
        IERC20Like(p.tokenOut).transfer(p.recipient, amountOut);
    }
}

/// @notice Option A ("offer a rate to borrow, loop on fill") end-to-end against a
///         faithful `MidnightMock`. A borrower rests a `buy == false` offer with
///         `callback = MidnightLoopCallback`; a lender hits it via `take`; the
///         onSell callback swaps the borrowed loan token to collateral and supplies
///         it into the borrower's own position — BEFORE the mock's solvency check —
///         building a leveraged position in one fill with no per-fill signature
///         and no settlement. The borrower DOES grant the callback
///         `setIsAuthorized`: the deployed venue gates `supplyCollateral` on it
///         (audit 2026-09-30 L-ML-1 — this suite used to pass without the grant
///         only because the mock skipped the check).
contract MidnightLoopCallbackTest is Test {
    MidnightMock midnight;
    MockERC20 COLL; // collateral, 18dp
    MockERC20 LOAN; // loan, 18dp (par 1:1 with COLL for legible leverage math)
    MockSwapRouter router;
    MidnightLoopCallback loopCb;
    MockRatifier ratifier;

    address alice = address(0xA11CE); // borrower / offer maker
    address bob = address(0xB0B); //     lender / taker

    uint256 constant SEED = 100e18; // Alice's starting collateral
    uint256 constant LLTV = 0.8e18;

    function setUp() public {
        midnight = new MidnightMock();
        COLL = new MockERC20("Collateral", "COLL", 18);
        LOAN = new MockERC20("Loan", "LOAN", 18);
        router = new MockSwapRouter();
        loopCb = new MidnightLoopCallback(address(midnight), address(router));
        ratifier = new MockRatifier();

        // Alice's one-time grants: her offer ratifier, and the loop callback, which
        // calls `supplyCollateral(onBehalf = alice)` — auth-gated on the venue.
        vm.startPrank(alice);
        midnight.setIsAuthorized(address(ratifier), true, alice);
        midnight.setIsAuthorized(address(loopCb), true, alice);
        vm.stopPrank();

        // Par pricing (same decimals) so 1 COLL backs 1 LOAN of value.
        midnight.setPrice(address(COLL), 1e18);

        // Seed Alice's Midnight collateral position.
        COLL.mint(address(this), SEED);
        COLL.approve(address(midnight), type(uint256).max);
        midnight.seedCollateral(_market(), alice, 0, SEED);

        // Fund the router's collateral inventory and the lender's loan balance.
        COLL.mint(address(router), 1_000e18);
        LOAN.mint(bob, 1_000e18);
        vm.prank(bob);
        LOAN.approve(address(midnight), type(uint256).max);
    }

    // ──────────────────── the headline: borrow-and-loop ────────────────────

    function test_loop_buildsHealthyLeveragedPosition() public {
        // Max debt against SEED alone is SEED*LLTV = 80; borrowing 300 is only
        // solvent BECAUSE the loop converts the proceeds to collateral in-fill.
        uint256 borrowUnits = 300e18;

        vm.prank(bob);
        midnight.take(_borrowOffer(), "", borrowUnits, bob, address(0), address(0), "");

        assertEq(_debtOf(alice), borrowUnits, "debt == borrowed units");
        assertEq(_collateralOf(alice), SEED + borrowUnits, "collateral == seed + looped proceeds");
        assertTrue(midnight.isHealthy(_market(), _id(), alice), "position solvent post-loop");
        // Proceeds fully converted — nothing stranded in the callback or lender path.
        assertEq(LOAN.balanceOf(address(loopCb)), 0, "no loan token stranded in callback");
        assertEq(LOAN.balanceOf(bob), 1_000e18 - borrowUnits, "lender funded the borrow");
    }

    /// @dev The callback runs, but a lossy swap under-collateralizes the new debt,
    ///      so Midnight's POST-callback solvency check reverts the whole fill —
    ///      proving the check is real and fires after the loop.
    function test_loop_underCollateralized_reverts() public {
        router.setRate(1, 10); // 300 loan → 30 coll ⇒ (100+30)*0.8 = 104 < 300 debt
        uint256 borrowUnits = 300e18;

        vm.prank(bob);
        vm.expectRevert(bytes("SellerIsLiquidatable"));
        midnight.take(_borrowOffer(), "", borrowUnits, bob, address(0), address(0), "");

        // Reverted atomically: no debt, collateral back to seed only.
        assertEq(_debtOf(alice), 0, "no debt after revert");
        assertEq(_collateralOf(alice), SEED, "collateral unchanged after revert");
    }

    /// @dev A slippage floor the loop can't meet reverts inside the swap itself
    ///      (still atomic — the borrow never sticks).
    function test_loop_slippageFloor_reverts() public {
        uint256 borrowUnits = 300e18;
        Offer memory o = _borrowOffer();
        // Demand a 1.5 COLL/LOAN rate out of a 1:1 swap → router reverts "slippage".
        o.callbackData = abi.encode(uint256(0), uint24(500), uint256(1.5e18));

        vm.prank(bob);
        vm.expectRevert(bytes("slippage"));
        midnight.take(o, "", borrowUnits, bob, address(0), address(0), "");
    }

    function test_onSell_onlyMidnight() public {
        vm.expectRevert(MidnightLoopCallback.OnlyMidnight.selector);
        loopCb.onSell(
            bytes32(0),
            _market(),
            1e18,
            1e18,
            0,
            alice,
            address(loopCb),
            abi.encode(uint256(0), uint24(500), uint256(0))
        );
    }

    // ──────────────────── audit 2026-09-30 ────────────────────

    /// L-ML-1: the deployed venue gates `supplyCollateral` on the borrower's grant,
    /// so a loop offer whose maker did NOT authorize the callback cannot fill. The
    /// pre-fix mock let this through, which is how the "no grant needed" claim
    /// survived in the docs.
    function test_audit_L_ML_1_loopNeedsCallbackAuthorization() public {
        vm.prank(alice);
        midnight.setIsAuthorized(address(loopCb), false, alice);

        vm.prank(bob);
        vm.expectRevert(MidnightMock.Unauthorized.selector);
        midnight.take(_borrowOffer(), "", 10e18, bob, address(0), address(0), "");
    }

    /// L-ML-4: the floor is a RATE scaled to each take. A borrower with headroom
    /// (so Midnight's whole-position solvency check is no backstop) signs a 0.95
    /// COLL/LOAN floor; a lender sandwiches the pool to 0.5 and takes the whole
    /// offer. Under the old absolute reading the signed word (0.95e18 wei) was a
    /// trivially-met floor and the borrower lost half the borrow to the sandwich.
    function test_audit_L_ML_4_largeTakeBelowRateReverts() public {
        _giveAliceHeadroom();
        router.setRate(1, 2); // sandwiched pool: 0.5 COLL per LOAN
        Offer memory o = _borrowOffer();
        o.callbackData = abi.encode(uint256(0), uint24(500), uint256(0.95e18));

        vm.prank(bob);
        vm.expectRevert(bytes("slippage"));
        midnight.take(o, "", 300e18, bob, address(0), address(0), "");
    }

    /// L-ML-4: the same rate floor admits partial takes of any size at a fair
    /// rate — an absolute floor sized for the whole offer reverted every one.
    function test_audit_L_ML_4_partialTakesHonourTheRate() public {
        Offer memory o = _borrowOffer();
        o.callbackData = abi.encode(uint256(0), uint24(500), uint256(0.95e18));
        o.maxUnits = 300e18;

        vm.prank(bob);
        midnight.take(o, "", 10e18, bob, address(0), address(0), "");
        vm.prank(bob);
        midnight.take(o, "", 90e18, bob, address(0), address(0), "");

        assertEq(_debtOf(alice), 100e18, "two partial takes");
        assertEq(_collateralOf(alice), SEED + 100e18, "each take looped at the fair rate");
    }

    /// L-ML-4: the scaled floor rounds UP, so a take can never clear a floor
    /// below the signed rate by rounding.
    function test_audit_L_ML_4_floorRoundsUp() public {
        _giveAliceHeadroom();
        // Router pays 1 wei less than the 1:1 rate on every swap.
        router.setRate(1e18 - 1, 1e18);
        Offer memory o = _borrowOffer();
        o.callbackData = abi.encode(uint256(0), uint24(500), uint256(1e18));

        vm.prank(bob);
        vm.expectRevert(bytes("slippage"));
        midnight.take(o, "", 3e18, bob, address(0), address(0), "");
    }

    function _giveAliceHeadroom() internal {
        COLL.mint(address(this), 10_000e18);
        midnight.seedCollateral(_market(), alice, 0, 10_000e18);
    }

    // ──────────────────── builders ────────────────────

    function _borrowOffer() internal view returns (Offer memory o) {
        o = Offer({
            market: _market(),
            buy: false, // maker is the seller/borrower
            maker: alice,
            start: 0,
            expiry: 1_900_000_000,
            tick: 0,
            group: bytes32(0),
            callback: address(loopCb),
            // collateralIndex, dexFee, minRateWad
            callbackData: abi.encode(uint256(0), uint24(500), uint256(0)),
            receiverIfMakerIsSeller: address(loopCb), // proceeds land where the loop runs
            ratifier: address(ratifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0, // exactly one cap (Midnight `InvalidOfferCaps`)
            continuousFeeCap: 0
        });
    }

    function _market() internal view returns (Market memory m) {
        CollateralParams[] memory cp = new CollateralParams[](1);
        cp[0] =
            CollateralParams({token: address(COLL), lltv: LLTV, liquidationCursor: 0.05e18, oracle: address(0x0AC1E)});
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

    function _id() internal view returns (bytes32) {
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

    function _debtOf(address who) internal view returns (uint256) {
        return midnight.debt(_id(), who);
    }

    function _collateralOf(address who) internal view returns (uint256) {
        return midnight.collateral(_id(), who, 0);
    }
}
