// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {Narrow160} from "@lib/Narrow160.sol";

import {EulerV2ModulesBase} from "../shared/EulerV2ModulesBase.t.sol";
import {EulerV2OperatorModule} from "../../src/EulerV2OperatorModule.sol";

/// @dev Pins the {Narrow160} guard at `EulerV2OperatorModule._batch` (Op.BatchOpen):
///
///     permit3.transferFrom(onBehalfOf, address(this), fundedAsset, Narrow160.to160(funded));
///     SafeTransferLib.forceApprove(fundedAsset, fundedVault, funded);
///
/// `funded` is `BatchData.sideAmount`, DECODED FROM THE ITEM'S `data` — the core only
/// width-checks the item slice, never this word. Without the guard a `uint160` clip
/// pulls a truncated amount while the un-clipped `funded` is approved to (and
/// deposited into) an order-named vault — the F-2 / F26/2d drain shape.
///
/// Entry path: `Settlement.fill` -> `Permit3.take` -> `operatorModule.takeOnBehalf`
/// (plain TAKE, op word 0 = BatchOpen) -> `_batch(open = true)`.
///
///   - sideAmount = 2^160       reverts `Narrow160.AmountOverflow` (bubbled unwrapped)
///                              and nothing moves: balances + both Permit3 books equal.
///   - sideAmount = 2^160 - 1   gets PAST the narrowing: the pull reaches Permit3 and
///                              dies on the maker's finite token allowance instead.
contract EulerNarrow160OverflowTest is EulerV2ModulesBase {
    uint256 constant COLLATERAL = 1 ether;
    uint256 constant BORROW = 1_000e6;

    function _batchOpenData(uint256 sideAmount) internal pure returns (bytes memory) {
        return abi.encode(
            EulerV2OperatorModule.BatchData({
                op: uint256(EulerV2OperatorModule.Op.BatchOpen),
                collateralVault: address(EWETH),
                borrowVault: address(EUSDC),
                sideAmount: sideAmount,
                totalAmount: BORROW // full fill — clears FullFillGuard before the pull
            })
        );
    }

    /// @dev Maker grants a realistic WETH token allowance to the module and a taker
    ///      allowance keyed to the exact `data`; returns the signed order.
    function _setup(uint256 nonce, bytes memory data) internal returns (Order memory o, bytes memory sig) {
        deal(WETH, maker, COLLATERAL);
        deal(WETH, solver, COLLATERAL);
        _approveSolverSide(COLLATERAL, WETH);

        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(operatorModule), WETH, uint160(COLLATERAL), 0);
        permit3.approveTaker(address(settlement), address(operatorModule), keccak256(data), uint160(BORROW), 0);
        vm.stopPrank();

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE, address(operatorModule), BORROW, address(0), data);
        o = _order(maker, nonce, USDC, WETH, BORROW, COLLATERAL, items);
        sig = _sign(o); // sign BEFORE any prank — _sign() consumes a pending prank
    }

    struct Snap {
        uint256 makerWeth;
        uint256 makerUsdc;
        uint256 moduleWeth;
        uint256 solverWeth;
        uint256 solverUsdc;
        uint256 vaultWeth; // eWETH-2's underlying balance
        uint256 makerShares; // maker's eWETH-2 shares
        uint256 makerDebt;
        uint256 moduleToVaultAllowance; // ERC-20 approve the drain would leave
        uint160 tokenAllowance; // Permit3 (maker, module, WETH)
        uint160 takerAllowance; // Permit3 (maker, settlement, module, ref)
    }

    function _snap(bytes memory data) internal view returns (Snap memory s) {
        s.makerWeth = IERC20(WETH).balanceOf(maker);
        s.makerUsdc = IERC20(USDC).balanceOf(maker);
        s.moduleWeth = IERC20(WETH).balanceOf(address(operatorModule));
        s.solverWeth = IERC20(WETH).balanceOf(solver);
        s.solverUsdc = IERC20(USDC).balanceOf(solver);
        s.vaultWeth = IERC20(WETH).balanceOf(address(EWETH));
        s.makerShares = EWETH.balanceOf(maker);
        s.makerDebt = _usdcDebt(maker);
        s.moduleToVaultAllowance = IERC20(WETH).allowance(address(operatorModule), address(EWETH));
        (s.tokenAllowance,) = permit3.tokenAllowance(maker, address(operatorModule), WETH);
        (s.takerAllowance,) =
            permit3.takerAllowance(maker, address(settlement), address(operatorModule), keccak256(data));
    }

    function _assertUnchanged(Snap memory a, Snap memory b) internal pure {
        assertEq(b.makerWeth, a.makerWeth, "maker WETH moved");
        assertEq(b.makerUsdc, a.makerUsdc, "maker USDC moved");
        assertEq(b.moduleWeth, a.moduleWeth, "module WETH moved");
        assertEq(b.solverWeth, a.solverWeth, "solver WETH moved");
        assertEq(b.solverUsdc, a.solverUsdc, "solver USDC moved");
        assertEq(b.vaultWeth, a.vaultWeth, "vault WETH moved");
        assertEq(b.makerShares, a.makerShares, "maker vault shares moved");
        assertEq(b.makerDebt, a.makerDebt, "maker debt moved");
        assertEq(b.moduleToVaultAllowance, 0, "module left a standing vault approval");
        assertEq(b.tokenAllowance, a.tokenAllowance, "Permit3 token allowance spent");
        assertEq(b.takerAllowance, a.takerAllowance, "Permit3 taker allowance spent");
    }

    /// sideAmount = 2^160: the smallest value `uint160()` would silently clip (to 0).
    function test_narrow160_batchOpenSideAmount_reverts() public {
        bytes memory data = _batchOpenData(uint256(type(uint160).max) + 1);
        (Order memory o, bytes memory sig) = _setup(101, data);

        Snap memory before = _snap(data);
        assertEq(before.tokenAllowance, uint160(COLLATERAL), "precondition: finite token allowance");
        assertEq(before.takerAllowance, uint160(BORROW), "precondition: taker allowance");

        vm.prank(solver);
        // Settlement and Permit3 bubble module reverts verbatim — the bare selector.
        vm.expectRevert(Narrow160.AmountOverflow.selector);
        settlement.fill(o, sig, BORROW);

        _assertUnchanged(before, _snap(data));
    }

    /// sideAmount = type(uint160).max fits, so `to160` is a no-op and the pull reaches
    /// Permit3 — which rejects it on the maker's finite token allowance. The revert is
    /// NOT AmountOverflow, proving the guard's boundary is exactly 2^160.
    function test_narrow160_batchOpenSideAmount_atMaxPassesNarrowing() public {
        bytes memory data = _batchOpenData(uint256(type(uint160).max));
        (Order memory o, bytes memory sig) = _setup(102, data);

        Snap memory before = _snap(data);

        vm.prank(solver);
        try settlement.fill(o, sig, BORROW) {
            fail("fill should not succeed at sideAmount = uint160.max");
        } catch (bytes memory reason) {
            assertGe(reason.length, 4, "revert carries a selector");
            assertTrue(bytes4(reason) != Narrow160.AmountOverflow.selector, "must get past the narrowing");
            assertEq(
                reason,
                abi.encodeWithSelector(IPermit3.InsufficientAllowance.selector, uint160(COLLATERAL)),
                "dies on the Permit3 token allowance, i.e. inside the pull"
            );
        }

        _assertUnchanged(before, _snap(data));
    }
}
