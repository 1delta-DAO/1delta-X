// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {MidnightModulesBase} from "../shared/MidnightModulesBase.t.sol";

/// @title MidnightStrandedBalanceTest
/// @notice F25/G-1 — the residual sweep must dispose of the DELTA this call
///         produced, never the module's whole balance.
///
///  F19 already settled the rule for the Aave and Morpho packages, and
///  {DustHandler.disposeResidual}'s floor overload states the threat model in as
///  many words: "anyone can transfer tokens to a module address, and anyone can be
///  the maker of a one-unit order against that module and asset, so a stranded
///  balance is claimable by the next filler rather than merely lost… 'the module
///  ends empty' is the wrong invariant… the right one is 'the module ends where it
///  started'."
///
///  `MidnightLendModule` was the one residual path in the package that never took
///  the floor. It read `IERC20(loanToken).balanceOf(address(this))` and sent all of
///  it to `onBehalfOf` — so whoever signed the next lend order in that token
///  collected anything sitting at the shared module address, at the price of one
///  dust-sized self-lend.
contract MidnightStrandedBalanceTest is MidnightModulesBase {
    uint256 constant STRANDED = 10_000e6;

    /// @dev The claim path, end to end. A balance is stranded at the module; the
    ///      maker signs an ordinary lend and fills it. Before the floor, the maker
    ///      walked away with `STRANDED` on top of their own unspent budget.
    function test_lend_doesNotPayOutAStrandedBalance() public {
        // Mis-sent, or left by any path that ever over-funds this module.
        LOAN.mint(address(lendModule), STRANDED);

        uint256 units = 1_000e6;
        LOAN.mint(maker, units);
        LOAN.mint(address(midnight), units);
        _makerApproveToken(address(lendModule), address(LOAN), units);
        _makerAuthorize(address(lendModule));

        vm.prank(address(settlement));
        lendModule.makeOnBehalf(maker, units, _lendData(units, units));

        // The invariant, stated directly: the module ends where it started.
        assertEq(
            IERC20(address(LOAN)).balanceOf(address(lendModule)),
            STRANDED,
            "stranded balance must stay at the module"
        );
        // And the maker cannot have collected it. They may receive their own
        // unspent budget back, which is bounded by what they put in.
        assertLe(
            IERC20(address(LOAN)).balanceOf(maker), units, "maker gained nothing beyond their own budget"
        );
    }

    /// @dev The floor must not break the thing it guards: a genuine unspent budget
    ///      still comes back, measured as the delta above the floor.
    function test_lend_stillRefundsTheCallersOwnUnspentBudget() public {
        LOAN.mint(address(lendModule), STRANDED);

        // Fund a budget larger than the offer consumes, so there IS a refund.
        uint256 units = 1_000e6;
        uint256 budget = units * 2;
        LOAN.mint(maker, budget);
        LOAN.mint(address(midnight), budget);
        _makerApproveToken(address(lendModule), address(LOAN), budget);
        _makerAuthorize(address(lendModule));

        vm.prank(address(settlement));
        lendModule.makeOnBehalf(maker, budget, _lendData(units, budget));

        assertEq(
            IERC20(address(LOAN)).balanceOf(address(lendModule)),
            STRANDED,
            "the module still ends exactly where it started"
        );
        assertGt(IERC20(address(LOAN)).balanceOf(maker), 0, "the maker's own unspent budget came back");
    }
}
