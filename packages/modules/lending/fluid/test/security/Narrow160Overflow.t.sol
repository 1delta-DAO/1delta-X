// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Narrow160} from "@lib/Narrow160.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";

import {FluidModulesBase} from "../shared/FluidModulesBase.t.sol";
import {FluidOperateModule} from "../../src/FluidModules.sol";

/// @title FluidNarrow160OverflowTest
/// @notice Pins the `Narrow160.to160` guard in `FluidBase._pullAndApprove`
///         (FluidModules.sol:83) on every caller whose amount comes from ORDER
///         DATA rather than from the core's width-checked slice.
///
///  The defect (F26/2d): `_pullAndApprove` pulled `uint160(amount)` via Permit3
///  but approved the vault for the full `uint256 amount`. With
///  `amount = 2^160 + 1` the pull clipped to ONE wei while the approve granted
///  ~1.46e48 to a `data`-chosen vault. Now the narrowing reverts instead.
///
///  Callers of `_pullAndApprove`, classified by where the amount comes from:
///   • FluidDepositModule / FluidRepayModule — `amount` is the core slice
///     (width-checked by `Base._runItem`): NOT data-derived, not covered here.
///   • FluidTakeForModule — `forAmount` arrives as a `uint160` through
///     `Permit3.takeFor`: NOT data-derived, not covered here.
///   • FluidOperateModule._open  — `p.sideAmount`   (decoded from `data`) ← covered
///   • FluidOperateModule._close — `p.sideAmount`   (decoded from `data`) ← covered
///                                 `p.repayCeiling` when sideAmount == FLUID_ALL ← covered
///
///  Entry path: Settlement (pranked) → `Permit3.take` → `FluidOperateModule.takeOnBehalf`,
///  the same path the integration tests drive. `take` calls the module directly,
///  so the module's revert bubbles unwrapped.
///
///  Each overflow test asserts (1) the exact `AmountOverflow` revert and (2) that
///  nothing moved: maker / module / vault / Liquidity USDC balances, the module's
///  ERC20 allowance to the vault, the maker's Permit3 token allowance to the
///  module, the maker's Permit3 taker allowance, and position NFT ownership.
///  The boundary tests use exactly `type(uint160).max`: that gets PAST the
///  narrowing and fails at the Permit3 token-allowance gate instead.
contract FluidNarrow160OverflowTest is FluidModulesBase {
    /// @dev Fluid Liquidity layer on Ethereum mainnet (holds all vault funds).
    address constant LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;

    uint256 constant OVER = uint256(type(uint160).max) + 1;
    uint256 constant AT_MAX = uint256(type(uint160).max);

    /// @dev Finite Permit3 token allowance maker → operateModule (a uint160.max
    ///      grant would be "infinite" and never gate).
    uint160 constant TOKEN_CAP = 1_000e6;
    uint256 constant COL_AMOUNT = 0.1 ether; // the take `amount` (full fill)

    uint256 nftId;

    struct Snap {
        uint256 makerUsdc;
        uint256 moduleUsdc;
        uint256 vaultUsdc;
        uint256 liquidityUsdc;
        uint256 moduleToVaultAllowance;
        uint160 p3TokenAllowance;
        uint160 p3TakerAllowance;
        address nftOwner;
    }

    function setUp() public override {
        super.setUp();
        nftId = _openPosition(maker, 1 ether, 1_000e6);
        deal(USDC, maker, 5_000e6);
        vm.label(LIQUIDITY, "FluidLiquidity");
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _data(FluidOperateModule.Mode mode, uint256 sideAmount, uint256 repayCeiling)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            FluidOperateModule.OperateData({
                mode: uint256(mode),
                vault: VAULT,
                factory: VAULT_FACTORY,
                fundingToken: USDC,
                nftId: nftId,
                sideAmount: sideAmount,
                repayCeiling: repayCeiling,
                totalAmount: COL_AMOUNT
            })
        );
    }

    function _grant(bytes memory data) internal {
        vm.startPrank(maker);
        permit3.approveToken(address(operateModule), USDC, TOKEN_CAP, 0);
        permit3.approveTaker(address(settlement), address(operateModule), keccak256(data), uint160(COL_AMOUNT), 0);
        vm.stopPrank();
    }

    function _snap(bytes memory data) internal view returns (Snap memory s) {
        s.makerUsdc = IERC20(USDC).balanceOf(maker);
        s.moduleUsdc = IERC20(USDC).balanceOf(address(operateModule));
        s.vaultUsdc = IERC20(USDC).balanceOf(VAULT);
        s.liquidityUsdc = IERC20(USDC).balanceOf(LIQUIDITY);
        s.moduleToVaultAllowance = IERC20(USDC).allowance(address(operateModule), VAULT);
        (s.p3TokenAllowance,) = permit3.tokenAllowance(maker, address(operateModule), USDC);
        (s.p3TakerAllowance,) =
            permit3.takerAllowance(maker, address(settlement), address(operateModule), keccak256(data));
        s.nftOwner = _ownerOf(nftId);
    }

    function _assertUnchanged(Snap memory a, Snap memory b) internal view {
        assertEq(b.makerUsdc, a.makerUsdc, "maker USDC moved");
        assertEq(b.moduleUsdc, a.moduleUsdc, "module USDC moved");
        assertEq(b.vaultUsdc, a.vaultUsdc, "vault USDC moved");
        assertEq(b.liquidityUsdc, a.liquidityUsdc, "Liquidity USDC moved");
        assertEq(b.moduleToVaultAllowance, a.moduleToVaultAllowance, "module->vault ERC20 allowance changed");
        assertEq(b.moduleToVaultAllowance, 0, "module left a vault grant");
        assertEq(b.p3TokenAllowance, a.p3TokenAllowance, "Permit3 token allowance consumed");
        assertEq(b.p3TakerAllowance, a.p3TakerAllowance, "Permit3 taker allowance consumed");
        assertEq(b.nftOwner, a.nftOwner, "position NFT moved");
        assertEq(b.nftOwner, maker, "maker no longer owns the position");
    }

    function _take(bytes memory data) internal {
        vm.prank(address(settlement));
        permit3.take(address(operateModule), maker, uint160(COL_AMOUNT), recv, data);
    }

    function _expectOverflowNoMove(bytes memory data) internal {
        _grant(data);
        Snap memory before = _snap(data);

        vm.expectRevert(Narrow160.AmountOverflow.selector);
        _take(data);

        _assertUnchanged(before, _snap(data));
    }

    /// @dev At exactly uint160.max the narrowing passes and the pull hits the
    ///      finite Permit3 token allowance — a DIFFERENT revert, proving the
    ///      AmountOverflow above is the narrowing and nothing earlier.
    function _expectPastNarrowing(bytes memory data) internal {
        _grant(data);
        Snap memory before = _snap(data);

        vm.expectRevert(abi.encodeWithSelector(IPermit3.InsufficientAllowance.selector, TOKEN_CAP));
        _take(data);

        _assertUnchanged(before, _snap(data));
    }

    // ── Open: sideAmount (collateral to supply) ─────────────────────────────

    function test_narrow160_operateOpenSideAmount_reverts() public {
        _expectOverflowNoMove(_data(FluidOperateModule.Mode.Open, OVER, 0));
    }

    function test_narrow160_operateOpenSideAmount_atMaxPassesNarrowing() public {
        _expectPastNarrowing(_data(FluidOperateModule.Mode.Open, AT_MAX, 0));
    }

    // ── Close: literal sideAmount (debt to repay) ───────────────────────────

    function test_narrow160_operateCloseSideAmount_reverts() public {
        _expectOverflowNoMove(_data(FluidOperateModule.Mode.Close, OVER, 0));
    }

    function test_narrow160_operateCloseSideAmount_atMaxPassesNarrowing() public {
        _expectPastNarrowing(_data(FluidOperateModule.Mode.Close, AT_MAX, 0));
    }

    // ── Close repay-all: repayCeiling (over-pull buffer) ────────────────────

    function test_narrow160_operateCloseRepayCeiling_reverts() public {
        _expectOverflowNoMove(_data(FluidOperateModule.Mode.Close, type(uint256).max, OVER));
    }

    function test_narrow160_operateCloseRepayCeiling_atMaxPassesNarrowing() public {
        _expectPastNarrowing(_data(FluidOperateModule.Mode.Close, type(uint256).max, AT_MAX));
    }
}
