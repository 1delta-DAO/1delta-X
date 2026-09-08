// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, LegOut} from "@core/settlement/Settlement.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {OperatorArg} from "../../src/interfaces/IDolomite.sol";
import {DolomiteTakeForModule, DolomiteTakeForModule} from "../../src/DolomiteModules.sol";
import {DolomiteModulesBase} from "../shared/DolomiteModulesBase.t.sol";

/// @dev PRE-FUNDED `TAKE_FOR` on Dolomite: the collateral leg is delivered to
/// the MODULE, which deposits it from its own balance. The maker's receive side
/// is strictly EMPTY — the ERC20 approval of the collateral to Permit3 is revoked
/// outright and no Permit3 token allowance to the module ever exists. The only
/// grants are the borrow gate (taker allowance) and the Dolomite-native
/// `setOperators` boolean, which every Dolomite module needs regardless of
/// funding shape. Run back-to-back with the pull variant from an identical fork
/// state: same position, one less ERC20 transfer, two fewer approvals.
contract DolomitePreFundTakeForOpenTest is DolomiteModulesBase {
    DolomiteTakeForModule takeForModule;
    DolomiteTakeForModule pushModule;

    uint256 constant COLLATERAL = 1 ether;
    uint256 constant BORROW = 1_000e6;

    function setUp() public override {
        super.setUp();
        takeForModule = new DolomiteTakeForModule(address(permit3), address(settlement));
        pushModule = new DolomiteTakeForModule(address(permit3), address(settlement));
        vm.label(address(takeForModule), "dolomiteTakeForModule");
        vm.label(address(pushModule), "dolomitePreFundTakeForModule");

        // Dolomite-native auth for BOTH variants — the operator boolean is the one
        // grant pre-funding cannot remove (no permissionless value-in path).
        vm.startPrank(maker);
        OperatorArg[] memory ops = new OperatorArg[](2);
        ops[0] = OperatorArg(address(takeForModule), true);
        ops[1] = OperatorArg(address(pushModule), true);
        DOLOMITE.setOperators(ops);
        IERC20(COLL).approve(address(permit3), type(uint256).max);
        IERC20(DEBT).approve(address(permit3), type(uint256).max);
        vm.stopPrank();
    }

    function _forLeg(uint256 j, bool preFund, address token) internal pure returns (uint256) {
        // bit 255 = leg reference; bit 253 = the PRE-FUND shape, which makes the core
        // require `legsOut[j].recipient == module` (F27/H-1).
        return (uint256(1) << 255) | (preFund ? (uint256(1) << 253) | (uint256(uint160(token)) << 16) : 0) | j;
    }

    /// @dev BYTE-IDENTICAL for both variants — that is the point: builders switch
    ///      by module address + leg recipient, nothing in `data` moves. The taker
    ///      book keys the ref by (spender, MODULE, keccak256(data)), so the two
    ///      grants below stay distinct despite the shared bytes.
    function _data(bool preFund) internal view returns (bytes memory) {
        return abi.encode(
            DolomiteTakeForModule.OpenData({
                forDesc: _forLeg(0, preFund, COLL),
                forCap: 0,
                dolomite: address(DOLOMITE),
                collMarketId: COLL_MARKET,
                collToken: COLL,
                borrowMarketId: DEBT_MARKET,
                accountNumber: ACCOUNT
            })
        );
    }

    /// @dev Authorize BOTH variants so the two runs differ only in the funding
    ///      path. Pull: token allowance + (already granted) ERC20 approve. Pre-fund:
    ///      the borrow gate ONLY.
    /// @dev Two blobs now: the PRE-FUND shape is declared in the descriptor the maker
    ///      signs (F27/H-1), so the taker grants are keyed on different `ref`s.
    function _authBoth(bytes memory pullData, bytes memory pushData) internal {
        vm.startPrank(maker);
        permit3.approveToken(address(takeForModule), COLL, uint160(COLLATERAL + 2), 0);
        permit3.approveTaker(address(settlement), address(takeForModule), keccak256(pullData), uint160(BORROW), 0);
        permit3.approveTaker(address(settlement), address(pushModule), keccak256(pushData), uint160(BORROW), 0);
        permit3.approveToken(address(settlement), DEBT, uint160(BORROW), 0);
        vm.stopPrank();
    }

    function _pullOrder(bytes memory data) internal view returns (Order memory) {
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE_FOR, address(takeForModule), BORROW, address(0), data);
        return _order(maker, 31, DEBT, COLL, BORROW, COLLATERAL, items);
    }

    /// @dev Same order with the module swapped and the collateral leg re-addressed
    ///      to it — the two edits that select the pre-fund shape.
    function _preFundOrder(bytes memory data) internal view returns (Order memory o) {
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE_FOR, address(pushModule), BORROW, address(0), data);
        o = _order(maker, 32, DEBT, COLL, BORROW, COLLATERAL, items);
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(COLL, COLLATERAL, 0, address(pushModule)); // ← delivered to the module
        o.legsOut = PackedEncode.legsOut(legsOut);
    }

    /// @dev Fill `o` measuring gas — its own frame so the two runs' locals never
    ///      share the outer test's stack (fork profiles compile optimizer=false).
    function _fillMeasured(Order memory o, bytes memory sig) internal returns (uint256 gasUsed) {
        vm.prank(solver);
        uint256 g0 = gasleft();
        settlement.fill(o, sig, BORROW);
        gasUsed = g0 - gasleft();
    }

    function test_preFundFunded_samePosition_zeroReceiveSideApprovals_andCostsNoMore() public {
        _neutralizeRiskOverride();
        deal(COLL, solver, COLLATERAL);
        _approveSolverSide(COLLATERAL, COLL);

        bytes memory pullData = _data(false);
        bytes memory pushData = _data(true);
        _authBoth(pullData, pushData);

        Order memory pull = _pullOrder(pullData);
        bytes memory pullSig = _sign(pull);
        Order memory preFund = _preFundOrder(pushData);
        bytes memory pushSig = _sign(preFund);

        uint256 col0 = _collateralOf(maker);
        uint256 debt0 = _debtOf(maker);
        uint256 snap = vm.snapshotState();

        // ---- A: pull-funded (wallet transit) ----
        uint256 pullGas = _fillMeasured(pull, pullSig);
        uint256 colPull = _collateralOf(maker) - col0;
        uint256 debtPull = _debtOf(maker) - debt0;
        assertEq(IERC20(DEBT).balanceOf(solver), BORROW, "pull: solver received the whole borrow");

        // ---- B: pre-funded, from the SAME starting state, with the maker's
        //         receive side stripped to NOTHING ----
        vm.revertToState(snap);
        vm.startPrank(maker);
        IERC20(COLL).approve(address(permit3), 0); //  no base ERC20 approval of collToken
        vm.stopPrank();
        assertEq(IERC20(COLL).allowance(maker, address(permit3)), 0, "ERC20 approval revoked before the fill");
        (uint160 modAllowance,) = permit3.tokenAllowance(maker, address(pushModule), COLL);
        assertEq(modAllowance, 0, "no Permit3 token allowance to the pre-fund module, ever");
        uint256 makerColl = IERC20(COLL).balanceOf(maker);

        uint256 pushGas = _fillMeasured(preFund, pushSig);

        assertApproxEqAbs(_collateralOf(maker) - col0, colPull, 2, "same collateral deposited");
        assertApproxEqAbs(_debtOf(maker) - debt0, debtPull, 2, "same debt drawn");
        assertApproxEqAbs(_collateralOf(maker) - col0, COLLATERAL, 2, "collateral is the signed OUTPUT LEG");
        assertApproxEqAbs(_debtOf(maker) - debt0, BORROW, 2, "debt is the signed item amount");
        assertEq(IERC20(COLL).balanceOf(maker), makerColl, "the maker's wallet was never touched");
        assertEq(IERC20(COLL).balanceOf(address(pushModule)), 0, "module drained: delivery fully deposited");
        assertEq(IERC20(DEBT).balanceOf(address(pushModule)), 0, "module drained");
        assertEq(IERC20(DEBT).balanceOf(solver), BORROW, "preFund: solver received the whole borrow");
        assertEq(IERC20(COLL).balanceOf(address(settlement)), 0, "settlement drained");

        emit log_named_uint("pull-funded (gas)", pullGas);
        emit log_named_uint("pre-funded (gas)", pushGas);
        emit log_named_int("saved       (gas)", int256(pullGas) - int256(pushGas));
        assertLe(pushGas, pullGas, "one less ERC20 transfer must not cost more");
    }
}
