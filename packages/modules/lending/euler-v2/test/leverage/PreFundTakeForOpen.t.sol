// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, LegOut} from "@core/settlement/Settlement.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {EulerV2OperatorModule} from "../../src/EulerV2OperatorModule.sol";
import {EulerV2ModulesBase} from "../shared/EulerV2ModulesBase.t.sol";

/// @dev PRE-FUNDED `TAKE_FOR` on Euler V2. The collateral output leg is signed with
/// `recipient = the module`, the core delivers it straight there and sizes
/// `forAmount` to exactly that delivery, and the module deposits from its OWN
/// balance — no Permit3 token allowance to the module, no ERC20 approve of the
/// collateral asset to Permit3, ever. Both are asserted ZERO before the fill. Run
/// back-to-back with the pull variant from an identical fork state: same position,
/// one less ERC20 transfer, two fewer approvals.
contract EulerPreFundTakeForOpenTest is EulerV2ModulesBase {
    // ⚠ ONE module, BOTH shapes. These were two contracts differing by a single
    //   line in the collateral leg, and each needed its own `setAccountOperator`.
    //   Merged, the pull baseline and the pre-fund variant are the SAME address and
    //   the shape is chosen by descriptor bit 253 alone — which is exactly what this
    //   test compares. `operatorModule` is inherited from the base.

    uint256 constant COLLATERAL = 1 ether;
    uint256 constant BORROW = 1_500e6;

    function setUp() public override {
        super.setUp();
        // Nothing to deploy or authorise here any more: the base already deployed
        // `operatorModule` and granted it operator rights ONCE. Both shapes ride it.
    }

    /// @dev ⚠ THE OP RIDES THE DESCRIPTOR — bits [244,252). {EulerV2OperatorModule}
    ///      hosts every op the maker's EVC operator grant covers, so the `TAKE_FOR`
    ///      seam has to name which one. It goes here rather than in a new field
    ///      because word 0 is inside `ref = keccak256(data)`, so the taker grant binds
    ///      the op: a grant signed for `Open` cannot be replayed as anything else.
    ///      {Base._forSlice} reads only bits 255, 254, 253 and [0,16), so these bits
    ///      are invisible to the core.
    function _forLeg(uint256 j, bool preFund, address token) internal pure returns (uint256) {
        // bit 255 = leg reference; bit 253 = the PRE-FUND shape, which makes the core
        // require `legsOut[j].recipient == module` (F27/H-1).
        return (uint256(1) << 255) | (uint256(EulerV2OperatorModule.Op.Open) << 244) | (preFund ? (uint256(1) << 253) | (uint256(uint160(token)) << 16) : 0) | j;
    }

    /// @dev Byte-identical layout for both variants — builders switch by module
    ///      address + leg recipient only. (The taker ref is `keccak256(data)` but
    ///      the allowance book is keyed per-module, so the shared bytes are safe.)
    function _data(bool preFund) internal view returns (bytes memory) {
        return abi.encode(
            EulerV2OperatorModule.OpenData({
                forDesc: _forLeg(0, preFund, WETH),
                forCap: 0,
                collateralVault: address(EWETH),
                borrowVault: address(EUSDC)
            })
        );
    }

    /// @dev Push order: same shape as the pull order, but the WETH output leg is
    ///      addressed to the module instead of the maker.
    function _preFundOrder(uint256 nonce, bytes memory data) internal view returns (Order memory o) {
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE_FOR, address(operatorModule), BORROW, address(0), data);
        o = _order(maker, nonce, USDC, WETH, BORROW, COLLATERAL, items);
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(WETH, COLLATERAL, 0, address(operatorModule)); // ← delivered to the module
        o.legsOut = PackedEncode.legsOut(legsOut);
    }

    function _pullOrder(uint256 nonce, bytes memory data) internal view returns (Order memory) {
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE_FOR, address(operatorModule), BORROW, address(0), data);
        return _order(maker, nonce, USDC, WETH, BORROW, COLLATERAL, items);
    }

    // ── The claim itself: the same open with the receive side stripped BARE. ──
    function test_preFundFunded_opensPosition_zeroReceiveSideApprovals() public {
        deal(WETH, solver, COLLATERAL);
        _approveSolverSide(COLLATERAL, WETH);

        bytes memory data = _data(true);
        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), 0); //  receive side stripped bare
        permit3.approveTaker(address(settlement), address(operatorModule), keccak256(data), uint160(BORROW), 0);
        vm.stopPrank();

        Order memory o = _preFundOrder(21, data);
        bytes memory sig = _sign(o);

        // Prove the receive side is empty BEFORE the fill, not just unused.
        assertEq(IERC20(WETH).allowance(maker, address(permit3)), 0, "no ERC20 approval of the collateral");
        (uint160 amt,) = permit3.tokenAllowance(maker, address(operatorModule), WETH);
        assertEq(amt, 0, "no Permit3 book entry for the module either");

        uint256 col0 = _wethCollateral(maker);
        uint256 debt0 = _usdcDebt(maker);
        uint256 makerWeth = IERC20(WETH).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, BORROW);

        assertApproxEqRel(_wethCollateral(maker) - col0, COLLATERAL, 1e15, "delivered leg became collateral");
        assertApproxEqRel(_usdcDebt(maker) - debt0, BORROW, 1e15, "debt drawn");
        assertEq(IERC20(WETH).balanceOf(maker), makerWeth, "the maker's wallet never saw the WETH");
        assertEq(IERC20(WETH).balanceOf(address(operatorModule)), 0, "module drained: delivery fully deposited");
        assertEq(IERC20(USDC).balanceOf(solver), BORROW, "solver received the input leg");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement drained");
    }

    // ── Partial fills: per-fill CEIL dust left on the module is consumed by the
    //    next slice's deposit — the module still ends drained. ──
    function test_preFundFunded_partialFills_moduleDrainedAcrossSlices() public {
        deal(WETH, solver, COLLATERAL * 2); // per-fill-ceil headroom on a SELL leg
        _approveSolverSide(COLLATERAL * 2, WETH);

        bytes memory data = _data(true);
        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), 0);
        permit3.approveTaker(address(settlement), address(operatorModule), keccak256(data), uint160(BORROW), 0);
        vm.stopPrank();

        Order memory o = _preFundOrder(22, data);
        bytes memory sig = _sign(o);

        uint256 col0 = _wethCollateral(maker);
        uint256 debt0 = _usdcDebt(maker);
        uint256 makerWeth = IERC20(WETH).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, BORROW / 3);
        vm.prank(solver);
        settlement.fill(o, sig, BORROW - BORROW / 3);

        assertApproxEqRel(_wethCollateral(maker) - col0, COLLATERAL, 1e15, "collateral = the whole signed leg");
        assertApproxEqRel(_usdcDebt(maker) - debt0, BORROW, 1e15, "debt = the whole signed amount");
        assertEq(IERC20(WETH).balanceOf(maker), makerWeth, "wallet untouched across slices");
        assertEq(IERC20(WETH).balanceOf(address(operatorModule)), 0, "module drained across slices");
        assertEq(IERC20(USDC).balanceOf(solver), BORROW, "solver received the whole borrow");
    }

    // ── Gas + equivalence: pull vs pre-funded back-to-back from an IDENTICAL fork state
    //    via snapshot/revert. Same position; pre-funding makes one less ERC20 transfer and
    //    must not cost more. ──
    function test_preFundFunded_samePosition_andCostsNoMore() public {
        deal(WETH, solver, COLLATERAL);
        _approveSolverSide(COLLATERAL, WETH);

        // ---- authorize BOTH variants so the runs differ only in funding path ----
        bytes memory pullData = _data(false);
        bytes memory pushData = _data(true);
        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), type(uint256).max); //   pull needs it
        permit3.approveToken(address(operatorModule), WETH, uint160(COLLATERAL + 2), 0);
        permit3.approveTaker(address(settlement), address(operatorModule), keccak256(pullData), uint160(BORROW), 0);
        permit3.approveTaker(address(settlement), address(operatorModule), keccak256(pushData), uint160(BORROW), 0);
        vm.stopPrank();

        Order memory pull = _pullOrder(23, pullData);
        bytes memory pullSig = _sign(pull);
        Order memory preFund = _preFundOrder(24, pushData);
        bytes memory pushSig = _sign(preFund);

        uint256 col0 = _wethCollateral(maker);
        uint256 debt0 = _usdcDebt(maker);
        uint256 snap = vm.snapshotState();

        // ---- A: pull-funded (wallet transit) ----
        vm.prank(solver);
        uint256 g0 = gasleft();
        settlement.fill(pull, pullSig, BORROW);
        uint256 pullGas = g0 - gasleft();
        uint256 colPull = _wethCollateral(maker) - col0;
        uint256 debtPull = _usdcDebt(maker) - debt0;

        // ---- B: pre-funded, from the SAME starting state, with the maker's
        //         receive side stripped to NOTHING ----
        vm.revertToState(snap);
        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), 0); //             no base ERC20 approval
        permit3.approveToken(address(operatorModule), WETH, 0, 0); // and no module allowance
        vm.stopPrank();
        uint256 makerWeth = IERC20(WETH).balanceOf(maker);

        vm.prank(solver);
        g0 = gasleft();
        settlement.fill(preFund, pushSig, BORROW);
        uint256 pushGas = g0 - gasleft();

        assertApproxEqAbs(_wethCollateral(maker) - col0, colPull, 2, "same collateral supplied");
        assertApproxEqAbs(_usdcDebt(maker) - debt0, debtPull, 2, "same debt drawn");
        assertEq(IERC20(WETH).balanceOf(maker), makerWeth, "the maker's wallet was never touched");
        assertEq(IERC20(WETH).balanceOf(address(operatorModule)), 0, "module drained");
        assertEq(IERC20(USDC).balanceOf(address(operatorModule)), 0, "module drained");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement drained");

        emit log_named_uint("pull-funded (gas)", pullGas);
        emit log_named_uint("pre-funded (gas)", pushGas);
        emit log_named_int("saved       (gas)", int256(pullGas) - int256(pushGas));
        assertLe(pushGas, pullGas, "one less ERC20 transfer must not cost more");
    }
}
