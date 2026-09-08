// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, LegOut} from "@core/settlement/Settlement.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Chains, Tokens} from "@coretest/data/LenderRegistry.sol";

import {IFluidVault} from "../../src/interfaces/IFluid.sol";
import {FluidTakeForModule, FluidTakeForModule} from "../../src/FluidModules.sol";
import {FluidModulesBase, IFluidVaultFactory721} from "../shared/FluidModulesBase.t.sol";

/// @dev {FluidTakeForModule} — the PRE-FUNDED twin of the `TAKE_FOR` open.
///
/// The maker signs the collateral output leg with `recipient = the module`, the
/// fill delivers it straight there, and the module supplies from its OWN balance:
/// no Permit3 token allowance to the module and no on-chain ERC20 approve of the
/// collateral to Permit3. Both grants are asserted ZERO before every pre-funded fill —
/// that absence is the feature under test. Same vault as the pull suite (mainnet
/// wstETH-USDC T1, id 14).
///
/// Pinned here:
///   1. Same-state A/B against the pull variant: identical position outcome
///      (collateral, debt), untouched maker wallet, and a cheaper fill (one less
///      ERC20 transfer).
///   2. Slicing still works on an existing position — the floor adjustment
///      (`floor = balance − forAmount`) keeps `_returnUnused` honest per slice.
///   3. A fresh open (`nftId == 0`) needs NO receive-side grant of any kind, not
///      even the ERC721 operator grant (there is no NFT to pull in).
///   4. Mis-pairing (a maker-addressed funding leg) fails closed: the module is
///      unfunded and the floor subtraction underflows before Fluid is touched.
contract FluidPreFundTakeForTest is FluidModulesBase {
    /// @dev Same vault the pull `TAKE_FOR` suite uses — vault 4's USDC borrow
    ///      limit is exhausted at the pinned block; 14 has headroom.
    address constant WSTETH_USDC_VAULT = 0x1982CC7b1570C2503282d0A0B41F69b3B28fdcc3;

    FluidTakeForModule takeForModule; // the PULL variant — the A side of the compare
    FluidTakeForModule pushModule;
    address WSTETH;

    // Constants rather than locals — these packages compile without the optimizer
    // and the A/B test below is frame-heavy.
    uint256 constant COL0 = 1 ether; //     seed collateral already in the position
    uint256 constant COL_ADD = 1 ether; //  delivered by the solver, supplied by the item
    uint256 constant DEBT_ADD = 1_000e6; // borrowed to the solver

    /// @dev Storage on purpose: set BEFORE any state snapshot, so `revertToState`
    ///      restores the same value and it costs no stack slot across the A/B run.
    uint256 posId;

    function setUp() public override {
        super.setUp();

        WSTETH = tokens[Chains.ETHEREUM_MAINNET][Tokens.WSTETH];
        takeForModule = new FluidTakeForModule(address(permit3), address(settlement));
        pushModule = new FluidTakeForModule(address(permit3), address(settlement));

        vm.label(WSTETH_USDC_VAULT, "FluidWstethUsdcVault");
        vm.label(WSTETH, "wstETH");
        vm.label(address(takeForModule), "fluidTakeForModule");
        vm.label(address(pushModule), "fluidPreFundTakeForModule");

        vm.startPrank(maker);
        // The PULL side's base grants — the pre-fund tests strip the wstETH one.
        IERC20(WSTETH).approve(address(permit3), type(uint256).max);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        // Strict-ownerOf ⇒ operator rights for JIT custody of an EXISTING position.
        // Unrelated to funding; the fresh-open test below revokes even this.
        IFluidVaultFactory721(VAULT_FACTORY).setApprovalForAll(address(takeForModule), true);
        IFluidVaultFactory721(VAULT_FACTORY).setApprovalForAll(address(pushModule), true);
        vm.stopPrank();
    }

    // ──────────────────── helpers ────────────────────

    /// @dev `preFund` (the parameter) sets descriptor bit 253 — the PRE-FUND shape, which makes the core
    ///      require `legsOut[0].recipient == module` (F27/H-1). The two variants
    ///      can therefore no longer share one blob: the shape is now part of what
    ///      the maker signs, which is the whole point — the core cannot infer it.
    function _data(uint256 nftId, uint256 totalAmount, bool preFund) internal view returns (bytes memory) {
        return abi.encode(
            FluidTakeForModule.OpenData({
                forDesc: (uint256(1) << 255)
                    | (preFund ? (uint256(1) << 253) | (uint256(uint160(WSTETH)) << 16) : 0) | 0, // fund from legsOut[0]
                forCap: 0,
                vault: WSTETH_USDC_VAULT,
                factory: VAULT_FACTORY,
                collateralToken: WSTETH,
                nftId: nftId,
                totalAmount: totalAmount
            })
        );
    }

    function _seedWstethPosition(uint256 col0) internal returns (uint256 nftId) {
        deal(WSTETH, maker, col0);
        vm.startPrank(maker);
        IERC20(WSTETH).approve(WSTETH_USDC_VAULT, col0);
        (nftId,,) = IFluidVault(WSTETH_USDC_VAULT).operate(0, int256(col0), 0, address(0));
        vm.stopPrank();
        require(nftId != 0, "seed position failed");
    }

    function _authPull(bytes memory data) internal {
        vm.startPrank(maker);
        permit3.approveToken(address(takeForModule), WSTETH, uint160(COL_ADD + 2), 0);
        permit3.approveTaker(address(settlement), address(takeForModule), keccak256(data), uint160(DEBT_ADD), 0);
        permit3.approveToken(address(settlement), USDC, uint160(DEBT_ADD), 0);
        vm.stopPrank();
    }

    /// @dev The pre-fund module's whole grant surface: ONE taker allowance (the borrow
    ///      gate) plus the settlement-side USDC allowance every levered order has.
    ///      Note what is missing: no `approveToken` for the collateral.
    function _authPreFund(bytes memory data) internal {
        vm.startPrank(maker);
        permit3.approveTaker(address(settlement), address(pushModule), keccak256(data), uint160(DEBT_ADD), 0);
        permit3.approveToken(address(settlement), USDC, uint160(DEBT_ADD), 0);
        vm.stopPrank();
    }

    /// @dev Strip the receive side to NOTHING and prove it: no on-chain ERC20
    ///      approval of the collateral to Permit3, no Permit3 token allowance to
    ///      the pre-fund module (the pull module's is zeroed too, so nothing could
    ///      fund a pull path by accident).
    function _stripAndAssertZeroReceiveSide() internal {
        vm.startPrank(maker);
        IERC20(WSTETH).approve(address(permit3), 0);
        permit3.approveToken(address(takeForModule), WSTETH, 0, 0);
        vm.stopPrank();

        assertEq(IERC20(WSTETH).allowance(maker, address(permit3)), 0, "no ERC20 approval of the collateral to Permit3");
        (uint160 amt,) = permit3.tokenAllowance(maker, address(pushModule), WSTETH);
        assertEq(amt, 0, "no Permit3 token allowance to the pre-fund module");
    }

    function _pullOrder(uint256 nonce, bytes memory data) internal view returns (Order memory) {
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE_FOR, address(takeForModule), DEBT_ADD, address(0), data);
        return _order(maker, nonce, USDC, WSTETH, DEBT_ADD, COL_ADD, items);
    }

    /// @dev Identical order, two changes: the item names the pre-fund module and the
    ///      collateral leg is delivered TO it ({Base._forSlice} admits the item's
    ///      own module as the referenced leg's recipient).
    function _preFundOrder(uint256 nonce, bytes memory data) internal view returns (Order memory o) {
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE_FOR, address(pushModule), DEBT_ADD, address(0), data);
        o = _order(maker, nonce, USDC, WSTETH, DEBT_ADD, COL_ADD, items);
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(WSTETH, COL_ADD, 0, address(pushModule)); // ← delivered to the module
        o.legsOut = PackedEncode.legsOut(legsOut);
    }

    /// @dev Own frame (stack headroom without the optimizer): sign, fill whole,
    ///      close, report gas + the position the fill built.
    function _fillAndClose(Order memory o) internal returns (uint256 gasUsed, uint256 col, uint256 debt) {
        bytes memory sig = _sign(o);
        vm.prank(solver);
        uint256 g0 = gasleft();
        settlement.fill(o, sig, DEBT_ADD);
        gasUsed = g0 - gasleft();
        (col, debt) = _closeAndMeasure(posId, (DEBT_ADD * 101) / 100);
    }

    function _closeAndMeasure(uint256 nftId, uint256 usdcBudget) internal returns (uint256 col, uint256 debt) {
        deal(USDC, maker, usdcBudget);
        vm.startPrank(maker);
        IERC20(USDC).approve(WSTETH_USDC_VAULT, usdcBudget);
        (, int256 colOut, int256 debtOut) =
            IFluidVault(WSTETH_USDC_VAULT).operate(nftId, type(int256).min, type(int256).min, maker);
        vm.stopPrank();
        col = uint256(-colOut);
        debt = uint256(-debtOut);
    }

    // ──────────── 1. A/B: same outcome as the pull variant, zero receive-side grants ────────────

    function test_preFundFunded_samePosition_zeroReceiveSideApprovals_andCostsLess() public {
        posId = _seedWstethPosition(COL0);
        deal(WSTETH, solver, COL_ADD * 2); // ceil headroom on a per-fill-ceil SELL leg
        _approveSolverSide(COL_ADD * 2, WSTETH);

        bytes memory pullData = _data(posId, DEBT_ADD, false);
        bytes memory pushData = _data(posId, DEBT_ADD, true);
        _authPull(pullData);
        _authPreFund(pushData);

        uint256 snap = vm.snapshotState();

        // ---- A: pull-funded (wallet transit) ----
        (uint256 pullGas, uint256 pullCol, uint256 pullDebt) = _fillAndClose(_pullOrder(1, pullData));

        // ---- B: pre-funded, from the SAME starting state, with the maker's
        //         receive side stripped to NOTHING ----
        vm.revertToState(snap);
        _stripAndAssertZeroReceiveSide();

        Order memory preFund = _preFundOrder(2, pushData);
        bytes memory sig = _sign(preFund);
        uint256 makerWsteth = IERC20(WSTETH).balanceOf(maker);

        vm.prank(solver);
        uint256 g0 = gasleft();
        settlement.fill(preFund, sig, DEBT_ADD);
        uint256 pushGas = g0 - gasleft();

        assertEq(IERC20(WSTETH).balanceOf(maker), makerWsteth, "the maker's wallet was never touched");
        assertEq(IERC20(WSTETH).balanceOf(address(pushModule)), 0, "module back to its pre-fill floor");
        assertEq(_ownerOf(posId), maker, "NFT handed straight back");
        assertEq(IERC20(USDC).balanceOf(solver), DEBT_ADD, "solver received the whole borrow");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement drained");

        (uint256 col, uint256 debt) = _closeAndMeasure(posId, (DEBT_ADD * 101) / 100);
        assertApproxEqAbs(col, pullCol, 2, "same collateral supplied as the pull variant");
        assertApproxEqAbs(debt, pullDebt, 2, "same debt drawn as the pull variant");

        emit log_named_uint("pull-funded (gas)", pullGas);
        emit log_named_uint("pre-funded (gas)", pushGas);
        emit log_named_int("saved       (gas)", int256(pullGas) - int256(pushGas));
        assertLt(pushGas, pullGas, "one less ERC20 transfer must not cost more");
    }

    // ──────────── 2. an existing position still slices, floor kept honest per slice ────────────

    function test_preFundFunded_existingPosition_partialFills_oneOperatePerSlice() public {
        posId = _seedWstethPosition(COL0);
        deal(WSTETH, solver, COL_ADD * 2);
        _approveSolverSide(COL_ADD * 2, WSTETH);

        bytes memory data = _data(posId, DEBT_ADD, true);
        _authPreFund(data);
        _stripAndAssertZeroReceiveSide();

        Order memory o = _preFundOrder(3, data);
        bytes memory sig = _sign(o);
        uint256 makerWsteth = IERC20(WSTETH).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, DEBT_ADD / 2);
        assertEq(IERC20(WSTETH).balanceOf(maker), makerWsteth, "wallet untouched after slice 1");
        assertEq(_ownerOf(posId), maker, "NFT handed straight back after slice 1");

        vm.prank(solver);
        settlement.fill(o, sig, DEBT_ADD - DEBT_ADD / 2);
        assertEq(IERC20(WSTETH).balanceOf(maker), makerWsteth, "wallet untouched after slice 2");
        assertEq(_ownerOf(posId), maker, "NFT handed back after slice 2");

        assertEq(IERC20(USDC).balanceOf(solver), DEBT_ADD, "solver received the whole borrow");
        assertEq(IERC20(WSTETH).balanceOf(address(pushModule)), 0, "module drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement drained");

        // ONE position, grown by both slices — the same outcome the pull suite pins.
        (uint256 col, uint256 debt) = _closeAndMeasure(posId, (DEBT_ADD * 101) / 100);
        assertApproxEqRel(col, COL0 + COL_ADD, 1e15, "collateral = seed + both slices");
        assertApproxEqRel(debt, DEBT_ADD, 1e15, "debt = the whole borrow");
    }

    // ──────────── 3. a fresh open needs NO receive-side grant of any kind ────────────

    /// Not even the ERC721 operator grant: `nftId == 0` mints to the module and is
    /// handed over, so there is no NFT to pull in. The maker's whole grant surface
    /// is the signed taker allowance (plus the USDC input-leg allowance every
    /// levered order has).
    function test_preFundFunded_freshOpen_fullFill_noReceiveSideGrantsAtAll() public {
        deal(WSTETH, solver, COL_ADD);
        _approveSolverSide(COL_ADD, WSTETH);

        bytes memory data = _data(0, DEBT_ADD, true);
        _authPreFund(data);
        _stripAndAssertZeroReceiveSide();
        vm.prank(maker);
        IFluidVaultFactory721(VAULT_FACTORY).setApprovalForAll(address(pushModule), false);

        uint256 before_ = IFluidVaultFactory721(VAULT_FACTORY).balanceOf(maker);

        Order memory o = _preFundOrder(4, data);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, DEBT_ADD);

        assertEq(IFluidVaultFactory721(VAULT_FACTORY).balanceOf(maker) - before_, 1, "exactly one new position");
        assertEq(IERC20(USDC).balanceOf(solver), DEBT_ADD, "solver received the borrow");
        assertEq(IERC20(WSTETH).balanceOf(maker), 0, "the delivery never touched the maker's wallet");
        assertEq(IERC20(WSTETH).balanceOf(address(pushModule)), 0, "module drained");
    }

    // ──────────── 4. mis-pairing fails closed ────────────

    /// A maker-addressed funding leg on the PRE-FUND module leaves it unfunded: the
    /// `floor = balance − forAmount` subtraction underflows before Fluid is
    /// touched. Nothing supplied, nothing stranded — the header's pairing rule.
    function test_preFundModule_makerAddressedLeg_failsClosed() public {
        posId = _seedWstethPosition(COL0);
        deal(WSTETH, solver, COL_ADD);
        _approveSolverSide(COL_ADD, WSTETH);

        bytes memory data = _data(posId, DEBT_ADD, true);
        _authPreFund(data);

        // The pre-fund item, but the collateral leg mistakenly stays maker-addressed.
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE_FOR, address(pushModule), DEBT_ADD, address(0), data);
        Order memory o = _order(maker, 5, USDC, WSTETH, DEBT_ADD, COL_ADD, items);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(); // arithmetic underflow in the floor computation
        settlement.fill(o, sig, DEBT_ADD);
    }
}
