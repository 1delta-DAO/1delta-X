// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

import {LiquityV2AddCollModule, LiquityV2TakerModule} from "../../src/LiquityV2Modules.sol";
import {ILiquityV2TroveManager, LatestTroveData} from "../../src/interfaces/ILiquityV2.sol";

/// @dev The open/onboarding surface the leverage flow needs beyond the module
///      interface: a plain `openTrove` (never a zapper — zappers capture the
///      trove by salting the id and installing themselves as managers) plus the
///      two per-trove manager grants that map onto MAKE/TAKE.
interface IBorrowerOpsLeverage {
    function openTrove(
        address _owner,
        uint256 _ownerIndex,
        uint256 _collAmount,
        uint256 _boldAmount,
        uint256 _upperHint,
        uint256 _lowerHint,
        uint256 _annualInterestRate,
        uint256 _maxUpfrontFee,
        address _addManager,
        address _removeManager,
        address _receiver
    ) external returns (uint256);

    function setAddManager(uint256 _troveId, address _manager) external;
    function setRemoveManagerWithReceiver(uint256 _troveId, address _manager, address _receiver) external;
}

/// @dev Leverage open on Liquity V2 (Ethereum mainnet WETH branch): the maker
///      signs ONE order whose items add WETH collateral to their trove (MAKE)
///      and borrow BOLD against it (TAKE). A solver funded with nothing but the
///      collateral token fills it and walks away with the borrow proceeds.
///
///        tokenIn  = BOLD (maker gives — sourced entirely from the borrow item)
///        tokenOut = WETH (solver gives → forwarded into the add-collateral item)
///
///      Items:
///        [0] MAKE  LiquityV2AddCollModule  addColl(troveId, WETH)
///        [1] TAKE  LiquityV2TakerModule    withdrawBold(troveId) — op 0
///
///      Liquity needs an EXISTING trove (no on-behalf open), so setUp opens a
///      minimal one for the maker through the real BorrowerOperations: 10 WETH
///      collateral, MIN_DEBT (2000 BOLD), then grants the modules their per-trove
///      manager roles exactly as the README documents.
contract LiquityV2LeverageTest is CoreSettlementBase {
    // ── Verified Ethereum mainnet addresses (Liquity V2, WETH branch) — same
    //    set as test/fork/LiquityV2ForkAuth.t.sol, pinned at the same block. ──
    address internal constant TROVE_MANAGER = 0x7bcb64B2c9206a5B699eD43363f6F98D4776Cf5A;
    address internal constant BORROWER_OPS = 0x372ABD1810eAF23Cb9D941BbE7596DFb2c46BC65;
    address internal constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;

    /// @dev WETH branch: coll AND the 0.0375-WETH gas compensation are both WETH.
    uint256 internal constant ETH_GAS_COMPENSATION = 0.0375 ether;
    uint256 internal constant OPEN_COLL = 10 ether; //   trove opened in setUp
    uint256 internal constant OPEN_DEBT = 2000e18; //    MIN_DEBT
    /// @dev High rate → the sorted-troves insert with empty hints lands at the
    ///      head after O(1) traversal instead of walking the whole branch list
    ///      over RPC. Bounds: [0.5%, 250%].
    uint256 internal constant INTEREST_RATE = 0.25e18;

    LiquityV2AddCollModule addCollModule;
    LiquityV2TakerModule takerModule;
    uint256 troveId;

    /// @dev Liquity V2 deployed long after the default 22M pin; use the block the
    ///      fork-auth suite verified the branch addresses at.
    function _forkBlock() internal view virtual override returns (uint256) {
        return 25_600_000;
    }

    function setUp() public virtual override {
        super.setUp();

        addCollModule = new LiquityV2AddCollModule(address(permit3), address(settlement));
        takerModule = new LiquityV2TakerModule(address(permit3));

        vm.label(address(addCollModule), "liquityAddCollModule");
        vm.label(address(takerModule), "liquityTakerModule");
        vm.label(TROVE_MANAGER, "troveManager");
        vm.label(BORROWER_OPS, "borrowerOperations");
        vm.label(BOLD, "BOLD");

        // ── Open the maker's trove through the real BorrowerOperations. ──
        deal(WETH, maker, OPEN_COLL + ETH_GAS_COMPENSATION);
        vm.startPrank(maker);
        IERC20(WETH).approve(BORROWER_OPS, type(uint256).max);
        troveId = IBorrowerOpsLeverage(BORROWER_OPS).openTrove(
            maker, //                     _owner
            0, //                         _ownerIndex
            OPEN_COLL,
            OPEN_DEBT,
            0, //                         _upperHint
            0, //                         _lowerHint
            INTEREST_RATE,
            type(uint256).max, //         _maxUpfrontFee
            address(0), //                _addManager    (granted below, as documented)
            address(0), //                _removeManager
            address(0) //                 _receiver
        );

        // Onboard the modules exactly as the README documents:
        //   add-manager  → MAKE legs (addColl / repayBold)
        //   remove-manager + receiver = module → TAKE legs (withdrawBold / withdrawColl)
        IBorrowerOpsLeverage(BORROWER_OPS).setAddManager(troveId, address(addCollModule));
        IBorrowerOpsLeverage(BORROWER_OPS).setRemoveManagerWithReceiver(
            troveId, address(takerModule), address(takerModule)
        );

        // Dump the BOLD minted at open so the maker wallet starts clean.
        IERC20(BOLD).transfer(address(0xdead), IERC20(BOLD).balanceOf(maker));
        vm.stopPrank();
    }

    // ──────────────────── Helpers ────────────────────

    function _borrowData(uint256 maxUpfrontFee) internal view returns (bytes memory) {
        return abi.encode(uint8(0), TROVE_MANAGER, troveId, BOLD, maxUpfrontFee);
    }

    function _addCollData() internal view returns (bytes memory) {
        return abi.encode(TROVE_MANAGER, troveId, WETH);
    }

    function _buildLeverageOrder(uint256 collateralIn, uint256 borrowOut) internal view returns (Order memory) {
        Item[] memory items = new Item[](2);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(addCollModule),
            amount: collateralIn,
            recipient: address(0),
            data: _addCollData()
        });
        items[1] = Item({
            op: ItemOp.TAKE,
            module: address(takerModule),
            amount: borrowOut,
            recipient: address(0),
            data: _borrowData(type(uint256).max)
        });
        return _order(maker, 1, BOLD, WETH, borrowOut, collateralIn, items);
    }

    function _approveMakerLeverageSide(uint256 collateralIn, uint256 borrowOut) internal {
        vm.startPrank(maker);
        // WETH: the add-coll module pulls the collateral via Permit3 during MAKE.
        permit3.approveToken(address(addCollModule), WETH, uint160(collateralIn), 0);
        // Permit3 taker gate on the exact borrow position + amount.
        permit3.approveTaker(address(settlement), keccak256(_borrowData(type(uint256).max)), uint160(borrowOut), 0);
        // BOLD fallback allowance for the tokenIn shortfall path — never triggers
        // here (the borrow fully funds tokenIn) but keeps the flow safe.
        IERC20(BOLD).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), BOLD, uint160(borrowOut), 0);
        vm.stopPrank();
    }

    function _troveData() internal view returns (LatestTroveData memory) {
        return ILiquityV2TroveManager(TROVE_MANAGER).getLatestTroveData(troveId);
    }

    // ──────────────────── Full leverage open ────────────────────

    function test_leverage_addColl_borrow_liquityV2() public {
        uint256 collateralIn = 1 ether; //   solver funds → maker's trove
        uint256 borrowOut = 1000e18; //      maker borrows → solver receives

        deal(WETH, solver, collateralIn);
        _approveMakerLeverageSide(collateralIn, borrowOut);
        _approveSolverSide(collateralIn, WETH);

        Order memory order = _buildLeverageOrder(collateralIn, borrowOut);
        bytes memory sig = _sign(order);

        LatestTroveData memory before = _troveData();

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, borrowOut)[0];

        assertEq(paid, collateralIn, "solver paid exactly the collateral leg");

        // Maker: trove grew by the collateral and by (borrow + upfront fee) debt.
        LatestTroveData memory after_ = _troveData();
        assertEq(after_.entireColl - before.entireColl, collateralIn, "trove coll up by collateralIn");
        assertGe(after_.entireDebt - before.entireDebt, borrowOut, "trove debt up by at least the borrow");
        // Upfront fee = ~7 days of avg branch interest — well under 2% of the draw.
        assertLt(after_.entireDebt - before.entireDebt, borrowOut + borrowOut / 50, "debt delta = borrow + small fee");

        // Solver: spent WETH, received the borrow proceeds.
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver WETH spent");
        assertEq(IERC20(BOLD).balanceOf(solver), borrowOut, "solver received BOLD");

        // Maker wallet untouched — both legs settled inside the position.
        assertEq(IERC20(WETH).balanceOf(maker), 0, "maker WETH forwarded into addColl");
        assertEq(IERC20(BOLD).balanceOf(maker), 0, "maker BOLD forwarded out via borrow");

        // Settlement & modules end empty.
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(BOLD).balanceOf(address(settlement)), 0, "settlement BOLD drained");
        assertEq(IERC20(WETH).balanceOf(address(addCollModule)), 0, "addColl module WETH drained");
        assertEq(IERC20(BOLD).balanceOf(address(takerModule)), 0, "taker module BOLD drained");
    }

    // ──────────────────── Partial fill (pro-rata) ────────────────────

    function test_leverage_partialFill_liquityV2() public {
        uint256 collateralIn = 1 ether;
        uint256 borrowOut = 1000e18;

        deal(WETH, solver, collateralIn);
        _approveMakerLeverageSide(collateralIn, borrowOut);
        _approveSolverSide(collateralIn, WETH);

        Order memory order = _buildLeverageOrder(collateralIn, borrowOut);
        bytes memory sig = _sign(order);

        LatestTroveData memory before = _troveData();

        // Fill HALF the order — items scale pro-rata: half the collateral in,
        // half the borrow out.
        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, borrowOut / 2)[0];

        assertEq(paid, collateralIn / 2, "solver paid half the collateral");

        LatestTroveData memory after_ = _troveData();
        assertEq(after_.entireColl - before.entireColl, collateralIn / 2, "trove coll up by half");
        assertGe(after_.entireDebt - before.entireDebt, borrowOut / 2, "trove debt up by half the borrow");
        assertLt(after_.entireDebt - before.entireDebt, borrowOut / 2 + borrowOut / 100, "no over-borrow");

        assertEq(IERC20(WETH).balanceOf(solver), collateralIn / 2, "solver kept the unfilled half");
        assertEq(IERC20(BOLD).balanceOf(solver), borrowOut / 2, "solver received half the borrow");

        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(BOLD).balanceOf(address(settlement)), 0, "settlement BOLD drained");
    }
}
