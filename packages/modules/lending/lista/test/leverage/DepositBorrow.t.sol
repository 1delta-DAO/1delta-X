// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order} from "@core/settlement/Settlement.sol";

import {ListaModulesBase, IListaBrokerViews} from "../shared/ListaModulesBase.t.sol";

/// @dev Lista leverage fork suite — BSC mainnet, USD1/BTCB brokered market.
///
///  This is the validation the package README defers: the on-behalf
///  `broker.borrow(amount, termId, user, receiver)` signature and its reliance
///  on Moolah `setAuthorization` are exercised against the DEPLOYED broker.
///
///  Shape (mirrors aave-v3/test/leverage/DepositBorrow.t.sol):
///    maker signs [MAKE supply BTCB collateral, TAKE fixed-term borrow USD1];
///    an inventory solver funds the collateral and receives the borrow proceeds.
///
///  ⚠️ Market-selection caveat validated on the way here: markets whose
///  collateral token has a Moolah `providers[id][token]` entry (e.g. the
///  flagship slisBNB markets) reject BOTH collateral modules with
///  `"not provider"` — see the harness header. Off-chain order construction
///  must check `providers[id][collateralToken] == 0` before offering the
///  supply-/withdraw-collateral legs on a Lista market.
contract ListaDepositBorrowTest is ListaModulesBase {
    uint256 constant COLLATERAL_IN = 0.1e18; //  BTCB the maker deposits (~$11k)
    uint256 constant BORROW_OUT = 1_000e18; //   USD1 the maker borrows (≈10% LTV @ 86% lltv)

    // ──────────────────── Deposit + fixed-term borrow in one fill ────────────────────

    function test_supplyCollateral_and_fixedTermBorrow_lista() public {
        deal(BTCB, solver, COLLATERAL_IN);

        _approveMakerDepositBorrowSide(COLLATERAL_IN, BORROW_OUT, true);
        _approveSolverSide(COLLATERAL_IN, BTCB);

        Order memory order = _buildDepositBorrowOrder(COLLATERAL_IN, BORROW_OUT);
        bytes memory sig = _sign(order);

        uint256 collateralBefore = _makerCollateral();
        uint256 debtBefore = IListaBrokerViews(BROKER).getUserTotalDebt(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, BORROW_OUT)[0];

        assertEq(paid, COLLATERAL_IN, "solver paid the full collateral");

        // Maker: fresh Moolah collateral position + fixed-term broker debt.
        assertEq(_makerCollateral() - collateralBefore, COLLATERAL_IN, "maker Moolah collateral up");
        uint256 debtOpened = IListaBrokerViews(BROKER).getUserTotalDebt(maker) - debtBefore;
        assertGe(debtOpened, BORROW_OUT, "maker broker debt covers the borrow");
        assertLt(debtOpened, (BORROW_OUT * 105) / 100, "debt is principal + bounded term interest");

        // Solver: spent BTCB, received the USD1 borrow proceeds.
        assertEq(IERC20(BTCB).balanceOf(solver), 0, "solver BTCB spent");
        assertEq(IERC20(USD1).balanceOf(solver), BORROW_OUT, "solver received USD1");

        // Wallet balances unchanged — neither leg's asset sat in the maker's EOA.
        assertEq(IERC20(BTCB).balanceOf(maker), 0, "maker BTCB forwarded into supply");
        assertEq(IERC20(USD1).balanceOf(maker), 0, "maker USD1 forwarded out via borrow");

        // Settlement & modules end empty.
        assertEq(IERC20(BTCB).balanceOf(address(settlement)), 0, "settlement BTCB drained");
        assertEq(IERC20(USD1).balanceOf(address(settlement)), 0, "settlement USD1 drained");
        assertEq(IERC20(BTCB).balanceOf(address(supplyModule)), 0, "supply module drained");
        assertEq(IERC20(USD1).balanceOf(address(takerModule)), 0, "taker module drained");
    }

    // ──────────────────── The protocol grant is actually enforced ────────────────────

    /// @dev Same fill WITHOUT the maker's Moolah `setAuthorization(takerModule)`:
    ///      the deployed broker must reject the on-behalf borrow. This pins the
    ///      auth model the README transcribed from the SDK — the borrow leg is
    ///      gated by the maker's Moolah authorization of the calling module, not
    ///      by a broker-side allowlist that would strand the module design.
    function test_fixedTermBorrow_requiresMoolahAuthorization() public {
        deal(BTCB, solver, COLLATERAL_IN);

        _approveMakerDepositBorrowSide(COLLATERAL_IN, BORROW_OUT, false); // no setAuthorization
        _approveSolverSide(COLLATERAL_IN, BTCB);

        Order memory order = _buildDepositBorrowOrder(COLLATERAL_IN, BORROW_OUT);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(bytes4(0xea8e4eb5)); // broker: NotAuthorized()
        settlement.fill(order, sig, BORROW_OUT);

        // Nothing moved.
        assertEq(_makerCollateral(), 0, "no collateral position opened");
        assertEq(IERC20(USD1).balanceOf(solver), 0, "no borrow proceeds paid");
        assertEq(IERC20(BTCB).balanceOf(solver), COLLATERAL_IN, "solver inventory untouched");
    }

    // ──────────────────── Withdraw-collateral value-out leg ────────────────────

    /// @dev Seed a collateral-only position, then fill [TAKE withdraw 0.04 BTCB]
    ///      against a solver paying USD1 — validates the Moolah on-behalf
    ///      `withdrawCollateral(mp, amount, onBehalf, receiver)` leg (op 1).
    function test_withdrawCollateral_take() public {
        uint256 seeded = 0.1e18;
        uint256 withdrawAmount = 0.04e18;
        uint256 usd1Out = 4_000e18; // solver's price for 0.04 BTCB

        _seedCollateral(seeded);
        deal(USD1, solver, usd1Out);

        _approveMakerWithdrawSide(withdrawAmount);
        _approveSolverSide(usd1Out, USD1);

        Order memory order = _buildWithdrawOrder(withdrawAmount, usd1Out);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, withdrawAmount)[0];

        assertEq(paid, usd1Out, "solver paid the USD1 leg");

        // Maker: collateral down by exactly the withdrawn amount, paid in USD1.
        assertEq(seeded - _makerCollateral(), withdrawAmount, "maker collateral down");
        assertEq(IERC20(USD1).balanceOf(maker), usd1Out, "maker received USD1");

        // Solver: received the withdrawn collateral.
        assertEq(IERC20(BTCB).balanceOf(solver), withdrawAmount, "solver received BTCB");
        assertEq(IERC20(USD1).balanceOf(solver), 0, "solver USD1 spent");

        // Settlement & module end empty.
        assertEq(IERC20(BTCB).balanceOf(address(settlement)), 0, "settlement BTCB drained");
        assertEq(IERC20(BTCB).balanceOf(address(takerModule)), 0, "taker module drained");
    }
}
