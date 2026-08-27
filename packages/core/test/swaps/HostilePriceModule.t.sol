// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "@core/settlement/Settlement.sol";
import {DutchAuction} from "@core/settlement/DutchAuction.sol";
import {IPriceModule} from "@core/interfaces/IPriceModule.sol";

import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";
import {PackedEncode} from "../shared/PackedEncode.sol";

/// @dev Returns whatever it is told to, including values far outside [0, 10000].
contract LiarModule is IPriceModule {
    uint256 public answer;

    constructor(uint256 a) {
        answer = a;
    }

    function bump(bytes32, address, address, uint256, uint256, uint256, bytes calldata, bytes calldata, bytes calldata)
        external
        view
        returns (uint256)
    {
        return answer;
    }
}

/// @dev Reverts. A price module that fails must fail the FILL, never be treated as
///      "no opinion" and silently skipped.
contract RevertingModule is IPriceModule {
    error Nope();

    function bump(bytes32, address, address, uint256, uint256, uint256, bytes calldata, bytes calldata, bytes calldata)
        external
        pure
        returns (uint256)
    {
        revert Nope();
    }
}

/// @dev Returns FEWER than 32 bytes, so there is no word to read.
contract ShortReturnModule {
    fallback(bytes calldata) external returns (bytes memory) {
        return hex"01";
    }
}

/// @dev Returns an enormous buffer — the classic return-bomb, trying to make the
///      caller pay unbounded memory-expansion gas or corrupt its own memory.
contract BombModule {
    fallback(bytes calldata) external returns (bytes memory) {
        return new bytes(200_000);
    }
}

/// @title HostilePriceModule
/// @notice THE CLAMP IS THE SECURITY ARGUMENT. An `Order.pricingModule` is
///         maker-signed, but what it returns is not, and on a cosigned-quote module
///         the value is derived from filler-supplied `takerData`. So an UNSIGNED
///         input reaches the price. This file asserts the bound that makes that
///         safe: whatever a module says, the executed price stays inside the
///         `start`/`end` band the maker signed, and NOWHERE outside it.
///
///  Provenance — Cyfrin's Bebop Router v2.0 audit, [H-1]: *"the signed router order
///  authorizes the user input pull, while the unsigned PMM calldata controls the
///  realized output."* The user's digest committed to the order fields but not to
///  the calldata that decided how much was delivered and to whom, so a relayer could
///  under-deliver (dust), redirect the output, or switch the delivery to native and
///  have the ERC-20 accounting read zero. It was rated High and cost the full swap.
///
///  Our shape is the same — untrusted input feeding the realized price — and the
///  defence is structural rather than a check: {DutchAuction.priceBump} clamps the
///  module's answer into [0, BPS] and then maps it through the maker's OWN signed
///  endpoints, so the worst a hostile module achieves is the maker's floor, which is
///  a price the maker already declared acceptable. Bebop's `limitAmount == 0` case
///  had no floor at all, which is precisely why theirs was exploitable.
///
///  The other half of [H-1] — output redirection — is pinned in `FillUpTo.t.sol`
///  ("recipient: destination, never authority"); output-leg recipients are inside
///  the signed `legsOut` blob and no filler input can move them.
contract HostilePriceModuleTest is MockSettlementBase {
    uint256 constant SELL_IN = 1_000e18;
    uint256 constant OUT_START = 2_000e18; // best for the maker
    uint256 constant OUT_END = 1_000e18; //   the maker's signed FLOOR

    function _fund() internal {
        tA.mint(maker, SELL_IN * 8);
        _makerApprove(address(settlement), address(tA), SELL_IN * 8);
        tB.mint(solver, OUT_START * 8);
        _solverApprove(address(settlement), address(tB), OUT_START * 8);
    }

    function _order(uint256 nonce, address module) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), SELL_IN, OUT_START);
        o.legsOut = PackedEncode.oneLegOut(address(tB), OUT_START, OUT_END, address(0));
        _setDecayStart(o, block.timestamp);
        o.pricingModule = module;
    }

    /// @dev A module answering far ABOVE the clamp is pinned to `BPS`, i.e. the
    ///      maker's signed floor — never below it. `type(uint256).max` is the
    ///      strongest possible lie and it buys the filler exactly nothing beyond
    ///      what the maker already agreed to.
    function test_absurdlyHighAnswer_clampsToTheSignedFloor() public {
        _fund();
        address mod = address(new LiarModule(type(uint256).max));
        Order memory o = _order(1, mod);
        bytes memory sig = _sign(o);

        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN);
        assertEq(tB.balanceOf(maker) - before_, OUT_END, "clamped to the maker's floor, not below");
    }

    /// @dev And a module answering 0 gives the maker its `start` — the clamp binds
    ///      in both directions, so a module cannot invent a price ABOVE the band
    ///      either (which would let a maker's own module over-charge a filler).
    function test_zeroAnswer_isTheSignedStart() public {
        _fund();
        address mod = address(new LiarModule(0));
        Order memory o = _order(2, mod);
        bytes memory sig = _sign(o);

        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN);
        assertEq(tB.balanceOf(maker) - before_, OUT_START, "0 bump == the signed start");
    }

    /// @dev THE BAND, fuzzed over every answer a module could give — including the
    ///      whole range above the clamp. The executed output must always land inside
    ///      the maker's signed endpoints. This is the property Bebop's [H-1] lacked.
    function testFuzz_anyAnswer_staysInsideTheSignedBand(uint256 answer) public {
        _fund();
        address mod = address(new LiarModule(answer));
        Order memory o = _order(3, mod);
        bytes memory sig = _sign(o);

        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN);
        uint256 got = tB.balanceOf(maker) - before_;

        assertLe(got, OUT_START, "never above the signed start");
        assertGe(got, OUT_END, "never below the signed floor");
    }

    /// @dev A REVERTING module must fail the fill, not be skipped. Failing open here
    ///      would silently fall back to some other price — the "unsigned input
    ///      decides the outcome" hazard by another route.
    function test_revertingModule_failsTheFill() public {
        _fund();
        Order memory o = _order(4, address(new RevertingModule()));
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(DutchAuction.PriceModuleFailed.selector);
        settlement.fill(o, sig, SELL_IN);
    }

    /// @dev A module returning fewer than 32 bytes leaves no word to read. The
    ///      settler must reject rather than consume whatever happened to be in
    ///      scratch space.
    function test_shortReturn_failsTheFill() public {
        _fund();
        Order memory o = _order(5, address(new ShortReturnModule()));
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(DutchAuction.PriceModuleFailed.selector);
        settlement.fill(o, sig, SELL_IN);
    }

    /// @dev A RETURN BOMB must not corrupt the caller or blow the gas budget: the
    ///      staticcall caps the copied return at ONE WORD, so the 200KB is never
    ///      copied. The fill proceeds on the first word, still clamped into the band.
    function test_returnBomb_isCappedAtOneWord() public {
        _fund();
        Order memory o = _order(6, address(new BombModule()));
        bytes memory sig = _sign(o);

        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN);
        uint256 got = tB.balanceOf(maker) - before_;
        assertLe(got, OUT_START, "still inside the band");
        assertGe(got, OUT_END, "still inside the band");
    }
}
