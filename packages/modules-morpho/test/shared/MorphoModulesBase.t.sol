// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {LimitOrder, Item, ItemOp, Validator} from "@core/settlement/LimitOrderSettlement.sol";

import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";
import {Chains, Tokens} from "@coretest/data/LenderRegistry.sol";

import {IMorphoBlue, MarketParams, Position, Id} from "../../src/interfaces/IMorphoBlue.sol";
import {
    MorphoBlueSupplyCollateralModule,
    MorphoBlueRepayModule,
    MorphoBlueWithdrawCollateralModule,
    MorphoBlueBorrowModule
} from "../../src/MorphoBlueModules.sol";

/// @dev Morpho Blue integration harness. Mirrors `AaveModulesBase` but binds to a
/// real Morpho market instead of an Aave pool. The big modelling difference: a
/// Morpho position is NOT tokenised — there is no aToken to read. Collateral and
/// debt are read straight off the singleton via `morpho.position(id, account)`,
/// and borrow shares are converted to assets with Morpho's own virtual-share math
/// (`_borrowAssets`). Authorisation for the taker legs is Morpho-native
/// (`setAuthorization`) rather than Aave credit-delegation / aToken pulls.
abstract contract MorphoModulesBase is CoreSettlementBase {
    // Morpho Blue singleton (mainnet).
    IMorphoBlue constant MORPHO = IMorphoBlue(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

    // Virtual shares/assets — copied from Morpho's SharesMathLib so the test can
    // convert borrow shares back to assets without importing the library.
    uint256 constant VIRTUAL_SHARES = 1e6;
    uint256 constant VIRTUAL_ASSETS = 1;

    MorphoBlueSupplyCollateralModule supplyModule;
    MorphoBlueRepayModule repayModule;
    MorphoBlueWithdrawCollateralModule withdrawModule;
    MorphoBlueBorrowModule borrowModule;

    address WSTETH;

    // The market every test uses: collateral wstETH, loan USDC, 86% LLTV.
    MarketParams marketParams;

    function setUp() public virtual override {
        super.setUp();

        WSTETH = tokens[Chains.ETHEREUM_MAINNET][Tokens.WSTETH];

        marketParams = MarketParams({
            loanToken: USDC,
            collateralToken: WSTETH,
            oracle: 0x48F7E36EB6B826B2dF4B2E630B62Cd25e89E40e2,
            irm: 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC,
            lltv: 860000000000000000
        });

        supplyModule = new MorphoBlueSupplyCollateralModule(address(permit3), address(MORPHO));
        repayModule = new MorphoBlueRepayModule(address(permit3), address(MORPHO));
        withdrawModule = new MorphoBlueWithdrawCollateralModule(address(permit3), address(MORPHO));
        borrowModule = new MorphoBlueBorrowModule(address(permit3), address(MORPHO));

        vm.label(address(MORPHO), "morphoBlue");
        vm.label(address(supplyModule), "morphoSupplyCollateralModule");
        vm.label(address(repayModule), "morphoRepayModule");
        vm.label(address(withdrawModule), "morphoWithdrawCollateralModule");
        vm.label(address(borrowModule), "morphoBorrowModule");
        vm.label(WSTETH, "wstETH");

        // Maker bare-approves wstETH to Permit3 (the supply module pulls it).
        vm.prank(maker);
        IERC20(WSTETH).approve(address(permit3), type(uint256).max);
    }

    // ──────────────────── Market helpers ────────────────────

    function _marketData() internal view returns (bytes memory) {
        return abi.encode(marketParams);
    }

    function _marketId() internal view returns (Id) {
        return Id.wrap(keccak256(abi.encode(marketParams)));
    }

    function _position(address user) internal view returns (Position memory) {
        return MORPHO.position(_marketId(), user);
    }

    function _collateral(address user) internal view returns (uint256) {
        return _position(user).collateral;
    }

    /// @dev Convert the user's live borrow shares to assets with rounding-up, the
    ///      same way Morpho values debt internally.
    function _borrowAssets(address user) internal view returns (uint256) {
        uint256 shares = _position(user).borrowShares;
        if (shares == 0) return 0;
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = MORPHO.market(_marketId());
        uint256 num = shares * (uint256(totalBorrowAssets) + VIRTUAL_ASSETS);
        uint256 den = uint256(totalBorrowShares) + VIRTUAL_SHARES;
        return (num + den - 1) / den; // mulDivUp
    }

    // ──────────────────── Position seeding ────────────────────

    /// @dev Maker supplies `amount` wstETH as collateral (no debt).
    function _seedCollateral(uint256 amount) internal {
        deal(WSTETH, maker, amount);
        vm.startPrank(maker);
        IERC20(WSTETH).approve(address(MORPHO), amount);
        MORPHO.supplyCollateral(marketParams, amount, maker, "");
        vm.stopPrank();
    }

    /// @dev Maker supplies `collateral` wstETH and borrows `debt` USDC against it,
    ///      dumping the proceeds so the wallet starts clean.
    function _openPosition(uint256 collateral, uint256 debt) internal {
        deal(WSTETH, maker, collateral);
        vm.startPrank(maker);
        IERC20(WSTETH).approve(address(MORPHO), collateral);
        MORPHO.supplyCollateral(marketParams, collateral, maker, "");
        // msg.sender == onBehalf, so no authorisation needed for the seed borrow.
        MORPHO.borrow(marketParams, debt, 0, maker, maker);
        IERC20(USDC).transfer(address(0xdead), debt);
        vm.stopPrank();
    }

    // ──────────────────── Approval helpers ────────────────────

    function _approveMakerSupplyBorrowSide(uint256 collateralIn, uint256 borrowOut) internal {
        bytes32 borrowRef = keccak256(_marketData());

        vm.startPrank(maker);
        // wstETH: supply module pulls the collateral via Permit3 during MAKE.
        IERC20(WSTETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(supplyModule), WSTETH, uint160(collateralIn), 0);

        // Morpho-native authorisation: lets the borrow module incur USDC debt on
        // the maker's behalf. The Permit3 taker allowance is what caps the fill.
        MORPHO.setAuthorization(address(borrowModule), true);

        // Permit3 taker gate on the exact market + amount.
        permit3.approveTaker(address(borrowModule), borrowRef, uint160(borrowOut), 0);

        // USDC fallback allowance for the tokenIn shortfall path — never triggers
        // here since the borrow fully funds tokenIn, but keeps it safe.
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(borrowOut), 0);
        vm.stopPrank();
    }

    function _approveMakerWithdrawSide(uint256 wstethIn, bytes32 ref) internal {
        vm.startPrank(maker);
        // Fallback for the tokenIn shortfall — never triggers in this flow.
        IERC20(WSTETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WSTETH, uint160(wstethIn), 0);

        // Morpho-native authorisation for the withdraw module. No token pull: the
        // collateral is not tokenised, so the taker allowance is the only cap.
        MORPHO.setAuthorization(address(withdrawModule), true);
        permit3.approveTaker(address(withdrawModule), ref, uint160(wstethIn), 0);
        vm.stopPrank();
    }

    function _approveMakerRepaySide(uint256 bufferedAmount, uint256 wstethForSolver) internal {
        vm.startPrank(maker);
        // tokenIn leg: maker pays wstETH to solver via Permit3.
        IERC20(WSTETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WSTETH, uint160(wstethForSolver), 0);
        // repay leg: repay module pulls USDC from maker.
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), USDC, uint160(bufferedAmount), 0);
        vm.stopPrank();
    }

    // ──────────────────── Module order builders ────────────────────

    function _buildWithdrawOrder(uint256 wstethIn, uint256 usdcOut)
        internal
        view
        returns (LimitOrder memory order)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(withdrawModule),
            amount: wstethIn,
            recipient: address(0),
            data: _marketData()
        });
        order = _order(maker, 1, WSTETH, USDC, wstethIn, usdcOut, items);
    }

    function _buildSupplyBorrowOrder(uint256 collateralIn, uint256 borrowOut)
        internal
        view
        returns (LimitOrder memory order)
    {
        Item[] memory items = new Item[](2);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(supplyModule),
            amount: collateralIn,
            recipient: address(0),
            data: _marketData()
        });
        items[1] = Item({
            op: ItemOp.TAKE,
            module: address(borrowModule),
            amount: borrowOut,
            recipient: address(0),
            data: _marketData()
        });
        order = _order(maker, 2, USDC, WSTETH, borrowOut, collateralIn, items);
    }

    function _buildRepayOrder(uint256 bufferedAmount, uint256 wstethForSolver)
        internal
        view
        returns (LimitOrder memory order)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(repayModule),
            amount: bufferedAmount,
            recipient: address(0),
            data: _marketData()
        });
        order = _order(maker, 3, WSTETH, USDC, wstethForSolver, bufferedAmount, items);
    }
}
