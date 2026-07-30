// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Permit3} from "@core/permit3/Permit3.sol";
import {Settlement, Order, Item, ItemOp} from "@core/settlement/Settlement.sol";

import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

import {RiverAddCollModule, RiverTakerModule, RiverOpenModule} from "../../src/RiverModules.sol";
import {IRiverXApp, IRiverTroveManager} from "../../src/interfaces/IRiver.sol";

/// @dev HEMI-mainnet fork tests for the River (Satoshi Protocol) modules — the
/// first execution of the package against the deployed SatoshiXApp diamond (the
/// README's "validate against the deployed diamond" caveat).
///
/// Addresses from docs.river.inc (Hemi "Deployed Contracts"), verified live in
/// these tests by the operations themselves:
///   • SatoshiXApp diamond  0x07BbC5A83B83a5C440D1CAedBF1081426d0AA4Ec
///   • satUSD               0xb4818BB69478730EF4e33Cc068dD94278e2766cB
///   • WETH (OP-stack)      0x4200000000000000000000000000000000000006
///   • WETH TroveManager    0xb655775C4C7C6e0C2002935133c950FB89974928
///
/// Forks LATEST (no pin): the public Hemi RPC is not archival at depth, and the
/// assertions are all relative deltas, so drifting state is tolerated by design.
/// Set HEMI_RPC_URL to override the endpoint.
contract RiverLeverageTest is CoreSettlementBase {
    address constant XAPP = 0x07BbC5A83B83a5C440D1CAedBF1081426d0AA4Ec;
    address constant SAT_USD = 0xb4818BB69478730EF4e33Cc068dD94278e2766cB;
    address constant HEMI_WETH = 0x4200000000000000000000000000000000000006;
    address constant TM = 0xb655775C4C7C6e0C2002935133c950FB89974928;

    uint256 constant MAX_FEE = 0.05e18; // 5% fee ceiling on mint ops

    RiverAddCollModule addCollModule;
    RiverTakerModule takerModule;
    RiverOpenModule openModule;

    function setUp() public override {
        _forkHemi();

        permit3 = new Permit3();
        settlement = new Settlement(address(permit3));

        addCollModule = new RiverAddCollModule(address(permit3), address(settlement));
        takerModule = new RiverTakerModule(address(permit3));
        openModule = new RiverOpenModule(address(permit3));

        WETH = HEMI_WETH; // reuse the base helpers' WETH slot for labels/approvals
        vm.label(XAPP, "satoshiXApp");
        vm.label(SAT_USD, "satUSD");
        vm.label(TM, "troveManagerWETH");
        vm.label(maker, "maker");
        vm.label(solver, "solver");

        // Bare ERC20 approves to Permit3 (the base setUp normally does this for
        // the mainnet tokens; we are on Hemi).
        vm.startPrank(maker);
        IERC20(HEMI_WETH).approve(address(permit3), type(uint256).max);
        IERC20(SAT_USD).approve(address(permit3), type(uint256).max);
        vm.stopPrank();
    }

    function _forkHemi() internal {
        try vm.envString("HEMI_RPC_URL") returns (string memory v) {
            if (bytes(v).length > 0) {
                vm.createSelectFork(v);
                return;
            }
        } catch {}
        vm.createSelectFork("https://rpc.hemi.network/rpc");
    }

    // ──────────────────── Helpers ────────────────────

    function _borrowData(uint256 maxFee) internal pure returns (bytes memory) {
        // op 0 = Borrow: (op, xapp, tm, debtToken, maxFee, upperHint, lowerHint)
        return abi.encode(uint8(0), XAPP, TM, SAT_USD, maxFee, address(0), address(0));
    }

    /// @dev Open the maker's trove DIRECTLY (maker calls the diamond itself) so
    ///      the leverage tests start from an existing position. Sized generously:
    ///      2 WETH collateral vs 2000 satUSD debt keeps ICR far above minimums.
    function _openTroveDirect(uint256 coll, uint256 debt) internal {
        deal(HEMI_WETH, maker, coll);
        vm.startPrank(maker);
        IERC20(HEMI_WETH).approve(XAPP, coll);
        IRiverXApp(XAPP).openTrove(TM, maker, MAX_FEE, coll, debt, address(0), address(0));
        // The minted satUSD is incidental to these tests — park it away so the
        // sweep-delta assertions start from a clean maker balance.
        IERC20(SAT_USD).transfer(address(0xD1ED), IERC20(SAT_USD).balanceOf(maker));
        vm.stopPrank();
    }

    function _approveMakerLeverageSide(uint256 collIn, uint256 borrowOut, bool delegate) internal {
        vm.startPrank(maker);
        // MAKE addColl pulls WETH from the maker via Permit3 (module = spender).
        permit3.approveToken(address(addCollModule), HEMI_WETH, uint160(collIn), 0);
        // The borrow proceeds land ON the maker (CDP, no receiver) and are swept
        // by the taker module via Permit3 — module = spender on satUSD.
        permit3.approveToken(address(takerModule), SAT_USD, uint160(borrowOut), 0);
        // Taker gate: the settlement is the spender-keyed taker; ref = borrow data.
        permit3.approveTaker(address(settlement), keccak256(_borrowData(MAX_FEE)), uint160(borrowOut), 0);
        // satUSD shortfall fallback for the tokenIn payout (never triggers).
        permit3.approveToken(address(settlement), SAT_USD, uint160(borrowOut), 0);
        // Diamond-wide delegation. FORK FINDING: the deployed diamond enforces
        // caller-or-delegate on EVERY op, value-in included — addColl needs the
        // grant too ("Caller not approved" otherwise).
        if (delegate) {
            IRiverXApp(XAPP).setDelegateApproval(address(takerModule), true);
            IRiverXApp(XAPP).setDelegateApproval(address(addCollModule), true);
        }
        vm.stopPrank();
    }

    function _buildLeverageOrder(uint256 nonce, uint256 collIn, uint256 borrowOut)
        internal
        view
        returns (Order memory order)
    {
        Item[] memory items = new Item[](2);
        items[0] = Item(
            ItemOp.MAKE,
            address(addCollModule),
            collIn,
            address(0),
            abi.encode(XAPP, TM, HEMI_WETH, address(0), address(0))
        );
        items[1] = Item(ItemOp.TAKE, address(takerModule), borrowOut, address(0), _borrowData(MAX_FEE));
        order = _order(maker, nonce, SAT_USD, HEMI_WETH, borrowOut, collIn, items);
    }

    function _troveState() internal view returns (uint256 debt, uint256 coll) {
        (debt, coll,,) = IRiverTroveManager(TM).getEntireDebtAndColl(maker);
    }

    // ──────────────────── Full leverage: addColl + borrow ────────────────────

    function test_leverage_addColl_borrow_river() public {
        _openTroveDirect(2 ether, 2000e18);
        (uint256 debt0, uint256 coll0) = _troveState();

        uint256 collIn = 1 ether;
        uint256 borrowOut = 500e18;
        deal(HEMI_WETH, solver, collIn);
        _approveMakerLeverageSide(collIn, borrowOut, true);
        _approveSolverSide(collIn, HEMI_WETH);

        Order memory order = _buildLeverageOrder(1, collIn, borrowOut);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, borrowOut)[0];

        assertEq(paid, collIn, "solver paid 1 WETH of collateral");
        (uint256 debt1, uint256 coll1) = _troveState();
        assertEq(coll1 - coll0, collIn, "trove collateral up by the deposit");
        // Debt rises by the borrow plus the one-off mint fee (≤ MAX_FEE).
        assertGe(debt1 - debt0, borrowOut, "debt >= borrowed amount");
        assertLe(debt1 - debt0, (borrowOut * (1e18 + MAX_FEE)) / 1e18, "fee within ceiling");
        assertEq(IERC20(SAT_USD).balanceOf(solver), borrowOut, "solver received the satUSD");
        assertEq(IERC20(HEMI_WETH).balanceOf(maker), 0, "maker WETH forwarded into addColl");
        assertEq(IERC20(SAT_USD).balanceOf(maker), 0, "borrow fully swept, nothing parked on the maker");
        assertEq(IERC20(SAT_USD).balanceOf(address(settlement)), 0, "settlement drained");
        assertEq(IERC20(HEMI_WETH).balanceOf(address(addCollModule)), 0, "addColl module drained");
    }

    // ──────────────────── Partial fill (pro-rata items) ────────────────────

    function test_partialFill_leverage_river() public {
        _openTroveDirect(2 ether, 2000e18);
        (uint256 debt0, uint256 coll0) = _troveState();

        uint256 collIn = 1 ether;
        uint256 borrowOut = 500e18;
        uint256 half = borrowOut / 2;
        deal(HEMI_WETH, solver, collIn);
        _approveMakerLeverageSide(collIn, borrowOut, true);
        _approveSolverSide(collIn, HEMI_WETH);

        Order memory order = _buildLeverageOrder(2, collIn, borrowOut);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, half);
        (, uint256 collMid) = _troveState();
        assertEq(collMid - coll0, collIn / 2, "half the collateral added");
        assertEq(IERC20(SAT_USD).balanceOf(solver), half, "half the borrow swept to solver");

        vm.prank(solver);
        settlement.fill(order, sig, borrowOut - half);
        (uint256 debt2, uint256 coll2) = _troveState();
        assertEq(coll2 - coll0, collIn, "collateral complete");
        assertGe(debt2 - debt0, borrowOut, "debt complete (plus fee)");
        assertEq(IERC20(SAT_USD).balanceOf(solver), borrowOut, "full borrow with solver");
    }

    // ──────────────────── Level B: atomic open-trove ────────────────────

    /// @dev The composite open: solver delivers the collateral, {RiverOpenModule}
    ///      pulls it + opens the trove + sweeps the minted satUSD to the pool for
    ///      the tokenIn payout. Full-fill only (composite side leg in `data`).
    function test_openTrove_viaOpenModule_river() public {
        uint256 side = 2 ether; //     collateral into the fresh trove
        uint256 debt = 2000e18; //     satUSD minted → solver
        deal(HEMI_WETH, solver, side);

        bytes memory openData = abi.encode(
            RiverOpenModule.OpenData(XAPP, TM, HEMI_WETH, SAT_USD, MAX_FEE, side, address(0), address(0), debt)
        );

        vm.startPrank(maker);
        permit3.approveToken(address(openModule), HEMI_WETH, uint160(side), 0);
        permit3.approveToken(address(openModule), SAT_USD, uint160(debt), 0);
        permit3.approveTaker(address(settlement), keccak256(openData), uint160(debt), 0);
        permit3.approveToken(address(settlement), SAT_USD, uint160(debt), 0);
        IRiverXApp(XAPP).setDelegateApproval(address(openModule), true);
        vm.stopPrank();
        _approveSolverSide(side, HEMI_WETH);

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE, address(openModule), debt, address(0), openData);
        Order memory order = _order(maker, 3, SAT_USD, HEMI_WETH, debt, side, items);
        order.minFillAnchor = debt; // composite ⇒ full-fill only
        bytes memory sig = _sign(order);

        assertEq(IRiverTroveManager(TM).getTroveStatus(maker), 0, "no trove yet");

        vm.prank(solver);
        settlement.fill(order, sig, debt);

        assertEq(IRiverTroveManager(TM).getTroveStatus(maker), 1, "trove active");
        (uint256 debtNow, uint256 collNow) = _troveState();
        assertEq(collNow, side, "trove holds the delivered collateral");
        assertGe(debtNow, debt, "debt >= minted amount");
        assertEq(IERC20(SAT_USD).balanceOf(solver), debt, "solver received the minted satUSD");
        assertEq(IERC20(HEMI_WETH).balanceOf(address(openModule)), 0, "open module drained");
    }

    // ──────────────────── Delegation is the wall ────────────────────

    function test_borrow_withoutDelegate_reverts() public {
        _openTroveDirect(2 ether, 2000e18);
        uint256 collIn = 1 ether;
        uint256 borrowOut = 500e18;
        deal(HEMI_WETH, solver, collIn);
        _approveMakerLeverageSide(collIn, borrowOut, false); // NO setDelegateApproval
        _approveSolverSide(collIn, HEMI_WETH);

        Order memory order = _buildLeverageOrder(4, collIn, borrowOut);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(order, sig, borrowOut);

        assertEq(IERC20(SAT_USD).balanceOf(solver), 0, "nothing minted");
    }
}
