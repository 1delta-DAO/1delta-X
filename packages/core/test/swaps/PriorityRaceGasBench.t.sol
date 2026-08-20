// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";

import {Order, Validator} from "@core/settlement/Settlement.sol";
import {DutchAuction} from "@core/settlement/DutchAuction.sol";
import {OrderState} from "@core/settlement/OrderState.sol";
import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";

import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";
import {PackedEncode} from "../shared/PackedEncode.sol";

interface IFill4 {
    function fill(Order calldata o, bytes calldata sig, uint256 amt, bytes calldata takerData)
        external
        returns (uint256[] memory);
}

/// @dev A validator that costs a STATICCALL and always passes — stands in for the real
///      ones (attestation, trigger, filler whitelist) a priority order may carry.
contract PassingValidator is IOrderValidator {
    function validate(Order calldata, address, bytes calldata, bytes calldata) external pure returns (bool) {
        return true;
    }
}

/// @dev Passes until armed, then reverts — so a loser that still reached the validator
///      walk would be unmistakable.
contract ExplodingValidator is IOrderValidator {
    bool public armed;

    function arm() external {
        armed = true;
    }

    function validate(Order calldata, address, bytes calldata, bytes calldata) external view returns (bool) {
        require(!armed, "validator reached");
        return true;
    }
}

/// @title PriorityRaceGasBench
/// @notice WHAT A LOST RACE COSTS THE SOLVER THAT LOST IT.
///
///  A priority-fee auction ({DutchAuction.priorityAuction}) is a gas auction: every
///  solver sends the SAME fill, the sequencer's fee ordering picks one, and every
///  other bidder lands and reverts. A reverted transaction still pays for the gas it
///  burned — at the bidder's OWN priority fee, which in a contested auction is the
///  highest number that solver was willing to name. So a loser pays
///  `gasUsed × (basefee + its own bid)`, and shaving `gasUsed` before the revert
///  shaves the tax the mechanism charges solvers for competing.
///
///  The numbers below are intra-transaction (Foundry runs a test as one tx), so slots
///  the winner already touched read WARM. A real losing transaction additionally pays
///  ~2,100 each for the cold `_locked` and `filled[orderHash]` — and, before
///  {OrderState._gateFillState} existed, for the maker's nonce word too — plus 21,000
///  intrinsic and the calldata cost printed alongside each row.
contract PriorityRaceGasBenchTest is MockSettlementBase {
    uint256 constant SELL_IN = 1_000e18;
    uint256 constant OUT_START = 2_000e18;
    uint256 constant OUT_END = 1_000e18;

    function _fund() internal {
        tA.mint(maker, SELL_IN);
        _makerApprove(address(settlement), address(tA), SELL_IN);
        tB.mint(solver, OUT_START);
        _solverApprove(address(settlement), address(tB), OUT_START);
    }

    function _prio(uint256 nonce) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), SELL_IN, OUT_START);
        o.legsOut = PackedEncode.oneLegOut(address(tB), OUT_START, OUT_END, address(0));
        o.timing = (uint256(1) << 103) | _expiryBits(block.timestamp + 1 hours);
        o.params = DutchAuction.packParams(0, 0, 0, 2 gwei, 0);
    }

    function _lose(string memory label, Order memory o, bytes memory sig) internal returns (uint256 used) {
        bytes memory cd = abi.encodeCall(IFill4.fill, (o, sig, SELL_IN, ""));
        vm.prank(solver);
        uint256 g = gasleft();
        (bool ok,) = address(settlement).call(cd);
        used = g - gasleft();
        require(!ok, "expected revert");
        console2.log(label, used, cd.length);
    }

    /// @dev Warms the shared state (token accounts, allowances, the guard slot) so the
    ///      first measured row does not absorb everyone else's cold access.
    function _warm() internal {
        _fund();
        Order memory w = _plainOrder(0, address(tA), address(tB), SELL_IN, OUT_START);
        bytes memory ws = _sign(w);
        vm.prank(solver);
        settlement.fill(w, ws, SELL_IN);
    }

    function test_bench_lostRace() public {
        _warm();
        vm.fee(1 gwei);
        vm.txGasPrice(2 gwei);

        // ── the winner fills it outright; every other bidder now over-fills.
        _fund();
        Order memory o = _prio(1);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN);
        _lose("lost race, plain order   gas / calldata:", o, sig);

        // ── the same race on an order carrying two validators. The gate runs BEFORE
        //    the validator walk, so the loser does not pay for their STATICCALLs.
        _fund();
        PassingValidator v = new PassingValidator();
        Order memory ov = _prio(2);
        Validator[] memory vs = new Validator[](2);
        vs[0] = Validator(address(v), "");
        vs[1] = Validator(address(v), "");
        ov.validators = PackedEncode.validators(vs);
        bytes memory vsig = _sign(ov);
        vm.prank(solver);
        settlement.fill(ov, vsig, SELL_IN);
        _lose("lost race, 2 validators  gas / calldata:", ov, vsig);
    }

    /// @dev The ordering IS the optimization, so pin it: a fully-filled order reports
    ///      {OverFill} even when it carries a validator that would revert the call —
    ///      proof the loser never reached the validator walk.
    function test_lostRace_gateRunsBeforeValidators() public {
        _fund();
        vm.fee(1 gwei);
        vm.txGasPrice(2 gwei);

        ExplodingValidator boom = new ExplodingValidator();
        Order memory o = _prio(3);
        Validator[] memory vs = new Validator[](1);
        vs[0] = Validator(address(boom), "");
        o.validators = PackedEncode.validators(vs);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN); // passes: the validator is not armed yet
        boom.arm();

        vm.prank(solver);
        vm.expectRevert(OrderState.OverFill.selector);
        settlement.fill(o, sig, SELL_IN);
    }
}
